# Odyssey sync protocol

Odyssey uses a device operation log and a server-global change cursor. Device
timestamps are preserved for meaning but never establish global order. Device
sequence numbers order local writes; committed server change IDs order canonical
changes.

## Identity and authentication

Every Odyssey-owned identifier and device ID is UUIDv7. Owner metadata, push,
pull, diagnostics, and conflict routes require the owner authentication
boundary. Credential-free development accepts the synthetic owner principal.
Sign in with Apple mode fails closed until its verifier is configured.

## Push

`POST /v1/sync/push` accepts one device's compact ascending batch. The request
contains its client schema version, last known global cursor, and immutable
operations. `Idempotency-Key` identifies the batch. An operation-level key may
be supplied; when omitted, its UUIDv7 operation ID is the effective key.

The server transaction:

1. replays an exactly committed batch receipt if one exists;
2. negotiates the supported schema window;
3. locks device sequence and global cursor state;
4. applies each domain merge policy;
5. appends the immutable operation result and any server change;
6. updates the canonical projection and transactional outbox;
7. commits a replayable batch receipt.

Reusing a batch or operation key for different content is a conflict. A lost
response is retried with the same content and returns the committed result.
Kill-switch freezes reject new batches but continue to replay committed ones.

## Pull

`GET /v1/sync/changes?cursor=c_N` returns an ordered, resumable page after the
cursor. Every change includes canonical revision, merge result, tombstone and
deletion epoch, originating device and operation, server receipt time, and the
next cursor. The response also publishes server and minimum client schema
versions.

A push does not advance the device's pull cursor: push responses do not contain
remote changes. Only a completed pull page or an explicit device diagnostics
report advances the recorded device cursor.

## Merge policies

- Append-only observations union duplicate content and reject updates.
- Normative charter, direction, life-stage, and season edits preserve concurrent
  revisions for review.
- Editable notes preserve both revisions instead of silently overwriting.
- Food presets merge disjoint fields and preserve overlapping edits.
- Permissions and standing authorizations choose the most restrictive state.
- Decisions and choices create explicit later revisions.
- External mirrors use source-revision precedence while retaining Odyssey
  semantic overlays.
- Tombstones dominate stale edits and cannot be resurrected by conflict
  resolution.

## Conflict workflow

`GET /v1/sync/conflicts` returns pending conflicts by default and deterministic
meaning-oriented explanations. Raw documents remain available to trusted
diagnostics, but ordinary UI should render the explanation and named fields,
not a JSON diff.

`POST /v1/sync/conflicts/{id}/resolve` accepts `keep_current`,
`accept_incoming`, or an explicit `merge` document when the domain permits it.
Resolution checks the displayed canonical revision, consumes the next device
sequence, emits a normal canonical server change, and stores an immutable
resolution receipt. Exact retries replay that receipt. Append-only records and
tombstones allow only `keep_current`; creating a separate new record is the
safe alternative.

## Diagnostics and repair

Devices report local queue depth, oldest unsynced operation, attachment backlog,
schema version, and applied cursor to
`PUT /v1/sync/devices/{device_id}/diagnostics`. `GET /v1/sync/diagnostics`
combines those reports with:

- last successful server push and pull;
- per-device and server cursors;
- clock-skew observation;
- schema compatibility;
- pending conflict, attachment, and outbox counts;
- push/pull kill-switch state;
- deterministic projection rebuild and integrity-check commands.

Diagnostics older than 24 hours are marked stale rather than presented as
current. The integrity checker separately verifies cursor continuity, canonical
revision/tombstone agreement, operation-to-change references, and immutable
conflict-resolution receipts.

## Attachments

Attachment bytes use the separate resumable flow under `/v1/attachments`.
Metadata initialization returns a short-lived signed chunk URL template. Each
chunk is immutable by index and SHA-256. Completion atomically assembles and
verifies the exact stored bytes before committing a content-addressed object
manifest. See `docs/architecture/attachment-encryption.md` for key ownership
and recovery consequences.

## Failure rules

- Transactions roll back the entire uncommitted batch.
- Applied responses lost in transit are safe to replay.
- A client cursor ahead of the server is rejected and triggers repair, never
  silent cursor reset.
- A server restored behind a surviving device must accept later immutable
  operations only after the operator confirms cursor and backup history; the
  client must not discard them.
- Schema-too-old clients receive the minimum version; schema-too-new clients
  receive the server version and retry only after compatibility is restored.
- Conflict and attachment payloads are private data and must not appear in logs.
