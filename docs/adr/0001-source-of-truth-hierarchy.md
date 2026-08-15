# ADR-0001: Source-of-truth hierarchy

- Status: accepted
- Date: 2026-08-15
- Owners: repository owner

## Context

Odyssey combines immutable observations, user assertions, external sources,
model interpretations, projections, and generated summaries. Treating any
derived representation as canonical would make correction and recovery unsafe.

## Options

1. Mutable current-state rows only.
2. Pure event sourcing for every subsystem.
3. Immutable source records and assertions plus rebuildable relational projections.

## Decision

Use immutable source records, domain events, typed assertions, corrections, and
tombstones as durable truth. Relational current-state tables, graph edges, full
text, vectors, context snapshots, summaries, and model outputs are projections
or explicitly versioned artifacts. External stores remain canonical for their
native objects unless Odyssey records an owner-authored overlay.

## Consequences

Writes carry provenance and idempotency metadata. Projection rebuilds and
semantic migrations are mandatory. Storage is larger, but history, correction,
sync convergence, and forensic recovery remain possible.

## Evidence

Master specification sections 8, 12, 22, 25, 31, and 47.

## Reversal trigger

Revisit only if a production workload demonstrates that the model cannot meet
durability or latency objectives after measured optimization. A convenience
preference is not a reversal trigger.

