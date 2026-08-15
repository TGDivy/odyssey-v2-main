# Odyssey backend

The backend is a Python modular monolith with separately runnable API and worker
processes. It keeps module ownership explicit while sharing one PostgreSQL
database and deployment artifact.

```bash
uv sync --all-groups
uv run odyssey-api
uv run pytest
```

The default configuration is safe for credential-free local development. Real
authentication, storage, integrations, and model providers must be enabled via
typed environment configuration and the deployment handoff.

## Durable data operations

Run migrations before importing data. This credential-free SQLite example uses
only the checked synthetic fixture:

```bash
export ODYSSEY_DATABASE_URL='sqlite+aiosqlite:////tmp/odyssey.sqlite'

uv run alembic upgrade head
uv run python ../tools/importers/import_synthetic_life.py \
  --database-url "$ODYSSEY_DATABASE_URL"
uv run python ../tools/data-repair/rebuild_projections.py \
  --database-url "$ODYSSEY_DATABASE_URL"
uv run python ../tools/export/export_database.py \
  --database-url "$ODYSSEY_DATABASE_URL" \
  --destination /tmp/odyssey-export
```

The fixture importer is idempotent and never resets the database. It preserves
the complete raw source documents, imports normalized events in transactions,
and rebuilds current-state projections. The repair command rebuilds projections
solely from the immutable ledger and exits nonzero if its integrity check fails.

The local export contains deterministic JSON Lines files for every Odyssey-owned
relational table plus a SHA-256 manifest. Verify the manifest with:

```bash
cd /tmp/odyssey-export
sha256sum -c manifest.sha256
```

Local exports are intentionally unencrypted development artifacts. Never place
real personal data in `/tmp` or source control; production owner-passphrase
encryption, resumable archive jobs, and signed manifests are separate deployment
requirements.

Before a local schema migration, create a native checkpoint in a new directory:

```bash
uv run python ../tools/backup/pre_migration_backup.py \
  --database-url "$ODYSSEY_DATABASE_URL" \
  --destination /tmp/odyssey-pre-migration-backup \
  --allow-plaintext-local
```

SQLite uses its online backup API, so committed WAL state is included without a
raw file copy. PostgreSQL uses `pg_dump` custom format and validates it with
`pg_restore --list`. The tool refuses to overwrite an existing destination,
writes owner-only files, checks the database/artifact structure, and verifies
detached SHA-256 hashes. `--allow-plaintext-local` is deliberately explicit:
this bundle format is not the encrypted production backup path.

Artifact verification does not make a backup recovery-valid. A backup remains
marked `pending_clean_room_restore` until the separate restore drill restores it
into an empty target and runs current migrations and integrity checks.

Run that drill against a target that does not yet exist (SQLite) or an empty,
isolated database (PostgreSQL):

```bash
uv run python ../tools/restore/clean_room_restore.py \
  --backup /tmp/odyssey-pre-migration-backup \
  --database-url 'sqlite+aiosqlite:////tmp/odyssey-restored.sqlite' \
  --report /tmp/odyssey-restore-report.json
```

The restore refuses a non-empty target, re-verifies the bundle, restores the
native database, applies the current Alembic head, rebuilds projections from the
ledger, runs database/foreign-key/projection integrity checks, and writes an
owner-only report. Database-only bundles explicitly report object restoration
as not applicable; once Odyssey owns attachments, their manifest is a mandatory
input rather than a silent skip. Secret rotation, fresh-client enrollment,
unsynced-operation reconciliation, and isolated-environment destruction remain
explicit report steps because they require operator or device context.
