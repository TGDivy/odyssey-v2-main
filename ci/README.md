# Continuous integration contract

`github-actions-verify.yml` is the environment-neutral GitHub Actions workflow
for this repository. Install it as `.github/workflows/verify.yml` using a GitHub
credential with `workflow` scope or through the GitHub web interface.

The managed development OAuth token used during initial scaffolding cannot
create workflow files, so the checked-in contract lives under `ci/` until the
owner completes that one-time installation. The workflow itself uses no Odyssey
secrets and runs `make verify`, the same command used locally.

Required branch protection for `main` after installation:

1. require pull requests for non-owner automation;
2. require the `portable` check;
3. dismiss stale approvals after code changes;
4. block force pushes and branch deletion;
5. allow the owner emergency path only under the incident runbook.

