resource "google_cloud_tasks_queue" "bounded" {
  name     = "${local.name}-bounded"
  location = var.region

  rate_limits {
    max_dispatches_per_second = var.task_queue_max_dispatches_per_second
    max_concurrent_dispatches = var.task_queue_max_concurrent_dispatches
  }

  retry_config {
    max_attempts       = 8
    max_retry_duration = "86400s"
    min_backoff        = "5s"
    max_backoff        = "3600s"
    max_doublings      = 8
  }

  stackdriver_logging_config {
    sampling_ratio = 1
  }

  depends_on = [google_project_service.required]
}
