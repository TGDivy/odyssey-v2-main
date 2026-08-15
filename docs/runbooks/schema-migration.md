# Schema migration

## Policy

Every migration is monotonic, uniquely identified, reviewed with its model
change, and tested from the immediately previous revision. Use
expand/migrate/contract for removals. A release note must never instruct wiping
production data.

## 1. Design and preflight

Document:

- old and new revision IDs;
- backward-compatible mixed-version window;
- expected row/storage amplification and lock duration;
- backfill idempotency and resume cursor;
- projection rebuild/version change;
- semantic meaning change and provenance implications;
- rollback build and forward-fix plan;
- acceptance counts, hashes, and invariants.

Run from the repository root:

```bash
make verify
git diff --check
```

On a Mac, also run Swift migrations/package tests and generate the Xcode project.
Against the anonymized ten-year fixture, record import, migration, query, and
projection-rebuild duration. A timeout is a failed gate, not permission to reset.

## 2. Prove upgrade from the previous revision

Create a database at the previous revision, load its fixture shape, and then
upgrade to `head`:

```bash
cd backend
ODYSSEY_DATABASE_URL="$ISOLATED_DATABASE_URL" uv run alembic upgrade PREVIOUS_REVISION
# Load only deterministic fixtures or an approved encrypted snapshot shape.
ODYSSEY_DATABASE_URL="$ISOLATED_DATABASE_URL" uv run alembic upgrade head
uv run python ../tools/data-repair/rebuild_projections.py \
  --database-url "$ISOLATED_DATABASE_URL"
uv run python ../tools/integrity/check_database.py \
  --database-url "$ISOLATED_DATABASE_URL" \
  --report "$ISOLATED_REPORT_PATH"
```

Expected results: Alembic reaches the intended revision, no source/ledger row is
lost, append-only triggers remain present, projection integrity is healthy, and
all applicable checks pass.

## 3. Create the pre-migration checkpoint

Stop or drain server writers for migrations that cannot safely overlap writes.
Local client capture remains available and queues sync operations.

Create and verify a new checkpoint using the incident-response backup command.
Record its manifest hash and selected Cloud SQL PITR timestamp. Restore the
checkpoint into an isolated target using the clean-room runbook before a
high-risk or contract-phase migration.

## 4. Deploy expand/migrate

Order a mixed-version release as follows:

1. deploy schema expansion;
2. verify migration revision and duration;
3. deploy dual-read/dual-write compatible server code;
4. release compatible clients;
5. run resumable backfill with provenance/version metadata;
6. compare counts, hashes, and semantic invariants;
7. rebuild/version derived projections;
8. switch readers only after acceptance.

The API and worker never run migrations implicitly at process startup. The
dedicated migration job must finish successfully before new server tasks receive
traffic.

## 5. Observe and roll forward

Watch error rate, database locks/storage, queue backlog, mixed client schema
versions, source hashes, projection lag, and integrity status. If the release is
unsafe:

- enable the relevant audited kill switch;
- stop the migration/backfill at its durable cursor;
- route traffic to the schema-compatible prior build when possible;
- preserve a checkpoint and diagnose;
- roll forward with a corrective migration.

Do not contract old columns/tables during the rollback window. Contract only
after backup/restore validation, owner acceptance, and evidence no supported
client reads the old representation.

## 6. Record completion

Attach migration start/end UTC times, old/new revisions, release SHAs, backup and
restore report hashes, fixture performance, row/hash comparisons, projection
checksum, and any deferred contract work to the release record. Update schema
export documentation and the requirements audit when storage semantics change.
