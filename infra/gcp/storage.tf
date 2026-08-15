resource "google_storage_bucket" "attachments" {
  name                        = "${var.project_id}-${local.name}-attachments"
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
    retention_duration_seconds = 604800
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.objects.id
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

  depends_on = [google_kms_crypto_key_iam_member.gcs_objects]
}

resource "google_storage_bucket" "object_archive" {
  name                        = "${var.project_id}-${local.name}-object-archive"
  project                     = var.project_id
  location                    = var.archive_location
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
    retention_period = 31536000
    is_locked        = false
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.archives.id
  }

  lifecycle_rule {
    condition {
      age        = 2555
      with_state = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_archives]
}

resource "google_storage_bucket" "database_backups" {
  name                        = "${var.project_id}-${local.name}-database-backups"
  project                     = var.project_id
  location                    = var.archive_location
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

  encryption {
    default_kms_key_name = google_kms_crypto_key.archives.id
  }

  lifecycle_rule {
    condition {
      age        = 35
      with_state = "LIVE"
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age        = 400
      with_state = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_archives]
}

resource "google_storage_bucket" "exports" {
  name                        = "${var.project_id}-${local.name}-exports"
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

  encryption {
    default_kms_key_name = google_kms_crypto_key.objects.id
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_objects]
}

resource "google_storage_bucket_iam_member" "api_attachments" {
  bucket = google_storage_bucket.attachments.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.api.email}"
}

resource "google_storage_bucket_iam_member" "api_attachment_bucket_metadata" {
  bucket = google_storage_bucket.attachments.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.api.email}"
}

resource "google_storage_bucket_iam_member" "backup_attachments_reader" {
  bucket = google_storage_bucket.attachments.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_storage_bucket_iam_member" "backup_attachment_bucket_metadata" {
  bucket = google_storage_bucket.attachments.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_storage_bucket_iam_member" "backup_archive_writer" {
  bucket = google_storage_bucket.object_archive.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_storage_bucket_iam_member" "backup_archive_bucket_metadata" {
  bucket = google_storage_bucket.object_archive.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_storage_bucket_iam_member" "backup_database_writer" {
  bucket = google_storage_bucket.database_backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup.email}"
}
