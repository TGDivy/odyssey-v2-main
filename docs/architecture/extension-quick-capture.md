# Extension quick-capture bridge

This bridge is the durable handoff boundary for App Intents, controls, widgets,
and same-device extension processes. It does not make an extension a second
ledger writer.

## Command contract

`OdysseyExtensionBridge` defines versioned commands for:

- bounded text capture; and
- food logging by opaque preset UUIDv7, expected preset revision, quantity,
  occurrence time, and IANA time zone.

The contract stores no food name in system-facing files. Decoding revalidates
every field, rejects mixed payload shapes, bounds text to 10,000 characters and
food quantity to 100 servings, and rejects future or invalid temporal context.

## Atomic queue

Each command is one protected JSON file under the environment's App Group:

```text
ExtensionCommands/v1/
  pending/
  processing/
  rejected/
```

Writers use a hidden temporary file and same-volume rename. The command UUID is
the filename and idempotency key, so duplicate delivery does not add another
operation. The main app claims by atomically moving one file to `processing`,
acknowledges only after the local ledger commit, and can return a failed claim or
recover interrupted claims after restart. The command UUID is also the created
entity and sync-operation identity. A replay after a crash therefore verifies
and accepts the matching projection rather than creating a second capture or
food occurrence. A conflicting projection is quarantined. Malformed and
permanently invalid files move to `rejected` instead of blocking later work;
transient storage failures return the claim and stop that drain pass.

Directories and files use owner-only POSIX modes, Apple Data Protection through
first unlock, and backup exclusion. The queue is a short handoff buffer, not a
history or sync source. Only the main app may translate a claimed command into
the protected SQLite ledger/projection/outbox transaction.

## Wired producers and consumer

The App Intents extension now queues a trimmed text command without opening the
app or touching SQLite. Its response says that durable ledger admission occurs
when Odyssey next runs. A separate food intent opens the app's private ranked
sheet; it does not publish preset names as App Intent entities or shortcut
suggestions.

The iPhone app constructs a portable-tested `ExtensionCommandProcessor` after
local bootstrap and drains at startup, foreground activation, and opportunistic
background refresh. Text occurrence time remains the command creation time,
while ledger `recorded_at`, entity creation, and outbox creation use the later
durable commit time. Draining is non-reentrant, bounded to 50 claims per pass,
and refreshes the relevant local views only after commit. Missing or invalid App
Group configuration disables only extension handoff and leaves direct local
capture available.

Widget/control producers and Watch transport remain unwired. Watch has a
separate device filesystem; it must forward the same command contract through
WatchConnectivity or direct authenticated sync, not assume the iPhone App Group
is shared across devices. No Xcode extension, Siri, background-execution,
widget/control, or physical Watch behavior is claimed from Linux parser tests.
