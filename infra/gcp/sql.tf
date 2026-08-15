resource "google_sql_database_instance" "primary" {
  name                = "${local.name}-postgres"
  region              = var.region
  database_version    = "POSTGRES_17"
  encryption_key_name = google_kms_crypto_key.database.id
  deletion_protection = var.cloud_sql_deletion_protection

  settings {
    tier                        = var.cloud_sql_tier
    availability_type           = var.cloud_sql_availability_type
    disk_type                   = "PD_SSD"
    disk_size                   = 20
    disk_autoresize             = true
    deletion_protection_enabled = var.cloud_sql_deletion_protection
    pricing_plan                = "PER_USE"
    user_labels                 = local.labels

    backup_configuration {
      enabled                        = true
      start_time                     = "01:17"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 35
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.private.id
      enable_private_path_for_google_cloud_services = true
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    insights_config {
      query_insights_enabled  = true
      query_plans_per_minute  = 5
      query_string_length     = 1024
      record_application_tags = true
      record_client_address   = false
    }

    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_kms_crypto_key_iam_member.cloud_sql,
    google_service_networking_connection.private_services,
  ]
}

resource "google_sql_database" "odyssey" {
  name     = "odyssey"
  instance = google_sql_database_instance.primary.name
}

resource "google_sql_user" "api" {
  name     = trimsuffix(google_service_account.api.email, ".gserviceaccount.com")
  instance = google_sql_database_instance.primary.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_sql_user" "worker" {
  name     = trimsuffix(google_service_account.worker.email, ".gserviceaccount.com")
  instance = google_sql_database_instance.primary.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_sql_user" "migration" {
  name     = trimsuffix(google_service_account.migration.email, ".gserviceaccount.com")
  instance = google_sql_database_instance.primary.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_sql_user" "backup" {
  name     = trimsuffix(google_service_account.backup.email, ".gserviceaccount.com")
  instance = google_sql_database_instance.primary.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}
