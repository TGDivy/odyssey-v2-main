locals {
  name = "${var.resource_prefix}-${var.environment}"

  labels = {
    application = "odyssey"
    environment = var.environment
    managed_by  = "opentofu"
    data_class  = "private"
  }

  required_services = toset([
    "artifactregistry.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "cloudtasks.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])

  secret_ids = toset([
    "apple-bootstrap-subject",
    "attachment-upload-signing-key",
    "auth-access-token-signing-key",
    "database-url",
    "model-provider-api-key",
    "oauth-client-secret",
    "telemetry-otlp-headers",
    "webhook-signing-secret",
  ])

  workload_count = var.deploy_workloads && var.api_image != "" && var.cloud_sql_proxy_image != "" ? 1 : 0
  backup_count   = var.deploy_workloads && var.backup_image != "" && var.cloud_sql_proxy_image != "" ? 1 : 0

  database_users = {
    api       = trimsuffix(google_service_account.api.email, ".gserviceaccount.com")
    worker    = trimsuffix(google_service_account.worker.email, ".gserviceaccount.com")
    migration = trimsuffix(google_service_account.migration.email, ".gserviceaccount.com")
    backup    = trimsuffix(google_service_account.backup.email, ".gserviceaccount.com")
  }

  database_urls = {
    for role, username in local.database_users :
    role => "postgresql+asyncpg://${urlencode(username)}@127.0.0.1:5432/${google_sql_database.odyssey.name}"
  }

  common_runtime_environment = {
    ODYSSEY_ENV        = var.environment
    ODYSSEY_LOG_LEVEL  = "INFO"
    ODYSSEY_COMMIT_SHA = var.commit_sha
  }

  api_environment = merge(local.common_runtime_environment, {
    ODYSSEY_PROCESS_ROLE                        = "api"
    ODYSSEY_DATABASE_URL                        = local.database_urls.api
    ODYSSEY_ATTACHMENT_STORE_BACKEND            = "gcs"
    ODYSSEY_STORAGE_BUCKET                      = google_storage_bucket.attachments.name
    ODYSSEY_STORAGE_KMS_KEY_ID                  = google_kms_crypto_key.objects.id
    ODYSSEY_STORAGE_REQUIRE_VERSIONING          = "true"
    ODYSSEY_STORAGE_REQUIRE_PUBLIC_ACCESS_BLOCK = "true"
    ODYSSEY_GCP_PROJECT_ID                      = var.project_id
    ODYSSEY_AUTH_MODE                           = var.auth_mode
    ODYSSEY_APPLE_CLIENT_ID                     = var.apple_client_id
    ODYSSEY_API_DOCS_ENABLED                    = tostring(var.api_docs_enabled)
    ODYSSEY_MODEL_PROVIDER                      = var.model_provider
    ODYSSEY_PROACTIVE_ENABLED                   = tostring(var.proactive_enabled)
  })

  api_secret_environment = merge(
    {
      ODYSSEY_ATTACHMENT_UPLOAD_SIGNING_KEY = "attachment-upload-signing-key"
      ODYSSEY_AUTH_ACCESS_TOKEN_SIGNING_KEY = "auth-access-token-signing-key"
    },
    var.apple_bootstrap_enabled ? {
      ODYSSEY_APPLE_BOOTSTRAP_SUBJECT = "apple-bootstrap-subject"
    } : {},
  )

  worker_environment = merge(local.common_runtime_environment, {
    ODYSSEY_PROCESS_ROLE      = "worker"
    ODYSSEY_DATABASE_URL      = local.database_urls.worker
    ODYSSEY_WORKER_BATCH_SIZE = tostring(var.worker_batch_size)
  })

  migration_environment = merge(local.common_runtime_environment, {
    ODYSSEY_PROCESS_ROLE = "migration"
    ODYSSEY_DATABASE_URL = local.database_urls.migration
  })

  backup_environment = merge(local.common_runtime_environment, {
    ODYSSEY_PROCESS_ROLE                        = "backup"
    ODYSSEY_DATABASE_URL                        = local.database_urls.backup
    ODYSSEY_ATTACHMENT_STORE_BACKEND            = "gcs"
    ODYSSEY_STORAGE_BUCKET                      = google_storage_bucket.attachments.name
    ODYSSEY_STORAGE_KMS_KEY_ID                  = google_kms_crypto_key.objects.id
    ODYSSEY_STORAGE_REQUIRE_VERSIONING          = "true"
    ODYSSEY_STORAGE_REQUIRE_PUBLIC_ACCESS_BLOCK = "true"
    ODYSSEY_GCP_PROJECT_ID                      = var.project_id
    ODYSSEY_BACKUP_DATABASE_BUCKET              = google_storage_bucket.database_backups.name
    ODYSSEY_BACKUP_OBJECT_ARCHIVE_BUCKET        = google_storage_bucket.object_archive.name
    ODYSSEY_BACKUP_ARCHIVE_KMS_KEY              = google_kms_crypto_key.archives.id
  })
}
