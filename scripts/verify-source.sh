#!/bin/bash
# sow: dt-media-vault-SOW-01
# Offline owning gate: source controls plus synthetic local verifier safety tests.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import ast
import difflib
import hashlib
import io
import json
import os
import posixpath
import re
import shlex
import subprocess
import sys
import tabnanny
import tempfile
import tokenize
import unittest
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit

BASELINE = "cf3bc5a48e108ed6f2a0a929a189b281bfc14ada"
VERIFIER_PHASE_BASELINE = "b3b21531e7f372e41d9dc7ae4142724de04e1c28"
CLEANUP_BASELINE = "4b355d39aafc229742ccb03448726ad0e83e8884"
SOW = "sow: dt-media-vault-SOW-01"
CLEANUP_SOW = "sow: dt-media-vault-SOW-02"
LOCK_SOW = "sow: dt-media-vault-SOW-03"
PUBLIC_SOW = "sow: public"
LOCK = "requirements-gate.lock"
LOCK_BYTES = 912
LOCK_SHA256 = "321934de86581ce858defa66c9fa9af70ba48a23eb687bf3524b006a5366da4e"
LOCK_PRIMARY_COMMIT = "73fd96105173fa2b90c626127a0c1ebd84687909"
# Bind only after actual reviewed PR4 merge and immutable source readback.
LOCK_PHASE_BASELINE = "9093d47ae0e07f628385dc1ebf3e696b922f6204"
MEMO = "docs/design/sow-01-media-vault-design.md"
INDEX = "docs/evidence/INDEX.json"
ARCHIVE_BYTES = 30132
ARCHIVE_SHA256 = "d6b8a7d2a411c2a17ccd3d4ec331aad66536c9748659507d0a1e879563653c3b"
ROOT = Path.cwd()
ENV = dict(os.environ, LC_ALL="C", MAKEFLAGS="", MFLAGS="")


def run(args, **kwargs):
    return subprocess.run(
        args, capture_output=True, text=True, timeout=30,
        env=kwargs.pop("env", ENV), **kwargs
    )


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def lint_python(text):
    # Compile only: never import or execute application source, create pyc, or scan data.
    compile(ast.parse(text), "<source>", "exec")
    tabnanny.process_tokens(tokenize.generate_tokens(io.StringIO(text).readline))


def check_document(text, name, tracked):
    require(SOW in text.splitlines(), "missing standalone SOW line")
    require(not any(line.rstrip() != line for line in text.splitlines()),
            "document trailing whitespace")
    fences = [line for line in text.splitlines() if line.startswith("```")]
    require(len(fences) % 2 == 0, "unclosed document fence")
    # Check inline links against Git's tracked paths, without filesystem traversal
    # or network requests. Remote link availability stays an independent review task.
    for destination in re.findall(r"\[[^\]]+\]\(([^\s)]+)\)", text):
        url = urlsplit(destination)
        if url.scheme:
            require(url.scheme in {"https", "mailto"}, "unsupported link scheme")
            if url.scheme == "https":
                require(bool(url.netloc), "HTTPS link missing host")
            continue
        require(not url.netloc, "network-path link")
        target = unquote(url.path)
        if not target:
            continue
        require(not target.startswith("/"), "absolute local link")
        relative = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
        require(relative != ".." and not relative.startswith("../"),
                "local link outside repository")
        require(relative in tracked, "local link not tracked")


def check_public_artifact(name, text):
    # A finite public-source boundary, not a general personal-data/secret detector.
    path = PurePosixPath(name)
    forbidden_parts = {"analysis_results", "inventories", "private", "credentials"}
    require(not forbidden_parts.intersection(path.parts), "private artifact directory")
    require(not path.name.startswith(".env"), "environment artifact")
    require(path.suffix.lower() not in {
        ".sqlite", ".sqlite3", ".db", ".csv", ".mp4", ".mov", ".wav",
        ".jpg", ".jpeg", ".png", ".pem", ".key",
    }, "inventory, credential or media artifact")
    require(not re.search(r"/(?:Volumes|Users|home)/", text),
            "host or personal absolute path")
    require(not re.search(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", text),
            "private key material")


def check_source_scope(names):
    # Exact amendment: verifier and its synthetic tests only; other product code stays intact.
    allowed = {MEMO, "Makefile", "scripts/verify-source.sh",
               "README.md", "README_GETTING_STARTED.md",
               "src/media_toolkit/verifier.py", "tests/test_verifier_safety.py"}
    require(set(names) <= allowed, "change outside finite design/gate/verifier scope")
    require(MEMO in names, "design memo missing from source slice")


def check_verifier_phase_scope(names):
    # Council X1: the historical baseline still includes Makefile, this phase cannot change it.
    allowed = {MEMO, "scripts/verify-source.sh", "README.md", "README_GETTING_STARTED.md",
               "src/media_toolkit/verifier.py", "tests/test_verifier_safety.py"}
    require(set(names) <= allowed, "change outside Council six-path verifier exception")



def check_cleanup_scope(names):
    # Exact INDEX cleanup allocation, no product changes.
    allowed = {MEMO, INDEX, "README.md", "README_GETTING_STARTED.md", "scripts/verify-source.sh"}
    require(set(names) <= allowed, "change outside approved cleanup phase")
    require(MEMO in names, "approved memo removal missing")
    require(set(names) == allowed, "cleanup must include the complete approved path set")


def check_lock_phase(names, payload):
    # One exact dependency-lock phase only.
    require(set(names) == {LOCK}, "lock phase paths differ from exact allocation")
    require(len(payload) == LOCK_BYTES, "lock phase byte count mismatch")
    require(hashlib.sha256(payload).hexdigest() == LOCK_SHA256,
            "lock phase SHA256 mismatch")


def check_lock_commit_record(commit, message):
    # The original directly authorised commit alone predates the normal SOW03 file.
    expected = CLEANUP_SOW if commit == LOCK_PRIMARY_COMMIT else LOCK_SOW
    require(expected in message.splitlines() or PUBLIC_SOW in message.splitlines(),
            "lock commit missing standalone SOW coverage")


def check_lock_commit_messages(baseline, head, directory=None):
    environment = ENV if directory is None else fixture_git_environment()
    result = run(["git", "rev-list", "--no-merges", baseline + ".." + head],
                 cwd=directory, env=environment)
    require(result.returncode == 0, "cannot enumerate lock phase commits")
    commits = result.stdout.splitlines()
    require(bool(commits), "lock phase has no covered implementation commits")
    for commit in commits:
        message = run(["git", "show", "-s", "--format=%B", commit],
                      cwd=directory, env=environment)
        require(message.returncode == 0, "cannot read lock phase commit")
        check_lock_commit_record(commit, message.stdout)


def check_memo_index(text):
    # Exact pins of the independently byte-verified staged historical memo.
    value = json.loads(text)
    require(isinstance(value, dict), "archive index object required")
    records = value.get("records")
    require(isinstance(records, list) and len(records) == 1,
            "missing or duplicate archive index row")
    row = records[0]
    require(isinstance(row, dict), "archive index row invalid")
    require(set(row) == {"path", "bytes", "sha256"}, "archive index field set mismatch")
    require(row.get("path") == MEMO, "archived memo path mismatch")
    require(type(row.get("bytes")) is int and row["bytes"] == ARCHIVE_BYTES,
            "archived memo byte count mismatch")
    require(row.get("sha256") == ARCHIVE_SHA256, "archived memo SHA256 mismatch")


def added_text(before, after):
    old, new = before.splitlines(), after.splitlines()
    return "\n".join(
        line
        for tag, _i, _j, start, end in difflib.SequenceMatcher(a=old, b=new).get_opcodes()
        if tag in {"insert", "replace"}
        for line in new[start:end]
    )


def fixture_git_environment():
    # Keep transport/policy settings; prevent inherited paths redirecting fixture writes.
    locations = {"GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"}
    return {key: value for key, value in ENV.items() if key not in locations}


def check_commit_messages(baseline, head="HEAD", directory=None, sow_line=SOW,
                          allow_public=False):
    # Integration commits inherit SOW coverage; audit every non-merge on every side.
    result = run(["git", "log", "--no-merges", "--format=%B%x00",
                  baseline + ".." + head], cwd=directory,
                 env=ENV if directory is None else fixture_git_environment())
    require(result.returncode == 0, "cannot read source commits")
    for message in filter(str.strip, result.stdout.split("\0")):
        require(sow_line in message.splitlines()
                or (allow_public and PUBLIC_SOW in message.splitlines()),
                "commit missing standalone SOW line")


def commit_graph_fixture(directory, side_message=None):
    # Disposable local bare Git graph only; no hooks, remote or application execution.
    environment = fixture_git_environment()
    initialized = run(["git", "init", "--bare", "--quiet", str(directory)],
                      env=environment)
    require(initialized.returncode == 0, "cannot initialize commit fixture")
    prefix = ["git", "-C", str(directory), "-c", "user.name=Gate Fixture",
              "-c", "user.email=gate-fixture@example.invalid",
              "-c", "commit.gpgSign=false"]
    tree = run([*prefix, "mktree"], input="", env=environment)
    require(tree.returncode == 0, "cannot create fixture tree")

    def commit(message, *parents):
        arguments = [*prefix, "commit-tree", tree.stdout.strip()]
        for parent in parents:
            arguments += ["-p", parent]
        result = run(arguments, input=message + "\n", env=environment)
        require(result.returncode == 0, "cannot create fixture commit")
        return result.stdout.strip()

    baseline = commit("fixture baseline excluded from audit")
    left = commit("left implementation\n\n" + SOW, baseline)
    right = commit("right implementation\n\n" + SOW
                   if side_message is None else side_message, baseline)
    merged = commit("GitHub-style merge without its own SOW line", left, right)
    return baseline, merged, commit


NAS_TARGETS = ("check-volumes", "analyze-dry", "analyze", "migrate",
               "verify-migration", "index-catalog", "link-project")


def assert_storage_refused(makefile, target, directory, make_options=()):
    # Only synthetic local roots and a recording worker; no application execution.
    marker = directory / "worker-called"
    worker = directory / "worker.py"
    worker.write_text("from pathlib import Path\nPath('worker-called').touch()\n")
    (directory / "source").mkdir(exist_ok=True)
    (directory / "target").mkdir(exist_ok=True)
    result = run(["make", "--no-print-directory", "-rR", "-f", str(makefile), *make_options, target,
                  "SOURCE_VOLUME=" + str(directory / "source"),
                  "TARGET_VOLUME=" + str(directory / "target"),
                  "PYTHON=" + shlex.join([sys.executable, str(worker)])],
                 cwd=directory, input="\n")
    require(result.returncode != 0 and "NAS_WORKFLOW_DISABLED" in result.stderr
            and not marker.exists(), "storage refusal failed: " + target)


class GateControls(unittest.TestCase):
    def test_commit_sow_accepts_merge_with_covered_parents(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            baseline, merged, _commit = commit_graph_fixture(directory)
            check_commit_messages(baseline, merged, directory)

    def test_commit_sow_rejects_linear_missing_or_nonstandalone_line(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            baseline, merged, commit = commit_graph_fixture(directory)
            for message in ("missing implementation reference", "prefix " + SOW):
                with self.subTest(message=message), self.assertRaisesRegex(
                        ValueError, "commit missing standalone SOW line"):
                    check_commit_messages(baseline, commit(message, merged), directory)

    def test_commit_sow_rejects_uncovered_second_parent_history(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            baseline, merged, _commit = commit_graph_fixture(
                directory, "side implementation missing SOW")
            with self.assertRaisesRegex(ValueError, "commit missing standalone SOW line"):
                check_commit_messages(baseline, merged, directory)

    def test_python_valid_and_rejects_syntax(self):
        lint_python("def identity(value):\n    return value\n")
        with self.assertRaises(SyntaxError):
            lint_python("def broken(:\n    pass\n")

    def test_python_rejects_indentation(self):
        with self.assertRaises((SyntaxError, tabnanny.NannyNag)):
            lint_python("if True:\n  value = 1\n value = 2\n")

    def test_document_link_and_sow(self):
        text = SOW + "\n\n[Code](../../src/example.py)\n"
        check_document(text, "docs/design/plan.md", {"src/example.py"})
        with self.assertRaises(ValueError):
            check_document(text, "docs/design/plan.md", set())
        with self.assertRaises(ValueError):
            check_document("[Code](../../src/example.py)\n", "docs/design/plan.md",
                           {"src/example.py"})

    def test_document_rejects_escape_and_unclosed_fence(self):
        for tail in ("[Outside](../../../outside.md)", "```sh\ntrue\n"):
            with self.subTest(tail=tail), self.assertRaises(ValueError):
                check_document(SOW + "\n" + tail, MEMO, set())

    def test_public_boundary_accepts_synthetic_design(self):
        check_public_artifact(MEMO, SOW + "\nMedia/Originals/<source-id>/\n")

    def test_public_boundary_rejects_private_artifacts_and_content(self):
        samples = [
            ("inventories/scan.json", "{}"),
            ("catalog.sqlite", ""),
            (".env.local", ""),
            (MEMO, "/Volu" + "mes/example/personal.mov"),
            (MEMO, "-----BE" + "GIN PRIVATE KEY-----"),
        ]
        for name, text in samples:
            with self.subTest(name=name), self.assertRaises(ValueError):
                check_public_artifact(name, text)

    def test_scope_rejects_product_or_dependency_changes(self):
        check_source_scope([MEMO, "Makefile", "scripts/verify-source.sh"])
        check_source_scope([MEMO, "src/media_toolkit/verifier.py",
                            "tests/test_verifier_safety.py"])
        check_verifier_phase_scope([MEMO, "src/media_toolkit/verifier.py",
                                   "tests/test_verifier_safety.py"])
        for name in ("Makefile", "src/media_toolkit/migrator.py", "pyproject.toml"):
            with self.subTest(phase_path=name), self.assertRaises(ValueError):
                check_verifier_phase_scope([MEMO, name])
        for name in ("src/media_toolkit/migrator.py", "pyproject.toml"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                check_source_scope([MEMO, name])

    def test_privacy_checks_new_text_without_reclassifying_legacy_source(self):
        legacy = "LEGACY_ROOT=/Volu" + "mes/example\n"
        safe = legacy + "verify: verify-source\n"
        check_public_artifact("Makefile", added_text(legacy, safe))
        with self.assertRaises(ValueError):
            check_public_artifact("Makefile", added_text(legacy, safe + legacy))

    def test_shell_syntax_accept_and_reject(self):
        require(run(["bash", "-n"], input="true\n").returncode == 0,
                "shell positive control")
        require(run(["bash", "-n"], input="if then\n").returncode != 0,
                "shell reject control")

    def test_make_verify_routes_only_to_offline_script(self):
        result = run(["make", "--no-print-directory", "-n", "verify"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "bash scripts/verify-source.sh")

    def test_make_has_no_storage_defaults(self):
        text = (ROOT / "Makefile").read_text()
        self.assertNotRegex(text, r"(?m)^\s*(?:SOURCE_VOLUME|TARGET_VOLUME)\s*[:?+]?=")
        self.assertNotIn("/Volu" + "mes/", text)

    def test_all_storage_targets_refuse_before_worker(self):
        for target in NAS_TARGETS:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                assert_storage_refused(ROOT / "Makefile", target, Path(temporary))

    def test_storage_targets_refuse_when_shared_guard_marked_old(self):
        for target in NAS_TARGETS:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                options = ["-o", "nas-disabled"]
                if target in {"analyze", "analyze-dry"}:
                    options += ["-o", "check-volumes"]
                assert_storage_refused(ROOT / "Makefile", target, Path(temporary), options)

    def test_storage_refusal_detects_each_removed_recipe_guard(self):
        original = (ROOT / "Makefile").read_text()
        guard = "\t$(error NAS_WORKFLOW_DISABLED: replacement tools and separately approved storage scope required)\n"
        for target in NAS_TARGETS:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temporary:
                header = target + (": check-volumes\n" if target in {"analyze", "analyze-dry"}
                                   else ":\n")
                self.assertEqual(original.count(header + guard), 1)
                mutant = original.replace(header + guard, header, 1)
                directory = Path(temporary)
                makefile = directory / "Makefile"
                makefile.write_text(mutant)
                options = ["-o", "nas-disabled"]
                if target in {"analyze", "analyze-dry"}:
                    options += ["-o", "check-volumes"]
                with self.assertRaisesRegex(ValueError, "storage refusal failed"):
                    assert_storage_refused(makefile, target, directory, options)
                if target != "check-volumes":
                    self.assertTrue((directory / "worker-called").is_file(),
                                    "mutant must reach the recording worker")

    def test_make_unknown_target_fails(self):
        result = run(["make", "--no-print-directory", "-n",
                      "__dt_media_vault_unknown_gate_control__"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No rule to make target", result.stderr)



class CleanupControls(unittest.TestCase):
    paths = {MEMO, INDEX, "README.md", "README_GETTING_STARTED.md", "scripts/verify-source.sh"}

    def test_exact_cleanup_paths_pass(self):
        check_cleanup_scope(self.paths)

    def test_cleanup_cannot_change_product_dependencies_or_make(self):
        for path in ("src/media_toolkit/verifier.py", "pyproject.toml", "Makefile"):
            with self.subTest(path=path), self.assertRaisesRegex(
                    ValueError, "outside approved cleanup phase"):
                check_cleanup_scope(self.paths | {path})

    def test_cleanup_commit_reference_covers_current_file_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _baseline, accepted, commit = commit_graph_fixture(directory)
            cleanup = commit("cleanup record identity\n\n" + CLEANUP_SOW, accepted)
            check_commit_messages(accepted, cleanup, directory, CLEANUP_SOW)
            old_identity = commit("stale cleanup identity\n\n" + SOW, accepted)
            with self.assertRaisesRegex(ValueError, "commit missing standalone SOW line"):
                check_commit_messages(accepted, old_identity, directory, CLEANUP_SOW)

    def test_cleanup_requires_archive_removal_and_complete_controls(self):
        with self.assertRaisesRegex(ValueError, "memo removal missing"):
            check_cleanup_scope(self.paths - {MEMO})
        with self.assertRaisesRegex(ValueError, "complete approved path set"):
            check_cleanup_scope(self.paths - {"README_GETTING_STARTED.md"})


class LockPhaseControls(unittest.TestCase):
    def payload(self):
        return (ROOT / LOCK).read_bytes()

    def test_exact_lock_phase_passes(self):
        check_lock_phase({LOCK}, self.payload())

    def test_lock_phase_rejects_extra_or_wrong_paths(self):
        for paths in ({LOCK, "pyproject.toml"}, {"other.lock"}, set()):
            with self.subTest(paths=paths), self.assertRaisesRegex(
                    ValueError, "lock phase paths"):
                check_lock_phase(paths, self.payload())

    def test_lock_phase_rejects_wrong_size(self):
        with self.assertRaisesRegex(ValueError, "lock phase byte count mismatch"):
            check_lock_phase({LOCK}, self.payload() + b" ")

    def test_lock_phase_rejects_wrong_hash_at_same_size(self):
        payload = self.payload()
        mutant = bytes([payload[0] ^ 1]) + payload[1:]
        with self.assertRaisesRegex(ValueError, "lock phase SHA256 mismatch"):
            check_lock_phase({LOCK}, mutant)

    def test_lock_provenance_exception_is_exact_commit_only(self):
        check_lock_commit_record(LOCK_PRIMARY_COMMIT, CLEANUP_SOW)
        with self.assertRaisesRegex(ValueError, "lock commit missing standalone SOW"):
            check_lock_commit_record("0" * 40, CLEANUP_SOW)

    def test_lock_commit_coverage_includes_every_nonmerge_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _baseline, accepted, commit = commit_graph_fixture(directory)
            covered = commit("lock phase\n\n" + LOCK_SOW, accepted)
            check_lock_commit_messages(accepted, covered, directory)
            uncovered = commit("missing lock coverage", accepted)
            merged = commit("integration", covered, uncovered)
            with self.assertRaisesRegex(ValueError, "lock commit missing standalone SOW"):
                check_lock_commit_messages(accepted, merged, directory)


class PublicSowControls(unittest.TestCase):
    def test_historical_audit_keeps_public_marker_disabled(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _baseline, accepted, commit = commit_graph_fixture(directory)
            public = commit("new public coverage\n\n" + PUBLIC_SOW, accepted)
            with self.assertRaisesRegex(ValueError, "commit missing standalone SOW line"):
                check_commit_messages(accepted, public, directory)
            check_commit_messages(accepted, public, directory, CLEANUP_SOW,
                                  allow_public=True)

    def test_public_commit_reference_accepts_covered_merge_parents(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _baseline, accepted, commit = commit_graph_fixture(directory)
            left = commit("left public coverage\n\n" + PUBLIC_SOW, accepted)
            right = commit("right public coverage\n\n" + PUBLIC_SOW, accepted)
            merged = commit("integration", left, right)
            check_commit_messages(accepted, merged, directory, CLEANUP_SOW, allow_public=True)
            check_lock_commit_messages(accepted, merged, directory)

    def test_public_reference_must_be_a_standalone_line(self):
        with self.assertRaisesRegex(ValueError, "lock commit missing standalone SOW"):
            check_lock_commit_record("0" * 40, "prefix " + PUBLIC_SOW)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _baseline, accepted, commit = commit_graph_fixture(directory)
            bad = commit("prefix " + PUBLIC_SOW, accepted)
            with self.assertRaisesRegex(ValueError, "commit missing standalone SOW line"):
                check_commit_messages(accepted, bad, directory, CLEANUP_SOW, allow_public=True)


class ArchiveIndexControls(unittest.TestCase):
    def index(self):
        return json.loads((ROOT / INDEX).read_text(encoding="utf-8"))

    def test_archive_index_accepts_verified_staged_identity(self):
        check_memo_index(json.dumps(self.index()))

    def test_archive_index_rejects_missing_path_and_byte_mismatch(self):
        with self.assertRaisesRegex(ValueError, "missing or duplicate archive index row"):
            check_memo_index('{"records": []}')
        for field, value, reason in (("path", "docs/design/other.md", "path mismatch"),
                                     ("bytes", ARCHIVE_BYTES + 1, "byte count mismatch")):
            data = self.index()
            data["records"][0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, reason):
                check_memo_index(json.dumps(data))

    def test_archive_index_rejects_location_metadata(self):
        data = self.index()
        data["records"][0]["new_location"] = "private-record-location"
        with self.assertRaisesRegex(ValueError, "archive index field set mismatch"):
            check_memo_index(json.dumps(data))

    def test_wrong_index_hash_mutant_dies_by_sha256_assertion(self):
        mutant = self.index()
        mutant["records"][0]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "archived memo SHA256 mismatch"):
            check_memo_index(json.dumps(mutant))
        print("INDEX_MUTANT_REJECTED: wrong SHA256 failed the intended assertion")


def main():
    require(sys.version_info >= (3, 12), "source gate requires Python 3.12+")
    status = run(["git", "status", "--porcelain=v1"])
    require(status.returncode == 0 and not status.stdout, "gate requires clean checkout")
    tracked_result = run(["git", "ls-files", "-z"])
    require(tracked_result.returncode == 0, "cannot enumerate tracked source")
    tracked = set(tracked_result.stdout.rstrip("\0").split("\0"))
    changed_result = run(["git", "diff", "--name-only", "-z", BASELINE, "HEAD"])
    require(changed_result.returncode == 0, "cannot compare source baseline")
    changed = set(filter(None, changed_result.stdout.split("\0")))
    historical = run(["git", "diff", "--name-only", "-z", BASELINE, CLEANUP_BASELINE])
    require(historical.returncode == 0, "cannot compare accepted source history")
    check_source_scope(set(filter(None, historical.stdout.split("\0"))))
    phase_result = run(["git", "diff", "--name-only", "-z", VERIFIER_PHASE_BASELINE,
                        CLEANUP_BASELINE])
    require(phase_result.returncode == 0, "cannot compare verifier phase baseline")
    check_verifier_phase_scope(set(filter(None, phase_result.stdout.split("\0"))))
    require(LOCK_PHASE_BASELINE is not None, "reviewed lock merge baseline not bound")
    for ancestor, descendant in ((CLEANUP_BASELINE, LOCK_PHASE_BASELINE),
                                 (LOCK_PHASE_BASELINE, "HEAD")):
        require(run(["git", "merge-base", "--is-ancestor", ancestor, descendant]).returncode == 0,
                "lock phase ancestry mismatch")
    lock_paths = run(["git", "diff", "--name-only", "-z",
                      CLEANUP_BASELINE, LOCK_PHASE_BASELINE])
    require(lock_paths.returncode == 0, "cannot compare lock phase baseline")
    lock_blob = subprocess.run(["git", "show", LOCK_PHASE_BASELINE + ":" + LOCK],
                               capture_output=True, timeout=30, env=ENV)
    require(lock_blob.returncode == 0, "cannot read merged lock blob")
    check_lock_phase(set(filter(None, lock_paths.stdout.split("\0"))), lock_blob.stdout)
    check_lock_commit_messages(CLEANUP_BASELINE, LOCK_PHASE_BASELINE)
    cleanup = run(["git", "diff", "--name-only", "-z", LOCK_PHASE_BASELINE, "HEAD"])
    require(cleanup.returncode == 0, "cannot compare cleanup phase baseline")
    check_cleanup_scope(set(filter(None, cleanup.stdout.split("\0"))))
    require(MEMO not in tracked, "archived memo still tracked")
    require(INDEX in tracked, "archive index is not tracked")
    require(changed <= tracked | {MEMO}, "deleted source outside archived memo")
    baseline_paths = run(["git", "ls-tree", "-r", "--name-only", "-z", BASELINE])
    require(baseline_paths.returncode == 0, "cannot enumerate baseline")
    baseline_tracked = set(filter(None, baseline_paths.stdout.split("\0")))

    sources = {}
    for name in sorted(tracked):
        relative = PurePosixPath(name)
        require(not relative.is_absolute() and ".." not in relative.parts,
                "unsafe tracked path")
        current = ROOT
        for part in relative.parts:
            current = current / part
            require(not current.is_symlink(), "tracked symlink boundary")
        require(current.is_file(), "tracked source not regular file")
        if current.suffix in {".py", ".sh", ".md"} or name in changed:
            sources[name] = current.read_text(encoding="utf-8")

    check_memo_index((ROOT / INDEX).read_text(encoding="utf-8"))

    for name, text in sources.items():
        if name.endswith(".py"):
            lint_python(text)
        if name.endswith(".sh"):
            require(run(["bash", "-n", name]).returncode == 0, "shell syntax: " + name)
    for name in sorted(changed & tracked):
        before = ""
        if name in baseline_tracked:
            preimage = run(["git", "show", BASELINE + ":" + name])
            require(preimage.returncode == 0, "cannot read baseline source")
            before = preimage.stdout
        check_public_artifact(name, added_text(before, sources[name]))
        if name.endswith(".md"):
            check_document(sources[name], name, tracked)
    whitespace = run(["git", "diff", "--check", BASELINE, "HEAD"])
    require(whitespace.returncode == 0, "changed source whitespace")
    check_commit_messages(BASELINE, CLEANUP_BASELINE)
    check_commit_messages(LOCK_PHASE_BASELINE, sow_line=CLEANUP_SOW, allow_public=True)

    print("Python syntax/indentation, shell syntax, docs, SOW and finite privacy/scope checks passed.",
          flush=True)
    ruff_version = run(["ruff", "--version"])
    require(ruff_version.returncode == 0, "existing dev tool ruff unavailable; do not install implicitly")
    print(ruff_version.stdout.strip(), flush=True)
    python_sources = sorted(name for name in tracked if name.endswith(".py"))
    fatal_lint = run(["ruff", "check", "--no-cache", "--select", "E9,F63,F7,F82",
                      "--", *python_sources])
    print(fatal_lint.stdout, end="", flush=True)
    require(fatal_lint.returncode == 0, "fatal Python lint failed: " + fatal_lint.stderr)

    suite = unittest.TestSuite([
        unittest.defaultTestLoader.loadTestsFromTestCase(GateControls),
        unittest.defaultTestLoader.loadTestsFromTestCase(CleanupControls),
        unittest.defaultTestLoader.loadTestsFromTestCase(LockPhaseControls),
        unittest.defaultTestLoader.loadTestsFromTestCase(PublicSowControls),
        unittest.defaultTestLoader.loadTestsFromTestCase(ArchiveIndexControls),
    ])
    require(unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful(),
            "positive/reject controls failed")
    verifier_tests = subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-s", "tests",
         "-p", "test_verifier_safety.py", "-v"],
        env=dict(ENV, PYTHONPATH=str(ROOT / "src")),
        capture_output=True, text=True, timeout=120,
    )
    print(verifier_tests.stdout, end="", flush=True)
    print(verifier_tests.stderr, end="", flush=True)
    require(verifier_tests.returncode == 0, "synthetic verifier safety controls failed")
    final_status = run(["git", "status", "--porcelain=v1"])
    require(final_status.returncode == 0 and not final_status.stdout,
            "gate changed source checkout")
    print("PASS: full offline source and synthetic verifier gate. No NAS/provider execution.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, SyntaxError, tabnanny.NannyNag,
            subprocess.TimeoutExpired) as exc:
        print("FAIL: " + str(exc), file=sys.stderr)
        sys.exit(1)
PY
