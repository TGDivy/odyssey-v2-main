# Attachment encryption and recovery

Odyssey attachment identifiers are content-addressed by the SHA-256 digest of
the exact bytes stored by the service. For a client-side encrypted attachment,
the digest therefore covers ciphertext, not plaintext. The upload service
never accepts plaintext key material and verifies every chunk plus the final
assembled object before making an attachment available.

## Encryption modes

- `none` stores the supplied bytes without application-level encryption. Cloud
  storage encryption still applies in deployed environments.
- `client_side` means the Apple client encrypts before upload. The metadata must
  identify the algorithm and may contain a wrapped data key, nonce strategy,
  and key version, but never a plaintext key or passphrase.
- Local-only attachments do not receive a cloud upload session and are excluded
  from server search, model retrieval, and remote restore.

The Apple implementation should use a fresh 256-bit data key per attachment and
an authenticated encryption construction provided by CryptoKit. The final
algorithm, nonce layout, and metadata schema must be versioned and covered by
known-answer tests before owner data is admitted.

## Key ownership

The attachment data key belongs to the owner, not the backend. A cloud-restorable
client-side encrypted object must carry only a wrapped data key. The wrapping
key is derived from or protected by an owner recovery key held in Keychain and
an offline recovery kit. Server configuration, database backups, object-store
backups, logs, and support tooling must not contain the unwrapped key.

Key references are opaque identifiers such as a Keychain record version. They
must not embed personal data. Rotation creates a new wrapped-key revision; it
does not rewrite the immutable ciphertext manifest without a new attachment
identifier and checksum.

## Recovery consequences

A complete restore of a client-side encrypted attachment requires all three:

1. the verified content-addressed object;
2. the attachment metadata and wrapped data key from the database/export;
3. the owner's recovery key or an enrolled device able to unwrap the data key.

Losing the recovery key and every enrolled device makes those attachments
permanently unreadable. The backend cannot reset or reconstruct the key. The
product must show this consequence before enabling client-side encryption and
must require a tested recovery-kit export before treating encrypted cloud
attachments as the only durable copy.

Database-only restoration is insufficient because it restores manifests but
not object bytes. Object-only restoration is also insufficient because it lacks
ownership, media type, encryption metadata, and key wrapping. Clean-room drills
must restore both stores and verify checksums before an attachment is reported
available.

## Operational rules

- Signed upload tokens are short-lived capabilities and must be redacted from
  access logs and incident artifacts.
- Interrupted uploads remain resumable by immutable chunk index and checksum.
- Duplicate ciphertext is stored once but may have multiple owner attachment
  records; plaintext deduplication is neither attempted nor inferred.
- Cache eviction never deletes the only unuploaded local copy.
- Deletion first creates a durable tombstone; physical object collection waits
  for retention, backup, and cross-device convergence policy.
