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
recover interrupted claims after restart. Malformed files move to `rejected`
instead of blocking later work.

Directories and files use owner-only POSIX modes, Apple Data Protection through
first unlock, and backup exclusion. The queue is a short handoff buffer, not a
history or sync source. Only the main app may translate a claimed command into
the protected SQLite ledger/projection/outbox transaction.

## Current boundary

The portable command and queue layer is implemented and tested. App Intent,
widget/control, iPhone drain, and WatchConnectivity producers/consumers are not
wired in this slice. Watch has a separate device filesystem; it must forward the
same command contract through WatchConnectivity or direct authenticated sync,
not assume the iPhone App Group is shared across devices. No Xcode extension or
physical Watch behavior is claimed.
