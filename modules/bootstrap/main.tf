# bootstrap: everything the cluster root needs before it can exist.
#   - a dedicated compartment (blast-radius + clean teardown)
#   - the versioned, private state bucket (seeded by `make seed`, adopted here)
#   - quotas, budget, egress alarms, least-privilege CI and state identities
#
# Break-glass: consumers run this root locally, never from CI.

data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.tenancy_ocid
}

locals {
  home_region = one([for r in data.oci_identity_region_subscriptions.this.region_subscriptions : r.region_name if r.is_home_region])
}

resource "oci_identity_compartment" "this" {
  compartment_id = var.tenancy_ocid
  name           = var.project
  description    = "OKE Always Free cluster (${var.project}), managed by OpenTofu"
  enable_delete  = true
  freeform_tags  = local.common_tags

  lifecycle {
    # Always Free compute only exists in the home region. Fail here, with a
    # clear message, instead of a capacity error two stacks later.
    precondition {
      condition     = var.region == local.home_region
      error_message = "region = \"${var.region}\" is not this tenancy's home region (\"${local.home_region}\"). Always Free compute only exists in the home region."
    }
  }
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

check "namespace_matches" {
  assert {
    condition     = data.oci_objectstorage_namespace.this.namespace == var.state_namespace
    error_message = "state_namespace (${var.state_namespace}) does not match the tenancy namespace (${data.oci_objectstorage_namespace.this.namespace})."
  }
}

# The bucket is created by the consumer's `make seed` (oci CLI) so the s3
# backend exists before the first init; the consumer root's `import` block
# adopts it (import blocks are root-only), and compartment_id moves it here.
resource "oci_objectstorage_bucket" "state" {
  compartment_id = oci_identity_compartment.this.id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = var.state_bucket
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"
  freeform_tags  = local.common_tags

  lifecycle {
    prevent_destroy = true
  }
}

# Object Storage needs explicit permission to run lifecycle rules.
resource "oci_identity_policy" "objectstorage_lifecycle" {
  compartment_id = var.tenancy_ocid
  name           = "${var.project}-objectstorage-lifecycle"
  description    = "Allow Object Storage to expire old state versions in ${var.project}"
  statements = [
    "Allow service objectstorage-${var.region} to manage object-family in compartment id ${oci_identity_compartment.this.id}",
  ]
  freeform_tags = local.common_tags
}

resource "oci_objectstorage_object_lifecycle_policy" "state" {
  namespace = data.oci_objectstorage_namespace.this.namespace
  bucket    = oci_objectstorage_bucket.state.name

  rules {
    name        = "expire-previous-state-versions"
    action      = "DELETE"
    target      = "previous-object-versions"
    is_enabled  = true
    time_amount = local.s.state_version_retention_days
    time_unit   = "DAYS"
  }

  depends_on = [oci_identity_policy.objectstorage_lifecycle]
}

# ---------------------------------------------------------------------------
# Cost guardrail. Always Free limits are tenancy-wide, so the budget targets
# the root compartment, not just ours. Budgets themselves are free.
# ---------------------------------------------------------------------------
resource "oci_budget_budget" "free_tier_guard" {
  compartment_id = var.tenancy_ocid
  display_name   = "${var.project}-free-tier-guard"
  description    = "Alerts on ANY spend. This tenancy should cost nothing."
  amount         = local.s.budget_amount
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]
  freeform_tags  = local.common_tags
}

resource "oci_budget_alert_rule" "actual_spend" {
  budget_id      = oci_budget_budget.free_tier_guard.id
  display_name   = "any-actual-spend"
  type           = "ACTUAL"
  threshold      = 1
  threshold_type = "PERCENTAGE"
  recipients     = join(",", local.s.budget_alert_emails)
  message        = "OCI tenancy has started incurring cost. Something is outside the Always Free allowance."
}

resource "oci_budget_alert_rule" "forecast_spend" {
  budget_id      = oci_budget_budget.free_tier_guard.id
  display_name   = "forecast-over-budget"
  type           = "FORECAST"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = join(",", local.s.budget_alert_emails)
  message        = "OCI forecasts spend above the free-tier guard budget this month."
}

# ---------------------------------------------------------------------------
# Hard limit, enforced by OCI itself. Matters most after a PAYG upgrade, when
# service limits rise and nothing else would stop an oversized node pool,
# a surge node or a stray VM. A1 and block-storage quotas are AD-scoped, so
# they're zeroed everywhere and granted only in the chosen AD (within one
# quota policy, a later statement overrides an earlier one).
# ---------------------------------------------------------------------------
data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

locals {
  a1_ad = data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name
}

resource "oci_limits_quota" "free_tier" {
  count          = local.s.enable_quotas ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${replace(var.project, "-", "")}FreeTierGuard"
  description    = "Caps A1 compute and block storage at the Always Free allowance"
  freeform_tags  = local.common_tags

  statements = [
    "zero compute-core quota standard-a1-core-count in tenancy",
    "set compute-core quota standard-a1-core-count to ${var.free_tier_limits.a1_ocpus} in tenancy where request.ad = '${local.a1_ad}'",
    "zero compute-memory quota standard-a1-memory-count in tenancy",
    "set compute-memory quota standard-a1-memory-count to ${var.free_tier_limits.a1_memory_gbs} in tenancy where request.ad = '${local.a1_ad}'",
    "zero block-storage quota total-storage-gb in tenancy",
    "set block-storage quota total-storage-gb to ${var.free_tier_limits.block_storage_gbs} in tenancy where request.ad = '${local.a1_ad}'",
  ]

  lifecycle {
    precondition {
      condition     = var.availability_domain_index < length(data.oci_identity_availability_domains.this.availability_domains)
      error_message = "availability_domain_index is out of range for this region."
    }
  }
}

# ---------------------------------------------------------------------------
# Egress early warning. Quotas can't cap traffic and budget alerts lag by
# hours, so watch bytes leaving every VNIC in the project compartment and
# email within minutes. Monitoring + Notifications sit inside the free tier.
#
# VnicToNetworkBytes counts ALL bytes a VNIC sends, including node-to-node
# (flannel) and node-to-LB traffic, so it over-estimates internet egress.
# That's the safe direction for an alarm.
# ---------------------------------------------------------------------------
resource "oci_ons_notification_topic" "alerts" {
  compartment_id = oci_identity_compartment.this.id
  name           = "${var.project}-alerts"
  description    = "Cost and traffic alarms for ${var.project}"
  freeform_tags  = local.common_tags

  lifecycle {
    precondition {
      condition     = length(local.s.budget_alert_emails) > 0 && alltrue([for e in local.s.budget_alert_emails : can(regex("^[^@\\s]+@[^@\\s]+$", e))])
      error_message = "bootstrap.budget_alert_emails must contain at least one valid email address."
    }
  }
}

# Each address gets a confirmation email from OCI; click it or nothing arrives.
resource "oci_ons_subscription" "email" {
  for_each       = toset(local.s.budget_alert_emails)
  compartment_id = oci_identity_compartment.this.id
  topic_id       = oci_ons_notification_topic.alerts.id
  protocol       = "EMAIL"
  endpoint       = each.value
  freeform_tags  = local.common_tags
}

locals {
  gib = 1024 * 1024 * 1024
  egress_alarms = {
    warning  = { gb = local.s.egress_alarm_gb_per_hour.warning, severity = "WARNING" }
    critical = { gb = local.s.egress_alarm_gb_per_hour.critical, severity = "CRITICAL" }
  }
}

resource "oci_monitoring_alarm" "egress" {
  for_each = local.egress_alarms

  compartment_id        = oci_identity_compartment.this.id
  metric_compartment_id = oci_identity_compartment.this.id
  display_name          = "${var.project}-egress-${each.key}"
  namespace             = "oci_vcn"
  query                 = "VnicToNetworkBytes[1h].grouping().sum() > ${each.value.gb * local.gib}"
  severity              = each.value.severity
  pending_duration      = "PT5M"
  resolution            = "1m"
  is_enabled            = true
  destinations          = [oci_ons_notification_topic.alerts.id]

  # Re-notify while still firing, so a weekend spike isn't a single email.
  repeat_notification_duration = "PT2H"
  message_format               = "ONS_OPTIMIZED"

  alarm_summary = "${var.project}: VNIC egress above ${each.value.gb} GB in the last hour"
  body          = <<-EOT
    Traffic leaving ${var.project} VNICs exceeded ${each.value.gb} GB over a rolling hour.
    The first 10 TB/month of internet egress is free; at this rate you'd pass it in
    about ${floor(10240 / each.value.gb / 24)} days. Check `kubectl top`, LB access logs,
    and anything public that could be hotlinked or abused.
  EOT

  freeform_tags = local.common_tags

  lifecycle {
    precondition {
      condition     = local.s.egress_alarm_gb_per_hour.warning > 0 && local.s.egress_alarm_gb_per_hour.critical > local.s.egress_alarm_gb_per_hour.warning
      error_message = "bootstrap.egress_alarm_gb_per_hour: thresholds must be positive and critical must exceed warning."
    }
  }
}

# ---------------------------------------------------------------------------
# Least-privilege state access. The S3-compat credentials (a Customer Secret
# Key) carry every permission of the user that owns them, so they must not
# belong to your admin user. Members of this group can read/write objects in
# the state bucket and nothing else.
#
# Create the user by hand (Identity -> Users), add it to this group, and
# generate its Customer Secret Key there: tofu creating the key would put the
# secret in state.
# ---------------------------------------------------------------------------
resource "oci_identity_group" "state_access" {
  compartment_id = var.tenancy_ocid
  name           = "${var.project}-tofu-state"
  description    = "Read/write OpenTofu state objects in ${var.state_bucket} only"
  freeform_tags  = local.common_tags
}

resource "oci_identity_policy" "state_access" {
  compartment_id = var.tenancy_ocid
  name           = "${var.project}-tofu-state"
  description    = "Scope the tofu-state group to the state bucket"
  statements = [
    "Allow group ${oci_identity_group.state_access.name} to read buckets in compartment id ${oci_identity_compartment.this.id} where target.bucket.name = '${var.state_bucket}'",
    "Allow group ${oci_identity_group.state_access.name} to manage objects in compartment id ${oci_identity_compartment.this.id} where target.bucket.name = '${var.state_bucket}'",
  ]
  freeform_tags = local.common_tags
}

# ---------------------------------------------------------------------------
# CI identities. Two groups so a pull request can never change infrastructure:
#   ci-plan  : read-only. Its API key lives in repo secrets (PR + drift plans).
#   ci-apply : manage, but only inside the project compartment. Its key lives
#              only in the GitHub "production" environment.
# Neither can touch tenancy-level resources (IAM, quotas, budgets): those stay
# with this stack, which only you run. Users and API keys are created by hand
# (README -> CI setup) so no private key ever enters state.
#
# Plan needs tenancy-wide read because some data sources (availability
# domains, region subscriptions, node pool options) are tenancy-scoped.
# ---------------------------------------------------------------------------
resource "oci_identity_group" "ci" {
  for_each       = toset(["plan", "apply"])
  compartment_id = var.tenancy_ocid
  name           = "${var.project}-ci-${each.key}"
  description    = "GitHub Actions ${each.key} identity for ${var.project}"
  freeform_tags  = local.common_tags
}

resource "oci_identity_policy" "ci" {
  compartment_id = var.tenancy_ocid
  name           = "${var.project}-ci"
  description    = "CI plan (read) and apply (manage in compartment) for ${var.project}"
  statements = [
    "Allow group ${oci_identity_group.ci["plan"].name} to read all-resources in tenancy",
    "Allow group ${oci_identity_group.ci["apply"].name} to read all-resources in tenancy",
    "Allow group ${oci_identity_group.ci["apply"].name} to manage all-resources in compartment id ${oci_identity_compartment.this.id}",
  ]
  freeform_tags = local.common_tags
}
