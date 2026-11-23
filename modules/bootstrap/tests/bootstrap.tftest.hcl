# Offline: `tofu test` in stacks/00-bootstrap. Checks the generated quota
# statements and alarm queries, which are plain strings OCI only parses at apply.
mock_provider "oci" {
  mock_data "oci_objectstorage_namespace" {
    defaults = { namespace = "testns" }
  }
  mock_data "oci_identity_region_subscriptions" {
    defaults = {
      region_subscriptions = [
        { region_name = "uk-london-1", is_home_region = true, region_key = "LHR", state = "READY", tenancy_id = "t" },
        { region_name = "eu-frankfurt-1", is_home_region = false, region_key = "FRA", state = "READY", tenancy_id = "t" },
      ]
    }
  }

  mock_data "oci_identity_availability_domains" {
    defaults = {
      availability_domains = [
        { id = "ad1", name = "Xyz:UK-LONDON-1-AD-1", compartment_id = "c" },
        { id = "ad2", name = "Xyz:UK-LONDON-1-AD-2", compartment_id = "c" },
      ]
    }
  }
}

variables {
  tenancy_ocid    = "ocid1.tenancy.oc1..mock"
  region          = "uk-london-1"
  project         = "oke-free"
  state_namespace = "testns"
  settings = {
    budget_alert_emails = ["a@example.com", "b@example.com"]
  }
}

run "quotas_pin_allowance_to_one_ad" {
  command = plan

  assert {
    condition     = contains(oci_limits_quota.free_tier[0].statements, "set compute-core quota standard-a1-core-count to 2 in tenancy where request.ad = 'Xyz:UK-LONDON-1-AD-1'")
    error_message = "A1 core quota statement wrong."
  }

  assert {
    condition     = oci_limits_quota.free_tier[0].statements[0] == "zero compute-core quota standard-a1-core-count in tenancy"
    error_message = "Zero statement must come before the per-AD grant (later statements win)."
  }
}

run "egress_alarms" {
  command = plan

  assert {
    condition     = oci_monitoring_alarm.egress["warning"].query == "VnicToNetworkBytes[1h].grouping().sum() > 5368709120"
    error_message = "Warning alarm query should be 5 GiB over a rolling hour."
  }

  assert {
    condition     = oci_monitoring_alarm.egress["critical"].severity == "CRITICAL"
    error_message = "Critical alarm severity wrong."
  }

  assert {
    condition     = length(oci_ons_subscription.email) == 2
    error_message = "Every alert email should be subscribed to the topic."
  }
}

run "thresholds_validated" {
  command = plan

  variables {
    settings = {
      budget_alert_emails      = ["a@example.com"]
      egress_alarm_gb_per_hour = { warning = 50, critical = 5 }
    }
  }

  expect_failures = [oci_monitoring_alarm.egress["warning"], oci_monitoring_alarm.egress["critical"]]
}

run "state_access_scoped_to_bucket" {
  command = plan

  assert {
    condition     = alltrue([for st in oci_identity_policy.state_access.statements : endswith(st, "where target.bucket.name = 'tofu-state'")])
    error_message = "Every state-access statement must be scoped to the state bucket."
  }
}

run "non_home_region_rejected" {
  command = plan

  variables {
    region = "eu-frankfurt-1"
  }

  expect_failures = [oci_identity_compartment.this]
}

run "ci_apply_confined_to_compartment" {
  command = plan

  assert {
    condition     = length([for st in oci_identity_policy.ci.statements : st if strcontains(st, "to manage")]) == 1
    error_message = "Exactly one manage statement (apply group)."
  }

  assert {
    condition     = alltrue([for st in oci_identity_policy.ci.statements : !strcontains(st, "manage") || strcontains(st, "in compartment id")])
    error_message = "Manage must be compartment-scoped, never tenancy-wide."
  }

  assert {
    condition     = !anytrue([for st in oci_identity_policy.ci.statements : strcontains(st, "-ci-plan to manage") || strcontains(st, "-ci-plan to use")])
    error_message = "The plan group must be read-only."
  }
}

run "unknown_setting_rejected" {
  command = plan

  variables {
    settings = {
      budget_alert_emails = ["a@example.com"]
      enable_qoutas       = false
    }
  }

  expect_failures = [var.settings]
}

run "alert_email_required" {
  command = plan

  variables {
    settings = {}
  }

  expect_failures = [oci_ons_notification_topic.alerts]
}

run "settings_override_defaults" {
  command = plan

  variables {
    settings = {
      budget_alert_emails = ["a@example.com"]
      enable_quotas       = false
    }
  }

  assert {
    condition     = length(oci_limits_quota.free_tier) == 0
    error_message = "enable_quotas = false must drop the quota."
  }
}
