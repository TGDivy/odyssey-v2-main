resource "google_billing_budget" "environment" {
  count = var.billing_account_id == "" ? 0 : 1

  billing_account = var.billing_account_id
  display_name    = "Odyssey ${var.environment} monthly budget"

  amount {
    specified_amount {
      currency_code = var.billing_currency_code
      units         = tostring(var.monthly_budget_amount)
    }
  }

  budget_filter {
    projects        = ["projects/${data.google_project.current.number}"]
    calendar_period = "MONTH"
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    disable_default_iam_recipients   = length(var.monitoring_notification_channel_ids) > 0
    enable_project_level_recipients  = true
    monitoring_notification_channels = var.monitoring_notification_channel_ids
  }

  depends_on = [google_project_service.required]
}
