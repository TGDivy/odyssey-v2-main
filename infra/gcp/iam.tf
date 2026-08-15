resource "google_service_account" "api" {
  account_id   = "${local.name}-api"
  display_name = "Odyssey ${var.environment} API"
}

resource "google_service_account" "worker" {
  account_id   = "${local.name}-worker"
  display_name = "Odyssey ${var.environment} bounded worker"
}

resource "google_service_account" "migration" {
  account_id   = "${local.name}-migration"
  display_name = "Odyssey ${var.environment} migration job"
}

resource "google_service_account" "backup" {
  account_id   = "${local.name}-backup"
  display_name = "Odyssey ${var.environment} backup job"
}

resource "google_service_account" "scheduler" {
  account_id   = "${local.name}-scheduler"
  display_name = "Odyssey ${var.environment} scheduler invoker"
}

resource "google_service_account" "deployer" {
  account_id   = "${local.name}-deployer"
  display_name = "Odyssey ${var.environment} CI deployer"
}

resource "google_project_iam_member" "api_roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
    "roles/cloudtrace.agent",
    "roles/cloudtasks.enqueuer",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_project_service_identity" "cloud_scheduler" {
  provider = google-beta
  project  = var.project_id
  service  = "cloudscheduler.googleapis.com"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "cloud_scheduler_service_agent" {
  project = var.project_id
  role    = "roles/cloudscheduler.serviceAgent"
  member  = "serviceAccount:${google_project_service_identity.cloud_scheduler.email}"
}

resource "google_project_iam_member" "worker_roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
    "roles/cloudtrace.agent",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_project_iam_member" "migration_roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
    "roles/logging.logWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.migration.email}"
}

resource "google_project_iam_member" "backup_roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_project_iam_member" "deployer_roles" {
  for_each = toset([
    "roles/artifactregistry.admin",
    "roles/cloudkms.admin",
    "roles/cloudsql.admin",
    "roles/cloudtasks.admin",
    "roles/compute.networkAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/monitoring.editor",
    "roles/resourcemanager.projectIamAdmin",
    "roles/run.admin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/storage.admin",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}
