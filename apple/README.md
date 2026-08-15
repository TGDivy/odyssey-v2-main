# Odyssey Apple workspace

The Swift 6.1 package graph is intentionally independent of signing and
personal Apple credentials. `OdysseyDomain` contains pure values and policy
invariants; platform frameworks stay behind adapter protocols in their own
modules.

`OdysseyData` uses the exactly pinned GRDB 7.11.1 package over SQLite. Its
authoritative store enables foreign keys, WAL, full synchronous durability,
strict schema migrations, FTS5, value observation, immutable ledger and
projection history, atomic sync-outbox writes, verified online backup,
projection replay, integrity checks, and complete JSON export. Schema v2 keeps
the applied device cursor separate from the latest observed server cursor,
stores every pulled server change as an immutable hash-checked receipt, applies
push results and pull pages transactionally, reconciles same-device optimistic
state, and records other-device changes in both the ledger and projection
history. Schema v3 adds a dedicated immutable owner-acceptance command queue,
separate delivery state, and immutable cached Charter/life-stage/season
receipts; these commands never enter generic document sync. Export format v3
includes sync receipts, structured operation results, acceptance attempts, and
cached life-model history. The checked-in `Package.resolved` makes dependency
resolution reproducible.

`OdysseySync` now includes backend-shaped wire contracts and an actor-isolated
`URLSessionSyncTransport`. It obtains a bearer token per request, refuses plain
HTTP and redirects by default, bounds request/response bodies, sends stable
idempotency/device/correlation headers, and decodes only the redacted API error
envelope. `OdysseyApplication` composes this boundary with durable persistence,
and the iPhone shell instantiates it only after local storage is available and
a non-placeholder remote configuration passes validation.

The same application layer now has a dedicated life-model transport and
coalescing acceptance coordinator. It validates queued request JSON against the
immutable command before network use, submits Charter/life-stage/season commands
in local order, caches matching event/ledger-backed receipts, schedules bounded
retryable failures, and records semantic `409` responses as terminal owner-review
conflicts. It refreshes current orientation after conflicts and bounded history
after each run without persisting server message text. This path is deliberately
separate from generic sync.

`OdysseyAuth` defines the closed challenge, exchange, refresh, recovery, and
device lifecycle values. Its actor-isolated access-token session keeps access
tokens in memory, refreshes through a device-bound credential, and persists
only the stable UUIDv7 device identity and refresh credential in a
non-synchronizing, this-device-only Keychain item. The Security-backed vault
fails closed on platforms without Keychain support. Its ephemeral HTTPS auth
client implements challenge, Apple exchange, refresh, and recovery exchange
without redirects, cookies, caches, or body-bearing errors. On iOS, macOS, and
visionOS, `SystemAppleAuthorizationPerformer` binds the backend challenge ID to
Apple `state`, sends only SHA-256 of the raw nonce to Apple, requests no profile
scopes, validates the returned state/token, and leaves the raw nonce only in
memory for backend exchange. The iPhone Workshop now exposes this enrollment
boundary and the local credential state, but these platform branches still
require Xcode and physical-device validation.

`OdysseyApplication` begins the portable composition layer. Its manual-capture
pipeline validates bounded capture context, preserves the original payload and
content hash, and commits `capture.recorded.v1`, the current projection, and a
sequenced sync operation in one SQLite transaction before returning. Capture
does not wait for authentication, networking, or interpretation; operational
secret material is rejected from this user-data path. Its actor-isolated sync
coordinator coalesces concurrent runs, pushes a sequence-ordered idempotent
batch, validates every operation result before mutation, schedules bounded
retries without retaining private server messages, then applies all pull pages
transactionally until the durable device cursor catches up. Offline diagnostics
report exact queue age/count, conflicts, cursors, schema compatibility, and the
attachment backlog without requiring a server call.

`NativeLocalServices` opens the stable Keychain device identity, protected
Application Support database, migration-backup directory, and capture service
before any remote configuration is parsed. `NativeRemoteServices` is a separate
optional layer that accepts HTTPS endpoints (or development loopback HTTP only)
and composes auth, the memory-only token session, transport, and coordinator.
It also composes the life-model transport and acceptance coordinator over the
same token session and local ledger. Placeholder or unsafe endpoints therefore
disable remote work without disabling offline capture or acceptance queueing.

The iPhone shell now uses the tested application reducer for bootstrap,
capture, enrollment, sync, diagnostics, and repair state. Its global text
capture returns only after the ledger/projection/outbox transaction, triggers
sync afterward without awaiting it, and schedules an opportunistic app-refresh
request. Workshop shows exact local queue/cursor/conflict state, offers Apple
device enrollment and local credential removal without claiming server
revocation, and exposes integrity verification and projection rebuild. These
SwiftUI, BackgroundTasks, Security, AuthenticationServices, and UIKit paths have
only received parse-level checks in this Linux environment; they have not been
Xcode-built or run on Apple hardware.

On a Mac with Swift 6.1 or newer and Xcode installed:

```bash
swift test --package-path apple
../tools/apple/generate-project.sh
```

The SQLite database must live in an Application Support container protected by
the platform data-protection policy. Callers must supply the stable Keychain
device identifier when opening `SQLiteLedgerStore`; opening an existing outbox
under a different identifier fails instead of risking sequence reuse. Opening
an older nonempty schema also requires a protected backup directory; the store
creates and restores-checks an online pre-migration snapshot before applying
the next monotonic migration.

The checked-in package graph is the source boundary used by iPhone, Watch,
iPad, Mac, widgets, App Intents, and share-extension targets. `project.yml` is
the reviewed XcodeGen 2.44.1 project source. Tracked configuration contains only
safe placeholders; ignored local xcconfig files supply the owner team, bundle
prefixes, API URLs, and associated domain. Follow
[`docs/deployment/OWNER_HANDOFF.md`](../docs/deployment/OWNER_HANDOFF.md) for the
exact account, entitlement, signing, device, and release gates.
