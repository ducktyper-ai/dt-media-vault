#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
if [[ "$(uname -s):$(uname -m)" != Darwin:arm64 ]]; then
    printf 'The Go binary gate requires the admitted native Darwin ARM64 host.\n' >&2
    exit 1
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/media-vault-verify.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
export CGO_ENABLED=0 GOTOOLCHAIN=local GOWORK=off
go version
go test -mod=readonly ./...
go build -mod=readonly -trimpath -o "$scratch/media-vault" ./cmd/media-vault
file "$scratch/media-vault" | grep -Eq 'Mach-O 64-bit executable arm64'
otool -L "$scratch/media-vault" | tee "$scratch/imports"
awk '
    NR == 1 { next }
    $1 == "/usr/lib/libSystem.B.dylib" || $1 == "/usr/lib/libSystem.dylib" { next }
    $1 == "/usr/lib/libresolv.9.dylib" { next }
    $1 ~ /^\/System\/Library\/Frameworks\// && $1 !~ /\/\.\.?(\/|$)|\/\// { next }
    { print "Unexpected Mach-O import: " $1 > "/dev/stderr"; failed = 1 }
    END { exit failed || NR < 2 }
' "$scratch/imports"
"$scratch/media-vault" --help
shasum -a 256 "$scratch/media-vault"
