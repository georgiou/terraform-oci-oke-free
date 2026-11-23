# Offline: `tofu test` in modules/cluster. Mocked provider, no credentials.
mock_provider "oci" {
  mock_data "oci_identity_compartments" {
    defaults = {
      compartments = [{
        compartment_id = "ocid1.tenancy.oc1..mock", defined_tags = {}, description = "", enable_delete = true,
        freeform_tags  = {}, id = "ocid1.compartment.oc1..project", inactive_state = "", is_accessible = true,
        name           = "oke-free", state = "ACTIVE", time_created = ""
      }]
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
  mock_data "oci_core_services" {
    defaults = {
      services = [{ id = "svc", name = "All LHR Services In Oracle Services Network", cidr_block = "all-lhr-services-in-oracle-services-network", description = "mock" }]
    }
  }
  mock_data "oci_containerengine_node_pool_option" {
    defaults = {
      sources = [
        { source_type = "IMAGE", source_name = "Oracle-Linux-8.10-aarch64-2026.10.30-0-OKE-1.36.4-950", image_id = "ocid1.image.arm" },
      ]
    }
  }
}

variables {
  tenancy_ocid = "ocid1.tenancy.oc1..mock"
  region       = "uk-london-1"
  project      = "oke-free"
}

run "allowlist_mode" {
  command = plan

  variables {
    settings = { api_allowed_cidrs = ["203.0.113.7/32"] }
  }

  assert {
    condition     = module.oke.free_tier_usage.a1_ocpus == "2/2"
    error_message = "Defaults should use exactly the A1 allowance."
  }

  assert {
    condition     = output.subnet_ids.lb == null && output.lb_nsg_id == null
    error_message = "Defaults are private-only: no LB subnet or NSG."
  }

  assert {
    condition     = output.settings.kubernetes_version == "v1.36.4" && output.settings.enable_tailscale == false
    error_message = "Unset keys must fall back to defaults."
  }
}

run "tailscale_mode_closed_api" {
  command = plan

  variables {
    settings = { enable_tailscale = true }
  }

  assert {
    condition     = output.settings.api_allowed_cidrs == []
    error_message = "Tailscale mode needs no allowlist."
  }
}

run "no_access_path_rejected" {
  # Public API, no allowlist, no Tailscale: nobody could reach the cluster.
  command = plan

  expect_failures = [var.settings]
}

run "unknown_setting_rejected" {
  command = plan

  variables {
    settings = { enable_tailscle = true }
  }

  expect_failures = [var.settings]
}

run "nodes_pinned_to_quota_ad" {
  command = plan

  variables {
    settings                  = { enable_tailscale = true }
    availability_domain_index = 1
  }

  assert {
    condition     = module.oke.free_tier_usage.a1_ocpus == "2/2"
    error_message = "plan should succeed with AD index 1"
  }
}

run "missing_compartment_explains_bootstrap" {
  command = plan

  override_data {
    target = data.oci_identity_compartments.project
    values = { compartments = [] }
  }

  variables {
    settings = { enable_tailscale = true }
  }

  expect_failures = [data.oci_identity_compartments.project]
}
