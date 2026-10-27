# Media vault code study and safe storage design

sow: dt-media-vault-SOW-01

Author: dt-media-vault-maintainer. Date: 2026-10-24. Status: proposed for
independent review and Council/operator acceptance.

Build a private, read-only inventory and content catalogue before changing any
storage layout. Keep original bytes and every observed location. Duplicate
discovery produces reports only. An off-site copy counts as protection only
after an independent restore succeeds. This assignment authorizes design only;
NAS discovery, account creation, mounts, implementation and migration require
their own approved scope.

## Source checkpoint and evidence

Inspected source: `cf3bc5a48e108ed6f2a0a929a189b281bfc14ada`, tree
`95fcedac6e580ba47c93a3915927e5968eaec769`. The initial index and worktree were
clean. Read all 19 tracked files: both READMEs, Makefile, project/configuration
files, licence, ignore rules, all Python modules and all three shell scripts.
No NAS or backup was accessed and no media inventory was collected.

The code is a small Python migration toolkit, not a general backup system.
It hashes selected media with BLAKE3, generates a JSON migration manifest and
CSV report, copies files, writes YAML sidecars, and indexes sidecars in SQLite.
The project scripts create folders and links. Existing documentation describes
an earlier migration workflow; its source-cleanup advice does not authorize
deleting anything under this charter.

The following findings are from source inspection, rather than a live scan:

| Source | Finding | Consequence for the design |
| --- | --- | --- |
| `analyzer.py:detect_duplicates`; `migrator.py:migrate`; `verifier.py:verify` | Every member of a duplicate group, including its selected primary, gets `is_duplicate=True`; copy and verification both exclude all flagged members. | Whole groups can disappear from the copy and its verification coverage. Separate content identity, location identity and reporting; never use duplicate status to exclude required backup content. |
| `migrator.py:migrate` | An existing matching hash is skipped; a different existing hash is overwritten with `shutil.copy2`. Target paths strip a leading slash but do not reject `..` or symlink escapes. | Require containment, collision refusal, exclusive creation and separately approved writes. Existence alone is not verification. |
| `verifier.py:verify` | Exceptions enter `errors` without necessarily increasing missing/corrupted counts. The success message checks only those counts; CLI does not return a failure status for verification defects. | Account for all entries and fail on any error, omitted entry or incomplete run. Remove cleanup claims in a later authorized patch. |
| `link_into_project.py:safe_symlink` | Calls `unlink()` on an existing file or link before creating a link. | This helper is incompatible with the no-delete rule and must not run against the NAS. Use catalogue references until a separately reviewed plan exists. |
| `analyzer.py:scan`, `_process_file`; configuration | Only configured media extensions enter scanning; files below the configured 1 MiB threshold are skipped. There is no full-device backup model. | Whole-NAS discovery must include small files, unknown formats, sidecars and backup containers; record every exclusion and unreadable subtree. |
| `utils/hash.py`; `analyzer.py` | Streaming full BLAKE3 is useful, but no before/after stability check or algorithm/version field protects a changing file. Dry runs emit a manifest containing `DRY_RUN` hashes and current timestamps. | Use explicit hash states and stable observations; preview output must never be executable as a transfer manifest. |
| `catalog.py:SCHEMA`, `upsert_sidecar` | Content hash is the sole primary key and upserts replace its single stored location. | A content object needs many locations and project references, without losing provenance. |
| `migrator.py:_create_sidecar` | Replacing the extension with `.yaml` makes equal-stem files of different formats collide. | Address sidecars by a separate stable file/location identity. |
| `analyzer.py:_determine_target_path`; project scripts | Mapping and project scaffolds use different layouts and device taxonomies; equal basenames can collide. Scripts write metadata without a reviewed plan. | Define one versioned naming policy, preserve card/package structure and preview every future allocation. |
| `pyproject.toml`; Makefile | Declared Python floor is 3.10, while scanning uses `Path.walk()` (3.12+). No tracked tests, CI workflow or owning verification target exists. A catch-all Make target silently accepts unknown names. | Agree the interpreter and an actual full gate before publication. A successful `make test` or unknown `make verify-full` would not prove testing occurred. |
| Makefile volume defaults and legacy targets | The baseline defaults name storage/NAS mounts. `migrate`, `index-catalog`, `link-project` and the old `verify` operate on those roots; indexing writes a database on the NAS and linking can unlink an existing file. | The offline source gate does not qualify these operations. Remove implicit volume defaults and disable legacy NAS operations under an explicit reviewed amendment before any NAS session. |

## Zeocore refactor proposal

Use zeocore for typed capability boundaries, explicit services/configuration,
structured results and bounded execution. Keep media policy in this repository.
The owner documentation at
[`zeroemployeeorg/zeocore@1f961d305198b460d355dc412aeaac767b433a90`](https://github.com/zeroemployeeorg/zeocore/blob/1f961d305198b460d355dc412aeaac767b433a90/llms.txt)
documents `zeo_core.tools` (`capability`, `ToolContext`, `invoke_sync`),
`zeo_core.contracts` (`CapabilityResult`), configuration, filesystem and path
services. Its documented Python floor is 3.12. This is an API study checkpoint,
not a dependency selection or installation approval.

Separate pure classification and naming functions from filesystem reads,
database writes and future transfer operations. Keep Click as a thin local
adapter during transition. Proposed capabilities are discovery, content
hashing, duplicate reporting, private catalogue search, backup planning and
restore verification. Names and request schemas require owner agreement before
implementation. No HTTP/MCP service, Runtime provider or ingestion daemon is
part of this first task.

Each request identifies an approved root alias, scan/snapshot ID, policy version,
private output location and resource budget. Reject ambient NAS defaults.
Context supplies a restricted reader, local catalogue and logger; absence of a
required service returns a structured unavailable/error result. Effects declare
reads and local writes accurately, but declarations are not authorization or
an operating-system sandbox. Restrict permissions at the NAS and mount too.
Never inject a general write/delete filesystem interface into discovery.

Results distinguish completed, partial, cancelled, offline, changed-during-read,
permission-denied and verification-failed outcomes. Private detail stays in a
private ledger; shared receipts carry fixed reason codes, counts and opaque
record references. A complete scan reconciles every discovered entry into a
finished classification, error or explicit exclusion; interrupted entries stay
pending. A missing directory is not an empty successful scan.

The local catalogue should have separate tables for scans, roots, observations,
content objects, locations, project references and backup/restore receipts.
Content keys include algorithm, full digest and length. Locations carry root
alias, private relative path, observation time and filesystem identity when
available. Indexes accelerate queries but remain rebuildable from versioned
private manifests. Store no absolute personal paths in public contracts.
Do not presume zeocore supplies a general SQLite or NAS connector.

Keep the catalogue, manifests, hash cache and reports under an operator-approved
private data root on the execution host, outside Git checkouts, NAS shares and
backup roots. Use a `dt-media-vault` directory with mode `0700` and data files
with mode `0600`; the exact root is private operator configuration. Preserve
these private records through a separately approved backup plan. Discovery
writes no catalogue database or reports to the NAS.

Implementation phases after design acceptance: agree owner contracts and
dependency/version checks; establish a synthetic offline test gate; implement
read-only discovery and reporting; validate a bounded approved real session;
implement separate backup/restore tools only under a new scope. Each phase has
its own review. No copying of another seat's credentials or runtime environment.

## Storage and naming proposal

Treat the present NAS layout as existing evidence. Introduce a logical catalogue
over it first. The following is a synthetic template for future approved
allocations, not an instruction to move or rename existing data:

```text
Media/
  Originals/<source-id>/<yyyy>/<yyyy-mm-dd-or-undated>/<ingest-id>/<original-relative-path>
  Projects/<yyyy>/<date>_<project-id>/
    00_admin/ 01_assets/ 02_shoots/ 03_selects/ 04_proxies/
    05_renders/ 06_deliverables/
DeviceBackups/<source-id>/<backup-set-id>/
```

Preserve original filenames, camera-card directory structure, companion metadata
and application backup packages. Opaque source/ingest IDs prevent same-name
collisions without exposing device identities. Use ASCII lowercase stable IDs
for new managed containers, ISO dates, and UTC observation timestamps. Preserve
the original timestamp, timezone and evidence source separately; an unknown
capture date stays `undated` rather than silently using scan time. Device and
project display labels remain private catalogue metadata. Never normalize or
rename an existing original as part of discovery.

Validate new relative paths for traversal, absolute paths, case/Unicode
collisions, length constraints and symlink escapes. Refuse conflicts and retain
both proposed allocations for review. Content identity and file identity remain
separate even when bytes match. Project views initially resolve catalogue
references; no link creation or replacement on the NAS. Backups of phones,
computers and application libraries retain their native format and restore
instructions rather than becoming media-only folders.

## Duplicate discovery and reporting

1. Inventory every operator-approved share/root read-only. Record scope and
   exclusions, including inaccessible roots, mount boundaries, hidden entries,
   unreadable directories and backup containers. Do not follow symlinks or cross
   mounts automatically. A coverage ledger prevents a partial scan being called
   whole-NAS coverage.
   Collect no GPS/location tags, faces or biometric identifiers by default.
   Any later metadata probe needs an explicit field allowlist and separate
   privacy approval; do not retain arbitrary ffprobe tags.
2. Group ordinary regular-file candidates by byte length. Include empty and tiny
   files. Size and optional samples only reduce work; neither establishes
   duplication. Hash unique-size files too when constructing the backup manifest.
3. Stream full BLAKE3 over stable file bytes with a bounded worker count. Record
   algorithm/version, byte count, observation/snapshot and start/end file stats.
   Changed identity/size/mtime or read failure invalidates the observation; retry
   within budget or report pending. A snapshot is preferable to stat heuristics,
   which cannot prove absence of concurrent writes.
4. Group only complete observations by algorithm, full digest and length. Report
   all locations. Separate hard-link aliases to one filesystem object from
   independent stored copies; exclude them from naive reclaimable-byte claims.
   Byte comparison can independently corroborate a group under a later approved
   read budget; content hashes, never names alone, establish candidate identity.
5. Preserve project/backup/package context and every location in the private
   report. An advisory preferred reference must never become a deletion,
   omission or transfer filter. Derived proxies/transcodes are related assets,
   not exact duplicates unless their actual bytes match.

Use a private incremental cache keyed by root/snapshot and observed file identity,
size and timestamps. It is a performance hint; rehash suspect entries and the
actual source/restore bytes used for verification. Do not treat an old digest as
proof of today's file. Throttle disk/network I/O, checkpoint locally, respect the
approved time window and stop promptly on disconnect. Initial concurrency is one
reader until measured capacity supports more. Keep CSV paths safely quoted and
prevent spreadsheet formula execution in display exports.

Report completed/pending/error/excluded counts, covered roots, duplicate groups,
logical repeated bytes and the limits of any physical-space estimate. No
automatic removal, consolidation, moves, renames or hard-link replacement.

## Private navigation and product synergies

Provide local search by content ID, original filename, date with provenance,
format, project/source alias, duration and backup/restore status. SQLite metadata
indexes are sufficient first; optional full-text search needs an availability
probe and separate scope. Search works against the last inventory while the NAS
is off and visibly shows its timestamp, partial coverage and offline status.
Opening a file requires a newly authorized live access window.

For dt-library integration, keep private RAW, curated publishing content,
identity/provenance and exception accounting separate. Reuse those boundaries
without adopting the newsletter pipeline's interpretation of duplicate inputs.
Consumer source checkpoints stay in the private design evidence until the
receiving owner approves public attribution. Propose an
owner-agreed reference from a studio asset to a media content ID and approved
derivative. dt-library receives only admitted publishing metadata; no personal
inventory, footage bytes, transcripts or RAW path is transferred by default.

Studio editors can resolve private project references to originals and keep
proxies/deliverables separately identified. Transcription, thumbnails, semantic
search and cloud/model calls require later privacy, rights, dependency and
provider approval. ZEOconnect holds credentials; Runtime supplies a separately
admitted execution lane; Messenger carries redacted task receipts. The NAS
never becomes a ZEO seat workspace.

## Access and offline operation proposal

Use a dedicated discovery account with read/list rights only on the shares the
operator approves. Deny administration, writes, deletion and access to unrelated
homes or applications. Confirm effective server ACLs, inherited groups and a
read-only client mount independently. Test ACL denial with an operator-owned
synthetic canary through a separately approved test; do not attempt writes to
personal data to prove read-only behavior.

Propose Tailscale access from the approved execution host, with the exact
topology retained in the private operator plan. Limit the grant to that
approved host/identity, destination and
chosen file-service port, with no broad subnet or admin-console access.
[Tailscale grants](https://tailscale.com/docs/features/access-control/grants)
can restrict destination/protocol/port; they do not establish file permissions.
The NAS owner chooses the supported read-only file protocol after confirming
its actual firmware and services. No new tailnet enrollment or policy edit is
authorized here.

Credentials live only in ZEOconnect and are supplied through its approved
ephemeral connection path. Never put secrets into command arguments, shell
history, environment dumps, files, messages, logs or Git. Confirm a suitable
NAS connection exists with the Connect owner before the first session; do not
invent a connector API or substitute a shared administrator credential.

Storage availability is operator-controlled. When unavailable, record `offline`,
preserve the last scan as stale, and send one request to the Architect for an
operator-approved availability window. Do not wait silently, auto-wake, retry
indefinitely or infer data loss
from unavailability. The private first-session annex defines the exact proposed
read-only commands and private evidence destination. No account or mount is
created during this task.

## Offsite protection and verified restores

Keep originals on the NAS, one versioned encrypted off-site copy in a separate
failure domain, and an additional disconnected or independently protected copy
where the operator can provision it. Choose a destination only after capacity,
cost, data-residency, upload-time and custody review; no paid provider or transfer
is approved by this design. Agree an initial RPO target of one approved backup
window and an RTO target of 24 hours for a priority subset; whole-vault RTO must
follow measured volume and throughput. These are proposed targets for operator
decision, not measured capabilities.

Use rsync over an approved encrypted channel to a new, versioned destination
namespace as the simplest candidate. Preserve source relative paths and include
non-media files and native backup packages. Source rights stay read-only;
destination rights allow creation only inside the named backup version. Do not
use delete, remove-source, in-place, or pruning options. Never propagate source
absence as deletion. A partial version stays explicitly incomplete and cannot
replace the last verified version.

The [rsync manual](https://www.samba.org/ftp/rsync/rsync.1.html) distinguishes
transfer checksums from its pre-transfer change check. Dry run previews changes;
neither it nor a successful transfer proves a restore. Negotiate actual tool
versions and metadata support before writing an exact future transfer command.
Verify ACLs, xattrs, hard links and symlink handling explicitly for device backup
sets; a plain archive flag is not a universal preservation guarantee. Include
the private manifest/catalogue, encryption metadata and recovery instructions in
the protected backup. A client-side encrypted format may require another tool
and its dependency review; do not claim rsync supplies at-rest encryption.

Before any future write, the operator must approve a finite plan and dry-run
diff. Establish NAS snapshots if its actual firmware/filesystem supports them,
with operator-controlled retention; snapshots alone do not replace off-site
protection. Complete the off-site copy and prove restores first. Any new writer
account is separate from discovery, restricted to explicitly named new folders
and the approved window. This never grants the seat permission to delete, move
or rename existing NAS/backup data. Snapshot retention/deletion remains with
the operator under its own policy.

A backup receipt reconciles planned objects/bytes against copied, verified,
failed and pending objects; an interrupted or failed item prevents completion.
Hash destination bytes independently against the stable source manifest, then
restore to a fresh isolated scratch location outside NAS/backups and compare
full hashes, sizes, metadata and application readability. Test ordinary files,
large footage, companion metadata and at least one native device backup using
its application-level restore procedure. Test recovery when the NAS is offline
and when the catalogue must be rebuilt. Keep recovery keys solely under
ZEOconnect/operator custody and test authorized retrieval without logging them.

Propose a restore drill after the first copy, after format/tool/key changes and
monthly thereafter, plus a capacity-planned full recovery exercise quarterly.
Retain failed drills and exact tool versions privately. Only a successful,
independently checked restore and operator acceptance can close protection
acceptance. It never authorizes source cleanup.

## Review and acceptance

| Decision or evidence | Required owner and outcome |
| --- | --- |
| Code-study/design review | Independent reviewer assesses the source findings, separation of effects, duplicate coverage, privacy and recovery plan. |
| Contracts and dependency pins | Zeocore and relevant consumers agree ownership and compatible versions before implementation; required dependency checks precede installation. |
| First discovery session | Operator approves the private annex, exact roots, time, account/ACLs, connection custody and commands. Only then can read-only access occur. |
| Protection | Operator selects destination, RPO/RTO, retention and key recovery; separate scope proves copy and restore before any write plan. |
| Council conditions | Resolve legacy NAS targets/defaults and current-HEAD public-data scrubbing under exact implementation coverage. Before any product implementation, require offline negative controls for duplicate coverage, path/collision containment, no overwrite, verification errors/omissions, changed reads, preview-manifest rejection and absent roots. |
| Source publication | Full owning gate on exact commit HEAD, `DIRTY 0`, actual host, exit code and log SHA256 recorded before any new PR; publication restrictions remain binding. No PR event may start heavy CI. |
| Completion | Council/operator receive and explicitly accept the reviewed memo and private annex. Receipt, a commit or a local check alone does not complete the SOW. |

The before-product-implementation C2 condition above remains the whole-product
qualification boundary. Architect ans_b363a376f80dd0a9 and issued SOW01 revision4
explicitly allocate the bounded verifier error/coverage phase described below
before that whole-C2 qualification is complete. This is a phase-specific source
allocation, not a claim that the seven categories, Python pin or full-source scrub
are met. Independent Council receiving and all broader product/NAS holds remain.

At the inspected baseline there was no offline source gate; its `make verify`
ran the NAS migration verifier. The Architect subsequently approved a finite
same-SOW amendment: `make verify` now calls only `scripts/verify-source.sh`,
and the legacy NAS verifier is explicitly named `make verify-migration`.
Unknown targets fail. Neither the source gate nor its tests execute a NAS
operation or import the application modules.

The full gate for this design/source slice checks Python syntax and indentation,
existing ruff fatal-error rules (`E9,F63,F7,F82`), shell syntax, changed-document
whitespace/fences/local links, standalone SOW lines, and a finite public artifact
boundary. Standard-library tests exercise passing and rejecting inputs plus
Make routing and unknown-target rejection. The scope check permits only this
memo, Makefile, the gate script and both README updates to differ from the
inspected baseline. The README updates distinguish offline source checks from
NAS verification and remove source-cleanup advice.
It checks local link targets against tracked source without following them or
making network requests. Privacy checks reject named private artifact classes,
host absolute paths and private-key headers; human privacy review remains
necessary. The gate requires a clean checkout, Python 3.12+ and already-installed
ruff; it installs nothing and leaves the checkout clean.

This is the owning publication gate for the approved design-only slice, not
evidence that existing migration behavior is safe. Product changes require
separate scope and behavioral tests for the documented defects. Run the full
gate on the exact commit in the assigned clean lane and preserve all failures.
Keep a single source writer and one open PR, with Architect signature and normal
merger integration without self-approval or self-merge.

Council design conditions remain distinct from this source gate. The private
catalogue and metadata-minimization rules above address the written design;
they do not establish an implementation. Current public baseline configuration
and examples require a finite scrub at HEAD, with history rewriting reserved
to the operator. Any future writer needs independently reviewed partial-version
and no-replacement publication semantics compatible with the charter's ban on
moving or renaming NAS/backup content. Resolve that interface before coding it.
Custody, network policy, execution placement, account ACLs, dependency adoption
and an off-site provider each retain their owner/Council approval requirements.


### Council C1 repair awaiting independent review

The Makefile no longer supplies storage-volume defaults or literal host roots.
All seven legacy storage targets (`check-volumes`, `analyze-dry`, `analyze`,
`migrate`, `verify-migration`, `index-catalog`, `link-project`) depend on a
shared failing guard and a failure as the first line of each recipe. Explicit
root variables and `make -o nas-disabled` cannot enable their recipes.
The offline gate executes each target with temporary synthetic roots and a
recording worker, requiring failure before that worker is reached. Tests also
mark the shared guard old (and analysis prerequisites old) to exercise each
recipe refusal. Seven fixtures remove one recipe guard at a time and must fail
the refusal assertion; six reach the recording worker and the volume-check
fixture succeeds against its temporary root, demonstrating the missing guard.
These controls qualify Make entry-point refusal only. Council C2 product behavior
controls remain unimplemented and require separate product scope. C1 acceptance
requires Council review of the new exact head; earlier signatures do not apply.


Council approved source head `7e99631` with binding conditions, then identified
that `make -o nas-disabled` can skip a prerequisite-only guard. This repair puts
the refusal first in every storage recipe; independent review applies to the
new exact head only. No NAS session is authorized by the earlier verdict.
C2 and the finite public-scrub backlog also retain host defaults in
`scripts/new_shoot.sh`, `scripts/scaffold_project.sh` and `analyzer.py`'s manifest
generation.
Those files remain outside this five-path implementation slice. The getting-started
advice to restore a target-volume default is removed here. Neither this targeted
removal nor the Make repair constitutes a full public-source scrub or product
qualification. Missing structure/migration-preview Make commands are no longer
presented as usable commands in the READMEs. Public role-name disclosure remains
an Architect review decision; no infrastructure inventory is added.


### Commit audit after integration

Architect decision `ans_85e97300b0c3ba70` clarifies that integration commits with
more than one parent inherit SOW coverage and need no separate SOW line. The
offline gate audits every non-merge commit reachable since the original baseline,
including commits on merged side branches; it does not use first-parent history.
Every implementation commit still needs an exact standalone SOW line. No commit,
parent, source tree or baseline is rewritten, and no historical SHA is exempted.
Disposable bare Git graphs check that a merge with covered parents passes, a
linear implementation with a missing or nonstandalone line fails, and an
uncovered implementation on a second-parent history fails. These controls are
source-policy checks, not C2 product or NAS qualification.


## Verifier error and coverage amendment, 27 October 2026

Architect ans_b363a376f80dd0a9 grants exactly existing verifier.py and new
[test_verifier_safety.py](../../tests/test_verifier_safety.py), plus bounded gate
and documentation changes in the original five paths. The full offline make verify
now preserves all18 source controls and runs the actual verifier/Click CLI against
synthetic local temporary files, using already available declared dependencies.
The source-only no-application-import statement above describes the prior slice;
this explicit amendment adds local verifier tests, never a NAS or provider run.

Read errors, missing/corrupt entries, malformed manifests and mismatched declared
coverage return failure; the CLI exits nonzero. Every manifest entry is checked,
including duplicate-labelled entries. Valid empty manifests say no files were
checked. Successful verification reports only the number of verified manifest
entries and never grants cleanup authority. Outcome counters reset for each run.
Basic selected-root/path/symlink refusals constrain the synthetic verifier cases;
this is not qualification of race-free filesystem traversal or the relay protocol.

The suite uses actual BLAKE3 for positive/corrupt fixture checks, deterministic
read-error injection through the hash collaborator and an actual module subprocess
for CLI status. Assertion-killed mutations restore the legacy success predicate,
remove failed CLI propagation and filter duplicate entries. No dependency installs,
real inventories, NAS reads, media transfers or destructive storage operations run
inside the gate. This fixes one C2 unit; other C2 categories, Python pinning, full
tracked-source scrubbing and N9 relay qualification remain separate open holds.
