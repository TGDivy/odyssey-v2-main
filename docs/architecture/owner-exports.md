# Encrypted owner exports

Odyssey owner exports implement Appendix B.9 as an owner-authenticated,
asynchronous, resumable, signed, and passphrase-encrypted archive. The feature
is disabled by default. Enabling it requires the API and worker to share a
dedicated wrapping key and durable attachment-object storage.

## API

The exact routes are:

- `POST /v1/exports`
- `GET /v1/exports/{job_id}`
- `GET /v1/exports/{job_id}/download`

Creation requires the normal owner authorization, an `Idempotency-Key`, and an
`X-Odyssey-Export-Passphrase` header. The passphrase is deliberately absent
from the JSON body, structured logs, outbox payload, and database. Reusing an
idempotency key with a different request or passphrase returns `409`.

The download route serves only a completed encrypted artifact. It supports one
HTTP byte range, including open-ended and suffix ranges, and returns
`Accept-Ranges`, `Content-Range`, a content hash `ETag`, and `Cache-Control:
private, no-store`.

## Key flow

For each job, the API:

1. generates a random 256-bit data-encryption key;
2. derives an owner key from the passphrase with scrypt (`N=32768`, `r=8`,
   `p=1`) and wraps the data key with AES-256-GCM;
3. independently wraps the same data key for the worker with AES-256-GCM under
   `ODYSSEY_EXPORT_WRAPPING_KEY`;
4. persists only the two envelopes and an HMAC-derived passphrase fingerprint
   used to enforce idempotency; and
5. enqueues only the job ID in the transactional outbox.

The worker unwraps the data key, builds the archive, rotates the artifact nonce
on every attempt, signs the canonical manifest with an Ed25519 key derived from
the configured wrapping key, encrypts the ZIP with AES-256-GCM, and writes the
encrypted bytes through the content-addressed `AttachmentStore`. A database
commit failure can therefore be retried without reusing a nonce for changed
plaintext. A completed object is safe to replay because its content hash is
stable.

The artifact header contains the owner envelope, cipher metadata, manifest
hash, signature, and public key. It never contains the worker envelope or
wrapping secret. The owner passphrase alone remains sufficient to decrypt a
completed artifact after Odyssey services are gone.

## Archive contents

The decrypted payload is a deterministic ZIP containing:

- JSONL, CSV, and/or Markdown views of each allowlisted owner dataset;
- raw committed attachment objects when `include_raw_sources` is true;
- dataset column/type descriptions, record counts, and schema revision;
- provenance, event schema versions, tombstones, revisions, and audit history
  where those fields exist;
- `manifest.json` with SHA-256 for every data file;
- `manifest.ed25519`; and
- `signing-public-key.txt`.

CSV values beginning with spreadsheet formula prefixes are escaped. ZIP paths
are generated internally, not copied from owner-provided filenames. The
verification library rejects duplicate, absolute, parent-traversal,
backslash-based, unmanifested, oversized, or hash-mismatched entries before
extraction.

## Secret boundary

The exporter uses a positive dataset and column allowlist. It excludes:

- Apple authentication challenges and token fingerprints;
- device authentication credential hashes;
- owner recovery credential hashes;
- upload token nonces and temporary object-storage paths;
- outbox leases and idempotency keys;
- sync request fingerprints; and
- owner and worker key envelopes from the decrypted archive.

Nested values with credential-, password-, passphrase-, private-key-, secret-,
or access-token-shaped field names are replaced with an explicit redaction
marker. The manifest reports the redaction count and excluded datasets without
including the removed values. This is defense in depth; callers must still not
store provider credentials as owner content.

## State and retry behavior

Jobs transition through `queued`, `processing`, and `completed` or `failed`.
Every transition is appended to `export_job_audit`; ORM listeners and database
triggers reject update or deletion. The outbox lease supplies retry attempts.
Transient failures return the job to `retry_pending`; the final configured
attempt marks it failed before the outbox dead-letters. Source integrity and
configured size-limit failures are terminal immediately and complete the
outbox item without retry churn.

`ODYSSEY_MAXIMUM_EXPORT_BYTES` limits both accumulated uncompressed files and
the final encrypted artifact. Assembly is currently in memory, so the runtime
memory limit must remain comfortably above this value.

## Owner verification

From the repository root, run:

```bash
cd backend
uv run python ../tools/export/decrypt_owner_export.py \
  /private/path/odyssey-export.odyx \
  --expected-signing-public-key 'REPLACE_BASE64_KEY_FROM_AUTHENTICATED_STATUS' \
  --output-dir /private/encrypted-volume/odyssey-export-verified
```

The tool prompts without echo for the passphrase. A protected passphrase file
can be supplied with `--passphrase-file`, but a command-line passphrase option
does not exist. It verifies the pinned Ed25519 key, signature, manifest hash,
every file hash and byte count, the job ID, and safe extraction paths. Use
`--decrypted-zip` only on an encrypted owner-controlled volume, and remove
decrypted material as soon as the drill ends.

## Rotation rule

The API and worker must use the same wrapping-key version for every queued job.
Before rotating the secret, prevent new export requests at the authenticated
ingress, let the old API/worker revision drain all `owner-export` outbox items,
pause the worker schedule, add the new version, and deploy API and worker
together before restoring traffic. Do not set the feature flag false before
the old worker drains because that also disables its export handler. Record
each authenticated status response's signing public key with its artifact hash.
Completed artifacts remain
decryptable with their owner passphrase and verifiable with their recorded old
public key; the service wrapping key is not needed after completion.
