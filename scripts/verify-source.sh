#!/bin/bash
# sow: dt-media-vault-SOW-01
# Offline owning gate: source controls plus synthetic local verifier safety tests.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

export PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import ast
import difflib
import io
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
SOW = "sow: dt-media-vault-SOW-01"
MEMO = "docs/design/sow-01-media-vault-design.md"
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


def check_commit_messages(baseline, head="HEAD", directory=None):
    # Integration commits inherit SOW coverage; audit every non-merge on every side.
    result = run(["git", "log", "--no-merges", "--format=%B%x00",
                  baseline + ".." + head], cwd=directory,
                 env=ENV if directory is None else fixture_git_environment())
    require(result.returncode == 0, "cannot read source commits")
    for message in filter(str.strip, result.stdout.split("\0")):
        require(SOW in message.splitlines(), "commit missing standalone SOW line")


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
    check_source_scope(changed)
    require(changed <= tracked, "deleted source in finite design/gate slice")
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

    for name, text in sources.items():
        if name.endswith(".py"):
            lint_python(text)
        if name.endswith(".sh"):
            require(run(["bash", "-n", name]).returncode == 0, "shell syntax: " + name)
    for name in sorted(changed):
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
    check_commit_messages(BASELINE)

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

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(GateControls)
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
