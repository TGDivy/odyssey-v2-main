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
