# Watch quick capture and phone handoff

Odyssey Watch uses its own protected local command outbox. It never assumes an
iPhone App Group container is mounted on Watch, and it never writes the iPhone
SQLite ledger directly.

## Supported warm actions

The current Watch source supports:

- a short text note entered with the system Watch text/dictation surface; and
- one-serving food logging from at most four ranked presets recently published
  by the paired iPhone.

Both actions construct the same validated `ExtensionCommand` used by iPhone
extensions, with `invoking_surface = watch`. The command is atomically persisted
under Watch Application Support before the UI reports success. Saving therefore
does not wait for reachability, phone ledger access, network, cloud sync, or
HealthKit.

## WatchConnectivity protocol

`OdysseyWatchConnectivity` is availability-gated framework code around portable
and Linux-tested contracts in `OdysseyExtensionBridge`:

1. Watch retains one protected JSON file per command UUID.
2. If the phone is reachable, Watch sends the bounded command data immediately.
3. Otherwise, or if immediate delivery fails, WatchConnectivity owns a
   background `transferUserInfo` copy.
4. The phone decodes and revalidates the command, requires the Watch invoking
   surface, and atomically enqueues it in the iPhone App Group queue.
5. Only after that durable handoff does the phone return or transfer an
   acknowledgment carrying the same command UUID.
6. Watch removes an accepted command by UUID. Retry receipts use a one-minute
   in-memory backoff; system outstanding transfers suppress duplicate sends.
7. Duplicate delivery is harmless: the iPhone queue, entity ID, and outbox
   operation all use the command UUID.

An `accepted` Watch receipt means **durably accepted into the iPhone handoff
queue**. It does not assert server sync, HealthKit write completion, or a visible
phone UI. The iPhone app independently drains that queue into its atomic local
ledger/projection/outbox transaction.

## Ranked food snapshot

After each successful local food-library projection, iPhone publishes a latest
application-context snapshot containing only:

- schema version;
- generation/expiry instants and IANA time zone; and
- at most four preset UUIDs, revisions, names, and serving descriptions in
  deterministic rank order.

The production projector uses a twelve-hour expiry; the wire contract rejects a
lifetime over twenty-four hours, duplicate preset IDs, invalid zones, and
unbounded text. Watch disables food actions when the snapshot expires. Preset
labels appear only inside the owner-opened Watch app and are marked privacy
sensitive; this slice adds no food complication, notification, or system
suggestion.

## Failure and recovery

- Unreachable phone: the local command remains visible as pending and background
  transfer remains eligible.
- Watch process termination: queue files remain under protected Application
  Support and interrupted claims recover on the next scan.
- Phone process termination: WatchConnectivity retains its transfer; phone
  acceptance is still an App Group file operation, not a ledger write from the
  callback.
- Stale preset revision: iPhone rejects the later ledger mutation rather than
  silently logging changed nutrition. The current Watch receipt covers handoff,
  so detailed rejection remains visible on iPhone; an end-to-end Watch outcome
  receipt is future work.
- Corrupt/foreign message: the codec fails closed and does not enter either
  queue.

## Evidence boundary

Portable command, codec, bounded snapshot, outbox scan, duplicate suppression,
receipt resolution, and projection tests run on Linux. Apple sources pass Swift
parser checks only. Xcode type-checking, pairing, background delivery,
reachability transitions, force-quit recovery, accessibility, warm-path timing,
and physical two-device evidence remain owner work in
`docs/deployment/OWNER_HANDOFF.md`.
