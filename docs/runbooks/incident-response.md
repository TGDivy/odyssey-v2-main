# Incident response

## Scope and severity

Use this runbook for suspected data loss/corruption, failed integrity checks,
stuck migrations, unavailable sync, exposed credentials, unsafe AI behavior,
or unauthorized side effects.

| Severity | Meaning | Initial response target |
| --- | --- | --- |
| SEV-1 | Active confidentiality breach, destructive writes, or unrecoverable history risk | Immediate |
| SEV-2 | Integrity failure, blocked capture/sync, restore failure, or unsafe consequential output | 30 minutes |
| SEV-3 | Degraded noncritical integration, stale derived state, or contained defect | One working day |

## 1. Contain without destroying evidence

Record UTC start time, environment, release SHA, database revision, affected
capability, and a payload-free symptom. Preserve the request correlation ID and
integrity/restore report hash when available.

Enable only the narrow controls required. Examples from `backend/`:

```bash
uv run python ../tools/admin/kill_switch.py \
  --database-url "$ODYSSEY_DATABASE_URL" enable capture_writes \
  --reason 'SEV-2: investigate durable write anomaly' \
  --changed-by "$ODYSSEY_OPERATOR_ID"

uv run python ../tools/admin/kill_switch.py \
  --database-url "$ODYSSEY_DATABASE_URL" enable destructive_compaction \
  --reason 'SEV-2: preserve evidence during integrity investigation' \
  --changed-by "$ODYSSEY_OPERATOR_ID"
```

Use `sync_push`, `sync_pull`, `proactive_delivery`, `ai_generation`, or
`external_side_effects` instead when that is the failing boundary. Do not block
local client capture merely because cloud intelligence is unavailable.

For a suspected credential breach, revoke/rotate the credential at its provider
before attempting normal recovery. Do not paste the old or new secret into the
incident record.

## 2. Preserve a checkpoint

For a local or isolated SQLite/PostgreSQL environment, create a new native
bundle. The explicit plaintext flag is local-only:

```bash
backup_dir="/secure/operator/path/incident-$(date -u +%Y%m%dT%H%M%SZ)"
uv run python ../tools/backup/pre_migration_backup.py \
  --database-url "$ODYSSEY_DATABASE_URL" \
  --destination "$backup_dir" \
  --allow-plaintext-local
```

Production uses Cloud SQL PITR plus the encrypted logical-dump workflow from the
owner handoff; never write a plaintext production dump to `/tmp`.

Expected output includes `artifact_verified: true`, a manifest SHA-256, schema
revision, artifact hash, and `recovery_validation: pending_clean_room_restore`.
Artifact verification is not a successful recovery.

## 3. Diagnose from references

Run integrity checks without printing record payloads:

```bash
report="/secure/operator/path/integrity-$(date -u +%Y%m%dT%H%M%SZ).json"
uv run python ../tools/integrity/check_database.py \
  --database-url "$ODYSSEY_DATABASE_URL" \
  --backup "$backup_dir" \
  --report "$report"
```

- Exit `0` means all applicable checks passed.
- Exit `2` means at least one check failed and destructive compaction is frozen.
- `not_configured` and `not_applicable` are explicit gaps, not passes.

Use [`record-trace.md`](record-trace.md) to follow a specific synthetic or
owner-approved identifier. Query IDs, counts, versions, and hashes first. View a
payload only with owner authorization and only on an approved machine.

## 4. Recover in isolation

Follow [`clean-room-recovery.md`](clean-room-recovery.md). Do not repair the only
copy in place. Prove the selected checkpoint restores, migrations apply, source
hashes match, provenance is reachable, and projections rebuild before changing
production.

When a code rollback is needed, roll back application traffic to a schema-
compatible build. Do not use an Alembic downgrade as an emergency substitute
for data recovery unless that exact downgrade was rehearsed and approved.

## 5. Resume deliberately

Before disabling a kill switch, require:

- root cause or bounded containment is documented;
- a fresh backup checkpoint exists;
- the isolated restore report is green;
- the current integrity report is green;
- affected clients/providers are reconciled;
- owner approval is recorded for consequential or privacy incidents.

Disable the narrow switch with a new reason. Never edit the prior audit row:

```bash
uv run python ../tools/admin/kill_switch.py \
  --database-url "$ODYSSEY_DATABASE_URL" disable destructive_compaction \
  --reason 'restore and integrity reports verified; incident INC-YYYYMMDD-N closed' \
  --changed-by "$ODYSSEY_OPERATOR_ID"
```

## 6. Close and learn

Record timeline, affected revisions, owner impact, detection gap, root cause,
recovery point/time, report hashes, corrective actions, and an explicitly
payload-free regression case. Rotate temporary access, remove local decrypted
artifacts, and verify external alerting still works. A SEV-1/2 closes only after
the next scheduled backup and integrity run also succeed.
