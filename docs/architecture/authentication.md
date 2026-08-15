# Owner authentication and device trust

Odyssey is a private single-owner deployment. Authentication therefore has two
separate proofs:

1. Sign in with Apple proves the configured owner identity during bootstrap or
   device enrollment.
2. An Odyssey access token proves a currently active, separately enrolled
   device on ordinary API calls.

An Apple email address is never an authority boundary. The durable
`owner_identities` row is constrained to the singleton owner ID `owner` and
stores the verified Apple `sub`. Every protected request also checks the
`auth_devices` row, so revocation takes effect immediately even if a short-lived
access token has not expired.

## Configuration

Production `sign_in_with_apple` mode fails settings validation unless the Apple
audience and a signing key of at least 32 bytes are present. Inject these values
from Secret Manager or the equivalent deployment secret store:

| Variable | Secret | Purpose |
| --- | --- | --- |
| `ODYSSEY_AUTH_MODE=sign_in_with_apple` | no | enables production authentication |
| `ODYSSEY_APPLE_CLIENT_ID` | no | exact bundle ID or Services ID expected in Apple `aud` |
| `ODYSSEY_APPLE_BOOTSTRAP_SUBJECT` | treat as sensitive | one-time allowlist for the first verified Apple `sub` |
| `ODYSSEY_AUTH_ACCESS_TOKEN_SIGNING_KEY` | yes | signs Odyssey HS256 access tokens; at least 32 random bytes |
| `ODYSSEY_APPLE_ISSUER` | no | defaults to `https://appleid.apple.com` |
| `ODYSSEY_APPLE_JWKS_URL` | no | defaults to Apple's official key endpoint |
| `ODYSSEY_APPLE_JWKS_CACHE_SECONDS` | no | successful verification-key cache, default one hour |
| `ODYSSEY_AUTH_ACCESS_TOKEN_TTL_SECONDS` | no | access-token lifetime, default 15 minutes |
| `ODYSSEY_AUTH_REFRESH_CREDENTIAL_TTL_DAYS` | no | device credential lifetime, default 90 days |
| `ODYSSEY_AUTH_CHALLENGE_TTL_SECONDS` | no | nonce challenge lifetime, default five minutes |
| `ODYSSEY_AUTH_MAX_PENDING_CHALLENGES` | no | global pending challenge cap, default 1,000 |
| `ODYSSEY_AUTH_MAX_PENDING_CHALLENGES_PER_DEVICE` | no | per-device pending cap, default five |

Never commit an Apple identity token, bootstrap subject, access-token signing
key, device refresh credential, or recovery credential. Safe diagnostics expose
only whether required values are configured.

## Apple enrollment flow

The native implementation lives in `OdysseyAuth`: `KeychainCredentialVault`
holds the this-device-only UUIDv7/refresh material,
`URLSessionAuthClient` performs the bounded no-redirect HTTPS exchanges,
`SystemAppleAuthorizationPerformer` binds the challenge to Apple `state` and
hashed `nonce`, and `AppleEnrollmentCoordinator` installs the resulting
credential into `AccessTokenSession`. Portable fixtures validate contracts,
nonce hashing, expiry failure, refresh serialization, and secret-free errors.
The Security and AuthenticationServices branches still need Xcode, signing,
and physical-device evidence before release.

1. The app generates and durably stores a UUIDv7 device ID.
2. It requests `POST /v1/auth/apple/challenges` for that device.
3. It passes the returned raw nonce into `ASAuthorizationAppleIDRequest.nonce`
   using the SHA-256 form required by the native Apple flow.
4. It sends the Apple identity token, raw nonce, challenge ID, and bounded
   device metadata to `POST /v1/auth/apple/exchange`.
5. The backend accepts only `RS256`, resolves `kid` through bounded cached Apple
   JWKS, and verifies signature, issuer, audience, expiry, issued-at age, subject,
   and the hashed nonce.
   Challenge creation prunes expired rows and enforces global/per-device caps;
   the deployment edge must additionally rate-limit the public auth routes.
6. The first successful exchange must match
   `ODYSSEY_APPLE_BOOTSTRAP_SUBJECT`; subsequent exchanges must match the
   durable subject. A consumed challenge can be retried only with the exact same
   identity-token hash, making response loss recoverable without permitting a
   different token replay.
7. The backend returns a 15-minute access token and a high-entropy device
   refresh credential. Only its SHA-256 hash is stored.

After confirming the first owner identity and at least two recovery credentials,
remove `ODYSSEY_APPLE_BOOTSTRAP_SUBJECT` from the runtime secret configuration.
The GCP deployment does this by setting `apple_bootstrap_enabled = false`,
deploying a revision with no subject reference, retiring pre-bootstrap rollback
revisions, and only then disabling the secret version. The durable allowlist
remains authoritative. Changing an email address or Apple relay address has no
effect on identity.

## Device credentials

The Apple client stores the refresh credential in Keychain with the strictest
accessibility compatible with background sync; it must never use UserDefaults,
logs, crash metadata, widgets, or notification payloads. The device ID and
credential survive ordinary app updates. A reinstall that loses Keychain state
uses a new UUIDv7 and performs Apple enrollment or the recovery procedure.

`POST /v1/auth/token/refresh` exchanges the active device credential for a new
short-lived access token. The refresh credential is stable until expiry,
explicit revocation, or a successful Apple re-enrollment that replaces it. This
avoids making a lost HTTP response revoke a healthy device. TLS is mandatory.

Protected capture and sync operations bind any supplied device ID to the access
token's `device_id`. Attachment chunk upload uses its separate short-lived,
upload-scoped signed URL token; initialization, completion, and status remain
owner authenticated.

## Revocation

`GET /v1/auth/devices` lists active and revoked enrollments without credential
material. An active device calls
`POST /v1/auth/devices/{device_id}/revoke` with one bounded reason code. The
transaction marks both the device and refresh credential revoked and appends an
immutable `auth_device_audit` event. Repeating the request is idempotent.

Every access-token authentication queries device state, so a revoked device is
denied immediately. A revoked device ID cannot be silently reactivated through
Apple or recovery exchange; a legitimate reinstall creates a new ID. Operators
must preserve the audit trail rather than deleting device rows.

## Recovery boundary

Recovery does not bypass identity durability. An operator provisions one-time
credentials only after the owner identity exists. The database stores a hash;
the raw material is immediately wrapped in the versioned
`odyssey-owner-recovery-v1` envelope using Scrypt (`N=32768`, `r=8`, `p=1`) and
AES-256-GCM with authenticated format metadata. The passphrase is never written
to the bundle or database. The encrypted bundle is written once to a new
owner-only file and should also reside in an encrypted password manager or
offline volume. Recovery exchange requires an unconsumed, unexpired, unrevoked
credential and consumes it in the same transaction that enrolls the fresh
device.

See [`../runbooks/account-recovery.md`](../runbooks/account-recovery.md) for
provisioning, drills, lost-device response, and replacement steps.

## Payload safety

Authentication request bodies and headers are never included in logs, traces,
or metrics. Apple email claims are ignored. Audit records contain device IDs,
bounded platform/app versions, event types, and reason codes—not identity
tokens, access tokens, refresh credentials, recovery material, or Apple JWKS
responses.
