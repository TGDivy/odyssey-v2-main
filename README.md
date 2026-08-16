# Odyssey

Odyssey is a private, Apple-native, local-first personal navigation system. It
keeps durable personal history, assembles context for consequential moments,
and supports action without turning life into a score or delegating agency to
an AI model.

The authoritative product and implementation contract is
[`docs/Odyssey_Master_Specification_2026-08-15.md`](docs/Odyssey_Master_Specification_2026-08-15.md).

## Current status

Implementation is proceeding in the specification's edition order:

1. durable substrate and executable skeleton;
2. orientation and low-friction foundations;
3. decision, consequence, and intent loops;
4. personal evidence, archive, and domain depth;
5. meta-learning and expressive world.

No production credentials or real personal data are required for local
development. Synthetic fixtures and deterministic fakes are the default.

## Prerequisites

- Git 2.45 or newer
- GNU Make 4 or newer
- Python 3.13 or newer
- [uv](https://docs.astral.sh/uv/)
- Docker with Compose v2
- Xcode with Swift 6.1 or newer for Apple targets (Mac-only)
- OpenTofu 1.8 or Terraform 1.9 for cloud provisioning

Run `make diagnostics` to see which capabilities are available on the current
machine. Commands that require Xcode are reported as skipped outside macOS.

## Repository map

- `apple/` — iPhone, Watch, iPad, Mac, widgets, intents, and Swift packages
- `backend/` — FastAPI modular monolith, workers, migrations, and tests
- `schemas/` — JSON Schema, OpenAPI, event contracts, and generated artifacts
- `infra/` — local containers and Google Cloud infrastructure as code
- `evals/` — replay cases, rubrics, datasets, and reports
- `fixtures/` — deterministic synthetic-life and integration fixtures
- `research/` — evidence manifests and appraisal templates
- `tools/` — code generation, diagnostics, import/export, and repair utilities
- `docs/` — architecture, decisions, runbooks, deployment, and product policy

## Quick start

The executable stack is introduced milestone by milestone. The stable entry
points are:

```bash
make diagnostics
make bootstrap
make dev
make verify
```

`make verify` runs every check available in the current environment and lists
Mac-only checks separately rather than silently pretending they ran.

## Evaluation corpus

Odyssey keeps provider-neutral evaluation artifacts under `evals/`. The first
version includes all twenty Appendix 48 stress scenarios, eight anchored
quality/safety rubrics, and golden replays through six production deterministic
policies. Validate the strict contracts, file digests, expected outputs, and
cross-policy safety invariants with:

```bash
cd backend
uv run python ../tools/evals/run.py --check
```

This command is part of `make verify`. It does not grade open-ended model
prose, prove Apple UI behavior, or replace historical, shadow, security, or
longitudinal evaluation. The scoring workflow, privacy rules, model-change
gate, and current evidence boundaries are documented in
[`docs/evaluation-protocols.md`](docs/evaluation-protocols.md).

## Accepted orientation state

Owner-authenticated commands under `/v1/seasons/*` now append immutable
Charter, descriptive life-stage, and season versions with optimistic
supersession, provenance, ledger events, and transactional outbox records.
Only deliberately accepted versions enter server context assembly; a generic
synced `season` document cannot silently become normative owner state.

The native portable layer now persists a separate immutable offline acceptance
queue, validates authenticated route bodies against queued metadata, delivers
commands sequentially with bounded retries, records `409` as an owner-review
conflict, and caches auditable server history. The iPhone Workshop provides
typed plain-language Charter, descriptive life-stage, and season editors; an
editable commission-derived seed; exact semantic review and immutable
acceptance confirmation; a hash-bound frozen outgoing-season summary with an
optional accepted/skipped retrospective; accepted history; terminal conflict
guidance; and offline queue status. These SwiftUI paths are source-validated
here but still require Xcode, simulator, accessibility, and physical-device
validation. Do not seed real orientation data through SQL or treat model output
as accepted.
See [`docs/architecture/life-model-acceptance.md`](docs/architecture/life-model-acceptance.md).

## Safety invariants

- Local capture and core state never depend on network or model availability.
- Personal history is append-only at the fact layer and recoverable by export.
- Consequential facts, recommendations, and model outputs retain provenance.
- Silence is a valid intervention result.
- People are never ranked and there is no universal Life Score.
- AI does not own canonical state, permissions, or irreversible actions.
- External side effects require the configured authority and confirmation.

See `docs/constitution.md`, `SECURITY.md`, and the architecture decision records
under `docs/adr/` before changing these boundaries.

Operational recovery procedures are indexed in `docs/runbooks/README.md`.

## Deployment

Local development is credential-free. Cloud and Apple account setup stays
outside source control and is documented step by step in
[`docs/deployment/OWNER_HANDOFF.md`](docs/deployment/OWNER_HANDOFF.md), including
owner-only gates, expected outputs, troubleshooting, evidence, entitlements,
deployment, rollback, export, and restoration.

## Encrypted owner export

Appendix B.9 is available at `POST /v1/exports`, is owner-authenticated, and is
disabled until durable object storage and a dedicated wrapping key are
configured. Jobs run through the transactional outbox; status and resumable
download use `GET /v1/exports/{job_id}` and
`GET /v1/exports/{job_id}/download`.

For a synthetic local drill, set `ODYSSEY_OWNER_EXPORT_ENABLED=true`, generate
at least 32 bytes of private `ODYSSEY_EXPORT_WRAPPING_KEY` material outside the
repository, start both API and worker with the same value, and submit the owner
passphrase only in `X-Odyssey-Export-Passphrase`. Verify a downloaded artifact
without placing the passphrase on the command line:

```bash
cd backend
uv run python ../tools/export/decrypt_owner_export.py \
  /private/path/odyssey-export.odyx \
  --expected-signing-public-key 'REPLACE_BASE64_KEY_FROM_JOB_STATUS'
```

The decrypted ZIP contains signed JSONL/CSV/Markdown datasets and optional raw
attachments, but excludes authentication/recovery credentials, operational
secrets, outbox state, and worker key material. See
[`docs/architecture/owner-exports.md`](docs/architecture/owner-exports.md) for
the format and threat boundary and
[`docs/deployment/OWNER_HANDOFF.md`](docs/deployment/OWNER_HANDOFF.md) for the
production key ceremony and first drill.

## Data policy

Never commit real personal data, access tokens, provider payloads, signed Apple
artifacts, production exports, or decrypted backups. Use only fixtures from
`fixtures/synthetic-life/` in tests and demos.
