# Odyssey owner deployment handoff

This is the owner-operated account, signing, cloud, deployment, recovery, and
release procedure required by §36.6 of the master specification. Run it from a
private owner-controlled machine. Replace every `REPLACE_*` value outside the
repository. Never commit account identifiers, billing identifiers, Apple
subjects, tokens, provider values, state, plans, signed artifacts, or real
personal data.

## Current evidence boundary

As of 2026-08-15, repository validation proves the credential-free contracts;
it does not prove an owner deployment:

- The current backend baseline passes 195 tests at 86.81% coverage. Schema
  generation verifies 67 artifacts, and OpenTofu 1.10.6 validates all five
  mocked plans including encrypted-export wiring. Run the complete
  cross-platform `make verify` again from the release commit before deployment.
- OpenTofu 1.10.6 and Google provider 7.44.0 were separately validated against
  five mocked plans. No real Google Cloud resource has been provisioned or
  deployed.
- A Docker build was attempted, but Docker Hub timed out before any Dockerfile
  build step ran. No Odyssey image has been built or pushed from this
  environment.
- No Apple-platform package build, Xcode archive, signing operation, TestFlight
  upload, or physical-device test has been performed. The portable Swift
  package has been compiled and its 45 deterministic tests have run under a temporary
  Linux Swift 6.1 toolchain; that is not Apple-platform validation.
- The cloud model remains `deterministic`. Adding a model-provider key alone
  enables nothing; no evaluated cloud-model adapter is implemented.
- External OAuth connectors and webhook handlers are not implemented. Their
  applications, redirect URIs, and secret versions must remain unconfigured.
- The backend Sign in with Apple verifier and native nonce-bound challenge,
  AuthenticationServices, exchange, refresh, and Keychain components now
  exist. Their Security/AuthenticationServices branches have not been compiled
  with Xcode or exercised with a real Apple credential. The Apple data package
  now has a
  GRDB ledger, migration-v2 preflight backup, immutable remote receipts,
  atomic push/pull persistence, projection rebuild, verified backup, and owner
  export. An authenticated HTTPS-only `URLSession` sync transport is also
  implemented and contract-tested. A portable application coordinator now
  connects that transport to durable push-result and resumable pull-page
  persistence, including exact local diagnostics and bounded retries. The
  iPhone shell now instantiates local services before optional remote services,
  exposes nonce-bound Apple enrollment, durable text capture, manual sync,
  integrity verification, projection rebuild, and an opportunistic app-refresh
  entry. None of those Apple-platform paths has been Xcode-built or
  device-tested.
  The device/refresh Keychain vault, in-memory access-token refresh session,
  native Apple ceremony, and auth HTTP exchange are implemented as package
  boundaries. Recovery UI, server-side device-revocation UI, and physical
  background-execution evidence are still not implemented.
- Edition 0 remains incomplete until a real cloud restore and physical-device
  evidence exist. Steps marked **BLOCKED** are release blockers, not optional
  paperwork.

## Gate labels and private record

- **OWNER REQUIRED** means an account holder must perform or approve the action.
- **AUTOMATABLE AFTER OWNER SETUP** means the checked-in command can run only
  after the named account values exist.
- **BLOCKED** means the repository does not yet contain the implementation or
  external evidence required to pass.
- **DO NOT CONFIGURE** means creating credentials now would add risk without an
  executable consumer.

Keep a private deployment record in an encrypted owner vault. For every step,
record UTC time, operator, environment, source commit, command or portal path,
resource IDs, result, evidence hash, and rollback decision. Store no raw token,
Apple subject, secret value, database URL, export payload, or private log body
in that record.

The shell examples assume `bash`, `jq`, `gh`, `gcloud`, OpenTofu 1.10.6,
Docker Buildx, and an owner-controlled clone:

```bash
export REPOSITORY_ROOT="/private/path/to/odyssey-v2-main"
export GITHUB_REPOSITORY="REPLACE_OWNER/REPLACE_REPOSITORY"
export STATE_PROJECT_ID="REPLACE_STATE_PROJECT"
export STAGING_PROJECT_ID="REPLACE_STAGING_PROJECT"
export PRODUCTION_PROJECT_ID="REPLACE_PRODUCTION_PROJECT"
export REGION="europe-west2"
export ARCHIVE_LOCATION="EU"
cd "$REPOSITORY_ROOT"
```

Run `make verify` before starting and again before every release. Stop if the
working tree is dirty or the checked-out commit is not the intended release.

## 1. Create or choose the Apple Developer account and team

**Gate: OWNER REQUIRED.** The owner must control the Apple ID, trusted phone
numbers, recovery contacts, legal agreements, and annual membership.

**Action**

1. Sign in at <https://developer.apple.com/account/> with an Apple ID protected
   by two-factor authentication.
2. Enroll as an individual or organization. For an organization, verify the
   legal entity, D-U-N-S record, and Account Holder authority.
3. Accept all pending agreements in Apple Developer and App Store Connect.
4. In **Membership details**, copy the ten-character Team ID into the private
   deployment record. Do not add it to a tracked file.
5. On the owner Mac, install Xcode, sign in under **Xcode → Settings →
   Accounts**, select the team, and run:

```bash
xcodebuild -version
xcrun swift --version
security find-identity -v -p codesigning
```

**Expected output**

- Membership is active and agreements show no pending action.
- Xcode reports an installed version with Swift 6.1 or newer support, as
  required by the pinned GRDB package manifest.
- `security find-identity` reports an Apple Development identity after Xcode
  manages certificates. Distribution identities may appear only after release
  setup.

**Troubleshooting**

- If the team is absent in Xcode, refresh the account, accept agreements, and
  confirm the selected organization role permits certificate/profile work.
- If no signing identity appears, let Xcode manage signing for a disposable
  empty project first; do not export a private key to source control or chat.
- If membership verification is pending, stop. A free personal team is not a
  production distribution substitute.

**Evidence retained**

- Membership status, Team ID, legal entity type, agreement status, Xcode/Swift
  versions, and certificate fingerprints. Retain fingerprints, not private
  keys or exported `.p12` files.

## 2. Create app identifiers and bundle IDs

**Gate: OWNER REQUIRED.** Bundle prefixes must be owner-controlled, globally
unique, and separate for development, staging, and production.

**Action**

Choose three base prefixes. The checked-in examples are placeholders and must
not be registered:

```bash
export DEV_BUNDLE_PREFIX="com.REPLACE_OWNER.odyssey.dev"
export STAGING_BUNDLE_PREFIX="com.REPLACE_OWNER.odyssey.staging"
export PRODUCTION_BUNDLE_PREFIX="com.REPLACE_OWNER.odyssey"

for prefix in \
  "$DEV_BUNDLE_PREFIX" \
  "$STAGING_BUNDLE_PREFIX" \
  "$PRODUCTION_BUNDLE_PREFIX"; do
  for suffix in app watch mac widgets intents share; do
    printf '%s.%s\n' "$prefix" "$suffix"
  done
done
```

In **Certificates, Identifiers & Profiles → Identifiers**, register each output
as an explicit App ID. Use descriptions that include the environment and
target. The main native Sign in with Apple audience is exactly
`$<ENV>_BUNDLE_PREFIX.app`.

The required target mapping is:

| Target | Bundle suffix |
| --- | --- |
| iPhone/iPad app | `.app` |
| Watch app | `.watch` |
| macOS app | `.mac` |
| Widget extension | `.widgets` |
| App Intents extension | `.intents` |
| Share extension | `.share` |

**Expected output**

- Apple lists 18 explicit identifiers: six targets in each of three
  environments.
- No development profile shares a production identifier.
- The identifiers exactly match the expansion in `apple/project.yml`.

**Troubleshooting**

- If an identifier is unavailable, choose another owner-controlled reverse
  domain prefix; do not append an undocumented suffix in Xcode only.
- If Xcode later reports an embedded target mismatch, compare all six bundle
  IDs and the Watch companion ID before regenerating profiles.
- Do not use wildcard App IDs; capabilities in later steps require explicit
  identifiers.

**Evidence retained**

- Private identifier inventory with environment, target, App ID resource ID,
  creation time, and Team ID. Do not commit the real prefix.

## 3. Enable capabilities and containers

**Gate: OWNER REQUIRED; ASSOCIATED-DOMAIN AND APNS DELIVERY REMAIN BLOCKED.**
Entitlements permit signing; they do not authorize runtime data access.

**Action**

Register one App Group per environment:

```bash
printf 'group.%s\n' \
  "$DEV_BUNDLE_PREFIX" \
  "$STAGING_BUNDLE_PREFIX" \
  "$PRODUCTION_BUNDLE_PREFIX"
```

Associate every target in that environment with its group. In the Developer
portal, enable only the capabilities represented by the checked-in
entitlements:

| Identifier | Capabilities |
| --- | --- |
| Main `.app` | App Groups, HealthKit, Sign in with Apple, Push Notifications, Associated Domains, Siri |
| Watch `.watch` | App Groups, HealthKit |
| macOS `.mac` | App Groups; sandbox/network/file entitlements remain Xcode-managed |
| Widgets `.widgets` | App Groups |
| Intents `.intents` | App Groups, Siri |
| Share `.share` | App Groups |

No iCloud or CloudKit container exists in the current design. Do not create one
or enable iCloud merely because Apple calls App Groups “containers.”

Choose an owner-controlled HTTPS domain before replacing
`applinks:example.invalid`. Host a valid AASA document and verify it without a
redirect:

```bash
export ASSOCIATED_DOMAIN="REPLACE_DOMAIN"
curl --fail --silent --show-error \
  "https://${ASSOCIATED_DOMAIN}/.well-known/apple-app-site-association" \
  | jq -e . >/dev/null
```

Push is an entitlement only at this stage. No APNs delivery adapter or APNs
secret container is implemented, so do not upload an APNs signing key to
Odyssey yet. Keep proactive delivery disabled.

**Expected output**

- Every App ID shows only the capabilities in the table.
- Each environment has one distinct App Group.
- The AASA request returns `200`, no redirect, and valid JSON when the domain
  gate is eventually completed.

**Troubleshooting**

- If profile generation says an entitlement is unavailable, re-open the App ID,
  verify the capability, and regenerate the profile. Do not delete the
  entitlement to make signing green without recording the deviation.
- HealthKit capability changes may require explicit agreement acceptance.
- If no owner-controlled domain exists, keep associated-domain release work
  blocked; never ship `example.invalid`.

**Evidence retained**

- Capability screenshots or portal export, App Group identifiers, AASA body
  hash and HTTP headers, profile UUIDs, and a note that APNs backend delivery
  remains unimplemented. Never retain an APNs private key in the evidence set.

## 4. Create Sign in with Apple configuration

**Gate: OWNER REQUIRED; DEVICE VALIDATION IS BLOCKED.** Backend and native
exchange code exist, but no owner-signed build or real Apple credential has
validated the ceremony.

**Action**

1. Make the main `.app` identifier in each environment a primary Sign in with
   Apple App ID, or group the nonproduction IDs under the production primary ID
   only after reviewing Apple transfer/grouping consequences.
2. For the current native-only design, use the main bundle ID as
   `ODYSSEY_APPLE_CLIENT_ID`. Do not create a web Services ID, return URL, or
   client secret; no web callback consumes them.
3. Record the audience privately and place it in the environment `.tfvars` as
   the nonsecret `apple_client_id` value.
4. After the checked-in native flow is composed into the staging app, perform
   one Apple authorization and keep the signed identity token only in app memory. The
   verified durable authority is Apple `sub`, never email.
5. Insert the expected first-owner `sub` through stdin only when the audited
   client ceremony can prove it:

```bash
export ENVIRONMENT="staging"
export PROJECT_ID="$STAGING_PROJECT_ID"
read -r -s APPLE_BOOTSTRAP_SUBJECT
printf '%s' "$APPLE_BOOTSTRAP_SUBJECT" | gcloud secrets versions add \
  "odyssey-${ENVIRONMENT}-apple-bootstrap-subject" \
  --project "$PROJECT_ID" --data-file=-
unset APPLE_BOOTSTRAP_SUBJECT
```

Do not decode an identity token into a ticket, paste it into a terminal command,
or use an Apple email/relay address as the bootstrap subject.

**Expected output**

- Apple lists Sign in with Apple on the main App ID.
- A future verified token has `iss=https://appleid.apple.com`, the exact bundle
  audience, a nonce matching the backend challenge, and the expected `sub`.
- Secret Manager reports one enabled bootstrap-subject version without showing
  its payload.

**Troubleshooting**

- `invalid_client` or audience failures mean the bundle ID, environment, and
  backend `apple_client_id` differ.
- A nonce failure must restart the challenge; never disable nonce validation.
- If the owner `sub` cannot be obtained through the implemented app flow, stop.
  This is the current repository state.

**Evidence retained**

- App ID grouping decision, client audience, challenge/exchange status codes,
  token hash, Apple key ID, and Secret Manager version number. Retain no token,
  raw nonce, subject, or email.

## 5. Create cloud projects and billing budget

**Gate: OWNER REQUIRED.** Use separate state, staging, and production projects.
The current IaC creates separate archive buckets inside each environment
project; it does not create the projects themselves.

**Action**

Authenticate the owner and list eligible billing accounts:

```bash
gcloud auth login
gcloud auth application-default login
gcloud billing accounts list
```

Create and link the three projects. Add `--organization` or `--folder` when the
owner account requires it:

```bash
gcloud projects create "$STATE_PROJECT_ID" --name="Odyssey State"
gcloud projects create "$STAGING_PROJECT_ID" --name="Odyssey Staging"
gcloud projects create "$PRODUCTION_PROJECT_ID" --name="Odyssey Production"

export BILLING_ACCOUNT_ID="REPLACE_AAAAAA-BBBBBB-CCCCCC"
for project in \
  "$STATE_PROJECT_ID" \
  "$STAGING_PROJECT_ID" \
  "$PRODUCTION_PROJECT_ID"; do
  gcloud billing projects link "$project" \
    --billing-account "$BILLING_ACCOUNT_ID"
  gcloud billing projects describe "$project"
done
```

Create a private Monitoring notification channel outside Odyssey for staging
and production, such as the owner's monitored email or paging destination.
Record each full resource name
`projects/PROJECT/notificationChannels/CHANNEL_ID`. Set private whole-number
monthly budget and ISO currency values in each private `.tfvars`. OpenTofu
creates 50%, 90%, and forecasted-100% budget thresholds during step 7.

**Expected output**

- `billingEnabled: true` for all projects.
- Project deletion protection/organization policy is appropriate for the owner.
- A real external notification channel exists before production planning.
- After step 7, Billing Budgets lists `Odyssey staging monthly budget` and
  `Odyssey production monthly budget`.

**Troubleshooting**

- If project creation or linking is denied, the owner needs Project Creator and
  Billing Account User permissions from the organization administrator.
- Budget creation requires billing-account permissions in addition to project
  ownership.
- Do not use a shared employer project, sandbox billing account, or a channel
  that depends on Odyssey being healthy.

**Evidence retained**

- Project numbers, billing-link status, budget amount/currency, threshold
  policy ID, channel resource ID, and a delivered channel test. Keep the billing
  account ID and addresses in the private record only.

## 6. Enable APIs

**Gate: OWNER REQUIRED, THEN AUTOMATABLE.** OpenTofu also manages these services;
the explicit bootstrap makes provider failures easier to diagnose.

**Action**

Enable state-project services:

```bash
gcloud services enable \
  cloudkms.googleapis.com \
  storage.googleapis.com \
  --project "$STATE_PROJECT_ID"
```

Enable every environment service declared in `infra/gcp/locals.tf`:

```bash
services=(
  artifactregistry.googleapis.com
  billingbudgets.googleapis.com
  cloudkms.googleapis.com
  cloudresourcemanager.googleapis.com
  cloudscheduler.googleapis.com
  cloudtasks.googleapis.com
  compute.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  logging.googleapis.com
  monitoring.googleapis.com
  run.googleapis.com
  secretmanager.googleapis.com
  servicenetworking.googleapis.com
  sqladmin.googleapis.com
  storage.googleapis.com
  sts.googleapis.com
)
for project in "$STAGING_PROJECT_ID" "$PRODUCTION_PROJECT_ID"; do
  gcloud services enable "${services[@]}" --project "$project"
  gcloud services list --enabled --project "$project" \
    --format='value(config.name)' | sort
done
```

**Expected output**

- Every service in the array appears in each environment's enabled list.
- No API key or service-account JSON key is created.

**Troubleshooting**

- `SERVICE_DISABLED` after a successful command can take several minutes to
  converge; retry the exact failed plan after confirming the enabled list.
- Organization policy may block service activation or service-agent creation;
  obtain a narrow exception rather than assigning Owner broadly.
- If billing-budget API activation fails, verify the billing account link and
  Billing Budgets permissions.

**Evidence retained**

- Sorted enabled-service list and activation UTC time for each project. Hash
  the files before placing them in the private evidence bundle.

## 7. Provision with infrastructure code

**Gate: OWNER REQUIRED. NO LIVE APPLY HAS BEEN PERFORMED BY THIS REPOSITORY
SESSION.** First apply creates foundations only; workloads remain off.

**Action**

Verify the exact source and local tooling:

```bash
cd "$REPOSITORY_ROOT"
git status --short
git rev-parse HEAD
tofu version
make infra-check
```

Create private configuration outside the clone:

```bash
umask 077
export ODYSSEY_PRIVATE_CONFIG="$HOME/.config/odyssey/deployment"
mkdir -p "$ODYSSEY_PRIVATE_CONFIG"
cp infra/gcp/bootstrap/terraform.tfvars.example \
  "$ODYSSEY_PRIVATE_CONFIG/bootstrap.tfvars"
cp infra/gcp/environments/staging.tfvars.example \
  "$ODYSSEY_PRIVATE_CONFIG/staging.tfvars"
cp infra/gcp/environments/production.tfvars.example \
  "$ODYSSEY_PRIVATE_CONFIG/production.tfvars"
cp infra/gcp/backend.staging.hcl.example \
  "$ODYSSEY_PRIVATE_CONFIG/staging.backend.hcl"
cp infra/gcp/backend.production.hcl.example \
  "$ODYSSEY_PRIVATE_CONFIG/production.backend.hcl"
chmod 600 "$ODYSSEY_PRIVATE_CONFIG"/*
```

Replace every marker privately. Keep `deploy_workloads = false`,
`public_api_enabled = false`, and `schedules_paused = true`. Use exact numeric
GitHub IDs obtained without parsing display names:

```bash
gh api "repos/${GITHUB_REPOSITORY}" \
  --jq '{repository: .full_name, repository_id: .id, owner_id: .owner.id}'
```

Bootstrap protected state with local state retained on an encrypted volume
until the deployer identity is added:

```bash
tofu -chdir=infra/gcp/bootstrap init
tofu -chdir=infra/gcp/bootstrap plan \
  -out="$ODYSSEY_PRIVATE_CONFIG/bootstrap.tfplan" \
  -var-file="$ODYSSEY_PRIVATE_CONFIG/bootstrap.tfvars"
tofu -chdir=infra/gcp/bootstrap apply \
  "$ODYSSEY_PRIVATE_CONFIG/bootstrap.tfplan"
tofu -chdir=infra/gcp/bootstrap output -json \
  > "$ODYSSEY_PRIVATE_CONFIG/bootstrap-outputs.json"
```

Put the resulting bucket in both backend files, then provision each foundation:

```bash
for environment in staging production; do
  tofu -chdir=infra/gcp init -reconfigure \
    -backend-config="$ODYSSEY_PRIVATE_CONFIG/${environment}.backend.hcl"
  tofu -chdir=infra/gcp plan \
    -out="$ODYSSEY_PRIVATE_CONFIG/${environment}-foundation.tfplan" \
    -var-file="$ODYSSEY_PRIVATE_CONFIG/${environment}.tfvars"
  tofu -chdir=infra/gcp show -no-color \
    "$ODYSSEY_PRIVATE_CONFIG/${environment}-foundation.tfplan" \
    > "$ODYSSEY_PRIVATE_CONFIG/${environment}-foundation.plan.txt"
  tofu -chdir=infra/gcp apply \
    "$ODYSSEY_PRIVATE_CONFIG/${environment}-foundation.tfplan"
  tofu -chdir=infra/gcp output -json \
    > "$ODYSSEY_PRIVATE_CONFIG/${environment}-outputs.json"
done
```

Add both deployer service-account emails from the outputs to
`state_admin_members`, re-plan/apply the bootstrap module with its protected
local state, verify CI state access, then securely archive or destroy the local
bootstrap state. Never delete it before the update or recreate the bucket by
hand.

**Expected output**

- Protected state bucket is versioned, retention-protected, private, and CMEK
  encrypted.
- Each environment has private VPC, PostgreSQL 17 Cloud SQL, PITR, CMEK buckets,
  Secret Manager containers without payloads, Artifact Registry, service
  accounts, WIF, budget, and monitoring resources.
- `api_url` and all `cloud_run_jobs` are `null` while workloads are disabled.
- Plans contain no secret values and no public API IAM grant.

**Troubleshooting**

- Bucket-name conflicts require a new globally unique private value, not manual
  reuse of another bucket.
- KMS failures usually mean a Google service agent has not propagated or lacks
  the narrow encrypter/decrypter role; inspect the failing resource dependency.
- Production guard failures identify a missing HA, deletion-protection, Apple,
  WIF, budget, alert, or public/paused prerequisite. Do not bypass the guard.
- Private Cloud SQL means the later privileged `psql` bootstrap requires an
  owner-approved VPC path; the module intentionally creates no public IP.

**Evidence retained**

- Source SHA, tool/provider versions, redacted plan text and hashes, apply IDs,
  outputs, state object generation, IAM policy snapshots, resource inventory,
  and budget/channel IDs. Keep plans and outputs encrypted outside Git.

## 8. Create provider or OAuth applications

**Gate: DO NOT CONFIGURE; CURRENTLY BLOCKED.** No external OAuth connector is
implemented. Sign in with Apple is handled in step 4 and is not this step.

**Action**

Confirm the executable connector inventory before creating any provider app:

```bash
cd "$REPOSITORY_ROOT"
find backend/src/odyssey/integrations -maxdepth 2 -type f -print \
  -exec sed -n '1,80p' {} \;
rg -n "oauth|authorization_code|webhook" backend/src apple/Packages || true
```

The expected current result is only the integrations package marker and no
OAuth authorization-code, PKCE, token-refresh, revocation, or provider client.
Do not create Strava, Google, Microsoft, Oura, Garmin, social, dating, or other
provider applications. Add one only with a reviewed connector, terms review,
least-scope list, deletion path, rate-limit policy, threat model, and ADR.

**Expected output**

- No provider application ID, client secret, production scope grant, or owner
  data authorization exists.

**Troubleshooting**

- A product desire or placeholder secret is not an implementation. Return to
  the edition plan and build the bounded connector before account setup.
- If a provider app was created prematurely, revoke its credentials and record
  deletion confirmation.

**Evidence retained**

- Dated “not configured” decision, code search result hash, and any revoked-app
  confirmation. Retain no provider payload.

## 9. Set redirect URIs and webhook secrets

**Gate: DO NOT CONFIGURE; CURRENTLY BLOCKED.** There are no callback or webhook
routes to receive these values.

**Action**

Leave the OpenTofu-created placeholders without enabled versions and verify
that state explicitly:

```bash
for environment_project in \
  "staging:$STAGING_PROJECT_ID" \
  "production:$PRODUCTION_PROJECT_ID"; do
  environment="${environment_project%%:*}"
  project="${environment_project#*:}"
  for suffix in oauth-client-secret webhook-signing-secret; do
    printf '%s %s: ' "$environment" "$suffix"
    gcloud secrets versions list "odyssey-${environment}-${suffix}" \
      --project "$project" --filter='state=ENABLED' \
      --format='value(name)'
  done
done
```

Native Sign in with Apple currently uses no web redirect URI. Do not invent one
or configure a Services ID callback.

**Expected output**

- Both commands print no enabled version for both environments.
- No DNS callback host or webhook endpoint is publicly exposed.

**Troubleshooting**

- If a version exists, identify who created it, disable/destroy it under the
  incident record, and rotate the upstream credential.
- A provider console that requires a redirect URI means its connector cannot be
  enabled yet.

**Evidence retained**

- Secret-version inventory and empty route inventory. Do not retain a disabled
  secret payload.

## 10. Add model-provider keys and policies

**Gate: DO NOT CONFIGURE; CURRENTLY BLOCKED.** Deterministic behavior is the only
implemented provider mode.

**Action**

Keep private `.tfvars` at:

```hcl
model_provider   = "deterministic"
proactive_enabled = false
```

Confirm no key version and no model adapter:

```bash
for environment_project in \
  "staging:$STAGING_PROJECT_ID" \
  "production:$PRODUCTION_PROJECT_ID"; do
  environment="${environment_project%%:*}"
  project="${environment_project#*:}"
  gcloud secrets versions list \
    "odyssey-${environment}-model-provider-api-key" \
    --project "$project" --filter='state=ENABLED' \
    --format='value(name)'
done
rg -n "class .*Provider|Responses API|chat.completions" backend/src/odyssey/ai || true
```

Adding a key alone enables nothing: the runtime neither injects that placeholder
as an environment variable nor implements a cloud-model client. A future
enablement requires task-specific evaluation, data-retention/region policy,
sensitive-route denial, budgets, structured output validation, deterministic
fallback, prompt/model versioning, and rollback.

**Expected output**

- No enabled model-key version.
- `/v1/admin/diagnostics` eventually reports `model_provider: deterministic`
  and `cloud_model: false` after authenticated enrollment.

**Troubleshooting**

- If a key exists, disable it both upstream and in Secret Manager. Do not treat
  its presence as a successful integration test.
- If a config change claims a provider without an adapter/eval report, revert
  to deterministic mode.

**Evidence retained**

- Empty secret-version result, policy decision, evaluation gate status, and
  deterministic diagnostics. No provider key or prompt containing owner data.

## 11. Build and deploy the backend

**Gate: BLOCKED UNTIL STEP 4 CAN SUPPLY THE OWNER SUBJECT; OWNER REQUIRED FOR
WORKFLOW INSTALLATION AND FIRST WORKLOAD APPLY.** Foundation deployment from
step 7 may proceed independently.

**Action**

Install the checked-in workflow contracts using an owner credential allowed to
modify workflows:

```bash
cd "$REPOSITORY_ROOT"
mkdir -p .github/workflows
install -m 0644 ci/github-actions-verify.yml .github/workflows/verify.yml
install -m 0644 ci/github-actions-deploy.yml .github/workflows/deploy.yml
git add .github/workflows
git commit -m "ci: install owner workflows"
git push origin main
```

Create protected `staging` and `production` GitHub environments. Require owner
approval for production and restrict it to `main`. Configure every environment
variable in `ci/README.md`: project, region, archive location, state bucket,
WIF provider, deployer service account, monitoring channels, billing values,
Apple client ID, immutable repository/owner IDs, digest-pinned Python/uv/proxy
images, and the exact PostgreSQL client package expression. Put no Odyssey
secret in GitHub.

The following owner-side function sets the complete variable contract. Resolve
the WIF/deployer outputs separately from each environment backend first:

```bash
gh api --method PUT "repos/${GITHUB_REPOSITORY}/environments/staging"
gh api --method PUT "repos/${GITHUB_REPOSITORY}/environments/production"

export STATE_BUCKET="$(jq -r '.state_bucket.value' \
  "$ODYSSEY_PRIVATE_CONFIG/bootstrap-outputs.json")"
export REPOSITORY_NUMERIC_ID="$(gh api "repos/${GITHUB_REPOSITORY}" --jq '.id')"
export REPOSITORY_OWNER_NUMERIC_ID="$(gh api \
  "repos/${GITHUB_REPOSITORY}" --jq '.owner.id')"

configure_github_environment() {
  local environment="$1"
  local project_id="$2"
  local wif_provider="$3"
  local deployer_service_account="$4"
  local monitoring_channel="$5"
  local monthly_budget="$6"
  local apple_client_id="$7"
  local apple_bootstrap_enabled="$8"

  gh variable set GCP_PROJECT_ID --env "$environment" --body "$project_id"
  gh variable set GCP_REGION --env "$environment" --body "$REGION"
  gh variable set GCP_ARCHIVE_LOCATION --env "$environment" \
    --body "$ARCHIVE_LOCATION"
  gh variable set GCP_STATE_BUCKET --env "$environment" --body "$STATE_BUCKET"
  gh variable set GCP_WIF_PROVIDER --env "$environment" --body "$wif_provider"
  gh variable set GCP_DEPLOYER_SERVICE_ACCOUNT --env "$environment" \
    --body "$deployer_service_account"
  gh variable set GCP_MONITORING_CHANNEL_IDS_JSON --env "$environment" \
    --body "$(jq -cn --arg channel "$monitoring_channel" '[$channel]')"
  gh variable set GCP_BILLING_ACCOUNT_ID --env "$environment" \
    --body "$BILLING_ACCOUNT_ID"
  gh variable set GCP_BILLING_CURRENCY_CODE --env "$environment" \
    --body "$BILLING_CURRENCY_CODE"
  gh variable set GCP_MONTHLY_BUDGET_AMOUNT --env "$environment" \
    --body "$monthly_budget"
  gh variable set APPLE_CLIENT_ID --env "$environment" --body "$apple_client_id"
  gh variable set APPLE_BOOTSTRAP_ENABLED --env "$environment" \
    --body "$apple_bootstrap_enabled"
  gh variable set REPOSITORY_NUMERIC_ID --env "$environment" \
    --body "$REPOSITORY_NUMERIC_ID"
  gh variable set REPOSITORY_OWNER_NUMERIC_ID --env "$environment" \
    --body "$REPOSITORY_OWNER_NUMERIC_ID"
  gh variable set PYTHON_BASE_IMAGE --env "$environment" \
    --body "$PYTHON_BASE_IMAGE"
  gh variable set UV_BASE_IMAGE --env "$environment" --body "$UV_BASE_IMAGE"
  gh variable set CLOUD_SQL_PROXY_IMAGE --env "$environment" \
    --body "$CLOUD_SQL_PROXY_IMAGE"
  gh variable set POSTGRESQL_CLIENT_PACKAGE --env "$environment" \
    --body "$POSTGRESQL_CLIENT_PACKAGE"
}
```

Call it with final argument `true` once for staging and once for production
after initializing each
backend and reading `github_workload_identity_provider` plus the `deployer`
member of `service_accounts`. Set production required reviewers in the GitHub
web UI; the basic environment API call above does not create that protection.

For the first private, paused workload apply, insert only the three required
Secret Manager versions. Use stdin:

```bash
export ENVIRONMENT="staging"
export PROJECT_ID="$STAGING_PROJECT_ID"
openssl rand -base64 48 | gcloud secrets versions add \
  "odyssey-${ENVIRONMENT}-attachment-upload-signing-key" \
  --project "$PROJECT_ID" --data-file=-
openssl rand -base64 48 | gcloud secrets versions add \
  "odyssey-${ENVIRONMENT}-auth-access-token-signing-key" \
  --project "$PROJECT_ID" --data-file=-
# Add apple-bootstrap-subject only through the verified step-4 ceremony.
```

Because the normal release workflow immediately migrates and promotes, build
the first images with the same pinned inputs and apply them privately before
using that workflow:

```bash
export COMMIT_SHA="$(git rev-parse HEAD)"
export SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
export PYTHON_BASE_IMAGE="REPLACE_IMAGE@sha256:REPLACE_64_HEX"
export UV_BASE_IMAGE="REPLACE_IMAGE@sha256:REPLACE_64_HEX"
export CLOUD_SQL_PROXY_IMAGE="REPLACE_IMAGE@sha256:REPLACE_64_HEX"
export POSTGRESQL_CLIENT_PACKAGE="REPLACE_PACKAGE=REPLACE_EXACT_VERSION"
tofu -chdir=infra/gcp init -reconfigure \
  -backend-config="$ODYSSEY_PRIVATE_CONFIG/staging.backend.hcl"
export AR_REPOSITORY="$(tofu -chdir=infra/gcp output -raw artifact_registry_repository)"
export API_TAG="${AR_REPOSITORY}/api:${COMMIT_SHA}"
export BACKUP_TAG="${AR_REPOSITORY}/backup:${COMMIT_SHA}"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker buildx build --platform linux/amd64 --target runtime --push \
  --provenance=mode=max --sbom=true \
  --build-arg "PYTHON_BASE_IMAGE=${PYTHON_BASE_IMAGE}" \
  --build-arg "UV_BASE_IMAGE=${UV_BASE_IMAGE}" \
  --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
  --tag "$API_TAG" backend
docker buildx build --platform linux/amd64 --target backup --push \
  --provenance=mode=max --sbom=true \
  --build-arg "PYTHON_BASE_IMAGE=${PYTHON_BASE_IMAGE}" \
  --build-arg "UV_BASE_IMAGE=${UV_BASE_IMAGE}" \
  --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" \
  --build-arg "POSTGRESQL_CLIENT_PACKAGE=${POSTGRESQL_CLIENT_PACKAGE}" \
  --tag "$BACKUP_TAG" backend

export API_DIGEST="$(gcloud artifacts docker images describe "$API_TAG" \
  --format='value(image_summary.digest)')"
export BACKUP_DIGEST="$(gcloud artifacts docker images describe "$BACKUP_TAG" \
  --format='value(image_summary.digest)')"
export API_IMAGE="${AR_REPOSITORY}/api@${API_DIGEST}"
export BACKUP_IMAGE="${AR_REPOSITORY}/backup@${BACKUP_DIGEST}"
trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed "$API_IMAGE"
trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed "$BACKUP_IMAGE"
printf 'api_image = "%s@%s"\nbackup_image = "%s@%s"\n' \
  "${AR_REPOSITORY}/api" "$API_DIGEST" \
  "${AR_REPOSITORY}/backup" "$BACKUP_DIGEST"
```

Put those digest references, the proxy digest, and full commit SHA into the
private environment `.tfvars`; set `deploy_workloads = true`, keep
`public_api_enabled = false` and `schedules_paused = true`, then plan/apply as in
step 7. Do not send traffic or execute migration until step 12 establishes
ownership.

**Expected output**

- Both image references end in `@sha256:` plus 64 lowercase hex characters.
- Scans/SBOM/provenance pass and Artifact Registry contains immutable images.
- API and three bounded jobs exist, but API has no public invoker and schedules
  remain paused.
- No startup migration runs automatically.

**Troubleshooting**

- This environment's Docker attempt stopped at a Docker Hub timeout before any
  build step. Retry only after registry reachability recovers; do not claim an
  image from a failed command.
- If a Cloud Run revision cannot resolve a secret, verify an enabled `latest`
  version by name without reading its payload.
- If a base image is not digest-pinned or the package is not exact, stop; the CI
  contract intentionally rejects mutable inputs.
- If workflow installation is denied, use the owner web interface or a token
  with workflow permission. Do not weaken repository protection.

**Evidence retained**

- Commit SHA, immutable image refs, provenance/SBOM artifacts, scan results,
  build logs, plan/apply hashes, revision/job names, and private/public IAM
  status. No registry credential or secret payload.

## 12. Run migrations and seed the owner account

**Gate: OWNER REQUIRED; OWNER SEED IS BLOCKED BY THE NATIVE SIGN IN WITH APPLE
CLIENT.** Never seed `owner_identities` with SQL.

**Action**

Cloud SQL has private IP only. From an approved owner host with private VPC
reachability, start Cloud SQL Auth Proxy v2 and connect as a privileged database
bootstrap operator. Do not temporarily enable public IP merely for convenience:

```bash
export ENVIRONMENT="staging"
export PROJECT_ID="$STAGING_PROJECT_ID"
tofu -chdir=infra/gcp init -reconfigure \
  -backend-config="$ODYSSEY_PRIVATE_CONFIG/staging.backend.hcl"
export CONNECTION_NAME="$(tofu -chdir=infra/gcp output -raw cloud_sql_connection_name)"
cloud-sql-proxy --private-ip --port=5432 "$CONNECTION_NAME"
```

In a separate private shell, derive role names from the protected output and
run the ownership script. `PGUSER`/authentication depend on the owner's approved
Cloud SQL bootstrap method and must not be committed:

```bash
export MIGRATION_USER="$(tofu -chdir=infra/gcp output -json service_accounts \
  | jq -r '.migration' | sed 's/\.gserviceaccount\.com$//')"
export API_USER="$(tofu -chdir=infra/gcp output -json service_accounts \
  | jq -r '.api' | sed 's/\.gserviceaccount\.com$//')"
export WORKER_USER="$(tofu -chdir=infra/gcp output -json service_accounts \
  | jq -r '.worker' | sed 's/\.gserviceaccount\.com$//')"
export BACKUP_USER="$(tofu -chdir=infra/gcp output -json service_accounts \
  | jq -r '.backup' | sed 's/\.gserviceaccount\.com$//')"

psql -h 127.0.0.1 -p 5432 -d odyssey \
  -v migration_user="$MIGRATION_USER" \
  --file infra/gcp/sql/bootstrap_ownership.sql
gcloud run jobs execute "odyssey-${ENVIRONMENT}-migration" \
  --project "$PROJECT_ID" --region "$REGION" --wait
psql -h 127.0.0.1 -p 5432 -d odyssey \
  -v migration_user="$MIGRATION_USER" \
  -v api_user="$API_USER" \
  -v worker_user="$WORKER_USER" \
  -v backup_user="$BACKUP_USER" \
  --file infra/gcp/sql/least_privilege_grants.sql
psql -h 127.0.0.1 -p 5432 -d odyssey \
  --no-align --tuples-only \
  --command='SELECT version_num FROM alembic_version;'
```

For this repository snapshot, stop if the result is not
`20260815_0017`. Confirm the accepted life-model table is append-only and that
the bounded worker has read-only export access after the grant script:

```bash
psql -h 127.0.0.1 -p 5432 -d odyssey --set ON_ERROR_STOP=on <<SQL
SELECT version_num = '20260815_0017' AS expected_head FROM alembic_version;
SELECT tgname FROM pg_trigger
WHERE tgrelid = 'public.life_model_versions'::regclass
  AND NOT tgisinternal;
SELECT has_table_privilege('$WORKER_USER', 'public.life_model_versions', 'SELECT')
  AS worker_can_export;
SELECT has_table_privilege('$WORKER_USER', 'public.life_model_versions', 'INSERT')
  AS worker_cannot_accept;
SQL
```

Expected values are `true`, the `life_model_versions_immutable` trigger, `true`,
and `false`. Treat an absent trigger or worker write privilege as a release
blocker. Do not seed Charter, life-stage, or season rows with SQL: the current
native editor is not implemented, and real accepted state must eventually pass
through an authenticated owner-review command.

The first owner row is created only by a successful nonce-bound
`POST /v1/auth/apple/exchange` whose verified `sub` matches the bootstrap
secret. After that enrollment and at least two encrypted recovery credentials,
set `apple_bootstrap_enabled = false` in the private environment `.tfvars`, set
the protected GitHub variable, apply the private revision, verify the service no
longer references the secret, and only then disable its enabled version:

```bash
gh variable set APPLE_BOOTSTRAP_ENABLED \
  --env "$ENVIRONMENT" --body false
# Privately change apple_bootstrap_enabled to false, then plan/apply as in step 7.
gcloud run services describe "odyssey-${ENVIRONMENT}-api" \
  --project "$PROJECT_ID" --region "$REGION" --format=json \
  | jq -e '[.spec.template.spec.containers[].env[]?
    | select(.name == "ODYSSEY_APPLE_BOOTSTRAP_SUBJECT")] | length == 0'
for version in $(gcloud secrets versions list \
  "odyssey-${ENVIRONMENT}-apple-bootstrap-subject" \
  --project "$PROJECT_ID" --filter='state=ENABLED' --format='value(name)'); do
  gcloud secrets versions disable "$version" \
    --secret "odyssey-${ENVIRONMENT}-apple-bootstrap-subject" \
    --project "$PROJECT_ID" --quiet
done
```

Never disable the version while an active or rollback revision still references
it. Keep `APPLE_BOOTSTRAP_ENABLED=false` permanently after first enrollment.

**Expected output**

- Migration job succeeds once and Alembic reports `20260815_0017`.
- Migration identity owns database/schema; API has table DML; worker can only
  read/update outbox; backup is read-only.
- A future first Apple exchange creates exactly one owner identity and one
  active device, without exposing `sub` in logs.

**Troubleshooting**

- `connection refused` usually means the operator host lacks private VPC
  routing. Establish an audited VPN/workstation/bastion path rather than adding
  public SQL access.
- Permission errors before migration mean ownership bootstrap did not run as a
  sufficiently privileged DB operator.
- A failed migration is rolled forward with a reviewed fix; do not wipe or
  downgrade production data.
- `OWNER_BOOTSTRAP_REQUIRED` means the subject secret is absent. Subject
  mismatch means stop and investigate; never update the database directly.

**Evidence retained**

- Proxy version, private route/bastion approval, migration execution ID,
  Alembic revision, grants query output, owner/device UUIDs, and recovery
  credential IDs/status. No DB password, token, refresh credential, or subject.

## 13. Configure Xcode signing

**Gate: OWNER REQUIRED. NO XCODE OR SIGNING VALIDATION HAS RUN HERE.**

**Action**

On the owner Mac, create ignored configuration files from the examples:

```bash
cd "$REPOSITORY_ROOT/apple"
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
cp Config/Development.local.example.xcconfig Config/Development.local.xcconfig
cp Config/Staging.local.example.xcconfig Config/Staging.local.xcconfig
cp Config/Production.local.example.xcconfig Config/Production.local.xcconfig
chmod 600 Config/Secrets.xcconfig Config/*.local.xcconfig
```

Replace the Team ID, bundle prefixes, real API URLs, and associated domain.
Confirm these files remain ignored:

```bash
git check-ignore -v \
  Config/Secrets.xcconfig \
  Config/Development.local.xcconfig \
  Config/Staging.local.xcconfig \
  Config/Production.local.xcconfig
```

Install exactly XcodeGen 2.44.1 and generate the project:

```bash
cd "$REPOSITORY_ROOT"
tools/apple/generate-project.sh
swift test --package-path apple
xcodebuild -workspace apple/Odyssey.xcworkspace \
  -scheme Odyssey-iOS -configuration Staging \
  -showBuildSettings \
  | rg 'DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER|CODE_SIGN_ENTITLEMENTS'
```

Use automatic signing for development/staging owner devices. Distribution
signing and App Store Connect access remain Account Holder-controlled. Archive
only after every embedded target/profile resolves:

```bash
xcodebuild -workspace apple/Odyssey.xcworkspace \
  -scheme Odyssey-iOS -configuration Staging \
  -destination 'generic/platform=iOS' \
  -archivePath "$HOME/Library/Developer/Xcode/Archives/Odyssey-Staging.xcarchive" \
  archive
```

**Expected output**

- Generator lists the workspace/schemes and Swift tests pass.
- Build settings contain the owner Team ID and staging IDs, never placeholders.
- Archive signs the iOS app plus Watch, widget, intents, and share extensions
  under the same team with the expected entitlements.

**Troubleshooting**

- XcodeGen version mismatch is intentional; use 2.44.1 rather than accepting
  unreviewed generated differences.
- Provisioning failures usually indicate a missing embedded-target identifier,
  App Group membership, or capability. Compare steps 2–3.
- If the archive still contains `example.invalid` or `com.example`, delete it,
  correct ignored config, clean DerivedData, and rebuild.

**Evidence retained**

- Xcode/Swift/XcodeGen versions, archive UUID/hash, signing certificate
  fingerprint, profile UUIDs/expiry, expanded entitlement report, build log,
  and dSYM inventory. Keep the archive/dSYM encrypted and out of Git.

## 14. Install the staging app and enroll a device

**Gate: OWNER REQUIRED AND EXTERNAL VALIDATION BLOCKED.** The iPhone source now
composes the GRDB ledger, Keychain identity, Apple enrollment, memory-only access
token, authenticated transport, durable capture, sync coordinator, local
diagnostics, and app-refresh entry. It is portable-package-tested and parse
checked only; no Xcode build, Apple credential, or physical-device behavior has
been validated.

**Action**

Register only owner-controlled device UDIDs in the staging profile or use
TestFlight internal testing once an archive is valid. For direct install:

```bash
xcrun devicectl list devices
xcrun devicectl device install app \
  --device "REPLACE_DEVICE_UDID" \
  "REPLACE_PATH_TO_STAGING_ODYSSEY_APP"
```

Before launch, confirm the environment/API URL from the signed build settings.
Do not enter real owner data. Then execute this staged flow:

1. Launch and verify the intentionally quiet `Now` state appears without a
   network requirement.
2. Open **Workshop**. Confirm the device shows no local sync credential and that
   the staging remote configuration is available.
3. Choose **Enroll this device with Apple**. Complete the owner Apple ceremony.
   The implemented flow obtains a backend challenge, sends SHA-256 of its raw
   nonce to Apple, validates challenge ID in Apple `state`, exchanges the raw
   nonce plus identity token, stores only the refresh credential in Keychain,
   and keeps the access token in memory.
4. Enable airplane mode. Capture a synthetic marker such as
   `STAGING OFFLINE CAPTURE <timestamp>`. Confirm the success haptic appears only
   after the local transaction and Workshop reports one queued operation.
5. Force-quit and relaunch while offline. Confirm the local ledger opens, the
   queue remains, and the Keychain credential is reported as stored.
6. Restore networking and choose **Sync Now**. Confirm the queue reaches zero,
   push/pull timestamps appear, and device/server cursors advance.
7. Run **Verify local integrity**, then **Rebuild projections from ledger** and
   verify both complete without changing the immutable ledger or losing the
   synthetic capture.
8. Background the app and retain the app-refresh scheduling/debug evidence. Do
   not claim timing guarantees; the OS may defer or cancel the task.

Follow `docs/architecture/authentication.md` for the matching backend and token
invariants. Local credential removal in Workshop is not server revocation; use
the backend owner runbook until a device-registry UI is implemented.

**Expected output**

- Required evidence: signed app installs without entitlement crash; one active
  server enrollment exists; the local credential survives force-quit/relaunch;
  offline capture commits and remains queued; authenticated push/pull clears the
  queue; cursors advance; integrity/rebuild succeed; app refresh is observed as
  opportunistic rather than exact.
- Still-unavailable evidence: uninstall/reinstall recovery, second-device
  convergence, server revocation from native UI, attachment transfer, and all
  HealthKit/Watch/widget/background production behaviors.

**Troubleshooting**

- Installation errors require checking device trust, profile inclusion, bundle
  IDs, and embedded profiles.
- A launch-only result is not enrollment, capture, sync, or background evidence.
- If local capture fails when the staging API is unreachable, stop: the
  local-first contract has regressed.
- If Workshop reports a placeholder host, fix the ignored staging xcconfig;
  never weaken HTTPS validation outside development loopback.
- Do not substitute a simulator for HealthKit, background, APNs, Watch, or
  physical-device behavior.

**Evidence retained**

- Device model/OS and hashed UDID reference, build/archive hash, install result,
  launch log, entitlement check, future device UUID/status, and refresh test
  status. No health data, token, Keychain item, or screenshot with private data.

## 15. Run integration smoke tests

**Gate: BACKEND HEALTH IS AUTOMATABLE; END-TO-END DEVICE SMOKE IS BLOCKED.**

**Action**

After step 12 and before public traffic, test the private/tagged staging URL
from an approved caller:

```bash
export API_URL="REPLACE_STAGING_CLOUD_RUN_URL"
export CLOUD_RUN_IDENTITY_TOKEN="$(gcloud auth print-identity-token)"
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${CLOUD_RUN_IDENTITY_TOKEN}" \
  -D "$ODYSSEY_PRIVATE_CONFIG/staging-live.headers" \
  "$API_URL/health/live" | jq -e '.status == "ok"'
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${CLOUD_RUN_IDENTITY_TOKEN}" \
  -D "$ODYSSEY_PRIVATE_CONFIG/staging-ready.headers" \
  "$API_URL/health/ready" | jq -e '.status == "ready" and .database == "reachable"'
unset CLOUD_RUN_IDENTITY_TOKEN
gcloud run jobs execute "odyssey-staging-worker" \
  --project "$STAGING_PROJECT_ID" --region "$REGION" --wait
```

When client enrollment exists, first run the implemented staging slice: Apple
challenge/exchange, refresh after relaunch, local offline capture, idempotent
push replay, resumable pull, local integrity/rebuild, app-refresh cancellation,
and payload-safe log inspection. The later complete matrix must additionally
cover pull on a second device, conflict resolution UX, attachment upload/hash,
server revocation UI, permission denial, Watch offline quick action, widget
freshness, and measured background reconciliation; those later surfaces remain
blocked until their implementations land.

**Expected output**

- Health responses are `200`; ready proves database reachability.
- Response headers contain correlation/trace/span IDs and logs contain no
  payloads.
- Worker job succeeds with bounded work.
- Required future result: two physical devices converge after offline capture.

**Troubleshooting**

- Live succeeds but ready fails: inspect Cloud SQL proxy startup, IAM DB login,
  private network, grants, and migration revision.
- `403` on a private health route means the current Google principal lacks the
  narrow Cloud Run Invoker permission; grant it only to the approved smoke-test
  principal and remove it after the test.
- `401` on protected routes is expected until a real owner device enrolls; do
  not switch production to development auth.
- A smoke suite without physical device and sync evidence cannot unblock
  production.

**Evidence retained**

- Status codes, redacted headers, trace/correlation IDs, revision/job execution,
  schema revision, device convergence hashes, permission matrix, and payload
  safety review. Retain no response payload containing owner history.

## 16. Enable production backup and alerts

**Gate: OWNER REQUIRED; REAL EXECUTION HAS NOT OCCURRED.** Do this only after
production ownership, migrations, grants, and private smoke pass.

**Action**

Apply production with digest-pinned workloads, then change the private values
to `schedules_paused = false` only after the first manual jobs pass. Keep
`proactive_enabled = false`. Execute and inspect the first backup:

```bash
export ENVIRONMENT="production"
export PROJECT_ID="$PRODUCTION_PROJECT_ID"
gcloud run jobs execute "odyssey-${ENVIRONMENT}-backup" \
  --project "$PROJECT_ID" --region "$REGION" --wait
gcloud logging read \
  'resource.type="cloud_run_job" AND resource.labels.job_name="odyssey-production-backup" AND jsonPayload.event="cloud_backup_completed"' \
  --project "$PROJECT_ID" --freshness=1h --limit=5 \
  --format=json > "$ODYSSEY_PRIVATE_CONFIG/production-backup-log.json"
gcloud sql instances describe "odyssey-production-postgres" \
  --project "$PROJECT_ID" --format=json \
  > "$ODYSSEY_PRIVATE_CONFIG/production-sql.json"
gcloud alpha monitoring policies list --project "$PROJECT_ID" \
  --format='table(displayName,enabled,name)'
```

Verify the SQL output shows automated backup enabled, PITR enabled, seven-day
transaction logs, 35 retained backups, regional HA, and deletion protection.
Verify database/object archive buckets are versioned, private, CMEK protected,
and have expected retention/lifecycle rules. Use the Monitoring console's
channel test and confirm delivery outside Odyssey. Verify budget threshold
delivery separately.

**Expected output**

- Backup job finishes successfully and emits one payload-free
  `cloud_backup_completed` event with manifest/report hashes.
- Daily/monthly/annual objects appear according to the current UTC date.
- Backup-stale, worker-error, API-error, and restore-failure policies are
  enabled and target the external channel.
- Scheduler jobs are enabled only after the manual pass.

**Troubleshooting**

- Backup dump failure: inspect backup image PostgreSQL client version, proxy,
  IAM grants, and catalog verification; do not mark a partial object as valid.
- Bucket metadata mismatch: stop and fix IaC/KMS/IAM rather than bypassing
  validation.
- Alert not delivered: keep production promotion blocked even if the policy
  exists.

**Evidence retained**

- Job execution ID, cloud manifest/report hashes and GCS generations, SQL backup
  configuration hash, bucket policy inventory, scheduler state, alert policy
  IDs, channel-test receipt, and budget-test receipt. No dump or owner payload
  in general evidence.

## 17. Perform the first export and restore drill

**Gate: OWNER REQUIRED AND LIVE PROOF IS CURRENTLY BLOCKED.** The encrypted,
signed, resumable owner-export implementation and deployment contract exist,
but no real Cloud Run export or clean-room cloud restore has run. Plaintext
local export remains unacceptable for real owner data.

**Action**

First enable the capability in staging. Confirm no export jobs are queued,
create the wrapping-key version through stdin, set the private staging
`.tfvars`, and apply the API and worker configuration together:

```bash
export ENVIRONMENT="staging"
export PROJECT_ID="$STAGING_PROJECT_ID"
openssl rand -base64 48 | gcloud secrets versions add \
  "odyssey-${ENVIRONMENT}-export-wrapping-key" \
  --project "$PROJECT_ID" --data-file=-
```

```hcl
owner_export_enabled = true
maximum_export_bytes = 536870912
```

Do not rotate this key while an `owner-export` outbox item is queued or
processing. For rotation, remove API invoker access or otherwise freeze new
authenticated export requests, let the old revision drain the queue, pause the
worker schedule, add the new secret version, and deploy API and worker together
before restoring traffic. Do not set the feature flag false before draining;
that also disables the export handler. Preserve the signing public key from
each authenticated job status; old completed artifacts use the old public key
but need only their owner passphrase for decryption.

On an encrypted owner-controlled machine, request an archive without placing
the token or passphrase in command arguments. Store the response and artifact
outside the repository:

```bash
umask 077
export API_BASE="https://REPLACE_STAGING_API"
export PRIVATE_EXPORT_DIR="/private/encrypted-volume/odyssey-export-drill"
mkdir -p "$PRIVATE_EXPORT_DIR"
read -r -s OWNER_ACCESS_TOKEN
printf '\n'
read -r -s OWNER_EXPORT_PASSPHRASE
printf '\n'
export JOB_RESPONSE="$PRIVATE_EXPORT_DIR/job.json"

{
  printf 'url = "%s/v1/exports"\n' "$API_BASE"
  printf 'request = "POST"\n'
  printf 'header = "Authorization: Bearer %s"\n' "$OWNER_ACCESS_TOKEN"
  printf 'header = "Idempotency-Key: first-owner-export-%s"\n' \
    "$(date -u +%Y%m%dT%H%M%SZ)"
  printf 'header = "Content-Type: application/json"\n'
  printf 'header = "X-Odyssey-Export-Passphrase: %s"\n' \
    "$OWNER_EXPORT_PASSPHRASE"
  printf 'data = "{\\"scope\\":\\"all_odyssey_owned_data\\",'
  printf '\\"formats\\":[\\"jsonl\\",\\"csv\\",\\"markdown\\"],'
  printf '\\"include_raw_sources\\":true,'
  printf '\\"include_model_traces\\":false,'
  printf '\\"encryption\\":{\\"mode\\":\\"owner_passphrase\\"}}"\n'
} | curl --fail-with-body --silent --show-error --config - \
  --output "$JOB_RESPONSE"

export STATUS_PATH="$(jq -r '.status_url' "$JOB_RESPONSE")"
```

Poll the authenticated status until it is `completed`; stop on `failed` and
retain only the error code. Then prove byte-range resume by downloading the
first 1,024 bytes and continuing the same file:

```bash
{
  printf 'header = "Authorization: Bearer %s"\n' "$OWNER_ACCESS_TOKEN"
} | curl --fail-with-body --silent --show-error --config - \
  "$API_BASE$STATUS_PATH" --output "$PRIVATE_EXPORT_DIR/status.json"
jq -e '.status == "completed" and .artifact_sha256 and .signing_public_key' \
  "$PRIVATE_EXPORT_DIR/status.json"

export DOWNLOAD_PATH="$(jq -r '.download_url' "$PRIVATE_EXPORT_DIR/status.json")"
export ARTIFACT="$PRIVATE_EXPORT_DIR/owner-export.odyx"
{
  printf 'header = "Authorization: Bearer %s"\n' "$OWNER_ACCESS_TOKEN"
  printf 'header = "Range: bytes=0-1023"\n'
} | curl --fail-with-body --silent --show-error --config - \
  "$API_BASE$DOWNLOAD_PATH" --output "$ARTIFACT"
{
  printf 'header = "Authorization: Bearer %s"\n' "$OWNER_ACCESS_TOKEN"
} | curl --fail-with-body --silent --show-error --config - \
  --continue-at - "$API_BASE$DOWNLOAD_PATH" --output "$ARTIFACT"

test "$(sha256sum "$ARTIFACT" | cut -d' ' -f1)" = \
  "$(jq -r '.artifact_sha256' "$PRIVATE_EXPORT_DIR/status.json")"
```

Verify and extract with the authenticated status key. The tool prompts for the
same passphrase; do not add it to the command line:

```bash
cd "$REPOSITORY_ROOT/backend"
uv run python ../tools/export/decrypt_owner_export.py \
  "$ARTIFACT" \
  --expected-signing-public-key \
    "$(jq -r '.signing_public_key' "$PRIVATE_EXPORT_DIR/status.json")" \
  --output-dir "$PRIVATE_EXPORT_DIR/verified"
unset OWNER_EXPORT_PASSPHRASE OWNER_ACCESS_TOKEN
```

Inspect the manifest, open representative Markdown/CSV/JSONL data, check one
raw attachment hash, and confirm no credential or recovery tables exist. Keep
the decrypted directory only for the drill window, on encrypted storage.

Then perform the independent service-disaster restore. This validates cloud
backup recovery, not owner-passphrase decryption:

Follow every section of `docs/runbooks/clean-room-recovery.md` in a dedicated,
expiring restore project. Select immutable GCS generations, materialize the
verified database bundle and object envelope, then restore objects directly
GCS-to-GCS so the archive is not staged on the operator machine:

```bash
cd "$REPOSITORY_ROOT/backend"
uv run python ../tools/backup/materialize_cloud_backup.py \
  --cloud-manifest "$CLOUD_MANIFEST" \
  --database-dump "$DATABASE_DUMP" \
  --destination "$BACKUP_DIR" \
  --archived-object-manifest "$ARCHIVED_OBJECT_MANIFEST" \
  --object-manifest-destination "$OBJECT_MANIFEST" \
  --allow-plaintext-isolated-restore

uv run python ../tools/restore/clean_room_restore.py \
  --backup "$BACKUP_DIR" \
  --database-url "$EMPTY_RESTORE_DATABASE_URL" \
  --object-manifest "$OBJECT_MANIFEST" \
  --object-archive-backend gcs \
  --object-archive-project "$PRODUCTION_PROJECT_ID" \
  --object-archive-bucket "$OBJECT_ARCHIVE_BUCKET" \
  --object-archive-kms-key "$OBJECT_ARCHIVE_KMS_KEY" \
  --object-restore-backend gcs \
  --object-restore-project "$RESTORE_PROJECT_ID" \
  --object-restore-bucket "$EMPTY_RESTORE_OBJECT_BUCKET" \
  --object-restore-kms-key "$RESTORE_OBJECT_KMS_KEY" \
  --report "$RESTORE_REPORT_PATH"
```

Apply current migrations, run integrity checks, enroll a fresh physical client,
reconcile a surviving unsynced operation fixture, measure RPO/RTO, rotate
temporary secrets, and destroy the isolated project. Do not substitute the
legacy plaintext development JSONL exporter for the encrypted API artifact.

**Expected output**

- Restore report says database and object restore passed, exact manifest hash
  and object count match, integrity is healthy, and current migration head is
  applied.
- Export creation returns `202`, status reaches `completed`, a resumed download
  matches `artifact_sha256`, and owner verification reports a valid pinned
  signature plus every file hash.
- The decrypted manifest records schema revision, exclusions, redactions,
  formats, raw attachment hashes, and no operational credential material.
- Fresh-device history, cursors, and projection checksums match.
- Cloud RPO is under 15 minutes and RTO under four hours, or the release remains
  blocked with measured remediation.
- Restore infrastructure is destroyed and billing confirms removal.

**Troubleshooting**

- Any hash, catalog, object-count, schema, projection, or cursor mismatch is a
  failed drill. Preserve evidence and stop promotion.
- Missing PostgreSQL clients or private networking must be fixed in the
  isolated environment, not worked around by skipping verification.
- `EXPORT_SIZE_LIMIT_EXCEEDED` requires a reviewed limit/memory change or a
  narrower future export scope; never bypass the limit with a plaintext dump.
- Signature, pinned-key, manifest, range-resume, or attachment-hash mismatch is
  a failed drill. Quarantine the encrypted artifact and stop promotion.
- Never place a plaintext real export in `/tmp`, Git, CI, or an unmanaged
  machine.

**Evidence retained**

- Export job ID, encrypted artifact/manifest hashes, pinned public key,
  verification report, range response headers, selected backup generations,
  source commit, restore/integrity report hashes, RPO/RTO, fresh-device
  convergence evidence, secret-version IDs, destruction receipt, billing
  check, and owner approval/rejection. Retain no passphrase, access token,
  wrapping-key value, or decrypted owner payload in general evidence. Keep
  decrypted artifacts only for the minimum drill window on encrypted storage.

## 18. Promote the production build

**Gate: OWNER REQUIRED AND CURRENTLY BLOCKED.** Do not promote while any prior
blocked gate remains, especially native enrollment, local durability, two-device
sync, physical-device checks, external alerts, encrypted export, or real
clean-room restore.

**Action**

Confirm the release commit is on protected `main`, all required checks pass,
production environment approval is configured, secret versions exist, and the
rollback revision is retained. Dispatch the owner-installed workflow:

```bash
cd "$REPOSITORY_ROOT"
git status --short
git rev-parse HEAD
gh workflow run deploy.yml \
  --ref main \
  -f target_environment=production
gh run watch --exit-status
```

The workflow verifies, builds reproducibly, attaches provenance/SBOM, scans,
creates a pre-migration backup, runs the explicit migration job, deploys a
tagged canary, checks readiness, sends 5% production traffic for five minutes,
checks errors, and promotes or returns traffic to the prior revision.

For Apple distribution, the Account Holder must first record whether Odyssey
uses private/custom distribution, unlisted distribution, or App Store release.
Upload the exact reviewed archive through Xcode Organizer or Transporter, retain
dSYMs, use an owner-only TestFlight internal cohort, and do not submit production
until device/restore gates pass.

**Expected output**

- GitHub summary records environment, Cloud Run revision, and immutable API
  image.
- Cloud Run shows 100% traffic on the approved revision after a clean canary;
  failure returns 100% to the recorded prior revision.
- TestFlight shows the matching build only after an actual upload, processing,
  export-compliance answers, and owner approval.

**Troubleshooting**

- No prior revision on a first release removes automated traffic rollback; keep
  the service private until smoke and restore gates are complete.
- Canary errors trigger rollback. Diagnose from payload-safe logs and use a
  forward schema fix; never routine-restore the database to roll back code.
- Apple processing/signing failures require fixing identifiers, entitlements,
  privacy declarations, or agreements; do not upload a differently configured
  ad-hoc build.
- If any claim depends on an unavailable device/cloud action, leave the release
  blocked rather than checking the box manually.

**Evidence retained**

- Owner approval, workflow/run IDs, release artifact/SBOM/provenance hashes,
  migration and backup execution IDs, canary URL/revision/error query, final
  traffic split, rollback revision, Apple archive/build/TestFlight IDs, dSYM
  hash, and release decision. No signing key, token, provider secret, or owner
  payload.

## Completion rule

The handoff is complete only when all 18 private evidence entries exist and no
**BLOCKED** gate remains. Repository checks, plans, screenshots, or a launchable
shell cannot substitute for a live restore and physical-device proof. Until
then, keep production traffic, proactive delivery, OAuth/webhooks, model keys,
and real owner data disabled.
