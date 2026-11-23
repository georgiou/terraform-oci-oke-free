# The cluster: network + OKE, in one state. Depends on the bootstrap module
# having created the project compartment (found by name, no remote state).

data "oci_identity_compartments" "project" {
  compartment_id = var.tenancy_ocid
  name           = var.project
  state          = "ACTIVE"

  lifecycle {
    postcondition {
      condition     = length(self.compartments) == 1
      error_message = "Compartment \"${var.project}\" not found under the tenancy. Apply the bootstrap root first (and keep `project` identical in both)."
    }
  }
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid

  lifecycle {
    postcondition {
      condition     = var.availability_domain_index < length(self.availability_domains)
      error_message = "availability_domain_index is out of range for this region."
    }
  }
}

locals {
  compartment_id = data.oci_identity_compartments.project.compartments[0].id
  a1_ad          = data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name
}

module "network" {
  source = "../network"

  compartment_id        = local.compartment_id
  name                  = var.project
  vcn_cidr              = local.s.vcn_cidr
  private_workers       = local.s.private_workers
  api_endpoint_public   = local.s.api_endpoint_public
  api_allowed_cidrs     = local.s.api_allowed_cidrs
  enable_tailscale      = local.s.enable_tailscale
  tailscale_direct_udp  = local.s.tailscale_direct_udp
  enable_public_ingress = local.s.enable_public_ingress
  enable_ipv6           = local.s.enable_ipv6
  lb_ingress_ports      = local.s.lb_ingress_ports
  lb_allowed_cidrs      = local.s.lb_allowed_cidrs
  freeform_tags         = local.common_tags
}

module "oke" {
  source = "../oke-cluster"

  compartment_id      = local.compartment_id
  tenancy_ocid        = var.tenancy_ocid
  name                = var.project
  kubernetes_version  = local.s.kubernetes_version
  vcn_id              = module.network.vcn_id
  subnet_ids          = module.network.subnet_ids
  nsg_ids             = module.network.nsg_ids
  api_endpoint_public = local.s.api_endpoint_public

  node_count                 = local.s.node_count
  node_ocpus                 = local.s.node_ocpus
  node_memory_gbs            = local.s.node_memory_gbs
  node_boot_volume_gbs       = local.s.node_boot_volume_gbs
  reserved_block_storage_gbs = local.s.reserved_block_storage_gbs
  free_tier_limits           = var.free_tier_limits
  availability_domains       = [local.a1_ad]
  node_image_id              = local.s.node_image_id
  ssh_public_key             = local.s.ssh_public_key

  freeform_tags = local.common_tags
}
