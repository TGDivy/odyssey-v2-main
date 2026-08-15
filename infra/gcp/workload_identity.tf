resource "google_iam_workload_identity_pool" "github" {
  count = var.enable_github_workload_identity ? 1 : 0

  workload_identity_pool_id = "${local.name}-github"
  display_name              = "Odyssey ${var.environment} GitHub"
  description               = "Short-lived deployment identity for one immutable GitHub repository"

  depends_on = [
    google_project_service.required,
    terraform_data.deployment_guard,
  ]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count = var.enable_github_workload_identity ? 1 : 0

  workload_identity_pool_id          = google_iam_workload_identity_pool.github[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "Odyssey ${var.environment} GitHub OIDC"
  description                        = "Repository, owner, and ref-bound GitHub Actions identity"

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.actor_id"            = "assertion.actor_id"
    "attribute.ref"                 = "assertion.ref"
    "attribute.repository"          = "assertion.repository"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
  }
  attribute_condition = "assertion.repository == '${var.github_repository}' && assertion.repository_id == '${var.github_repository_id}' && assertion.repository_owner_id == '${var.github_repository_owner_id}' && assertion.ref == '${var.github_deploy_ref}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_deployer" {
  count = var.enable_github_workload_identity ? 1 : 0

  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github[0].name}/attribute.repository/${var.github_repository}"

  depends_on = [google_iam_workload_identity_pool_provider.github]
}
