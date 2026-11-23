sow: public

# Run Media Vault from a release

Media Vault is a command-line tool for indexing media sidecars into a SQLite
catalog. It runs to completion for each invocation.

## Setup and readiness

Verify the archive with its SHA-256 file, unpack it into a versioned release
directory, and invoke the launcher from that directory. Use native CPython 3.12
on Apple silicon macOS 14 or newer. Runtime dependencies ship in the archive.

```sh
shasum -a 256 -c dt-media-vault-0.1.0-darwin-arm64.tar.gz.sha256
./bin/media-catalog --help
```

The readiness command prints the CLI help and exits zero. The CLI has no
listener port, health URL, or persistent process. Run invocations under the
dedicated application account. For a deployment probe, run the readiness command
once under that account.

## Configuration and data

No environment variable is required when `python3.12` is available on PATH.
Set `MEDIA_VAULT_PYTHON` to an absolute native CPython 3.12 path if the
application account uses a restricted PATH. The CLI requires no credentials.

Pass an explicit SQLite file to `--catalog` and an authorized media directory
to `--root`. Keep the catalog in the application's persistent data directory,
outside the versioned release. The deployment data directory is
`/var/db/zeo/apps/dt-media-vault/data`. When omitted, `--sidecars-dir` resolves
to `Catalog/sidecars` inside the specified media root.

```sh
./bin/media-catalog index-sidecars --catalog "$CATALOG_PATH" --root "$MEDIA_ROOT"
```

Use an isolated fixture for qualification. Production media access requires its
own approval.

## Build and review

`make verify` is the offline source gate. On the authorized native Darwin ARM64
builder, use `make release-candidate` at the exact review commit. The builder
needs Git, native CPython 3.12 with venv and pip, and access to the hash-pinned
wheel index. It exercises CLI startup from the packaged files.

From the clean upstream main commit approved for release, run `make release`.
It publishes the archive and its checksum together in
`dist/dt-media-vault-0.1.0-darwin-arm64/`, or under the specified
`RELEASE_DIR`. A candidate uses a directory with its commit suffix. Existing
release directories are preserved. The archive records the exact source
commit and expected tag
`v0.1.0` in `RELEASE.json`. Publish only when that tag resolves to the archived
commit.
