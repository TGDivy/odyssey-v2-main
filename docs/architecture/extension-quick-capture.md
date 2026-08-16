# Extension quick-capture bridge

This bridge is the durable handoff boundary for App Intents, controls, widgets,
and same-device extension processes. It does not make an extension a second
ledger writer.

## Command contract

`OdysseyExtensionBridge` defines versioned commands for:

- bounded text capture; and
- food logging by opaque preset UUIDv7, expected preset revision, quantity,
  occurrence time, and IANA time zone; and
- non-sensitive requests to present the private Capture or Food sheet.

The contract stores no food name in system-facing files. Decoding revalidates
every field, rejects mixed payload shapes, bounds text to 10,000 characters and
food quantity to 100 servings, and rejects future or invalid temporal context.
Presentation requests contain no capture or food value.

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
recover interrupted claims after restart. For ledger mutations, the command
UUID is also the created entity and sync-operation identity. A replay after a
crash therefore verifies and accepts the matching projection rather than
creating a second capture or food occurrence. A conflicting projection is
quarantined. Malformed and permanently invalid files move to `rejected` instead
of blocking later work;
transient storage failures return the claim and stop that drain pass.

Directories and files use owner-only POSIX modes, Apple Data Protection through
first unlock, and backup exclusion. The queue is a short handoff buffer, not a
history or sync source. Only the main app may translate a claimed mutation into
the protected SQLite ledger/projection/outbox transaction or consume a private
presentation route.

## Wired producers and consumer

The App Intents extension now queues a trimmed text command without opening the
app or touching SQLite. Its response says that durable ledger admission occurs
when Odyssey next runs. A separate food intent opens the app's private ranked
sheet; it does not publish preset names as App Intent entities or shortcut
suggestions.

The Now widget contains generic Capture and Food buttons, and the WidgetKit
bundle defines matching Control Center controls. They enqueue presentation-only
commands and open Odyssey; no food preset label or value enters WidgetKit or
Control Center. The app rejects an unhandled presentation command after five
minutes, allowing at most one minute of future clock skew, so a failed launch
cannot surprise the owner with a stale sheet days later. These actions never log
food or create a capture by themselves: the owner still reviews the private
in-app sheet and explicitly saves.

The iPhone app constructs a portable-tested `ExtensionCommandProcessor` after
local bootstrap and drains at startup, foreground activation, and opportunistic
background refresh. Text occurrence time remains the command creation time,
while ledger `recorded_at`, entity creation, and outbox creation use the later
durable commit time. Draining is non-reentrant, bounded to 50 claims per pass,
and refreshes the relevant local views only after commit. Missing or invalid App
Group configuration disables only extension handoff and leaves direct local
capture available.

Watch now persists text/food commands in a separate protected Application
Support outbox, attempts immediate WatchConnectivity delivery, falls back to a
system background transfer, and removes a command only after an iPhone handoff
receipt with the same UUID. The iPhone publishes an expiring four-preset food
snapshot through application context. It still does not share App Group storage
with Watch. See
[`watch-quick-capture.md`](watch-quick-capture.md). No Xcode extension, Siri,
background-execution, WidgetKit/Control Center, or physical Watch behavior is
claimed from Linux parser tests.
