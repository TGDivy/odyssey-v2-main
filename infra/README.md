# Odyssey infrastructure

The local stack mirrors production boundaries without requiring credentials:

- PostgreSQL 17 with `pgvector`, range-index support, and cryptographic helpers;
- S3-compatible MinIO object storage;
- the same API container used by Cloud Run;
- a separately runnable idempotent-worker process;
- deterministic model and development-auth modes.

Start it with:

```bash
make dev
```

The API is available at `http://127.0.0.1:8080`, and the MinIO console is at
`http://127.0.0.1:9001`. All credentials in `compose.yaml` are local-only and
must never be reused outside the local environment.

The one-shot `storage-init` service creates the private `odyssey-local` bucket
and enables versioning before the API starts. The API uses the same S3 adapter
boundary as a production-compatible object store; direct filesystem storage is
reserved for credential-free tests and explicitly selected local processes.

Container registries may be unavailable from managed development networks. A
registry timeout does not require changing image provenance; use an approved
network or pre-pull the pinned images. Production image and account setup is
documented separately under `docs/deployment/`.

Destroying Compose volumes deletes only synthetic local data. No production or
owner export path may instruct an operator to delete a volume to solve a schema
or migration problem.
