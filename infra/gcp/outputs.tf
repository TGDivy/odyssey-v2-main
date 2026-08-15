output "project_number" {
  description = "Numeric project identifier used by service identities."
  value       = data.google_project.current.number
}

output "artifact_registry_repository" {
  description = "Docker repository path without an image name."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.containers.repository_id}"
}

output "api_url" {
  description = "Cloud Run API URL, null until workloads are enabled."
  value       = try(google_cloud_run_v2_service.api[0].uri, null)
}

output "cloud_run_jobs" {
  description = "Bounded job names; null until each workload is enabled."
  value = {
    migration = try(google_cloud_run_v2_job.migration[0].name, null)
    worker    = try(google_cloud_run_v2_job.worker[0].name, null)
    backup    = try(google_cloud_run_v2_job.backup[0].name, null)
  }
}

output "cloud_sql_connection_name" {
  description = "Cloud SQL connection name used by the Auth Proxy."
  value       = google_sql_database_instance.primary.connection_name
}

output "storage_buckets" {
  description = "Private versioned data bucket names."
  value = {
    attachments      = google_storage_bucket.attachments.name
    object_archive   = google_storage_bucket.object_archive.name
    database_backups = google_storage_bucket.database_backups.name
    exports          = google_storage_bucket.exports.name
  }
}

output "service_accounts" {
  description = "Workload service account emails for grants and auditing."
  value = {
    api       = google_service_account.api.email
    worker    = google_service_account.worker.email
    migration = google_service_account.migration.email
    backup    = google_service_account.backup.email
    scheduler = google_service_account.scheduler.email
    deployer  = google_service_account.deployer.email
  }
}

output "tasks_queue" {
  description = "Bounded Cloud Tasks queue resource ID."
  value       = google_cloud_tasks_queue.bounded.id
}

output "github_workload_identity_provider" {
  description = "WIF provider name for GitHub auth, null when disabled."
  value       = try(google_iam_workload_identity_pool_provider.github[0].name, null)
}
