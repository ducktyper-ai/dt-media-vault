"""Synthetic hook and diagnostics checks; no push, media, or network."""
# sow: public
import importlib.util
import contextlib
import io
import os
from types import SimpleNamespace
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("devtools", ROOT / "scripts/devtools.py")
TOOLS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOLS)


class HookControls(unittest.TestCase):
    def invoke(self, directory, updates, arguments=("origin", "synthetic")):
        hook = directory / "pre-push"
        hook.write_bytes((ROOT / "scripts/pre-push.sh").read_bytes())
        return subprocess.run(["sh", str(hook), *arguments], input=updates,
                              capture_output=True, text=True, check=False,
                              env=dict(os.environ, TMPDIR=str(directory)))

    def test_refuses_main_update_and_delete_and_mixed_push(self):
        for update in ("refs/heads/work abc refs/heads/main def\n",
                       "refs/heads/work abc refs/heads/main def",
                       "(delete) 000 refs/heads/main def\n",
                       "refs/heads/work abc refs/heads/work def\n"
                       "refs/heads/other abc refs/heads/main def\n"):
            with self.subTest(update=update), tempfile.TemporaryDirectory() as tmp:
                result = self.invoke(Path(tmp), update)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("REFUSED", result.stderr)

    def test_feature_push_chains_previous_hook_with_updates(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            previous = directory / "pre-push.media-vault-previous"
            previous.write_text('#!/bin/sh\ncat > "$(dirname "$0")/seen"\nexit 23\n')
            previous.chmod(0o755)
            updates = "refs/heads/work abc refs/heads/work def\n"
            result = self.invoke(directory, updates)
            self.assertEqual(result.returncode, 23)
            self.assertEqual((directory / "seen").read_text(), updates)

    def test_prior_hook_receives_exact_empty_trailing_input_and_arguments(self):
        cases = ("", "\n", "refs/heads/work abc refs/heads/work def",
                 "refs/heads/work abc refs/heads/work def\n\n")
        arguments = ("origin with space", "synthetic endpoint")
        for updates in cases:
            with self.subTest(updates=updates), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                previous = directory / "pre-push.media-vault-previous"
                previous.write_text(
                    '#!/bin/sh\nprintf "%s\\000" "$@" > "$(dirname "$0")/argv"\n'
                    'cat > "$(dirname "$0")/seen"\nexit 23\n'
                )
                previous.chmod(0o755)
                result = self.invoke(directory, updates, arguments)
                self.assertEqual(result.returncode, 23)
                self.assertEqual((directory / "seen").read_bytes(), updates.encode())
                self.assertEqual((directory / "argv").read_bytes(),
                                 b"origin with space\0synthetic endpoint\0")
                self.assertEqual(list(directory.glob("dt-media-vault-pre-push.*")), [])

    def test_rejected_push_does_not_call_previous(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            previous = directory / "pre-push.media-vault-previous"
            previous.write_text('#!/bin/sh\ntouch "$(dirname "$0")/called"\n')
            previous.chmod(0o755)
            self.invoke(directory, "refs/heads/work abc refs/heads/main def\n")
            self.assertFalse((directory / "called").exists())

    def test_installer_preserves_hook_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            hook = Path(tmp) / "hooks/pre-push"
            hook.parent.mkdir()
            original = b"#!/bin/sh\nexit 23\n"
            hook.write_bytes(original)
            hook.chmod(0o755)
            with patch.object(TOOLS, "hook_location", return_value=hook):
                self.assertEqual(TOOLS.hooks(), 0)
                self.assertEqual(TOOLS.hooks(), 0)
            self.assertEqual(hook.with_name("pre-push.media-vault-previous").read_bytes(), original)

    def test_installer_refuses_existing_backup_without_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            hook = Path(tmp) / "pre-push"
            backup = hook.with_name("pre-push.media-vault-previous")
            backup.write_bytes(b"held")
            with patch.object(TOOLS, "hook_location", return_value=hook):
                with self.assertRaisesRegex(RuntimeError, "refusing"):
                    TOOLS.hooks()
            self.assertEqual(backup.read_bytes(), b"held")
            self.assertFalse(hook.exists())

    def test_custom_hook_location_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            common = Path(tmp) / "git"
            custom = Path(tmp) / "custom/pre-push"
            with patch.object(TOOLS, "git", side_effect=[str(common), str(custom)]):
                with self.assertRaisesRegex(RuntimeError, "custom core.hooksPath"):
                    TOOLS.hook_location()

    def test_doctor_does_not_mutate_or_print_environment_values(self):
        def version(command, **kwargs):
            output = {"ruff": "ruff 0.17.4\n", "mypy": "mypy 2.4.1 (compiled: yes)\n"}.get(command[0], "version fixture\n")
            return SimpleNamespace(returncode=0, stdout=output)

        with tempfile.TemporaryDirectory() as tmp:
            capture = io.StringIO()
            with patch.object(TOOLS, "hook_location", return_value=Path(tmp) / "missing"), \
                    patch.object(TOOLS.shutil, "which", side_effect=lambda name: name), \
                    patch.object(TOOLS.metadata, "version", return_value="999.0.0"), \
                    patch.object(TOOLS.subprocess, "run", side_effect=version), \
                    patch.dict(os.environ, {"SOURCE_VOLUME": "PRIVATE_VALUE_NOT_FOR_OUTPUT"}), \
                    patch.object(Path, "write_bytes") as write, \
                    patch.object(Path, "mkdir") as mkdir, \
                    contextlib.redirect_stdout(capture):
                self.assertEqual(TOOLS.doctor(), 1)  # Missing hook is actionable, not a pass.
                write.assert_not_called()
                mkdir.assert_not_called()
            self.assertNotIn("PRIVATE_VALUE_NOT_FOR_OUTPUT", capture.getvalue())
            self.assertIn("FIX main-push guard", capture.getvalue())

    def test_symlink_hook_refused_without_modification(self):
        with tempfile.TemporaryDirectory() as tmp:
            common = Path(tmp)
            (common / "hooks").mkdir()
            target = common / "original"
            target.write_text("held")
            hook = common / "hooks/pre-push"
            hook.symlink_to(target)
            with patch.object(TOOLS, "git", side_effect=[str(common), str(hook)]):
                with self.assertRaisesRegex(RuntimeError, "symlink"):
                    TOOLS.hook_location()
            self.assertEqual(target.read_text(), "held")

    def test_scope_rejects_product_or_lock_changes(self):
        # The full gate itself exercises phase checks; these inputs must remain out of scope.
        text = (ROOT / "scripts/verify-source.sh").read_text()
        section = text.split("def check_makefile_scope(names):", 1)[1].split("def check_lock_phase", 1)[0]
        namespace = {"require": lambda ok, reason: None if ok else (_ for _ in ()).throw(ValueError(reason))}
        exec("def check_makefile_scope(names):" + section, namespace)
        required = {"Makefile", "scripts/devtools.py", "scripts/pre-push.sh",
                    "uv.lock", "requirements-gate-universal.lock", "pyproject.toml"}
        namespace["check_makefile_scope"](required)
        for extra in ("src/media_toolkit/migrator.py", "requirements-gate.lock", "src/media_toolkit/analyzer.py"):
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                namespace["check_makefile_scope"](required | {extra})


if __name__ == "__main__":
    unittest.main()
