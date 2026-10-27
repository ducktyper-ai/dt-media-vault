"""sow: dt-media-vault-SOW-01

Actual read-only verifier/CLI controls against disposable synthetic local files.
"""
import contextlib
import io
import json
import os
import stat
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from click.testing import CliRunner

from media_toolkit import verifier
from media_toolkit.utils.hash import compute_file_hash


class VerifierSafety(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vfy-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "target"
        self.root.mkdir()
        self.file = self.root / "clip.bin"
        self.file.write_bytes(b"synthetic fixture, never original media")
        self.digest = compute_file_hash(self.file)
        self.manifest = self.base / "manifest.json"
        self.write_manifest()

    def write_manifest(self, files=None, **fields):
        entries = ([{"target_path": "/clip.bin", "hash": self.digest}]
                   if files is None else files)
        self.manifest.write_text(json.dumps(dict(total_files=len(entries), files=entries,
                                                **fields)))

    def snapshot(self):
        entries = {}
        for p in self.base.rglob("*"):
            mode = stat.S_IMODE(p.lstat().st_mode)
            if p.is_symlink():
                value = ("symlink", os.readlink(p), mode)
            elif p.is_dir():
                value = ("directory", None, mode)
            else:
                value = ("file", p.read_bytes(), mode)
            entries[str(p.relative_to(self.base))] = value
        return entries

    def invoke(self, module=verifier, root=None):
        before = self.snapshot()
        result = CliRunner().invoke(module.main, ["--manifest", str(self.manifest),
                                                  "--target", str(root or self.root)])
        self.assertEqual(self.snapshot(), before, "verification must not mutate fixtures")
        self.assertNotIn("Safe to clean", result.output)
        return result

    def assert_read_error_rejected(self, module=verifier):
        with patch.object(module, "verify_file_hash", side_effect=OSError("synthetic read error")):
            result = self.invoke(module)
        self.assertNotEqual(result.exit_code, 0, result.output)
        self.assertNotIn("Verified all", result.output)

    def assert_missing_rejected(self, module=verifier):
        self.write_manifest([{"target_path": "missing.bin", "hash": self.digest}])
        result = self.invoke(module)
        self.assertNotEqual(result.exit_code, 0, result.output)

    def assert_duplicate_coverage(self, module=verifier):
        second = self.root / "copy.bin"
        second.write_bytes(self.file.read_bytes())
        self.write_manifest([{"target_path": name, "hash": self.digest, "is_duplicate": True}
                             for name in ("clip.bin", "copy.bin")])
        result = self.invoke(module)
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("Verified all 2 manifest entries", result.output)
        self.write_manifest([{"target_path": name, "hash": self.digest, "is_duplicate": True}
                             for name in ("clip.bin", "missing.bin")])
        result = self.invoke(module)
        self.assertNotEqual(result.exit_code, 0, result.output)

    def test_matching_file_and_legacy_root_relative_path(self):
        result = self.invoke()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("Verified all 1 manifest entries", result.output)

    def test_actual_module_cli_subprocess(self):
        import subprocess
        import sys
        before = self.snapshot()
        for digest, expected in ((self.digest, 0), ("0" * 64, 1)):
            self.write_manifest([{"target_path": "clip.bin", "hash": digest}])
            result = subprocess.run([sys.executable, "-m", "media_toolkit.verifier",
                                     "--manifest", str(self.manifest), "--target", str(self.root)],
                                    env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertNotIn("Safe to clean", result.stdout)
        self.write_manifest()
        self.assertEqual(self.snapshot(), before)

    def test_read_error_is_nonzero(self):
        self.assert_read_error_rejected()

    def test_missing_file_is_nonzero(self):
        self.assert_missing_rejected()

    def test_corrupt_file_is_nonzero(self):
        self.write_manifest([{"target_path": "clip.bin", "hash": "0" * 64}])
        self.assertNotEqual(self.invoke().exit_code, 0)

    def test_every_duplicate_entry_is_checked(self):
        self.assert_duplicate_coverage()

    def test_manifest_omission_and_invalid_totals_refuse(self):
        for total in (2, -1, True, "1", None):
            with self.subTest(total=total):
                self.write_manifest()
                data = json.loads(self.manifest.read_text())
                data['total_files'] = total
                self.manifest.write_text(json.dumps(data))
                result = self.invoke()
                self.assertNotEqual(result.exit_code, 0)
                self.assertNotIn("Verified all", result.output)

    def test_invalid_manifest_shapes_and_json_refuse(self):
        for data in ([], {}, {"files": {}, "total_files": 0},
                     {"files": [None], "total_files": 1}):
            with self.subTest(data=data):
                self.manifest.write_text(json.dumps(data))
                self.assertNotEqual(self.invoke().exit_code, 0)
        self.manifest.write_text("not JSON")
        self.assertNotEqual(self.invoke().exit_code, 0)

    def test_preview_or_malformed_digest_refuses(self):
        for digest in ("DRY_RUN", "", None, "x" * 64):
            with self.subTest(digest=digest):
                self.write_manifest([{"target_path": "clip.bin", "hash": digest}])
                self.assertNotEqual(self.invoke().exit_code, 0)

    def test_empty_manifest_is_explicitly_empty(self):
        self.write_manifest([])
        result = self.invoke()
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIn("Empty manifest: no files checked", result.output)
        self.assertNotIn("Verified all", result.output)

    def test_absent_or_nondirectory_root_is_not_created(self):
        absent = self.base / "absent"
        self.assertNotEqual(self.invoke(root=absent).exit_code, 0)
        self.assertFalse(absent.exists())
        self.assertNotEqual(self.invoke(root=self.file).exit_code, 0)
        subject = verifier.MigrationVerifier(self.manifest, absent)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(subject.verify())
        alias = self.base / "root-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.assertNotEqual(self.invoke(root=alias).exit_code, 0)

    def test_target_escape_symlink_directory_or_missing_field_refuses(self):
        outside = self.base / "outside.bin"
        outside.write_bytes(self.file.read_bytes())
        (self.root / "alias.bin").symlink_to(outside)
        (self.root / "directory").mkdir()
        for target in ("../outside.bin", "//outside.bin", "alias.bin", "directory", "", None):
            with self.subTest(target=target):
                self.write_manifest([{"target_path": target, "hash": self.digest}])
                self.assertNotEqual(self.invoke().exit_code, 0)
        self.write_manifest([{"hash": self.digest}])
        self.assertNotEqual(self.invoke().exit_code, 0)

    def test_repeated_verification_resets_outcome(self):
        subject = verifier.MigrationVerifier(self.manifest, self.root)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(subject.verify())
            with patch.object(verifier, "verify_file_hash", side_effect=OSError("synthetic")):
                self.assertFalse(subject.verify())
            self.assertEqual(subject.verified_count, 0)
            self.assertEqual(len(subject.errors), 1)
            self.assertTrue(subject.verify())
        self.assertEqual(subject.verified_count, 1)
        self.assertEqual(subject.errors, [])

    def test_mutations_are_assertion_killed(self):
        source = Path(verifier.__file__).read_text()
        predicate = ("not self.errors and self.missing_count == 0 and\n"
                     "                    self.corrupted_count == 0 and\n"
                     "                    self.verified_count == self.expected_count")
        variants = (
            (predicate, "self.missing_count == 0 and self.corrupted_count == 0",
             self.assert_read_error_rejected),
            ('raise click.ClickException("verification incomplete")', 'return',
             self.assert_missing_rejected),
            ('# Duplicate classification is a report, never permission to omit coverage.',
             "files_to_verify = [f for f in files_to_verify if not f.get('is_duplicate', False)]",
             self.assert_duplicate_coverage),
        )
        for before, after, assertion in variants:
            with self.subTest(mutation=before):
                self.write_manifest()
                self.assertEqual(source.count(before), 1, "mutation anchor changed")
                module = types.ModuleType("media_toolkit._synthetic_verifier_mutant")
                module.__package__ = "media_toolkit"
                exec(compile(source.replace(before, after, 1), "<synthetic-mutant>", "exec"),
                     module.__dict__)
                with self.assertRaises(AssertionError):
                    assertion(module)


if __name__ == "__main__":
    unittest.main()
