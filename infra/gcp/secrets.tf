resource "google_secret_manager_secret" "placeholder" {
  for_each = local.secret_ids

  secret_id = "${local.name}-${each.value}"
  labels    = local.labels

  replication {
    user_managed {
      replicas {
        location = var.region

        customer_managed_encryption {
          kms_key_name = google_kms_crypto_key.objects.id
        }
      }
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.secret_manager]
}

resource "google_secret_manager_secret_iam_member" "api_access" {
  for_each = toset(concat(
    [
      "apple-bootstrap-subject",
      "attachment-upload-signing-key",
      "auth-access-token-signing-key",
      "database-url",
      "model-provider-api-key",
      "oauth-client-secret",
      "telemetry-otlp-headers",
      "webhook-signing-secret",
    ],
    var.owner_export_enabled ? ["export-wrapping-key"] : [],
  ))

  project   = var.project_id
  secret_id = google_secret_manager_secret.placeholder[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "worker_access" {
  for_each = toset(concat(
    [
      "database-url",
      "model-provider-api-key",
      "oauth-client-secret",
      "telemetry-otlp-headers",
      "webhook-signing-secret",
    ],
    var.owner_export_enabled ? ["export-wrapping-key"] : [],
  ))

  project   = var.project_id
  secret_id = google_secret_manager_secret.placeholder[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_secret_manager_secret_iam_member" "migration_database" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.placeholder["database-url"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.migration.email}"
}

resource "google_secret_manager_secret_iam_member" "backup_database" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.placeholder["database-url"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.backup.email}"
}
