# Life-model acceptance

Odyssey treats the Charter, life stage, and season as owner-accepted normative
state, not as mutable model memory. This implementation covers the server-side
acceptance/history boundary, portable native draft and offline-command ledgers,
authenticated delivery, immutable history cache, and the iPhone Workshop
editor/review/conflict surface for §§6–7.

## Authority boundary

- Only an authenticated owner command can append an accepted version.
- `metadata.created_by` must be the authenticated owner. Model, integration,
  system, and device actors cannot accept orientation state.
- Assisted and imported documents require an explicit owner-reviewed or
  owner-approved acceptance method. `Season.created_from` must match it.
- No background job, inferred behavior, generic sync document, or model output
  can activate a Charter, life-stage revision, or season.
- Every accepted document keeps a UUIDv7 provenance record and content hash.

The server ships no permanent Charter seed. The native Workshop can create an
editable synthetic seed derived from the commission, but it remains an
owner-authored local draft until the owner reviews and accepts that exact
version.

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

Every version envelope includes its immutable `event_id` and `ledger_sequence`.
Native clients therefore cache auditable server history rather than inferring
event identity from the most recent POST receipt.

## Native offline delivery

SQLite schema v3 stores the immutable acceptance request and document separately
from mutable delivery state. Reusing an event or version ID for different
content fails locally. Accepted server versions are append-only cached records;
integrity verification and owner export include both command attempts and the
remote history cache. Normative commands never enter generic sync.

`URLSessionLifeModelTransport` obtains a bearer token per call, allows only the
validated HTTPS/development-loopback origin, refuses redirects, cookies and
caches, bounds response bodies, and validates that queued JSON exactly matches
its immutable event, version, logical identity, predecessor, method, acceptance
time and document before transmission.

`LifeModelAcceptanceCoordinator` coalesces concurrent runs and submits ready
commands in local sequence order. Successful receipts must exactly match the
queued command before transactionally becoming accepted and cached. Network and
retryable API failures use bounded exponential delays. A delayed retry blocks
every later command, and scheduling a retry stops the current delivery batch;
terminal conflicts and rejections do not block an ordered successor. HTTP `409`
is terminal:
the command becomes a reviewable conflict, current orientation is fetched and
cached when available, and no last-write-wins merge occurs. Persisted failures
use fixed local copy and never retain the server message. Each run also refreshes
bounded history for all three kinds; history failures do not reverse an already
durable acceptance outcome.

Workshop drafts reuse the existing local fact-and-event ledger instead of a
mutable side database. Creation, every content edit, semantic review, queueing,
and abandonment append local-only `life_model.draft.*` events and sequential
`life_model_draft` projection revisions; no draft enters generic sync. The
portable Workshop service validates the typed Charter/life-stage/season domain
contract, owner authorship, immutable identities and canonical JSON on every
edit. Review compares the draft with its immutable cached predecessor while
hiding storage metadata and IDs. Queueing requires the exact persisted review
digest, then emits the dedicated acceptance command. Draft history is therefore
recoverable by ledger replay and included in owner export without making a
model-generated suggestion canonical.

## Native Workshop ceremony

`LifeModelWorkshopDraftFactory` creates owner-authored Charter, descriptive
life-stage, and Charter-bound season proposals. It also creates same-identity
revisions from immutable cached history and a new-identity successor only after
a terminal season. Identity, version, predecessor, metadata, provenance, and
effective-interval fields are not editable through SwiftUI.

The iPhone Workshop exposes only typed plain-language fields:

- chosen Charter values, responsibilities, ways of being, boundaries, and
  anti-optimization statements;
- descriptive career, partnership/family, health/capability, geography,
  financial, care, identity-transition, horizon, and uncertainty context;
- season status, portfolio role/allocation, minimum commitments, sacrifice
  limits, signals, constraints, opportunity budgets, non-goals, guardrails,
  protected experiences, trade-offs, good-week description, review cadence,
  and transition conditions.

Saving appends a local draft event. Review persists the exact document digest
and presents metadata-free semantic changes plus attention warnings. Acceptance
requires a separate explicit acknowledgement that this exact version is
immutable. Offline acceptance stays in the dedicated command queue; enrollment
then triggers sequential authenticated delivery and a complete remote-history
refresh. Accepted history is decoded back into typed read-only views.

Terminal `409` conflicts display fixed local guidance. No server message text is
persisted or shown as authority, and no auto-merge occurs. After history refresh,
the owner can inspect the newly accepted meaning and start a fresh reviewed
revision.

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

Current resolution uses the accepted supersession timeline. The native Workshop
constructs the dedicated queue command only from an exact persisted review,
shows the semantic diff, refreshes immutable history after delivery, and
surfaces terminal conflicts rather than applying last-write-wins.

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

- Xcode/UI automation and a two-device Workshop refresh proof against the
  server history cache.
- Frozen outgoing-season summary and optional retrospective draft.
- Recommendation and UI citations that expose which accepted versions were
  used.
- macOS Workshop parity and Xcode/accessibility/device validation.
