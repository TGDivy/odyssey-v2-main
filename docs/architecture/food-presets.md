# Food preset and ranking foundation

This document defines the first Milestone 1.2 food-capture foundation. It is a
portable domain contract and deterministic ranking policy, not a completed meal
logger. Recipe composition, restaurant-menu modeling, nutrition advice, and
training/nutrition experimentation remain deferred to Milestone 3.3.

## Preset contract

`FoodPreset` is a simple owner-defined semantic shortcut for one repeatable food
or drink serving. Version 1 contains:

- the standard immutable `EntityMetadata` envelope;
- a trimmed name and serving description of at most 100 characters each;
- at most 20 trimmed aliases, unique after POSIX case/diacritic folding and not
  equivalent to the name; and
- an optional nutrient profile.

The nutrient profile uses explicit units and accepts only finite,
non-negative, bounded values for energy in kilocalories, protein in grams,
caffeine in milligrams, and alcohol in grams. Its source is either an owner
estimate or a package label. Package-label data requires a short source
description so an apparently precise value is never detached from its stated
origin. A profile cannot be empty. These fields are capture metadata, not
clinical interpretation or dietary guidance.

Operational-secret sensitivity is rejected. Tombstoned presets remain valid
historical values but are excluded from current ranking.

## Context contract

Each ranking usage has its own UUIDv7 identity, preset identity, occurrence
time, and already-derived context. Context is intentionally coarse:

| Local hour | Time band |
| --- | --- |
| 04:00–10:59 | `morning` |
| 11:00–14:59 | `midday` |
| 17:00–21:59 | `evening` |
| all other hours | `other` |

Day kind is `weekday` or `weekend`. Both values are derived with a named IANA
time zone so UTC does not silently replace the owner's local context. Invalid
time zones and non-finite clocks fail closed.

## Deterministic ranking

`context_frequency_v1` is the default strategy. It considers only usages in the
closed 90-day window ending at `asOf`; a 14-day subwindow supplies recency. A
context signal must appear at least twice before it can outrank ordinary
frequency, preventing one incidental use from dominating the list. The default
result limit is four and the hard limit is 100.

Candidates sort by these keys, in order:

1. repeated exact-context count;
2. repeated local-time-band count;
3. 14-day use count;
4. 90-day use count;
5. most recent occurrence;
6. POSIX case/diacritic-folded name; and
7. UUIDv7 text.

`frequency_only_v1` sets both context keys to zero while retaining the remaining
ordering. Every result reports the strategy, stable reason, counts, and last-use
time so a later surface can explain the order without inventing a narrative.
The implementation uses no model, network request, health inference, hidden
score, or randomized tie-break.

Identical usage IDs deduplicate idempotently. Conflicting values under one
usage ID and duplicate preset identities fail closed. Future, pre-lookback,
unknown-preset, and tombstoned-preset history cannot affect the result.

## Durable preset lifecycle

`FoodPresetService` is composed during native local bootstrap and stores presets
in the same protected SQLite ledger used by capture and sync. Create, revise,
and archive each make one atomic commit containing:

- an immutable `food_preset.created.v1` or `food_preset.revised.v1` local ledger
  entry;
- the next complete `food_preset` projection; and
- a sequence-ordered sync-outbox operation.

Revision requires the exact current revision, preserves identity, creation
metadata, owner, sensitivity, and entity provenance, and rejects no-op edits.
Its sync payload contains only changed top-level fields plus revision metadata;
cleared optional values are explicit JSON `null`. This retains the server's
ability to identify disjoint semantic edits rather than treating every update
as a replacement. The local projection still stores the complete validated
document.

Archive advances the revision, records `tombstoned_at`, writes a delete
projection, and queues an empty-object delete payload. Archived presets remain
in immutable history but cannot be revised or resurrected and do not appear in
active pages or ranking. Current active reads are bounded to 500 presets.
Malformed projection identity, revision, tombstone, dates, actor metadata, or
domain content fails closed before it reaches ranking.

## Durable occurrence lifecycle

`FoodOccurrence` is the immutable semantic record for each durable food or
drink log. It snapshots the selected preset ID and exact preset revision,
name, and serving description so later preset edits cannot rewrite history. It
also carries a finite serving quantity, optional total nutrient values in the
same explicit units/source contract, occurrence time, named IANA time zone, and
the exact UTC offset that zone had at that instant. The offset is validated
against daylight-saving rules rather than accepted as display metadata.

Occurrence time may precede recording time but cannot follow the current record
revision. Quantity is greater than zero and at most 100 servings. Malformed
decoded nutrient values, operational-secret metadata, invalid actor/date
metadata, unsupported zones, and mismatched offsets fail closed. Preset
nutrition corrections require an explicit future occurrence revision; changing
a preset alone never mutates an existing occurrence snapshot.

`FoodOccurrenceService` is composed during native local bootstrap. Record,
correct, and void each make one atomic commit containing an immutable
`food.consumed.v1` or `food.consumption_corrected.v1` local ledger entry, the
next complete `food_occurrence` projection, and a sequence-ordered sync-outbox
operation. Record requires the exact active preset revision and calculates total
nutrients once from that revision. Correction requires both exact occurrence
and preset revisions, sends only changed top-level fields, and never mutates a
prior ledger entry. Void advances the occurrence revision and writes a true
tombstone with an empty delete payload; it cannot be restored through this
service. Active, bounded occurrence pages provide the ranker's deterministic
usage history.

## Permission-gated HealthKit write boundary

`FoodHealthWritePlan` deterministically maps an immutable occurrence snapshot to
exact dietary-energy kilocalories, protein grams, and caffeine milligrams.
Alcohol grams are reported as omitted instead of being coerced into an inexact
HealthKit type. The portable coordinator never requests permission implicitly:
unauthorized writes return a typed result while the durable Odyssey commit
remains successful.

On Apple platforms, `HealthKitFoodWriter` requests only write access for the
supported nutrient types currently present in the owner food library. Samples
carry the Odyssey occurrence ID, occurrence revision, preset ID/revision,
nutrient kind, and HealthKit sync identifier/version metadata. Repeated delivery replaces the
same Odyssey-owned occurrence samples; correction clears stale owned samples
before a replacement when authorization changed, and void deletes only samples
tagged with that occurrence. Authorized startup/manual reconciliation replays
active local occurrences and durable tombstone IDs so transient failure or
reinstall/restore can converge. No health value gates or rolls back local
logging.

## Ranked warm-path timing boundary

`WarmPathTimer` uses monotonic uptime rather than wall time and applies the
Milestone 1.2 target literally: a committed food quick log qualifies only with
two or three interactions and a duration strictly below 5,000 milliseconds.
Opening the private Food sheet starts an attempt; a successful tap on one of the
currently ranked presets completes it as the second interaction. The launch
correlation and surface survive App Intent, widget, and Control Center command
handoff without carrying a preset name or value.

Typing in search, opening preset creation, opening correction, choosing an
unranked result, refreshing manually, entering Health actions, a failed durable
commit, or dismissing the sheet abandons the attempt and produces no qualifying
result. A successful measurement is retained only in the running iPhone model
and shown to the owner in Now until dismissed, replaced, or the next bootstrap.
The technical signal contains only workflow, surface, outcome, interaction
count, duration bucket, target result, timestamp, and an opaque correlation
UUID. It does not contain food identity, serving, nutrients, query text, or
occurrence data; the default recorder exports nothing.

Portable tests prove target boundaries, duration bucketing, and invalid-clock
handling. They do not prove SwiftUI interaction counting or device latency. The
strict owner-run release-build protocol in
`docs/deployment/OWNER_HANDOFF.md` is required before claiming the physical
under-five-second exit criterion.

## Current boundary

The iPhone Now surface and global quick-action menu now open a local-first
quick-log sheet. It presents the top four deterministic context/frequency
results as one-tap one-serving logs, supports alias-aware search across all
active presets, creates owner-estimated presets without requesting Health
permission, and exposes recent corrections and voids as explicit revision
actions. Portable projector/reducer state keeps loading and mutation transitions
deterministic. This slice does **not** provide a cross-stack occurrence-event
consumer or a live experiment assignment. Generated schemas
register both preset and both occurrence event names. Backend
integration proves that native-shaped disjoint edits normalize mechanical
metadata and converge while overlapping owner fields remain conflicts; a
portable pull-persistence regression proves the resulting canonical document is
still a valid `FoodPreset`. No authenticated physical two-device run has been
performed, so live convergence remains owner evidence. Xcode/accessibility,
physical warm-path timing, and physical HealthKit permission, sample ownership,
correction, and non-interference proof remain. Optional nutrient values alone do
not authorize HealthKit access; only the explicit food-sheet action can request
write permission.

Twenty focused tests cover value validation, time-zone-aware context derivation,
both ranking strategies, threshold behavior, deterministic ordering, excluded
history, idempotent deduplication, fail-closed identity handling, atomic preset
lifecycle commits, partial/null sync payloads, optimistic revision, and
tombstones, including server-normalized pull materialization, immutable
occurrence snapshots, DST-aware offsets, malformed nutrient rejection, atomic
occurrence record/correct/void behavior, and the warm-path timing contract. The
full portable Swift package reports 135 tests passing under the official Swift
6.1 Linux toolchain. This does not type-check SwiftUI or prove Xcode, HealthKit,
signing, simulator, accessibility, or physical-device behavior.
