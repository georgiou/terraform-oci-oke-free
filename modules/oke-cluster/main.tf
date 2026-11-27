locals {
  total_ocpus      = var.node_count * var.node_ocpus
  total_memory_gbs = var.node_count * var.node_memory_gbs
  total_block_gbs  = var.node_count * var.node_boot_volume_gbs + var.reserved_block_storage_gbs

  k8s_semver = trimprefix(var.kubernetes_version, "v")

  # Newest aarch64 (non-GPU) OKE image built for this Kubernetes version.
  # Image names look like Oracle-Linux-8.10-aarch64-2026.10.30-0-OKE-1.36.4-1234
  candidate_images = {
    for s in data.oci_containerengine_node_pool_option.this.sources :
    s.source_name => s.image_id
    if s.source_type == "IMAGE"
    && strcontains(s.source_name, "aarch64")
    && strcontains(s.source_name, "OKE-${local.k8s_semver}-")
    && !strcontains(s.source_name, "GPU")
  }
  newest_image_name = try(reverse(sort(keys(local.candidate_images)))[0], null)
  node_image_id     = coalesce(var.node_image_id, try(local.candidate_images[local.newest_image_name], null), "NO-MATCHING-IMAGE")
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

data "oci_containerengine_node_pool_option" "this" {
  node_pool_option_id = "all"
  compartment_id      = var.compartment_id
}

# BASIC_CLUSTER: the control plane is free. ENHANCED costs per cluster-hour.
resource "oci_containerengine_cluster" "this" {
  compartment_id     = var.compartment_id
  name               = var.name
  kubernetes_version = var.kubernetes_version
  vcn_id             = var.vcn_id
  type               = "BASIC_CLUSTER"
  freeform_tags      = var.freeform_tags

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }

  endpoint_config {
    is_public_ip_enabled = var.api_endpoint_public
    subnet_id            = var.subnet_ids["api"]
    nsg_ids              = [var.nsg_ids["api"]]
  }

  options {
    # Empty when the network has no public ingress: the cloud controller then
    # has nowhere to put an OCI load balancer.
    service_lb_subnet_ids = compact([lookup(var.subnet_ids, "lb", null)])

    kubernetes_network_config {
      pods_cidr     = var.pods_cidr
      services_cidr = var.services_cidr
    }

    # Tag what the cloud controller creates so it's attributable in billing.
    persistent_volume_config {
      freeform_tags = var.freeform_tags
    }
    service_lb_config {
      freeform_tags = var.freeform_tags
    }
  }
}

resource "oci_containerengine_node_pool" "a1" {
  compartment_id     = var.compartment_id
  cluster_id         = oci_containerengine_cluster.this.id
  name               = "${var.name}-a1"
  kubernetes_version = var.kubernetes_version
  node_shape         = "VM.Standard.A1.Flex"
  ssh_public_key     = var.ssh_public_key
  freeform_tags      = var.freeform_tags

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = local.node_image_id
    boot_volume_size_in_gbs = var.node_boot_volume_gbs
  }

  node_config_details {
    size                                = var.node_count
    nsg_ids                             = [var.nsg_ids["workers"]]
    is_pv_encryption_in_transit_enabled = true
    freeform_tags                       = var.freeform_tags

    # OKE spreads nodes over placements, and over fault domains within each.
    dynamic "placement_configs" {
      for_each = coalesce(var.availability_domains, data.oci_identity_availability_domains.this.availability_domains[*].name)
      content {
        availability_domain = placement_configs.value
        subnet_id           = var.subnet_ids["workers"]
      }
    }
  }

  initial_node_labels {
    key   = "oke.free/pool"
    value = "a1"
  }

  node_eviction_node_pool_settings {
    eviction_grace_duration              = "PT30M"
    is_force_delete_after_grace_duration = true
  }

  # Basic OKE does not support automatic node cycling. Replace workers
  # manually during upgrades, removing each old worker before adding its replacement.

  lifecycle {
    precondition {
      condition     = local.total_ocpus <= var.free_tier_limits.a1_ocpus
      error_message = "Node pool needs ${local.total_ocpus} A1 OCPUs; Always Free allows ${var.free_tier_limits.a1_ocpus}. This would be billed."
    }
    precondition {
      condition     = local.total_memory_gbs <= var.free_tier_limits.a1_memory_gbs
      error_message = "Node pool needs ${local.total_memory_gbs} GB A1 memory; Always Free allows ${var.free_tier_limits.a1_memory_gbs} GB. This would be billed."
    }
    precondition {
      condition     = local.total_block_gbs <= var.free_tier_limits.block_storage_gbs
      error_message = "Boot volumes (${var.node_count} x ${var.node_boot_volume_gbs} GB) + ${var.reserved_block_storage_gbs} GB reserved for PVs = ${local.total_block_gbs} GB; Always Free allows ${var.free_tier_limits.block_storage_gbs} GB."
    }
    precondition {
      condition     = local.node_image_id != "NO-MATCHING-IMAGE"
      error_message = "No aarch64 OKE node image found for Kubernetes ${var.kubernetes_version}. Check `oci ce node-pool-options get --node-pool-option-id all` or set node_image_id."
    }
  }
}
