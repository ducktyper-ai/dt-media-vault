"""Read-only diagnostics and opt-in hook installation. No media or app imports."""
# sow: public
from __future__ import annotations

import hashlib
from importlib import metadata
import re
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LOCK_SHA256 = "321934de86581ce858defa66c9fa9af70ba48a23eb687bf3524b006a5366da4e"
UNIVERSAL_SHA256 = "807f45132f15b0e77ba76ca4f9b8eba6f7e9c1d41e8051950428d2de64ff2adf"
EXPORT_SHA256 = "d1dc474392912a9b6c5761195a1f71943198f2801892a418c81b6e249781734d"


def git(*arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments], cwd=ROOT, capture_output=True, text=True,
        check=False, timeout=10,
        env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1"),
    )
    if result.returncode:
        raise RuntimeError("Git metadata unavailable; check this checkout")
    return result.stdout.strip()


def hook_location() -> Path:
    common = Path(git("rev-parse", "--git-common-dir"))
    if not common.is_absolute():
        common = ROOT / common
    active = Path(git("rev-parse", "--git-path", "hooks/pre-push"))
    if not active.is_absolute():
        active = ROOT / active
    expected = common.resolve() / "hooks" / "pre-push"
    # Never edit a shared/custom hooksPath, or follow a hook symlink.
    if active.is_symlink() or active.parent.is_symlink():
        raise RuntimeError("symlink hook location; ask its owner to integrate the guard")
    if active.resolve() != expected:
        raise RuntimeError("custom core.hooksPath; ask its owner to integrate the guard")
    return expected


def hooks() -> int:
    destination = hook_location()
    payload = (ROOT / "scripts/pre-push.sh").read_bytes()
    previous = destination.with_name("pre-push.media-vault-previous")
    if destination.exists() and destination.read_bytes() == payload:
        if not os.access(destination, os.X_OK):
            raise RuntimeError("existing guard is not executable; owner must repair it")
        print("PASS main-push guard already installed")
        return 0
    if previous.exists() or previous.is_symlink():
        raise RuntimeError("saved previous hook exists; refusing to overwrite hook chain")
    if destination.exists() and not destination.is_file():
        raise RuntimeError("existing hook is not a regular file")
    if destination.exists() and not os.access(destination, os.X_OK):
        raise RuntimeError("existing nonexecutable hook; owner must resolve it first")
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".media-vault-hook-", dir=destination.parent)
    staged = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
        staged.chmod(0o755)
        if destination.exists():
            destination.rename(previous)
        try:
            staged.replace(destination)
        except OSError:
            if previous.exists() and not destination.exists():
                previous.rename(destination)
            raise
    finally:
        if staged.exists():
            staged.unlink()
    print("PASS installed main-push guard; previous executable hook preserved and chained")
    return 0


def doctor() -> int:
    failures = 0

    def report(ok: bool, label: str, fix: str) -> None:
        nonlocal failures
        print(("PASS " + label) if ok else ("FIX " + label + ": " + fix))
        failures += int(not ok)

    report(sys.version_info >= (3, 12), "Python 3.12+ source-gate minimum",
           "select a compatible interpreter on the authorized build host")
    for name, arguments, expected in (
        ("git", ["--version"], None), ("make", ["--version"], None),
        ("bash", ["--version"], None), ("uv", ["--version"], None),
        ("ruff", ["--version"], "ruff 0.17.4"),
        ("mypy", ["--version"], "mypy 2.4.1"),
    ):
        executable = shutil.which(name)
        if not executable:
            report(False, name, "use make setup on an authorized build host; no implicit install")
            continue
        result = subprocess.run([executable, *arguments], capture_output=True,
                                text=True, check=False, timeout=10)
        version = result.stdout.splitlines()[0] if result.stdout else "unknown version"
        report(result.returncode == 0 and (expected is None or version.split()[:2] == expected.split()),
               name + " version " + version,
               "use the frozen universal toolchain; Ruff 0.17.4 and mypy 2.4.1")
    # Metadata only: never import the application or execute a package to diagnose it.
    for package, minimum in (("blake3", (0, 4, 1)), ("click", (8, 1, 7)),
                             ("rich", (13, 7, 0)), ("mypy", (1, 8, 0))):
        try:
            installed_version = metadata.version(package)
        except metadata.PackageNotFoundError:
            report(False, package + " runtime/development prerequisite",
                   "use explicit setup on the authorized build host")
            continue
        stable = re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", installed_version)
        numeric = tuple(int(part) for part in installed_version.split(".")) if stable else ()
        padded = numeric + (0,) * (3 - len(numeric))
        report(bool(stable) and padded >= minimum, package + " metadata " + installed_version,
               "select the declared minimum or reconcile a nonstable version explicitly")
    for utility in ("sh", "cat", "mktemp", "rm"):
        report(shutil.which(utility) is not None, utility + " hook prerequisite",
               "restore the host shell utilities before installing the hook")
    payload = (ROOT / "requirements-gate.lock").read_bytes()
    report(len(payload) == 912 and hashlib.sha256(payload).hexdigest() == LOCK_SHA256,
           "original gate lock identity", "restore the reviewed lock; never regenerate it implicitly")
    for name, size, expected_hash in (
        ("uv.lock", 340177, UNIVERSAL_SHA256),
        ("requirements-gate-universal.lock", 88357, EXPORT_SHA256),
    ):
        locked = (ROOT / name).read_bytes()
        report(len(locked) == size and hashlib.sha256(locked).hexdigest() == expected_hash,
               name + " identity", "restore the reviewed universal lock and matching export")
    print("INFO historical lock retained; universal lock/export includes runtime and dev closure")
    print("INFO setup selects existing Python 3.12; no interpreter download or source build")
    print("INFO environment names: PATH selects tools; TMPDIR is optional; SOURCE_VOLUME and TARGET_VOLUME are not needed")
    print("INFO offline gate needs no media root, mounted volume, service, or network")
    print("INFO dependency acquisition needs package-index access only during explicit setup")
    print("INFO build/test/gate execution is forbidden on the Mac mini")
    try:
        active = hook_location()
        installed = (active.is_file() and os.access(active, os.X_OK)
                     and active.read_bytes() == (ROOT / "scripts/pre-push.sh").read_bytes())
        report(installed, "main-push guard installed", "run make hooks; never replace other owners' hooks")
    except RuntimeError as error:
        report(False, "hook ownership", str(error))
    return int(bool(failures))


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in {"doctor", "hooks"}:
        print("Usage: python3 scripts/devtools.py doctor|hooks", file=sys.stderr)
        return 2
    try:
        return doctor() if sys.argv[1] == "doctor" else hooks()
    except (OSError, RuntimeError, subprocess.TimeoutExpired):
        print("FIX developer command failed; check tool access and hook ownership; no media operation", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
