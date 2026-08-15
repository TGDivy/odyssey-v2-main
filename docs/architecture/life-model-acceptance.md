# Life-model acceptance

Odyssey treats the Charter, life stage, and season as owner-accepted normative
state, not as mutable model memory. This implementation covers the server-side
acceptance and history boundary for §§6–7. It does not yet provide the native
Workshop editor or offline acceptance queue.

## Authority boundary

- Only an authenticated owner command can append an accepted version.
- `metadata.created_by` must be the authenticated owner. Model, integration,
  system, and device actors cannot accept orientation state.
- Assisted and imported documents require an explicit owner-reviewed or
  owner-approved acceptance method. `Season.created_from` must match it.
- No background job, inferred behavior, generic sync document, or model output
  can activate a Charter, life-stage revision, or season.
- Every accepted document keeps a UUIDv7 provenance record and content hash.

The server ships no permanent Charter seed. A future native editor may begin
from the commission seed, but the owner must edit or affirm it before it becomes
accepted state.

## Immutable storage

`life_model_versions` stores one append-only row per accepted document:

- owner, kind, logical identity, monotonically increasing logical version, and
  a unique per-kind acceptance sequence that closes concurrent root races;
- explicit predecessor version;
- acceptance method/time and optional season status;
- canonical document and SHA-256 content hash;
- ledger event ID/type/sequence and recorded time.

ORM listeners and PostgreSQL/SQLite triggers reject update and delete. The
same transaction appends source/provenance, a registered domain event, an
outbox job, and the accepted version. Owner export includes these rows.

Retries reuse `event_id`. Replaying identical content returns the original
ledger sequence with `created=false`; changing acceptance semantics or reusing
an ID owned by another durable event fails. Every non-initial command must name
`expected_current_version_id`, so a stale device receives a conflict instead of
silently winning.

## Endpoints

All routes require Odyssey owner authentication:

| Route | Purpose |
| --- | --- |
| `POST /v1/seasons/charter/revisions` | Accept an initial Charter or deliberate revision |
| `POST /v1/seasons/life-stage/revisions` | Accept an owner-authored/reviewed descriptive stage |
| `POST /v1/seasons/revisions` | Accept a season version, status change, or explicit successor |
| `GET /v1/seasons/orientation` | Resolve the accepted version of each kind as of an optional instant |
| `GET /v1/seasons/history?kind=...` | Inspect immutable accepted history, newest first |

The generated OpenAPI document is the field-level request/response contract.
Commands include a device ID for authenticated-device matching and audit, but
development auth has no bound device.

## Charter rules

- The logical `charter_id` never changes after initial acceptance.
- `version_number` and `metadata.revision` increase exactly by one.
- `supersedes_version_id` must equal the current accepted version.
- Logical revisions preserve original `metadata.created_at`.
- At least one chosen value and one anti-optimization statement are required.
- Accepted times cannot move backward through a supersession chain.

This is deliberate revision, not preference inference. A changed Charter is a
new inspectable document and event; prior meaning remains exportable.

## Life-stage rules

Life stage remains descriptive. The acceptance endpoint records only a document
the owner authored or reviewed. It does not infer culturally normative career,
partnership, family, geography, health, or financial milestones. A major
transition may use a new `stage_id`; its first logical revision still explicitly
supersedes the current accepted life-stage version.

## Season rules

An accepted season must reference the current accepted Charter revision and
include the decision-policy fields required by §7: provenance, explicit
non-goals, qualitative good-week description, transition triggers, review
cadence, constraints/budgets/signals/guardrails, protected experiences, and
categorical portfolio allocation.

The service enforces these versioned status transitions:

```text
draft -> draft | calibration | active | abandoned
calibration -> calibration | active | abandoned
active -> active | transitioning | abandoned
transitioning -> transitioning | complete | active
complete / abandoned -> terminal for that season identity
```

A successor is accepted only after the current season reaches a terminal state,
uses a new `season_id`, explicitly names `supersedes_season_id`, and starts as
draft, calibration, or active. This emits `season.transitioned.v1`; activation
and same-season revisions emit registered activation/revision events. Existing
historical rows are never rewritten.

Composition remains a soft product constraint where the specification says it
should: atypical primary counts, more than two supporting directions, or more
than five foundations return warnings. More than two primary directions still
requires an explicit explanation at the domain-contract layer.

## Downstream resolution

The deterministic context builder resolves accepted versions as of the
requested scenario time and emits them as `charter_version`, `life_stage`, and
`season_version` facts. It intentionally drops generic canonical sync entities
with life-model names. This prevents a raw sync write or unresolved multi-device
edit from changing recommendation context.

Current resolution uses the accepted supersession timeline. A future local
editor must apply the same rules before queueing an acceptance command and must
show semantic conflicts rather than applying last-write-wins.

## Deployment and operations

Migration `20260815_0017` creates the table, checks, indexes, self-reference,
and append-only triggers. Re-run `infra/gcp/sql/least_privilege_grants.sql`
after migration: API has DML, backup is read-only, and the bounded export worker
receives read-only access to `life_model_versions`.

After deploying, verify:

1. Alembic reports `20260815_0017`.
2. Both append-only triggers exist in the target database.
3. API can append/read synthetic versions and worker can only select them.
4. Reusing a command event is idempotent and a stale predecessor returns `409`.
5. Context contains only accepted life-model facts.
6. Owner export includes `life_model_versions` and no credential material.

Do not insert or repair accepted orientation rows with SQL. Restore/replay the
immutable source and ledger or use a reviewed forward command. Keep real
Charter/life-stage/season response bodies and exports out of tickets, logs, and
source control.

## Remaining work

- Native Workshop editor, review diff, semantic conflict UI, and acceptance
  ceremony.
- Atomic local SQLite history and offline queue using the same command rules.
- Sync projection/receipt integration across multiple owner devices.
- Frozen outgoing-season summary and optional retrospective draft.
- Recommendation and UI citations that expose which accepted versions were
  used.
- macOS/Xcode/device validation; this Linux run had no Swift toolchain.
