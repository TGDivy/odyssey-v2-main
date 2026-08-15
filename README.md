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
- Xcode with Swift 6 for Apple targets (Mac-only)
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

Local development is credential-free. Cloud and Apple account setup is kept
outside source control and will be documented step by step in
`docs/deployment/OWNER_HANDOFF.md`, including expected outputs, secrets,
entitlements, deployment, rollback, export, and restoration.

## Data policy

Never commit real personal data, access tokens, provider payloads, signed Apple
artifacts, production exports, or decrypted backups. Use only fixtures from
`fixtures/synthetic-life/` in tests and demos.
