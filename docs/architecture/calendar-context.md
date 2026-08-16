# Local calendar context mirror

Calendar is an external mutable observation, not Odyssey's source of intention.
The implementation therefore keeps EventKit identifiers as opaque references
inside a separate local-only integration mirror. It does not create an Odyssey
semantic identity from an EventKit identifier and does not place mirrored event
documents in the sync outbox.

## Permission boundary

`EventKitCalendarAdapter` distinguishes modern EventKit access levels:

- `fullAccess` (and the deprecated equivalent `authorized`) permits reads;
- `writeOnly` is represented as `partial` and does not permit a query;
- not-determined, denied, restricted, and unavailable states return explicit
  degraded outcomes with no local deletion;
- the full-access request occurs only after the owner chooses the Workshop
  action.

This read path never writes, moves, or deletes an EventKit event. Future event
creation should prefer write-only access or EventKitUI and remain a separate
adapter and confirmation flow.

## Source document

Each `CalendarMirrorItem` records only the event context needed for local
planning:

- opaque event and optional provider references;
- calendar identifier/title and source identifier/title/type;
- whether the source calendar allows modifications (diagnostic only);
- title, availability, recurrence presence, and confirmed/tentative/canceled
  state;
- source `lastModifiedDate` when supplied;
- absolute timed bounds or local-date all-day bounds with an exclusive end;
- the event or query-default IANA zone plus start/end UTC offsets.

Attendees, organizer contact data, notes, URLs, alarms, and attachment content
are intentionally not mirrored by this slice. Empty provider labels remain
unknown rather than being fabricated.

## Bounded reconciliation

The iPhone requests a window from 14 days before through 180 days after the
refresh instant. EventKit returns a complete snapshot for that bounded window;
it does not provide a HealthKit-style anchor. `CalendarMirrorCoordinator`:

1. loads and hash-verifies existing local calendar documents;
2. rejects out-of-window or conflicting same-identity records;
3. encodes accepted events as deterministic sorted-key JSON;
4. identifies previously mirrored in-window events absent from the new snapshot;
5. atomically inserts mutable events, updates changed/canceled versions, removes
   absent local observations, and records the successful query window/time.

Exact documents are duplicates. Changed documents update because calendar
entries are mutable observations. A canceled event remains an explicit mirrored
record while EventKit still returns it; a source deletion removes only the local
record. Permission denial or query failure leaves the prior mirror and marker
untouched. Explicit revocation removes all local calendar records and the marker
without changing the source calendar or system authorization.

## Diagnostics and evidence

Workshop exposes capability, read permission, local count, last bounded window,
last successful refresh, newest source version, lag, rejected count, schema
status, contribution meaning, refresh, and local removal. It does not display
event titles in integration diagnostics.

Portable contracts, mutable reconciliation, cancellation, deletion, duplicate,
denial, timezone, and revocation behavior pass under Swift 6.1. The guarded
EventKit branch is parser-validated and was strict-concurrency type-checked
against its public API shape; no Apple SDK/Xcode build or physical permission,
account, recurrence, cancellation, or timezone behavior is claimed. The owner
protocol is in `docs/deployment/OWNER_HANDOFF.md`.
