# Local capture attachment storage

Odyssey stores capture media locally before any capture record may reference
it. This layer is deliberately local-only: it does not imply cloud upload,
client-side encryption, transcription, provider access, or remote restore.

## Object and manifest contract

`LocalCaptureAttachmentStore` places each attachment in a versioned Application
Support root under a UUIDv7 directory. The synchronized capture sees only an
opaque reference such as `odyssey-local-attachment:v1:<uuid>`, never an absolute path,
source filename, temporary picker URL, or security-scoped bookmark.

Each object directory contains:

- `content`, the exact copied bytes;
- `manifest.json`, a sorted versioned manifest containing attachment identity,
  capture kind, SHA-256, byte count, media type, creation time, sensitivity,
  local-only retention, protection policy, and staged/committed state.

The content hash covers the exact local plaintext bytes. It must not be reused
as a claim about future encrypted cloud ciphertext. A later client-side upload
adapter requires its own versioned encryption manifest and ciphertext hash as
described in `docs/architecture/attachment-encryption.md`.

## Durability and recovery

Source files are copied through a bounded stream into a hidden staging
directory. In-memory imports use the same size limit. The store then:

1. hardens the staging directory and content permissions;
2. synchronizes content to the filesystem;
3. computes SHA-256 by streaming the staged copy;
4. writes and synchronizes the staged manifest atomically;
5. excludes the local-only object from platform backup where supported;
6. atomically renames the complete directory to its UUIDv7 destination.

No source filename is retained. Empty files, symlinks, non-regular files,
unsupported capture kinds, malformed media types, oversized data, invalid
clocks, operational-secret classification, and identifier collisions fail
before an object becomes visible.

The staged state supports the filesystem/database handoff. After a capture
ledger transaction references the opaque object, composition marks the
manifest committed. On startup, reconciliation promotes referenced staged
objects. An unreferenced staged object is retained for explicit repair review,
because a bounded projection scan cannot prove that older owner data is
orphaned. The in-process capture coordinator may discard staging only when it
knows the ledger transaction failed. Recovery never garbage-collects a
committed object merely because a current projection does not reference it;
deletion requires a future durable tombstone and retention policy.

Reads require an exact `CaptureAttachmentReference`, committed state, matching
byte count, and a freshly streamed content hash. A mismatch fails closed.

## Capture composition

`LocalMediaCaptureService` is the only composition path from protected bytes to
`ManualCaptureService`. It accepts a bounded file URL or in-memory payload plus
the media kind, media type, capture context, invoking surface and sensitivity.
It then:

1. publishes a complete staged local-only object;
2. creates one `CaptureAttachmentReference` from that exact manifest;
3. commits the immutable capture, projection and ordered sync operation through
   the existing ledger transaction;
4. marks the referenced manifest committed.

If capture validation or the ledger transaction fails, the service knows the
staged object is unreferenced and discards it. If final manifest promotion fails
after the ledger commit, the receipt reports `recovery_required` rather than
claiming the capture failed or attempting to rewrite it. Native bootstrap scans
recent capture projections, promotes referenced staging, retains uncertain
staging for repair, and exposes a typed recovery report. Corruption in this
attachment recovery pass does not disable text capture or the primary ledger.

## Voice recording surface

The iPhone Capture sheet makes Text and Voice separate, explicit modes. Voice
recording begins only after the owner selects Start Recording. The recorder
reads `AVAudioApplication.shared.recordPermission` and uses
`AVAudioApplication.requestRecordPermission()` only when the state is
undetermined. Denial keeps the sheet usable, leaves text capture available, and
offers an explicit route to the app's system Settings page. Returning active
refreshes the displayed permission state but never starts recording without a
new owner action.

`VoiceCaptureRecorder` records mono MPEG-4 AAC into a temporary `.m4a` file. It
applies complete Data Protection to that file before recording and calls
`record(forDuration:)` with a hard five-minute ceiling. A scene transition away
from the active foreground stops the recorder. Cancelling or recording again
removes the temporary file; a successful Save copies it through
`LocalMediaCaptureService` before the source is discarded.

Permission requests carry an invocation identifier, so cancellation while the
system prompt is outstanding prevents a delayed result from starting audio.
Delegate completion and encoding-error callbacks must match both the active
recording state and exact temporary URL, which prevents stale callbacks from
mutating a replacement recording. The recording state disables mode changes,
interactive dismissal, and duplicate starts where those actions could abandon
an active recorder. Save sets a synchronous sheet-local submission guard before
starting the asynchronous durable handoff, preventing duplicate captures or a
dismissal race before the application reducer publishes its saving state.

This surface never invokes speech recognition, and the iOS target does not
declare Speech Recognition usage. It also never invokes provider
interpretation, attachment upload, or remote restore. Its disclosure says that
the audio stays on this device and can be lost with the app or device. Swift
parser validation and the portable media-service tests do not type-check
AVFoundation/SwiftUI or prove microphone prompts, audio encoding, background
transitions, Data Protection while locked, accessibility, or physical-device
behavior; those remain owner-only Xcode and device checks.

## Ephemeral picker handoff

Photo and document providers may expose a selected file URL only for the
duration of their callback. `LocalCaptureImportBuffer` provides the narrow
handoff needed before picker UI can safely use those URLs. Native bootstrap owns
one versioned buffer under Application Support and removes all prior entries
before exposing local services, because these temporary copies have not entered
the ledger or durable attachment store and therefore have no ambiguous owner
history to preserve.

Preparing an import obtains security-scoped access only for the copy where the
platform supplies it, rejects empty, oversized, non-file, non-regular, and
symbolic-link sources, and streams at most 128 MiB in 64 KiB chunks. It writes to
an opaque UUIDv7 filename without retaining the provider path or source name.
The root uses `0700`, each file uses `0600`, Apple mobile targets require
complete Data Protection, and the root is excluded from backup. A cancelled or
replaced selection can be discarded by its exact typed handle without touching
the source file.

This buffer is deliberately not a capture or attachment manifest. A future
picker surface must still require an explicit Save, copy the prepared file
through `LocalMediaCaptureService`, and discard the temporary handle only after
that durable handoff succeeds. Portable tests prove the bounded copy,
permissions, opaque naming, unsafe-source rejection, exact discard, and
bootstrap cleanup. PhotosUI, document-provider callback behavior, and Apple Data
Protection remain unproved until Xcode/device validation.

## Protection boundary

Directories use owner-only `0700` permissions and content/manifests use `0600`.
On iOS, watchOS, tvOS, and visionOS, the store also requires
`completeUntilFirstUserAuthentication` Data Protection so background-safe local
work remains possible after the first device unlock. Failure to apply that
protection fails the write. Linux portable tests verify permissions, opaque
metadata, atomic recovery semantics, and integrity behavior; they do not prove
Apple Data Protection or device lock behavior.

Objects in this version are `local_only` and excluded from Odyssey server
search, model retrieval, attachment upload, and remote restore. Losing the
device or deleting the app can therefore lose the only copy. Voice/photo/file
UI must state that boundary until a tested encrypted upload and recovery flow is
enabled.

## Current limit

The default object limit is 128 MiB. The SHA-256 utility supports incremental
updates and bounded file reads, with NIST known-answer and chunk-boundary tests.
The protected object and durable media-capture coordinator are implemented.
The guarded iPhone AVFoundation recorder is source-implemented, and the
protected ephemeral import buffer is portable-tested. Photo/file chooser UI,
playback, repair UI, and the attachment lifecycle/tombstone flow follow in
separate Milestone 1.2 slices.
