# Odyssey Google Cloud deployment

This directory is the production-shaped OpenTofu reference deployment. It
creates a private network, Cloud SQL PostgreSQL, versioned CMEK buckets, Secret
Manager placeholders, digest-pinned Cloud Run workloads, bounded schedules and
queues, external alerts, a billing budget, Artifact Registry, and repository-
bound GitHub workload identity federation.

No secret payload or personal identifier belongs in a committed variable file.
Secret versions are inserted after the foundation plan and remain outside
OpenTofu state.

## Prerequisites

- an owner-controlled Google Cloud organization or account with billing;
- separate staging and production projects;
- OpenTofu 1.10.6 or a compatible version satisfying `versions.tf`;
- Google Cloud CLI authenticated as the bootstrap operator;
- a private external monitoring notification channel;
- exact numeric GitHub repository and owner IDs;
- digest-pinned Python, uv, and Cloud SQL Auth Proxy images.

Run `make infra-check` before any plan. When OpenTofu is installed,
`make verify` also runs formatting, provider validation, and four mocked plans.

## 1. Bootstrap protected state

Copy `bootstrap/terraform.tfvars.example` outside the repository, replace every
marker, and keep that file private. The initial bootstrap uses local state:

```bash
tofu -chdir=infra/gcp/bootstrap init
tofu -chdir=infra/gcp/bootstrap plan -out=bootstrap.tfplan \
  -var-file=/private/path/bootstrap.tfvars
tofu -chdir=infra/gcp/bootstrap apply bootstrap.tfplan
```

Record `state_bucket`, then protect or securely remove the local bootstrap
state. Re-run bootstrap whenever an explicit state administrator is added. The
deployment service account must eventually appear in `state_admin_members` as
`serviceAccount:...` so CI can use the backend without a static key.

## 2. Provision the foundation

Copy the environment example and backend example outside the repository. Keep
`deploy_workloads = false` for the first apply:

```bash
tofu -chdir=infra/gcp init -reconfigure \
  -backend-config=/private/path/staging.backend.hcl
tofu -chdir=infra/gcp plan -out=foundation.tfplan \
  -var-file=/private/path/staging.tfvars
tofu -chdir=infra/gcp apply foundation.tfplan
```

This creates secret containers but no versions and no workload that could start
with incomplete configuration. The production guard refuses a workload plan
without HA SQL, deletion protection, WIF, budget, external alert channel,
public Cloud Run invocation, and Sign in with Apple configuration.

## 3. Insert required secret versions

Use stdin so values do not appear in shell history. Replace `ENVIRONMENT` and
`PROJECT_ID` in the shell environment first:

```bash
openssl rand -base64 48 | gcloud secrets versions add \
  "odyssey-${ENVIRONMENT}-attachment-upload-signing-key" \
  --project "${PROJECT_ID}" --data-file=-
openssl rand -base64 48 | gcloud secrets versions add \
  "odyssey-${ENVIRONMENT}-auth-access-token-signing-key" \
  --project "${PROJECT_ID}" --data-file=-
read -r -s APPLE_BOOTSTRAP_SUBJECT
printf '%s' "${APPLE_BOOTSTRAP_SUBJECT}" | gcloud secrets versions add \
  "odyssey-${ENVIRONMENT}-apple-bootstrap-subject" \
  --project "${PROJECT_ID}" --data-file=-
unset APPLE_BOOTSTRAP_SUBJECT
```

The other placeholders are reserved for integrations and telemetry. Add a
version only when the corresponding capability is enabled. Never put a secret
value in `.tfvars`, a plan, GitHub Actions variables, or command arguments.
After the first verified owner enrollment and recovery setup, set
`apple_bootstrap_enabled = false`, deploy and retain a post-bootstrap rollback
revision, then disable the one-time subject version as described in the owner
handoff.

## 4. Establish database ownership and grants

Cloud SQL IAM authentication creates login identities but not PostgreSQL object
privileges. Before the first migration, connect as a privileged bootstrap
operator through Cloud SQL Auth Proxy v2 with automatic IAM authentication and
run `sql/bootstrap_ownership.sql` with the migration username from the
`service_accounts` output, stripped of `.gserviceaccount.com`:

```bash
psql -v migration_user='replace-migration-user' \
  --file infra/gcp/sql/bootstrap_ownership.sql
```

Keep `schedules_paused = true` and the API non-public during this bootstrap
window. Enable the digest-pinned workloads, execute the migration job once,
then run the post-migration grants with all four usernames:

```bash
psql -v migration_user='replace-migration-user' \
  -v api_user='replace-api-user' \
  -v worker_user='replace-worker-user' \
  -v backup_user='replace-backup-user' \
  --file infra/gcp/sql/least_privilege_grants.sql
```

The migration identity owns the database and schema. The API receives table
DML, the bounded worker can only read and update the outbox, and backup is
read-only. Re-run the grant review when a migration introduces a new worker-
owned table; do not broaden the worker to all tables for convenience. Only
after the grant audit succeeds should `schedules_paused` become false and the
public API IAM grant be enabled.

## 5. Enable workloads

Set immutable `api_image`, `backup_image`, and `cloud_sql_proxy_image` values,
set `commit_sha`, and change `deploy_workloads` to true. Plan and inspect before
applying. The first workload apply stays private and paused until the ownership,
migration, and grant sequence above completes. A normal release then runs the backup job, migration job, tagged
canary health check, controlled traffic promotion, and automatic traffic
rollback from `ci/github-actions-deploy.yml`.

The API image field and traffic are deliberately ignored after initial service
creation so the release workflow can create no-traffic revisions and promote
them safely. OpenTofu continues to own identities, scaling, environment,
networking, jobs, schedules, storage, and alerts.

## Validation limits

Credential-free checks prove structure and provider-schema validity only. They
do not prove project quotas, billing permissions, notification delivery, Apple
configuration, IAM database grants, a successful Cloud Run revision, or a real
restore. Those checks are explicit owner-handoff gates and must retain their
provider evidence. Follow
[`docs/deployment/OWNER_HANDOFF.md`](../../docs/deployment/OWNER_HANDOFF.md) in
order; do not skip its blocked or owner-required gates.
