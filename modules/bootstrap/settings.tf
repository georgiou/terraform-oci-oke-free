# Settings with defaults. Consumers pass a plain object (`bootstrap = {...}` in
# their settings file); new keys added here reach them without changing their
# root module, and typos fail validation instead of being silently ignored.
locals {
  defaults = {
    # Addresses that receive budget and egress alerts (required; OCI emails a
    # confirmation link to each).
    budget_alert_emails = []
    # Monthly budget in the billing currency. Any spend is a bug.
    budget_amount = 1
    # Days to keep non-current state object versions.
    state_version_retention_days = 90
    # OCI quotas capping A1 and block storage at free_tier_limits.
    enable_quotas = true
    # Rolling-hour egress alarm thresholds (GB). Free 10 TB/month ~ 14 GB/hour.
    egress_alarm_gb_per_hour = { warning = 5, critical = 50 }
  }

  s = merge(local.defaults, var.settings)

  common_tags = merge({ "managed-by" = "opentofu", "project" = var.project }, var.freeform_tags)
}
