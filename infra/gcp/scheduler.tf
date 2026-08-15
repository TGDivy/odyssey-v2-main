resource "google_cloud_run_v2_job_iam_member" "scheduler_worker_invoker" {
  count = local.workload_count

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.worker[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_backup_invoker" {
  count = local.backup_count

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.backup[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_cloud_scheduler_job" "worker" {
  count = local.workload_count

  name             = "${local.name}-worker"
  region           = var.region
  description      = "Run one bounded Odyssey outbox pass"
  schedule         = var.worker_schedule
  time_zone        = "Etc/UTC"
  attempt_deadline = "60s"

  http_target {
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.worker[0].name}:run"
    http_method = "POST"
    body        = base64encode("{}")
    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  retry_config {
    retry_count          = 3
    min_backoff_duration = "5s"
    max_backoff_duration = "60s"
    max_doublings        = 3
  }

  depends_on = [
    google_cloud_run_v2_job_iam_member.scheduler_worker_invoker,
    google_project_iam_member.cloud_scheduler_service_agent,
  ]
}

resource "google_cloud_scheduler_job" "backup" {
  count = local.backup_count

  name             = "${local.name}-backup"
  region           = var.region
  description      = "Create and verify the daily Odyssey logical and object backup"
  schedule         = var.backup_schedule
  time_zone        = "Etc/UTC"
  attempt_deadline = "60s"

  http_target {
    uri         = "https://run.googleapis.com/v2/projects/${var.project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.backup[0].name}:run"
    http_method = "POST"
    body        = base64encode("{}")
    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.scheduler.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  retry_config {
    retry_count          = 3
    min_backoff_duration = "30s"
    max_backoff_duration = "600s"
    max_doublings        = 4
  }

  depends_on = [
    google_cloud_run_v2_job_iam_member.scheduler_backup_invoker,
    google_project_iam_member.cloud_scheduler_service_agent,
  ]
}
