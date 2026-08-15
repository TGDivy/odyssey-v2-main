# Continuous integration contract

`github-actions-verify.yml` is the environment-neutral verification workflow.
`github-actions-deploy.yml` is the manual, protected staging/production release
workflow. Install them as `.github/workflows/verify.yml` and
`.github/workflows/deploy.yml` using a credential with `workflow` scope or the
GitHub web interface.

The managed development OAuth token used during initial scaffolding cannot
create workflow files, so the checked-in contract lives under `ci/` until the
owner completes that one-time installation. The workflow itself uses no Odyssey
secrets and runs `make verify`, the same command used locally. Every referenced
action is pinned to a full commit SHA.

The deploy workflow uses GitHub OIDC and Google workload identity federation;
it does not use a service-account key. Create protected `staging` and
`production` GitHub environments. Require owner approval for production and
configure these environment variables:

| Variable | Purpose |
| --- | --- |
| `GCP_PROJECT_ID` | Dedicated environment project |
| `GCP_REGION` | Primary Cloud Run and Cloud SQL region |
| `GCP_ARCHIVE_LOCATION` | Archive bucket/KMS location |
| `GCP_STATE_BUCKET` | Protected backend bucket |
| `GCP_WIF_PROVIDER` | Full workload identity provider resource name |
| `GCP_DEPLOYER_SERVICE_ACCOUNT` | CI deployer service-account email |
| `GCP_MONITORING_CHANNEL_IDS_JSON` | JSON list of external channel IDs |
| `GCP_BILLING_ACCOUNT_ID` | Billing account used by the budget |
| `GCP_BILLING_CURRENCY_CODE` | Three-letter billing currency |
| `GCP_MONTHLY_BUDGET_AMOUNT` | Whole-number monthly budget |
| `APPLE_CLIENT_ID` | Environment-specific Apple client identifier |
| `REPOSITORY_NUMERIC_ID` | Immutable numeric GitHub repository ID |
| `REPOSITORY_OWNER_NUMERIC_ID` | Immutable numeric GitHub owner ID |
| `PYTHON_BASE_IMAGE` | Python base image pinned by digest |
| `UV_BASE_IMAGE` | uv image pinned by digest |
| `CLOUD_SQL_PROXY_IMAGE` | Cloud SQL Auth Proxy v2 pinned by digest |
| `POSTGRESQL_CLIENT_PACKAGE` | Exact Debian package version expression |

Do not place provider keys, Apple subjects, signing keys, OAuth secrets, or
database credentials in GitHub variables. The release only verifies that
required Secret Manager versions exist; it cannot read their payloads.

The production workflow builds provenance and SBOM attestations, scans both
images, stores release evidence, creates a verified pre-migration backup, runs
the explicit migration job, sends 5% traffic to a tagged canary, checks errors,
then promotes or returns traffic to the prior retained revision.

Required branch protection for `main` after installation:

1. require pull requests for non-owner automation;
2. require the `portable` check;
3. dismiss stale approvals after code changes;
4. block force pushes and branch deletion;
5. allow the owner emergency path only under the incident runbook.

Also require the protected `production` environment approval and forbid
deployment from any ref other than `refs/heads/main`. Artifact Registry keeps
the most recent 20 releases so the rollback revision remains pullable.
