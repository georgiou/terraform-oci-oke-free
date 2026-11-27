# Offline: `tofu test` in modules/oke-cluster. Proves the module refuses to
# plan anything that would leave the Always Free allowance.
mock_provider "oci" {
  mock_data "oci_identity_availability_domains" {
    defaults = {
      availability_domains = [
        { id = "ad1", name = "Xyz:UK-LONDON-1-AD-1", compartment_id = "c" },
        { id = "ad2", name = "Xyz:UK-LONDON-1-AD-2", compartment_id = "c" },
      ]
    }
  }

  mock_data "oci_containerengine_node_pool_option" {
    defaults = {
      sources = [
        { source_type = "IMAGE", source_name = "Oracle-Linux-8.10-aarch64-2026.09.01-0-OKE-1.36.4-900", image_id = "ocid1.image.old-arm" },
        { source_type = "IMAGE", source_name = "Oracle-Linux-8.10-aarch64-2026.10.30-0-OKE-1.36.4-950", image_id = "ocid1.image.new-arm" },
        { source_type = "IMAGE", source_name = "Oracle-Linux-8.10-2026.10.30-0-OKE-1.36.4-950", image_id = "ocid1.image.x86" },
        { source_type = "IMAGE", source_name = "Oracle-Linux-8.10-Gen2-GPU-aarch64-2026.10.30-0-OKE-1.36.4-950", image_id = "ocid1.image.gpu" },
        { source_type = "IMAGE", source_name = "Oracle-Linux-8.10-aarch64-2026.10.30-0-OKE-1.35.2-950", image_id = "ocid1.image.other-k8s" },
      ]
    }
  }
}

variables {
  compartment_id     = "ocid1.compartment.oc1..mock"
  tenancy_ocid       = "ocid1.tenancy.oc1..mock"
  name               = "oke-free"
  kubernetes_version = "v1.36.4"
  vcn_id             = "ocid1.vcn.oc1..mock"
  subnet_ids         = { api = "s-api", workers = "s-workers", lb = "s-lb" }
  nsg_ids            = { api = "n-api", workers = "n-workers", lb = "n-lb" }
}

run "defaults_fit_free_tier" {
  command = plan

  assert {
    condition     = oci_containerengine_cluster.this.type == "BASIC_CLUSTER"
    error_message = "Only BASIC clusters have a free control plane."
  }

  assert {
    condition     = local.node_image_id == "ocid1.image.new-arm"
    error_message = "Should pick the newest non-GPU aarch64 image for the pinned Kubernetes version."
  }

  assert {
    condition     = length(oci_containerengine_node_pool.a1.node_pool_cycling_details) == 0
    error_message = "Basic OKE must not configure Enhanced-only node cycling."
  }

  assert {
    condition     = length(oci_containerengine_node_pool.a1.node_config_details[0].placement_configs) == 2
    error_message = "Node pool should be placed across all availability domains."
  }
}

run "single_big_node_fits" {
  command = plan

  variables {
    node_count      = 1
    node_ocpus      = 2
    node_memory_gbs = 12
  }
}

run "third_node_rejected" {
  command = plan

  variables {
    node_count = 3
  }

  expect_failures = [oci_containerengine_node_pool.a1]
}

run "old_4_ocpu_allowance_rejected" {
  command = plan

  variables {
    node_count      = 2
    node_ocpus      = 2
    node_memory_gbs = 12
  }

  expect_failures = [oci_containerengine_node_pool.a1]
}

run "block_storage_overcommit_rejected" {
  command = plan

  variables {
    node_boot_volume_gbs       = 100
    reserved_block_storage_gbs = 50
  }

  expect_failures = [oci_containerengine_node_pool.a1]
}

run "missing_image_rejected" {
  command = plan

  variables {
    kubernetes_version = "v1.99.0"
  }

  expect_failures = [oci_containerengine_node_pool.a1]
}

run "pinned_to_quota_ad" {
  command = plan

  variables {
    availability_domains = ["Xyz:UK-LONDON-1-AD-1"]
  }

  assert {
    condition     = length(oci_containerengine_node_pool.a1.node_config_details[0].placement_configs) == 1
    error_message = "Nodes must stay in the quota AD."
  }
}

run "no_lb_subnet" {
  command = plan

  variables {
    subnet_ids = { api = "s-api", workers = "s-workers" }
    nsg_ids    = { api = "n-api", workers = "n-workers" }
  }

  assert {
    condition     = length(oci_containerengine_cluster.this.options[0].service_lb_subnet_ids) == 0
    error_message = "No service LB subnet without public ingress."
  }
}
