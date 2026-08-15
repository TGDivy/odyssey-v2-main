resource "google_cloud_run_v2_service" "api" {
  count = local.workload_count

  name                = "${local.name}-api"
  location            = var.region
  description         = "Odyssey ${var.environment} owner API"
  labels              = local.labels
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = var.environment == "production"

  template {
    service_account                  = google_service_account.api.email
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"
    timeout                          = "300s"
    max_instance_request_concurrency = 40

    scaling {
      min_instance_count = var.api_min_instances
      max_instance_count = var.api_max_instances
    }

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"

      network_interfaces {
        network    = google_compute_network.private.id
        subnetwork = google_compute_subnetwork.run.id
      }
    }

    containers {
      name       = "api"
      image      = var.api_image
      depends_on = ["cloud-sql-proxy"]

      ports {
        name           = "http1"
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = local.api_environment
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.api_secret_environment
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.placeholder[env.value].secret_id
              version = "latest"
            }
          }
        }
      }

      startup_probe {
        initial_delay_seconds = 2
        period_seconds        = 5
        timeout_seconds       = 3
        failure_threshold     = 24

        http_get {
          path = "/health/ready"
          port = 8080
        }
      }

      liveness_probe {
        period_seconds    = 30
        timeout_seconds   = 3
        failure_threshold = 3

        http_get {
          path = "/health/live"
          port = 8080
        }
      }
    }

    containers {
      name  = "cloud-sql-proxy"
      image = var.cloud_sql_proxy_image
      args = [
        "--auto-iam-authn",
        "--private-ip",
        "--structured-logs",
        "--port=5432",
        google_sql_database_instance.primary.connection_name,
      ]

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      startup_probe {
        period_seconds    = 2
        timeout_seconds   = 1
        failure_threshold = 30

        tcp_socket {
          port = 5432
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      traffic,
    ]

    precondition {
      condition     = var.api_min_instances <= var.api_max_instances
      error_message = "api_min_instances cannot exceed api_max_instances"
    }

    precondition {
      condition     = var.auth_mode != "sign_in_with_apple" || var.apple_client_id != ""
      error_message = "apple_client_id is required when Sign in with Apple is enabled"
    }
  }

  depends_on = [
    google_project_iam_member.api_roles,
    google_secret_manager_secret_iam_member.api_access,
    google_sql_user.api,
    google_storage_bucket_iam_member.api_attachment_bucket_metadata,
    google_storage_bucket_iam_member.api_attachments,
    terraform_data.deployment_guard,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "public_api" {
  count = var.public_api_enabled ? local.workload_count : 0

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_job" "migration" {
  count = local.workload_count

  name                = "${local.name}-migration"
  location            = var.region
  labels              = local.labels
  deletion_protection = var.environment == "production"

  template {
    parallelism = 1
    task_count  = 1

    template {
      service_account       = google_service_account.migration.email
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = "1800s"
      max_retries           = 0

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"

        network_interfaces {
          network    = google_compute_network.private.id
          subnetwork = google_compute_subnetwork.run.id
        }
      }

      containers {
        name       = "migration"
        image      = var.api_image
        depends_on = ["cloud-sql-proxy"]
        command    = ["python", "-m", "odyssey.jobs.sidecar"]
        args       = ["uv", "run", "--no-sync", "alembic", "upgrade", "head"]

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }

        dynamic "env" {
          for_each = local.migration_environment
          content {
            name  = env.key
            value = env.value
          }
        }
      }

      containers {
        name  = "cloud-sql-proxy"
        image = var.cloud_sql_proxy_image
        args = [
          "--auto-iam-authn",
          "--private-ip",
          "--quitquitquit",
          "--structured-logs",
          "--port=5432",
          google_sql_database_instance.primary.connection_name,
        ]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        startup_probe {
          period_seconds    = 2
          timeout_seconds   = 1
          failure_threshold = 30

          tcp_socket {
            port = 5432
          }
        }
      }
    }
  }

  depends_on = [
    google_project_iam_member.migration_roles,
    google_sql_user.migration,
    terraform_data.deployment_guard,
  ]
}

resource "google_cloud_run_v2_job" "worker" {
  count = local.workload_count

  name                = "${local.name}-worker"
  location            = var.region
  labels              = local.labels
  deletion_protection = var.environment == "production"

  template {
    parallelism = 1
    task_count  = 1

    template {
      service_account       = google_service_account.worker.email
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = "900s"
      max_retries           = 2

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"

        network_interfaces {
          network    = google_compute_network.private.id
          subnetwork = google_compute_subnetwork.run.id
        }
      }

      containers {
        name       = "worker"
        image      = var.api_image
        depends_on = ["cloud-sql-proxy"]
        command    = ["python", "-m", "odyssey.jobs.sidecar"]
        args       = ["uv", "run", "--no-sync", "odyssey-worker-once"]

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }

        dynamic "env" {
          for_each = local.worker_environment
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = local.worker_secret_environment
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = google_secret_manager_secret.placeholder[env.value].secret_id
                version = "latest"
              }
            }
          }
        }
      }

      containers {
        name  = "cloud-sql-proxy"
        image = var.cloud_sql_proxy_image
        args = [
          "--auto-iam-authn",
          "--private-ip",
          "--quitquitquit",
          "--structured-logs",
          "--port=5432",
          google_sql_database_instance.primary.connection_name,
        ]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        startup_probe {
          period_seconds    = 2
          timeout_seconds   = 1
          failure_threshold = 30

          tcp_socket {
            port = 5432
          }
        }
      }
    }
  }

  depends_on = [
    google_project_iam_member.worker_roles,
    google_secret_manager_secret_iam_member.worker_access,
    google_sql_user.worker,
    google_storage_bucket_iam_member.worker_attachments,
    google_storage_bucket_iam_member.worker_attachment_bucket_metadata,
    terraform_data.deployment_guard,
  ]
}

resource "google_cloud_run_v2_job" "backup" {
  count = local.backup_count

  name                = "${local.name}-backup"
  location            = var.region
  labels              = local.labels
  deletion_protection = var.environment == "production"

  template {
    parallelism = 1
    task_count  = 1

    template {
      service_account       = google_service_account.backup.email
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = "3600s"
      max_retries           = 2

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"

        network_interfaces {
          network    = google_compute_network.private.id
          subnetwork = google_compute_subnetwork.run.id
        }
      }

      containers {
        name       = "backup"
        image      = var.backup_image
        depends_on = ["cloud-sql-proxy"]
        command    = ["python", "-m", "odyssey.jobs.sidecar"]
        args       = ["uv", "run", "--no-sync", "odyssey-cloud-backup"]

        resources {
          limits = {
            cpu    = "2"
            memory = "2Gi"
          }
        }

        dynamic "env" {
          for_each = local.backup_environment
          content {
            name  = env.key
            value = env.value
          }
        }
      }

      containers {
        name  = "cloud-sql-proxy"
        image = var.cloud_sql_proxy_image
        args = [
          "--auto-iam-authn",
          "--private-ip",
          "--quitquitquit",
          "--structured-logs",
          "--port=5432",
          google_sql_database_instance.primary.connection_name,
        ]

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        startup_probe {
          period_seconds    = 2
          timeout_seconds   = 1
          failure_threshold = 30

          tcp_socket {
            port = 5432
          }
        }
      }
    }
  }

  depends_on = [
    google_project_iam_member.backup_roles,
    google_sql_user.backup,
    google_storage_bucket_iam_member.backup_archive_bucket_metadata,
    google_storage_bucket_iam_member.backup_archive_writer,
    google_storage_bucket_iam_member.backup_attachment_bucket_metadata,
    google_storage_bucket_iam_member.backup_attachments_reader,
    google_storage_bucket_iam_member.backup_database_writer,
    google_storage_bucket_iam_member.backup_database_bucket_metadata,
    terraform_data.deployment_guard,
  ]
}

resource "google_cloud_run_v2_job_iam_member" "deployer_migration_invoker" {
  count = local.workload_count

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.migration[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_cloud_run_v2_job_iam_member" "deployer_worker_invoker" {
  count = local.workload_count

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.worker[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_cloud_run_v2_job_iam_member" "deployer_backup_invoker" {
  count = local.backup_count

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.backup[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.deployer.email}"
}
