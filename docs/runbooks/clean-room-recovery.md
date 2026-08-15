# Clean-room recovery

## Objective

Prove a selected backup can reconstruct Odyssey in an isolated environment
without proprietary manual database editing. Initial targets are cloud RPO under
15 minutes, cloud RTO under four hours, and full clean-room rebuild under one
working day.

## 1. Select and verify the recovery point

Choose the last known-good native/logical database backup and object manifest.
Record their immutable hashes, creation times, schema revisions, encryption/key
versions, and the reason later recovery points are excluded.

For local bundles:

```bash
cd /path/to/backup
sha256sum -c manifest.sha256
```

This verifies only the manifest. The Odyssey restore tool rechecks both manifest
and artifact. Production selection must also verify Cloud SQL PITR availability
and object-version/lifecycle state.

## 2. Provision empty isolated infrastructure

Use a dedicated restore project/database/bucket with no production traffic,
separate service identities, restricted egress, and an external expiry ticket.
The target database must be empty. Never point the drill at production or an
existing developer database.

## 3. Create and verify the object archive

Attachment backup copies every database-referenced content hash into a separate
versioned archive store, verifies source and destination bytes, and writes a
mode-`0600` payload-free manifest. Production uses a separate GCS bucket and
ambient workload identity:

```bash
cd backend
uv run python ../tools/backup/object_archive.py backup \
  --manifest "$OBJECT_MANIFEST" \
  --archive-backend gcs \
  --archive-project "$RESTORE_PROJECT_ID" \
  --archive-bucket "$OBJECT_ARCHIVE_BUCKET" \
  --archive-kms-key "$OBJECT_ARCHIVE_KMS_KEY"

uv run python ../tools/backup/object_archive.py verify \
  --manifest "$OBJECT_MANIFEST" \
  --archive-backend gcs \
  --archive-project "$RESTORE_PROJECT_ID" \
  --archive-bucket "$OBJECT_ARCHIVE_BUCKET" \
  --archive-kms-key "$OBJECT_ARCHIVE_KMS_KEY"
```

For a credential-free synthetic drill, select `--archive-backend local`, pass
`--archive-path`, and add `--allow-plaintext-local-archive`. That approval is
for synthetic/local data only. The tool refuses plaintext local archives by
default.

## 4. Restore database and objects

Database-only local example from `backend/`:

```bash
uv run python ../tools/restore/clean_room_restore.py \
  --backup "$BACKUP_DIR" \
  --database-url "$EMPTY_RESTORE_DATABASE_URL" \
  --report "$RESTORE_REPORT_PATH"
```

Combined synthetic database/object example from `backend/`:

```bash
uv run python ../tools/restore/clean_room_restore.py \
  --backup "$BACKUP_DIR" \
  --database-url "$EMPTY_RESTORE_DATABASE_URL" \
  --object-manifest "$OBJECT_MANIFEST" \
  --object-archive-path "$LOCAL_OBJECT_ARCHIVE" \
  --object-restore-path "$EMPTY_LOCAL_OBJECT_TARGET" \
  --allow-plaintext-local-object-archive \
  --report "$RESTORE_REPORT_PATH"
```

The command refuses a non-empty target, verifies hashes, restores the native
artifact, applies current Alembic migrations, rebuilds projections, compares
non-derived table counts, restores every object named by the database and
manifest, checks database/foreign-key integrity, and writes a mode-`0600`
report. A successful object drill reports `object_restore: passed`, the exact
object count, and the object-manifest hash.

Database-only bundles report `object_restore: not_included_database_only`. That
is acceptable only when `attachment_objects` is empty. If any attachment object
exists, a matching object manifest and verified object restore are mandatory;
a database-only run is a failed recovery drill.

## 5. Run current integrity checks

```bash
uv run python ../tools/integrity/check_database.py \
  --database-url "$EMPTY_RESTORE_DATABASE_URL" \
  --backup "$BACKUP_DIR" \
  --report "$POST_RESTORE_INTEGRITY_REPORT"
```

Require zero source-hash mismatches, zero provenance orphans, active immutable
triggers, active foreign-key enforcement, matching ledger/projection counts and
sequences, and a successful backup freshness check where applicable.

## 6. Rotate recovery credentials

Create new restore-environment secrets and invalidate temporary bootstrap
credentials. A production incident also rotates any credential that may have
been exposed. Verify workloads use secret references, not copied plaintext.

## 7. Enroll a fresh client

Install a clean development/staging build on a fresh simulator/device, complete
owner bootstrap, pull the restored history, and compare server/client ledger
cursors and projection checksums. Do not use real owner history on an unmanaged
simulator.

## 8. Reconcile surviving local operations

Inject or replay the approved unsynced-operation fixture, then prove push is
idempotent, conflicts follow domain policy, tombstones do not resurrect, and
both simulated devices converge. Preserve the before/after operation IDs and
counts, not private payloads.

## 9. Approve or reject the recovery point

The drill passes only when database, objects (when applicable), migrations,
integrity, fresh-client enrollment, and operation reconciliation pass. Record
RPO/RTO, report hashes, mismatches, manual steps, and owner/operator approval.
Hash verification alone is never a pass.

## 10. Destroy the isolated environment

Retain only approved encrypted reports/artifacts under policy. Revoke temporary
identities, destroy restore databases/buckets/keys, remove decrypted local files,
and verify billing resources are gone. Destruction must target the restore
environment identifiers recorded in step 2; never use a wildcard or production
project default.

Quarterly production drills repeat every step. Credential-free synthetic drills
run whenever backup, migration, sync, or attachment formats change.
