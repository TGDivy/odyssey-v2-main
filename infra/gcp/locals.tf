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

  workload_count = var.deploy_workloads && var.api_image != "" ? 1 : 0
  backup_count   = var.deploy_workloads && var.backup_image != "" ? 1 : 0
}
