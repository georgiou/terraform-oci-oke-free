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

# Copied into the scaffolded example consumer by `make validate-template`:
# plans the consumer's cluster root with the template's example settings.
run "example_settings_plan" {
  command = plan

  assert {
    condition     = module.cluster.settings.enable_tailscale == true
    error_message = "Example settings should select Tailscale access."
  }

  assert {
    condition     = module.cluster.free_tier_usage.a1_ocpus == "2/2"
    error_message = "Example settings should fit the free tier exactly."
  }
}
