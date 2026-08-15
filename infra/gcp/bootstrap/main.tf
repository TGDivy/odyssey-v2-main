locals {
  labels = {
    application = "odyssey"
    managed_by  = "opentofu"
    data_class  = "operational_secret"
    purpose     = "terraform_state"
  }
}

resource "google_project_service" "required" {
  for_each = toset([
    "cloudkms.googleapis.com",
    "storage.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_kms_key_ring" "state" {
  name     = "odyssey-state"
  location = var.region

  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key" "state" {
  name            = "opentofu-state"
  key_ring        = google_kms_key_ring.state.id
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = true
  }
}

data "google_storage_project_service_account" "gcs" {
  project = var.project_id

  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key_iam_member" "gcs" {
  crypto_key_id = google_kms_crypto_key.state.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

resource "google_storage_bucket" "state" {
  name                        = var.state_bucket_name
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = local.labels

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 2592000
  }

  retention_policy {
    retention_period = 2592000
    is_locked        = false
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.state.id
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 365
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs]
}

resource "google_storage_bucket_iam_member" "state_admin" {
  for_each = var.state_admin_members

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = each.value
}

resource "google_storage_bucket_iam_member" "state_bucket_reader" {
  for_each = var.state_admin_members

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.legacyBucketReader"
  member = each.value
}
