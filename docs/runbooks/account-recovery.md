# Owner account and device recovery

Use this runbook when all active device credentials are unavailable, an owner
device is lost, or a clean-room restore needs a fresh device. Prefer normal Sign
in with Apple whenever the Apple account is available. Recovery credentials are
an independent, one-time path for a restored server with an existing owner
identity.

## 1. Provision recovery material

Run this only after the first verified Apple enrollment and current backup. The
output path must not exist. Use an approved owner-controlled machine and an
encrypted destination or immediately import the resulting file into an
end-to-end encrypted password manager:

```bash
cd backend
uv run python ../tools/admin/recovery_credential.py \
  --database-url "$ODYSSEY_DATABASE_URL" \
  create \
  --label primary \
  --created-by owner \
  --valid-days 365 \
  --output /approved/encrypted/location/odyssey-recovery-primary.json
```

Expected output reports a credential ID, expiry, path, and file mode `0600`; it
never prints the credential. The CLI prompts twice for a passphrase of at least
16 characters and writes only an authenticated AES-256-GCM/Scrypt envelope.
Store that passphrase separately from the bundle or in a distinct protected
entry. Verify the destination permissions and encrypted backup independently.
Create a secondary credential with a different passphrase in a separate
encrypted location. Do not email, photograph, print to a shared printer, paste
into chat, or place either file in source control or an unencrypted cloud drive.

Inventory credentials without revealing hashes or raw values:

```bash
uv run python ../tools/admin/recovery_credential.py \
  --database-url "$ODYSSEY_DATABASE_URL" list
```

Expected status is `available`. Rotate before expiry and after every drill or
real use.

## 2. Contain a lost or compromised device

From another active device, list enrollments and revoke the affected UUID with
the `lost` or `compromised` reason. Confirm that both an ordinary protected API
request and refresh attempt from the affected test client return `401`. Preserve
the immutable audit event and relevant trace IDs.

If no active device remains, recover a fresh device first, then revoke every
missing enrollment. Also use Apple's account/device controls when compromise is
suspected; Odyssey revocation does not remotely erase an Apple device.

## 3. Recover a fresh device

1. Verify the API and database were restored through
   [`clean-room-recovery.md`](clean-room-recovery.md), including integrity checks.
2. Install the expected signed staging or production app on the fresh device.
3. Let the app generate a new UUIDv7; never reuse a revoked device ID.
4. In the app's dedicated recovery UI, select the encrypted recovery record.
   Enter the passphrase locally; the app verifies/decrypts the versioned bundle,
   sends the recovered credential once to `POST /v1/auth/recovery/exchange` over
   TLS, and then clears transient memory. Do not pass the credential or
   passphrase as a shell argument, query parameter, crash attachment, or support
   message.
5. Confirm the response enrolls the expected new device and that token refresh
   works.
6. Confirm replaying the same recovery credential returns `401`.
7. Pull and verify the restored history, cursors, projection checksums, and
   attachment manifest before allowing new real capture.
8. Revoke lost devices and create a replacement recovery credential in a new
   encrypted location.

## 4. Revoke unused material

```bash
uv run python ../tools/admin/recovery_credential.py \
  --database-url "$ODYSSEY_DATABASE_URL" \
  revoke RECOVERY_CREDENTIAL_UUID \
  --revoked-by owner
```

Expected status is `revoked`. A consumed credential cannot be repurposed or
revoked; retain its lifecycle record for audit.

## 5. Failure handling

- **Apple works:** use a fresh Apple nonce challenge instead of recovery.
- **Recovery says invalid:** check credential ID/status/expiry from the safe
  list command, deployment clock, schema head, and that the restored database
  contains `owner_identities`. Never inspect or log the submitted raw value.
- **No Apple access and no valid recovery material:** stop. Restore a recovery
  point and encrypted material that were previously verified. Do not edit the
  owner subject, device status, or credential hashes directly to bypass auth.
- **Access-token signing key rotated:** existing access tokens fail immediately;
  an active refresh or recovery credential can obtain a token signed by the new
  key.
- **Credential exposed:** revoke its ID, preserve incident metadata without the
  raw value, rotate affected device credentials, and follow
  [`incident-response.md`](incident-response.md).

Run a staging recovery drill at least quarterly and after auth-schema or key
management changes. Record only IDs, timestamps, hashes of reports, status
codes, and trace IDs—not tokens or recovery material.
