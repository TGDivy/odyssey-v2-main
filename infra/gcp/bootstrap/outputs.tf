output "state_bucket" {
  description = "Protected state bucket name for backend configuration."
  value       = google_storage_bucket.state.name
}

output "state_kms_key" {
  description = "Customer-managed encryption key protecting state objects."
  value       = google_kms_crypto_key.state.id
}
