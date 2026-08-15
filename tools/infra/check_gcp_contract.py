#!/usr/bin/env python3
"""Deterministically verify the credential-free GCP deployment contract."""

import re
from pathlib import Path

REQUIRED_FILES = (
    "infra/gcp/.terraform.lock.hcl",
    "infra/gcp/apis.tf",
    "infra/gcp/artifact_registry.tf",
    "infra/gcp/budget.tf",
    "infra/gcp/guards.tf",
    "infra/gcp/iam.tf",
    "infra/gcp/kms.tf",
    "infra/gcp/monitoring.tf",
    "infra/gcp/network.tf",
    "infra/gcp/outputs.tf",
    "infra/gcp/runtime.tf",
    "infra/gcp/scheduler.tf",
    "infra/gcp/secrets.tf",
    "infra/gcp/sql.tf",
    "infra/gcp/storage.tf",
    "infra/gcp/tasks.tf",
    "infra/gcp/tests/deployment.tftest.hcl",
    "infra/gcp/workload_identity.tf",
    "infra/gcp/bootstrap/.terraform.lock.hcl",
    "infra/gcp/bootstrap/main.tf",
    "infra/gcp/bootstrap/terraform.tfvars.example",
    "infra/gcp/backend.staging.hcl.example",
    "infra/gcp/backend.production.hcl.example",
    "infra/gcp/environments/staging.tfvars.example",
    "infra/gcp/environments/production.tfvars.example",
    "infra/gcp/sql/bootstrap_ownership.sql",
    "infra/gcp/sql/least_privilege_grants.sql",
    "infra/gcp/README.md",
    "ci/github-actions-deploy.yml",
)

REQUIRED_RESOURCES = {
    "google_artifact_registry_repository.containers",
    "google_billing_budget.environment",
    "google_cloud_run_v2_job.backup",
    "google_cloud_run_v2_job.migration",
    "google_cloud_run_v2_job.worker",
    "google_cloud_run_v2_service.api",
    "google_cloud_scheduler_job.backup",
    "google_cloud_scheduler_job.worker",
    "google_cloud_tasks_queue.bounded",
    "google_iam_workload_identity_pool.github",
    "google_iam_workload_identity_pool_provider.github",
    "google_kms_crypto_key.archives",
    "google_kms_crypto_key.database",
    "google_kms_crypto_key.objects",
    "google_monitoring_alert_policy.backup_stale",
    "google_monitoring_alert_policy.database_disk",
    "google_secret_manager_secret.placeholder",
    "google_sql_database_instance.primary",
    "google_storage_bucket.attachments",
    "google_storage_bucket.database_backups",
    "google_storage_bucket.object_archive",
    "terraform_data.deployment_guard",
}

REQUIRED_SNIPPETS = {
    "infra/gcp/guards.tf": (
        "digest-pinned API, backup, and Cloud SQL proxy images",
        "production workloads require owner auth",
    ),
    "infra/gcp/runtime.tf": (
        '"--auto-iam-authn"',
        '"--quitquitquit"',
        'version = "latest"',
        "deletion_protection",
    ),
    "infra/gcp/storage.tf": (
        "public_access_prevention",
        "soft_delete_policy",
        "versioning",
        "matches_prefix",
    ),
    "infra/gcp/sql.tf": (
        "point_in_time_recovery_enabled = true",
        'type     = "CLOUD_IAM_SERVICE_ACCOUNT"',
        "prevent_destroy = true",
    ),
    "infra/gcp/workload_identity.tf": (
        "assertion.repository_id",
        "assertion.repository_owner_id",
        "assertion.ref",
    ),
    "infra/gcp/bootstrap/main.tf": (
        "public_access_prevention",
        "prevent_destroy = true",
        "roles/storage.objectAdmin",
    ),
    "ci/github-actions-deploy.yml": (
        "provenance: mode=max",
        "severity: CRITICAL,HIGH",
        "Create pre-migration backup",
        "--no-traffic --tag canary",
        "${PREVIOUS_REVISION}=100",
    ),
}

RESOURCE_PATTERN = re.compile(r'resource\s+"([^"]+)"\s+"([^"]+)"')


class ContractError(RuntimeError):
    pass


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def check_files(root: Path) -> None:
    missing = [relative for relative in REQUIRED_FILES if not (root / relative).is_file()]
    if missing:
        raise ContractError(f"missing infrastructure files: {', '.join(missing)}")


def check_layout(root: Path) -> tuple[int, set[str]]:
    resources: set[str] = set()
    scoped_resources: set[str] = set()
    resource_count = 0
    for path in sorted((root / "infra/gcp").rglob("*.tf")):
        if ".terraform" in path.parts:
            continue
        content = path.read_text()
        if "\t" in content:
            raise ContractError(f"tab character in {path.relative_to(root)}")
        if any(line.rstrip() != line for line in content.splitlines()):
            raise ContractError(f"trailing whitespace in {path.relative_to(root)}")
        check_balanced_braces(path.relative_to(root), content)
        scope = "bootstrap" if "bootstrap" in path.relative_to(root / "infra/gcp").parts else "root"
        for resource_type, resource_name in RESOURCE_PATTERN.findall(content):
            resource = f"{resource_type}.{resource_name}"
            scoped_resource = f"{scope}:{resource}"
            if scoped_resource in scoped_resources:
                raise ContractError(f"duplicate resource address: {scoped_resource}")
            scoped_resources.add(scoped_resource)
            if scope == "root":
                resources.add(resource)
            resource_count += 1
    return resource_count, resources


def check_balanced_braces(path: Path, content: str) -> None:
    depth = 0
    quoted = False
    escaped = False
    line_comment = False
    block_comment = False
    index = 0
    while index < len(content):
        character = content[index]
        following = content[index + 1] if index + 1 < len(content) else ""
        if line_comment:
            if character == "\n":
                line_comment = False
            index += 1
            continue
        if block_comment:
            if character == "*" and following == "/":
                block_comment = False
                index += 2
            else:
                index += 1
            continue
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
            index += 1
            continue
        if character == '"':
            quoted = True
        elif character == "#" or (character == "/" and following == "/"):
            line_comment = True
            index += int(character == "/")
        elif character == "/" and following == "*":
            block_comment = True
            index += 1
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth < 0:
                raise ContractError(f"unbalanced closing brace in {path}")
        index += 1
    if depth != 0 or quoted or block_comment:
        raise ContractError(f"unbalanced HCL structure in {path}")


def check_contract(root: Path, resources: set[str]) -> None:
    missing_resources = sorted(REQUIRED_RESOURCES - resources)
    if missing_resources:
        raise ContractError(f"missing resources: {', '.join(missing_resources)}")
    all_configuration = "\n".join(
        path.read_text()
        for path in sorted((root / "infra/gcp").rglob("*.tf"))
        if ".terraform" not in path.parts
    )
    if "google_secret_manager_secret_version" in all_configuration:
        raise ContractError("secret payload versions must never be managed in OpenTofu state")
    if "secret_data" in all_configuration:
        raise ContractError("secret payload material must not appear in infrastructure code")
    for relative, snippets in REQUIRED_SNIPPETS.items():
        content = (root / relative).read_text()
        missing = [snippet for snippet in snippets if snippet not in content]
        if missing:
            raise ContractError(f"{relative} is missing controls: {', '.join(missing)}")


def check_examples(root: Path) -> None:
    examples = [
        root / "infra/gcp/environments/staging.tfvars.example",
        root / "infra/gcp/environments/production.tfvars.example",
        root / "infra/gcp/bootstrap/terraform.tfvars.example",
    ]
    for path in examples:
        content = path.read_text().lower()
        if "replace" not in content:
            raise ContractError(f"example lacks explicit replacement markers: {path}")
        if "tgdivy" in content or "odyssey-v2-main" in content:
            raise ContractError(f"personal repository data appears in example: {path}")


def check_action_pins(root: Path) -> None:
    for path in sorted((root / "ci").glob("*.yml")):
        for line in path.read_text().splitlines():
            match = re.search(r"\buses:\s*[^@\s]+@([^\s]+)", line)
            if match and not re.fullmatch(r"[0-9a-f]{40}", match.group(1)):
                raise ContractError(f"GitHub Action is not commit-pinned in {path.name}: {line}")


def main() -> None:
    root = repository_root()
    check_files(root)
    resource_count, resources = check_layout(root)
    check_contract(root, resources)
    check_examples(root)
    check_action_pins(root)
    print(
        "GCP infrastructure contract verified: "
        f"{resource_count} resources, {len(REQUIRED_FILES)} required artifacts"
    )


if __name__ == "__main__":
    main()
