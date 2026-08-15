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

For a logical cloud backup, download only the selected immutable cloud
manifest, its database generation, and the small archived object manifest. Do
not download the attachment archive itself. The selected manifest URI comes
from the successful backup-job report retained by operations:

```bash
umask 077
gcloud storage cp "$SELECTED_CLOUD_MANIFEST_URI" "$CLOUD_MANIFEST"

DATABASE_DUMP_URI="$({
  jq -r '.manifest.database_objects[]
    | select(.retention_tier == "daily")
    | "gs://\(.bucket_name)/\(.storage_key)#\(.generation)"' \
    "$CLOUD_MANIFEST"
} | head -n 1)"
OBJECT_MANIFEST_KEY="$(jq -r '.manifest.object_manifest_archive_key' \
  "$CLOUD_MANIFEST")"
OBJECT_MANIFEST_GENERATION="$(jq -r \
  '.manifest.object_manifest_archive_version' "$CLOUD_MANIFEST")"

test -n "$DATABASE_DUMP_URI"
test -n "$OBJECT_MANIFEST_KEY"
test "$OBJECT_MANIFEST_GENERATION" != null
gcloud storage cp "$DATABASE_DUMP_URI" "$DATABASE_DUMP"
gcloud storage cp \
  "gs://${OBJECT_ARCHIVE_BUCKET}/${OBJECT_MANIFEST_KEY}#${OBJECT_MANIFEST_GENERATION}" \
  "$ARCHIVED_OBJECT_MANIFEST"

cd backend
uv run python ../tools/backup/materialize_cloud_backup.py \
  --cloud-manifest "$CLOUD_MANIFEST" \
  --database-dump "$DATABASE_DUMP" \
  --destination "$BACKUP_DIR" \
  --archived-object-manifest "$ARCHIVED_OBJECT_MANIFEST" \
  --object-manifest-destination "$OBJECT_MANIFEST" \
  --allow-plaintext-isolated-restore
```

Use a dedicated encrypted operator volume and securely destroy the downloaded
database dump, materialized bundle, and manifests after the drill. The tool
refuses an existing destination and verifies the cloud envelope, selected dump
size/hash, archived object-manifest hash, and cross-manifest object counts
before writing mode-`0600` restore inputs.

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

Production GCS archive to isolated GCS destination, from `backend/`:

```bash
uv run python ../tools/restore/clean_room_restore.py \
  --backup "$BACKUP_DIR" \
  --database-url "$EMPTY_RESTORE_DATABASE_URL" \
  --object-manifest "$OBJECT_MANIFEST" \
  --object-archive-backend gcs \
  --object-archive-project "$PRODUCTION_PROJECT_ID" \
  --object-archive-bucket "$OBJECT_ARCHIVE_BUCKET" \
  --object-archive-kms-key "$OBJECT_ARCHIVE_KMS_KEY" \
  --object-restore-backend gcs \
  --object-restore-project "$RESTORE_PROJECT_ID" \
  --object-restore-bucket "$EMPTY_RESTORE_OBJECT_BUCKET" \
  --object-restore-kms-key "$RESTORE_OBJECT_KMS_KEY" \
  --report "$RESTORE_REPORT_PATH"
```

For an isolated local object destination, replace the four
`--object-restore-*` GCS arguments with
`--object-restore-backend local --object-restore-path "$EMPTY_LOCAL_OBJECT_TARGET"`
and add `--allow-plaintext-local-objects`. Never use that local mode with owner
data on an unmanaged or unencrypted machine.

The command refuses a non-empty target, verifies hashes, restores the native
artifact, applies current Alembic migrations, rebuilds projections, compares
non-derived table counts, restores every object named by the database and
manifest, checks database/foreign-key integrity, and writes a mode-`0600`
report. A successful object drill reports `object_restore: passed`, the exact
object count, and the object-manifest hash. GCS archive restoration reads and
verifies one content-addressed object at a time; the complete archive is never
staged on the operator machine.

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
