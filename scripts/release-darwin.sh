#!/bin/bash
set -euo pipefail

fail() {
    printf 'Media Vault release: %s\n' "$*" >&2
    exit 1
}

[[ "$(uname -s):$(uname -m)" == Darwin:arm64 ]] || fail 'Requires native Darwin ARM64.'
mode=${1:-}
case "$mode" in release|candidate) ;; *) fail 'Expected release or candidate.' ;; esac
[[ -z "$(git status --porcelain)" ]] || fail 'The source checkout must be clean.'
head=$(git rev-parse HEAD)
tree=$(git rev-parse 'HEAD^{tree}')
if [[ "$mode" == release ]]; then
    gold=$(git ls-remote --exit-code https://github.com/ducktyper-ai/dt-media-vault.git refs/heads/main)
    [[ "${gold%%$'\t'*}" == "$head" ]] || fail 'HEAD must match upstream main.'
fi

python=${MEDIA_VAULT_PYTHON:-python3.12}
"$python" -I -c 'import platform, sys; sys.exit(not (
    platform.python_implementation() == "CPython" and sys.version_info[:2] == (3, 12)
    and platform.machine() == "arm64"
))' || fail 'Requires native CPython 3.12.'
version=$("$python" -I -c 'import pathlib, tomllib; print(tomllib.loads(
    pathlib.Path("pyproject.toml").read_text())["project"]["version"])')
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Expected a semantic release version.'
tag="v$version"
name="dt-media-vault-$version-darwin-arm64"
if [[ "$mode" == candidate ]]; then
    name="$name-candidate-${head:0:12}"
fi

out=${RELEASE_DIR:-dist}
mkdir -p -- "$out"
out=$(cd -- "$out" && pwd -P)
destination="$out/$name"
[[ ! -e "$destination" && ! -L "$destination" ]] || fail 'Release output already exists.'
archive="$destination/$name.tar.gz"
scratch=$(mktemp -d "$out/.media-vault-release.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
stage="$scratch/stage"
mkdir -p "$stage/bin" "$stage/docs" "$scratch/wheel" "$scratch/publish"

"$python" -I -m venv "$scratch/build"
build_python="$scratch/build/bin/python"
pip=("$build_python" -I -m pip --isolated --disable-pip-version-check)
"${pip[@]}" install --index-url https://pypi.org/simple --no-deps --only-binary=:all: \
    --require-hashes -r scripts/release-build.lock
"$build_python" -I -m hatchling build -t wheel -d "$scratch/wheel"
wheels=("$scratch"/wheel/*.whl)
[[ ${#wheels[@]} == 1 && -f "${wheels[0]}" ]] || fail 'Expected exactly one CLI wheel.'
read -r wheel_sha _ < <(shasum -a 256 "${wheels[0]}")
printf './%s --hash=sha256:%s\n' "${wheels[0]##*/}" "$wheel_sha" > "$scratch/wheel/product.lock"
"${pip[@]}" install --index-url https://pypi.org/simple --no-deps --only-binary=:all: \
    --require-hashes --no-compile --target "$stage/lib" -r scripts/release-runtime.lock
(
    cd "$scratch/wheel"
    "${pip[@]}" install --no-index --no-deps --only-binary=:all: --require-hashes \
        --no-compile --target "$stage/lib" -r product.lock
)
# Use a portable launcher; generated wheel scripts keep their build-time interpreter path.
rm -rf -- "$stage/lib/bin"
cat > "$stage/bin/media-catalog" <<'LAUNCHER'
#!/bin/bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
exec "${MEDIA_VAULT_PYTHON:-python3.12}" -I -B -c '
import sys
sys.path.insert(0, sys.argv.pop(1))
from media_toolkit.catalog import cli
cli(prog_name="media-catalog")
' "$root/lib" "$@"
LAUNCHER
chmod 0755 "$stage/bin/media-catalog"
cp LICENSE CHANGELOG.md "$stage/"
cp docs/RUN.md "$stage/docs/"
printf '{"version":"%s","tag":"%s","source_commit":"%s","source_tree":"%s","target":"darwin-arm64","mode":"%s"}\n' \
    "$version" "$tag" "$head" "$tree" "$mode" > "$stage/RELEASE.json"

MEDIA_VAULT_PYTHON="$python" "$stage/bin/media-catalog" --help
[[ "$(git rev-parse HEAD)" == "$head" && -z "$(git status --porcelain)" ]] ||
    fail 'The source checkout changed during the build.'
(
    cd "$scratch/publish"
    COPYFILE_DISABLE=1 tar -C "$stage" -czf "$name.tar.gz" bin lib docs LICENSE CHANGELOG.md RELEASE.json
    shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256"
)
# Publish both files in one rename, without replacing even an empty destination.
"$python" -I - "$scratch/publish" "$destination" <<'PYTHONSCRIPT'
import ctypes
import os
import sys

source, destination = map(os.fsencode, sys.argv[1:])
rename_exclusive = 0x00000004  # Darwin RENAME_EXCL in sys/stdio.h
rename = ctypes.CDLL(None, use_errno=True).renamex_np
rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
rename.restype = ctypes.c_int
if rename(source, destination, rename_exclusive) != 0:
    error = ctypes.get_errno()
    raise SystemExit(f"Could not publish release directory: {os.strerror(error)}")
PYTHONSCRIPT
printf '%s\n' "$archive"
cat "$archive.sha256"
