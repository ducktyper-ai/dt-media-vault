# Go archive planner

The first Go command, `media-vault plan`, reads an admitted ingest
directory and inspects proposed paths under a separate archive root. It
writes a digest-pinned JSON plan to stdout. It reports full BLAKE3 content
identities, retained duplicate observations, file and byte totals, and
destination copy, reuse, or conflict decisions.

## Root admission

Pass canonical absolute directory paths, trusted device numbers, and
logical IDs. Each root must already contain a regular
`.media-vault-root` file with its exact logical ID and one newline.
The planner checks markers and devices and never creates them. Runtime
admits the actual volume configuration. A missing mount or a mismatch
fails before a plan is emitted. Device numbers identify the current mount,
so Runtime must readmit them after remount. The root marker and the
device/inode ancestry of the opened directories must also match.

```sh
media-vault plan --ingest "$INGEST_ROOT" --ingest-id "$INGEST_ID" \
  --ingest-device "$INGEST_DEVICE" --archive "$ARCHIVE_ROOT" \
  --archive-id "$ARCHIVE_ID" --archive-device "$ARCHIVE_DEVICE" \
  --device "$RECORDING_DEVICE" --date "$RECORDING_DATE" --project "$PROJECT_ID"
```

The last three flags carry known batch metadata. Leave them out when
unknown. An empty scan or a conflict produces an incomplete plan and a
nonzero exit. Relative source paths are preserved as observations. Target
paths use a portable stem, a full digest, and device and date directories.
Existing case-folded or Unicode-equivalent destination names are reported
as conflicts. Regular AppleDouble and .DS_Store files are reported as
skipped, with their source bytes retained. The scan treats a file whose
identity, size, modification time, or change time shifts as unresolved.
The intended NAS backend still needs qualification of those read signals.
The plan digest is SHA-256 over the compact JSON encoding of the inner
plan object in its defined field order.

## Verification and scope

`make verify` on the admitted Darwin ARM64 worker runs the synthetic Go
tests, builds the cgo-disabled CLI, and verifies Mach-O architecture and
system-only imports before the help smoke check. The paired review
specified libSystem and Apple system framework imports. The existing
Python sources and their retired gate remain behavior reference.

[Catalog contract files](catalog/CATALOG-V1-CONTRACT.txt) carry the exact
agreed draft schema and fixture. Catalog query, staging, verified
copy application, and release packaging follow in later review phases.
