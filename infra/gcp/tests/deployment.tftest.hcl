mock_provider "google" {
  mock_resource "google_compute_network" {
    defaults = {
      id = "projects/odyssey-test/global/networks/odyssey-private"
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      email = "odyssey-test@odyssey-test.iam.gserviceaccount.com"
      name  = "projects/odyssey-test/serviceAccounts/odyssey-test@odyssey-test.iam.gserviceaccount.com"
    }
  }
}
mock_provider "google-beta" {}

run "foundation_without_workloads" {
  command = plan

  variables {
    project_id  = "odyssey-development-000001"
    environment = "development"
  }

  assert {
    condition     = local.workload_count == 0
    error_message = "foundation plans must not create workloads implicitly"
  }
}

run "development_workloads" {
  command = plan

  variables {
    project_id            = "odyssey-development-000001"
    environment           = "development"
    deploy_workloads      = true
    auth_mode             = "development"
    api_image             = "europe-west2-docker.pkg.dev/example/odyssey/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    backup_image          = "europe-west2-docker.pkg.dev/example/odyssey/backup@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    cloud_sql_proxy_image = "gcr.io/cloud-sql-connectors/cloud-sql-proxy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    commit_sha            = "dddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = local.workload_count == 1 && local.backup_count == 1
    error_message = "an explicit complete image set must enable all bounded workloads"
  }
}

run "production_requires_operational_controls" {
  command = plan

  variables {
    project_id            = "odyssey-production-000001"
    environment           = "production"
    deploy_workloads      = true
    api_image             = "europe-west2-docker.pkg.dev/example/odyssey/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    backup_image          = "europe-west2-docker.pkg.dev/example/odyssey/backup@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    cloud_sql_proxy_image = "gcr.io/cloud-sql-connectors/cloud-sql-proxy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    commit_sha            = "dddddddddddddddddddddddddddddddddddddddd"
    apple_client_id       = "com.example.odyssey"
  }

  expect_failures = [terraform_data.deployment_guard]
}

run "production_workloads" {
  command = plan

  variables {
    project_id                         = "odyssey-production-000001"
    environment                        = "production"
    deploy_workloads                   = true
    api_image                          = "europe-west2-docker.pkg.dev/example/odyssey/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    backup_image                       = "europe-west2-docker.pkg.dev/example/odyssey/backup@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    cloud_sql_proxy_image              = "gcr.io/cloud-sql-connectors/cloud-sql-proxy@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    commit_sha                         = "dddddddddddddddddddddddddddddddddddddddd"
    apple_client_id                    = "com.example.odyssey"
    public_api_enabled                 = true
    monitoring_notification_channel_ids = [
      "projects/odyssey-production-000001/notificationChannels/123456789",
    ]
    billing_account_id                   = "ABCDEF-123456-ABCDEF"
    enable_github_workload_identity      = true
    github_repository                    = "example/odyssey"
    github_repository_id                 = "123456789"
    github_repository_owner_id           = "987654321"
  }

  assert {
    condition     = google_cloud_run_v2_service.api[0].deletion_protection
    error_message = "production API deletion protection must remain enabled"
  }
}
