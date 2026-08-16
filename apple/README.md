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

The portable Workshop service stores each normative draft creation, edit,
review, queue transition, and abandonment as a local-only immutable ledger event
plus a sequential projection. It validates typed domain content and immutable
identity on every edit, generates a plain-language semantic diff against cached
accepted history, and requires the exact reviewed digest before creating an
acceptance command. Draft edits remain owner-exported and replayable but never
become canonical through generic synchronization.

The iPhone Workshop builds on that service with typed Charter-value and policy
list fields, descriptive life-stage contexts, and season portfolio, status,
constraint, opportunity-budget, signal, guardrail, and transition editors. It
ships an editable synthetic commission-derived seed, not accepted defaults.
Starting a successor freezes a non-judgmental summary bound to the outgoing
accepted version ID, logical ID, content hash, status, title, and interval. An
optional retrospective draft covers achievements, disappointments, changed
decisions, carry-forward practices, beliefs, people/experiences, data quality,
and unfinished commitments; it may remain a draft, be accepted, or be skipped.
Every acceptance opens a complete semantic review, shows composition warnings,
and requires an explicit immutable-history confirmation. Accepted versions are
decoded into read-only plain-language history. A `409` remains a visible
terminal meaning conflict with no auto-merge; the owner must refresh history and
start a new reviewed revision.

The iPhone Map consumes only that immutable accepted Season history. A portable
deterministic projector derives qualitative paths, protected terrain, open
horizon, transition/review landmarks, and deliberately dormant areas without
scores, inferred progress, or tasks. The calm SwiftUI `Canvas` prototype has a
first-class Plain Language presentation that lists the complete projection;
visual limits never hide policy from the alternative. Drafts and queued
proposals cannot appear as current orientation. See
[`docs/architecture/season-map-prototype.md`](../docs/architecture/season-map-prototype.md).

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

Capture interpretation now has a full versioned native contract, provider-neutral
adapter boundary, and durable local execution service. Every proposed field
carries a validated reference to its immutable source capture. After the
original write returns, the service coalesces identical work, invokes the first
deterministic fallback, and atomically appends `capture.interpreted.v1`, advances
the projection, and queues sync. It recognizes only explicit owner-written
prefixes, treats other text as an unstructured note, and leaves media pending
rather than inventing content. Bootstrap and opportunistic app refresh rescan
pending captures. Provider-backed interpretation remains unavailable. See
[`docs/architecture/capture-interpretation.md`](../docs/architecture/capture-interpretation.md).
The same cross-stack contract now defines stable append-only owner acceptance,
correction, and dismissal lineage. The local service enforces latest-version and
optimistic-revision review, atomically records the result and sync update, and
preserves every prior version. The iPhone Archive resolves detail navigation by
capture ID, renders the immutable source payload and every inferred or
owner-reviewed version with exact source references, and exposes explicit
Accept, Correct Category, and Dismiss actions. A failed UI retry retains the
same review-version ID for the same content; a successful local review refreshes
Archive/diagnostics, schedules background work, and triggers sync separately.

The first food-capture foundation is portable and deliberately narrow.
`OdysseyDomain` validates simple owner-defined presets, aliases, servings, and
optional source-labeled nutrient values with explicit units.
`OdysseyApplication` provides versioned deterministic context/frequency and
frequency-only ranking over coarse time-zone-aware local context, bounded
lookback windows, explainable counts, and stable ties. `FoodPresetService` now
persists create, optimistic revision, and archive as one atomic
ledger/projection/sync-outbox commit, preserves immutable identity and
provenance, emits changed-field sync updates, and prevents tombstone
resurrection. See
[`docs/architecture/food-presets.md`](../docs/architecture/food-presets.md).
Generated event contracts now register preset create/revise and occurrence
consume/correct payloads. A backend
native-document test normalizes mechanical metadata during disjoint merges, and
a portable pull-persistence test decodes the resulting canonical revision;
overlapping owner fields remain explicit conflicts.
`OdysseyDomain` also defines a validated `FoodOccurrence` snapshot with the
selected preset revision, serving quantity, source-labeled nutrient totals,
occurrence time, IANA zone, and original UTC offset. `FoodOccurrenceService` is
composed during native bootstrap and atomically records, optimistically
corrects, or tombstones occurrences across the ledger, current projection, and
sync outbox. Active occurrences produce deterministic ranking history without
rewriting older preset snapshots. The iPhone Now surface and global quick-action
menu now open a local-first food sheet with four deterministic suggestions,
search across all presets and aliases, preset creation, recent history, and
explicit correction/void actions. A portable projector/reducer owns loading and
mutation state. The SwiftUI source is parser-validated but not Xcode-built or
device-timed. `OdysseyHealth` now supplies a portable-tested food write plan and
coordinator plus an Apple-guarded `HealthKitFoodWriter`. The UI requests
write-only access only after an explicit explanation, and local commits never
depend on the result. Exact dietary energy, protein, and caffeine samples carry
stable Odyssey occurrence/revision sync metadata; correction replaces only
Odyssey-owned samples and void deletes them. Alcohol grams remain Odyssey-only
rather than being mapped to an inexact type. The HealthKit branch is not
Xcode-built or device-tested; a live ranking experiment also remains absent.

`OdysseyExtensionBridge` now defines the next extension boundary: validated
text/opaque-preset food commands and a Data-Protected, backup-excluded atomic
App Group file queue with UUID idempotency, claim/ack/retry, malformed-command
quarantine, and interrupted-claim recovery. Extensions still do not write the
ledger directly. The text App Intent queues offline without opening Odyssey,
while the food intent opens the private ranked sheet without publishing preset
labels. The iPhone performs bounded non-reentrant startup/foreground/background
drains through a portable-tested processor. Command identity is reused for the
entity and outbox operation, so post-commit crash replay verifies the projection
instead of duplicating it. Widget/control producers and WatchConnectivity remain
separate implementation slices; see
[`docs/architecture/extension-quick-capture.md`](../docs/architecture/extension-quick-capture.md).

`LocalCaptureAttachmentStore` now supplies the protected local object boundary
needed by voice/photo/file capture. It copies files through a bounded stream,
hashes the copied bytes incrementally, records no source filename or absolute
path, publishes only an opaque UUIDv7 reference after an atomic directory
rename, and supports staged/committed crash reconciliation. Object directories
and files use owner-only permissions; Apple mobile targets additionally fail
closed unless Data Protection can be applied. This first manifest version is
local-only and excluded from backup, upload, provider interpretation, and remote
restore. `LocalMediaCaptureService` now composes that store with the immutable
capture ledger: bytes publish first, one capture/projection/outbox transaction
commits second, and manifest promotion follows with explicit recovery state.
Known failed ledger handoffs discard only their own staging; bootstrap promotes
referenced staging and preserves uncertain data for repair. The iPhone Capture
sheet now offers explicit Text, Voice, Photo, and File modes. Voice recording
uses the stable microphone-permission API, a five-minute `AVAudioRecorder`
ceiling, protected temporary storage, foreground lifecycle stopping, and stale
permission/delegate callback guards before routing Save through
`LocalMediaCaptureService`.
Permission denial offers Settings without disabling text capture, and the sheet
discloses that this audio is not transcribed, uploaded, or remotely restorable.
`LocalCaptureImportBuffer` now supplies the safe prerequisite for ephemeral
photo/document-provider URLs: it obtains security-scoped access only for a
bounded streaming copy, uses opaque names and owner-only permissions, applies
complete Data Protection, excludes the root from backup, and removes known
uncommitted leftovers during native bootstrap. The UI now composes that buffer
with a one-photo `PHPickerViewController` and a one-file system importer, exact
request-generation guards, explicit Save, and cancel/replacement cleanup. It
declares no broad Photo Library usage permission and performs no preview,
content sniffing, interpretation-byte access, upload, or remote restore.
Playback remains unwired. See
[`docs/architecture/local-capture-attachments.md`](../docs/architecture/local-capture-attachments.md).

`NativeLocalServices` opens the stable Keychain device identity, protected
Application Support database, migration-backup directory, and capture service
before any remote configuration is parsed. `NativeRemoteServices` is a separate
optional layer that accepts HTTPS endpoints (or development loopback HTTP only)
and composes auth, the memory-only token session, transport, and coordinator.
It also composes the life-model transport and acceptance coordinator over the
same token session and local ledger. Placeholder or unsafe endpoints therefore
disable remote work without disabling offline capture or acceptance queueing.

The iPhone shell now uses the tested application reducer for bootstrap,
capture, Workshop loading/edit/review/queue/delivery, enrollment, sync,
diagnostics, and repair state. Global text and saved voice/photo/file capture
return only after the ledger/projection/outbox transaction, trigger sync
afterward without awaiting it, and schedule an opportunistic app-refresh
request. Workshop shows both dedicated normative-command and generic-sync
queue/conflict state, offers Apple device enrollment and local credential
removal without claiming server revocation, and exposes integrity verification
and projection rebuild. These SwiftUI, PhotosUI, Uniform Type Identifiers,
AVFoundation, BackgroundTasks, Security, AuthenticationServices, and UIKit paths
have not been Xcode-built or run on Apple hardware in this environment.

On a Mac with Swift 6.1 or newer and Xcode installed:

```bash
swift test --package-path apple
../tools/apple/generate-project.sh
```

The portable package currently reports 126 tests passing under the official
Swift 6.1 release toolchain on Linux. That result does not type-check SwiftUI or
replace the required Xcode, simulator, accessibility, signing, and device runs.

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
