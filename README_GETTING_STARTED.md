# Try the Media Vault Go planner

Use disposable files to run the read-only planner and inspect its JSON output.
The source checkout is the current distribution. Darwin ARM64 release
packaging is pending.

## Verify and build from source

Runtime runs this block from the repository root on the admitted Darwin ARM64
ENG-UK worker, as its unprivileged gate account, without sudo. Use the Go
version specified in `go.mod` and the dependencies pinned by `go.sum`.

```bash
(
  set -eu
  export CGO_ENABLED=0 GOTOOLCHAIN=local GOWORK=off
  make verify

  scratch=$(mktemp -d "${TMPDIR:-/tmp}/media-vault-demo.XXXXXXXX")
  scratch=$(cd "$scratch" && pwd -P)
  go build -mod=readonly -trimpath -o "$scratch/media-vault" ./cmd/media-vault
  "$scratch/media-vault" --help

  mkdir "$scratch/ingest" "$scratch/archive"
  printf 'demo-ingest\n' > "$scratch/ingest/.media-vault-root"
  printf 'demo-archive\n' > "$scratch/archive/.media-vault-root"
  printf 'synthetic clip\n' > "$scratch/ingest/clip.mov"

  "$scratch/media-vault" plan \
    --ingest "$scratch/ingest" --ingest-id demo-ingest \
    --ingest-device "$(stat -f '%d' "$scratch/ingest")" \
    --archive "$scratch/archive" --archive-id demo-archive \
    --archive-device "$(stat -f '%d' "$scratch/archive")" \
    > "$scratch/plan.json"
  printf 'Plan saved at %s/plan.json\n' "$scratch"
)
```

A successful result contains `plan_sha256`, sets `plan.complete` to `true`,
and includes one entry in `plan.rows` with `"action": "copy"`. The action
describes a proposed copy. The example stores the plan alongside the two
demo directories and leaves the archive directory with only its root marker.

For root admission, conflict handling and exit behavior, see the
[planner guide](docs/GO-PLAN.md). The demo admits only the scratch directories.
Runtime must admit the canonical paths, logical marker IDs and current device
numbers for any approved real-storage run. Legacy migration and catalog Make
targets are disabled.
