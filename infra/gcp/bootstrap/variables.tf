variable "project_id" {
  description = "Google Cloud project that owns protected OpenTofu state."
  type        = string
}

variable "region" {
  description = "KMS region for the state encryption key."
  type        = string
  default     = "europe-west2"
}

variable "state_bucket_name" {
  description = "Globally unique bucket name chosen by the owner."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid globally unique GCS bucket name"
  }
}

variable "state_admin_members" {
  description = "Explicit IAM members allowed to read and update state objects."
  type        = set(string)

  validation {
    condition     = length(var.state_admin_members) > 0
    error_message = "at least one owner-controlled state administrator is required"
  }
}
