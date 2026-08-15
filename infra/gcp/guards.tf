resource "terraform_data" "deployment_guard" {
  input = {
    environment      = var.environment
    deploy_workloads = var.deploy_workloads
  }

  lifecycle {
    precondition {
      condition = !var.deploy_workloads || (
        var.api_image != "" &&
        var.backup_image != "" &&
        var.cloud_sql_proxy_image != ""
      )
      error_message = "deploy_workloads requires digest-pinned API, backup, and Cloud SQL proxy images"
    }

    precondition {
      condition = var.environment != "production" || !var.deploy_workloads || (
        var.auth_mode == "sign_in_with_apple" &&
        var.apple_client_id != "" &&
        var.public_api_enabled &&
        !var.api_docs_enabled &&
        var.cloud_sql_availability_type == "REGIONAL" &&
        var.cloud_sql_deletion_protection &&
        length(var.monitoring_notification_channel_ids) > 0 &&
        var.billing_account_id != "" &&
        var.enable_github_workload_identity
      )
      error_message = "production workloads require owner auth, public invocation, protected HA SQL, external alerts, a budget, and WIF"
    }

    precondition {
      condition = !var.enable_github_workload_identity || (
        var.github_repository != "" &&
        var.github_repository_id != "" &&
        var.github_repository_owner_id != ""
      )
      error_message = "GitHub WIF requires repository name plus immutable repository and owner IDs"
    }
  }
}
