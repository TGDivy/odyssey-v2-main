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

## Current boundary

This slice does **not** provide meal occurrence storage, a quick-log UI,
HealthKit writes, a cross-stack domain-event consumer, or a live experiment
assignment. Generated schemas now register both preset event names. Backend
integration proves that native-shaped disjoint edits normalize mechanical
metadata and converge while overlapping owner fields remain conflicts; a
portable pull-persistence regression proves the resulting canonical document is
still a valid `FoodPreset`. No authenticated physical two-device run has been
performed, so live convergence remains owner evidence. Meal ledger, native UI,
permission, and integration slices remain. In particular, the presence of
optional nutrient values does not authorize HealthKit access or write anything
to Apple Health.

Eleven focused tests cover value validation, time-zone-aware context derivation,
both ranking strategies, threshold behavior, deterministic ordering, excluded
history, idempotent deduplication, fail-closed identity handling, atomic preset
lifecycle commits, partial/null sync payloads, optimistic revision, and
tombstones, including server-normalized pull materialization. The full portable
Swift package reports 111 tests passing under the official Swift 6.1 Linux
toolchain. This does not type-check SwiftUI or prove Xcode, HealthKit, signing,
simulator, accessibility, or physical-device behavior.
