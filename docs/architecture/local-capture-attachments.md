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
The AVFoundation recorder, picker imports, playback, repair UI, and attachment
lifecycle/tombstone flow follow in separate Milestone 1.2 slices.
