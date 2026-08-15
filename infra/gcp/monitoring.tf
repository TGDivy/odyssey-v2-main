resource "google_logging_metric" "backup_success" {
  name        = "${local.name}-backup-success"
  description = "Verified Odyssey cloud backup completions without payload fields"
  filter      = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${local.name}-backup\" AND jsonPayload.event=\"cloud_backup_completed\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "worker_error" {
  name        = "${local.name}-worker-error"
  description = "Bounded worker errors requiring operator attention"
  filter      = "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"${local.name}-worker\" AND severity>=ERROR"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "restore_verification_failure" {
  name        = "${local.name}-restore-verification-failure"
  description = "Clean-room restore verification failures without payload fields"
  filter      = "resource.type=\"cloud_run_job\" AND jsonPayload.event=\"clean_room_restore_failed\" AND jsonPayload.environment=\"${var.environment}\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "backup_stale" {
  count = local.backup_count

  display_name          = "Odyssey ${var.environment}: verified backup stale"
  combiner              = "OR"
  severity              = "CRITICAL"
  notification_channels = var.monitoring_notification_channel_ids
  user_labels           = local.labels

  conditions {
    display_name = "No verified backup for 24 hours"

    condition_absent {
      filter   = "resource.type = \"cloud_run_job\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.backup_success.name}\""
      duration = "86400s"

      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Odyssey verified backup is stale"
    content   = "Follow `docs/runbooks/clean-room-recovery.md`; do not delete or reset production data."
  }
}

resource "google_monitoring_alert_policy" "worker_error" {
  count = local.workload_count

  display_name          = "Odyssey ${var.environment}: bounded worker error"
  combiner              = "OR"
  severity              = "ERROR"
  notification_channels = var.monitoring_notification_channel_ids
  user_labels           = local.labels

  conditions {
    display_name = "Worker emitted an error"

    condition_threshold {
      filter          = "resource.type = \"cloud_run_job\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.worker_error.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Odyssey worker requires attention"
    content   = "Inspect payload-safe job logs and the transactional outbox diagnostics before retrying."
  }
}

resource "google_monitoring_alert_policy" "api_server_errors" {
  count = local.workload_count

  display_name          = "Odyssey ${var.environment}: API server errors"
  combiner              = "OR"
  severity              = "ERROR"
  notification_channels = var.monitoring_notification_channel_ids
  user_labels           = local.labels

  conditions {
    display_name = "More than five 5xx responses in five minutes"

    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.label.\"service_name\" = \"${local.name}-api\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.\"response_code_class\" = \"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Odyssey API error rate increased"
    content   = "Pause rollout traffic and follow the backend rollback procedure in the owner handoff."
  }
}

resource "google_monitoring_alert_policy" "database_disk" {
  display_name          = "Odyssey ${var.environment}: database disk pressure"
  combiner              = "OR"
  severity              = "WARNING"
  notification_channels = var.monitoring_notification_channel_ids
  user_labels           = local.labels

  conditions {
    display_name = "Cloud SQL disk utilization above 80%"

    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND resource.label.\"database_id\" = \"${var.project_id}:${google_sql_database_instance.primary.name}\" AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "600s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }

      trigger {
        count = 1
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Odyssey database disk pressure"
    content   = "Review growth and backup health; expand capacity without destructive compaction."
  }
}

resource "google_monitoring_alert_policy" "restore_verification_failure" {
  display_name          = "Odyssey ${var.environment}: restore verification failed"
  combiner              = "OR"
  severity              = "CRITICAL"
  notification_channels = var.monitoring_notification_channel_ids
  user_labels           = local.labels

  conditions {
    display_name = "A restore drill failed integrity verification"

    condition_threshold {
      filter          = "resource.type = \"cloud_run_job\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.restore_verification_failure.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "Odyssey clean-room restore failed"
    content   = "Treat the backup as unverified and follow the recovery runbook before any destructive operation."
  }
}
