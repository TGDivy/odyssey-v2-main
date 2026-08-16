# Native Now and Tomorrow context

Status: Milestone 1.4 repository implementation complete on 2026-08-16.
Portable policy, persistence, and composition are automated-test covered. The
SwiftUI and WidgetKit sources are parser-checked only; Xcode, signing,
accessibility, simulator, App Group, timeline, and physical-device behavior
remain owner-only proof.

## Product boundary

The iPhone Now surface is a bounded local projection, not a feed. It renders at
most three substantial objects:

1. a guilt-free re-entry card when a durable absence qualifies;
2. current context with at most one accepted Season thread and one next
   transition; and
3. a one-screen Tomorrow Map with at most three known transitions.

Quick Capture and Food remain local-first actions outside that object count. No
model, network response, remote credential, or free-form synthesis is required
to build any part of this surface.

The implementation never interprets missing or denied Calendar context as
intentional silence. It distinguishes:

- **intentional quiet**: Calendar context is fresh and the deterministic state
  is Clear, or the owner explicitly chose Stay Quiet;
- **known open time**: fresh Calendar context supports the Open state;
- **empty context**: no attention claim can be made from inspectable sources,
  but silence is not inferred; and
- **unavailable projection**: verified local state or source decoding failed,
  so the last valid projection remains visible when one exists.

## Deterministic current-state projection

`NativeNowContextProjector` composes accepted local Season history and the local
Calendar, Health, Weather, and broad Location mirrors. Each source is reported
as fresh, stale, missing, denied, or unavailable with a bounded observation
time.

State priority is fixed and tested:

1. Disrupted;
2. Recovery;
3. Preparation;
4. Choice;
5. Open; and
6. Clear.

The current native signals are deliberately narrow:

- a fresh broad place in a different IANA time zone from the device produces
  Disrupted;
- an explicit material Health constraint count can produce Recovery;
- a busy Calendar commitment beginning within three hours produces
  Preparation;
- overlapping current busy commitments or an explicit unresolved-decision
  count produce Choice;
- fresh Calendar context with no current or near-term busy commitment produces
  Open; and
- all other combinations produce Clear without claiming intentional silence
  unless the context gate passes.

The iPhone composition currently supplies zero explicit decision and Health
constraint counts because the corresponding durable decision/constraint
services are later milestones. It does not infer illness, injury, recovery, or
a decision from raw Health samples, Weather, capture text, or model output.
Weather is exposed as source availability but is not yet a state-changing
signal. The current thread is derived only from the latest immutable accepted
Season whose status can orient current action; drafts and queued proposals are
ignored.

A manual correction is reason-coded, local, explicit in the UI, and never
rewrites any source record. The UI uses a 24-hour expiry; the contract rejects
any correction lasting more than 48 hours. An expired correction is removed
from the hash-verified local state before the next projection. Owner-requested
quiet forces Clear and is represented as intentional owner choice even when
Calendar context is incomplete.

## Tomorrow Map

`TomorrowMapProjector` uses named-zone Gregorian calendar arithmetic rather
than fixed 24-hour offsets, so local-day boundaries survive daylight-saving and
travel transitions. The current v1 input is the bounded local Calendar mirror
plus the accepted Season thread.

The projector:

- labels stale Calendar context and renders it as cached rather than current,
  while missing, denied, or unavailable context fails closed without inferring
  an open day;
- excludes canceled/free items from busy commitments;
- clips commitments to the target local day and merges occupied intervals;
- reports overlap, less-than-30-minute transition margin, high schedule load,
  or multiple tentative commitments as one pressure point;
- proposes at most one deterministic preparation action;
- protects the largest known open period of at least 90 minutes between 08:00
  and 21:00 local time;
- renders at most three chronological transitions; and
- calls a day intentionally open only when Calendar context is fresh and no
  busy commitment intersects tomorrow.

Expected sleep, training plans, travel legs, people, and durable unresolved
decisions can be added only through typed source contracts in their owning
milestones. The v1 projector does not fabricate those inputs.

## Durable Now and re-entry state

SQLite schema v5 adds `local_application_state`, a bounded local-only key/value
store with schema version, canonical document bytes, SHA-256, and update time.
Reads and whole-ledger integrity checks recompute the digest and fail closed on
mutation. This state does not create a ledger event or sync-outbox operation.

`NowExperienceService` owns the `now_experience` record:

- last owner-visible visit time;
- optional bounded `NowStateCorrection`; and
- an explicit document schema version.

Background refresh never advances the visit time. Foreground/bootstrap refresh
advances it only when no re-entry surface is active. Continue, Revise Season,
and Stay Quiet durably record the response before removing re-entry; Stay Quiet
also writes the bounded owner-requested correction.

`NativeReentryProjector` enters only after at least three days away. It builds
privacy-bounded material changes from accepted Season versions, recent local
capture revisions, currently relevant Calendar source-version changes, and a
fresh cross-zone broad place. Existing UUIDv7 identifiers are reused where
available. Calendar and Location aggregates receive deterministic SHA-256-
derived UUIDv7 identifiers whose timestamp comes from the source change; no
random identifier is generated during rendering.

The policy then:

- ranks only current material changes;
- returns at most three summaries;
- asks at most one highest-value generic clarification question;
- expires supplied stale opportunities;
- always offers Continue, Revise Season, and Stay Quiet;
- suppresses accumulated backlog; and
- applies no absence penalty.

Capture summaries never include the original payload. Calendar re-entry
summaries never include titles. Broad Location summaries expose only the fact
that the current time zone differs, not a place name or coordinate.

## Runtime and widget cache

`OdysseyAppModel` rebuilds Now after local bootstrap, foreground entry,
owner-requested refresh, accepted Workshop history changes, capture mutations,
Calendar/Health/Location/Weather state changes, extension drains, sync, and
opportunistic background refresh. A monotonic in-memory generation discards an
older asynchronous refresh before it can overwrite a newer correction or
re-entry response.

The app publishes `NowWidgetSnapshot` to the same App Group root used by
extension commands:

- path: `NowWidgetSnapshot/v1/current.json`;
- maximum encoded payload: 16 KiB;
- atomic replacement and owner-only file mode;
- complete-until-first-authentication Data Protection on supported Apple
  platforms;
- excluded from backup;
- generic state/summary and Tomorrow shape only;
- no Calendar title, Season title, capture payload, health value, coordinate,
  or source identifier; and
- `privacySensitive = true` for system redaction.

The snapshot contract permits at most 24 hours of validity. The iPhone runtime
uses the earlier of six hours or the next known transition. The widget renders
current, stale, unavailable, and preview states separately, marks snapshot
content privacy-sensitive, and retains only generic Capture/Food actions. It
adds a stale timeline entry no sooner than five minutes after timeline creation
and asks WidgetKit for a later reload. Those entries are reconciliation hints,
not refresh guarantees; WidgetKit may coalesce or defer them.

## Repository validation

The complete portable Swift 6.1 suite passes 200 tests in the pinned Ubuntu
container. Milestone-focused coverage includes:

- all six state priorities, manual correction bounds/expiry, owner quiet, and
  empty-versus-intentional silence;
- named-zone Tomorrow Map behavior, overlap/margin pressure, transition bounds,
  protected open time, and unavailable Calendar behavior;
- three-day re-entry, bounded ranking, one question, no-change restart,
  deterministic native aggregate identifiers, and payload-safe capture copy;
- schema-v5 local-state migration, round trip, digest tamper detection, and
  integrity verification;
- native Calendar/Season/Location projection composition; and
- widget snapshot lifetime/size validation plus atomic cache round trip,
  malformed-data rejection, and removal.

All iOS and widget Swift sources pass Swift parser validation in this Linux
environment. This does not type-check SwiftUI or WidgetKit and is not evidence
of App Group entitlement access, Data Protection behavior, widget scheduling,
lock-screen redaction, accessibility, performance, or physical-device behavior.
Follow `docs/deployment/OWNER_HANDOFF.md` step 14 for those owner-only checks.
