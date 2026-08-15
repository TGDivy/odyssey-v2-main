variable "project_id" {
  description = "Dedicated Google Cloud project for one Odyssey environment."
  type        = string
}

variable "region" {
  description = "Primary regional data location."
  type        = string
  default     = "europe-west2"
}

variable "environment" {
  description = "Odyssey environment name."
  type        = string

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be development, staging, or production"
  }
}

variable "resource_prefix" {
  description = "Short resource name prefix."
  type        = string
  default     = "odyssey"
}

variable "api_image" {
  description = "Immutable API image reference, including an @sha256 digest."
  type        = string
  default     = ""

  validation {
    condition     = var.api_image == "" || can(regex("@sha256:[0-9a-f]{64}$", var.api_image))
    error_message = "api_image must be empty or pinned by sha256 digest"
  }
}

variable "backup_image" {
  description = "Immutable backup job image reference, including an @sha256 digest."
  type        = string
  default     = ""

  validation {
    condition     = var.backup_image == "" || can(regex("@sha256:[0-9a-f]{64}$", var.backup_image))
    error_message = "backup_image must be empty or pinned by sha256 digest"
  }
}

variable "cloud_sql_proxy_image" {
  description = "Digest-pinned official Cloud SQL Auth Proxy v2 image."
  type        = string
  default     = ""

  validation {
    condition     = var.cloud_sql_proxy_image == "" || can(regex("@sha256:[0-9a-f]{64}$", var.cloud_sql_proxy_image))
    error_message = "cloud_sql_proxy_image must be empty or pinned by sha256 digest"
  }
}

variable "commit_sha" {
  description = "Source commit represented by the deployed image."
  type        = string
  default     = "development"

  validation {
    condition     = var.commit_sha == "development" || can(regex("^[0-9a-f]{40}$", var.commit_sha))
    error_message = "commit_sha must be development or a full 40-character Git SHA"
  }
}

variable "deploy_workloads" {
  description = "Create Run workloads only after placeholder secrets have versions."
  type        = bool
  default     = false
}

variable "public_api_enabled" {
  description = "Grant public Run invocation; Odyssey owner authentication still applies."
  type        = bool
  default     = false
}

variable "auth_mode" {
  description = "Backend authentication mode for this environment."
  type        = string
  default     = "sign_in_with_apple"

  validation {
    condition     = contains(["development", "sign_in_with_apple"], var.auth_mode)
    error_message = "auth_mode must be development or sign_in_with_apple"
  }
}

variable "apple_client_id" {
  description = "Public Sign in with Apple service or bundle identifier."
  type        = string
  default     = ""
}

variable "api_docs_enabled" {
  description = "Expose interactive API documentation. Keep false in production."
  type        = bool
  default     = false
}

variable "model_provider" {
  description = "Configured model provider capability name."
  type        = string
  default     = "deterministic"
}

variable "proactive_enabled" {
  description = "Enable proactive delivery only after policy and owner approval."
  type        = bool
  default     = false
}

variable "cloud_sql_tier" {
  description = "Cloud SQL machine tier."
  type        = string
  default     = "db-custom-2-7680"
}

variable "cloud_sql_availability_type" {
  description = "REGIONAL for production HA or ZONAL for lower-cost nonproduction."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "ZONAL"], var.cloud_sql_availability_type)
    error_message = "cloud_sql_availability_type must be REGIONAL or ZONAL"
  }
}

variable "cloud_sql_deletion_protection" {
  description = "Protect the Cloud SQL instance from accidental deletion."
  type        = bool
  default     = true
}

variable "archive_location" {
  description = "Separate archive bucket location; choose another region or multi-region."
  type        = string
  default     = "EU"
}

variable "monitoring_notification_channel_ids" {
  description = "Pre-created private notification channel resource IDs."
  type        = list(string)
  default     = []
}

variable "billing_account_id" {
  description = "Billing account for budget alerts; empty skips budget creation."
  type        = string
  default     = ""
}

variable "monthly_budget_amount" {
  description = "Monthly project budget in billing-account currency."
  type        = number
  default     = 100
}

variable "github_repository" {
  description = "Exact OWNER/REPOSITORY allowed to use deployment workload identity."
  type        = string
  default     = ""
}

variable "enable_github_workload_identity" {
  description = "Provision GitHub Actions workload identity federation."
  type        = bool
  default     = false
}

variable "api_min_instances" {
  description = "Minimum API instances."
  type        = number
  default     = 0
}

variable "api_max_instances" {
  description = "Maximum API instances."
  type        = number
  default     = 3
}

variable "worker_batch_size" {
  description = "Maximum transactional outbox records processed per bounded worker run."
  type        = number
  default     = 50

  validation {
    condition     = var.worker_batch_size >= 1 && var.worker_batch_size <= 500
    error_message = "worker_batch_size must be between 1 and 500"
  }
}

variable "backup_schedule" {
  description = "UTC cron schedule for logical database and object backup."
  type        = string
  default     = "17 2 * * *"
}

variable "worker_schedule" {
  description = "UTC cron schedule for one bounded outbox worker pass."
  type        = string
  default     = "* * * * *"
}
