locals {
  # Three regional subnets, carved deterministically from the VCN CIDR.
  #   api      /28  OKE API endpoint (one private IP + optional public IP)
  #   workers  /24  node VNICs (pods use the flannel overlay, not VCN IPs)
  #   lb       /24  OCI LB / NLB provisioned by the cloud controller
  cidrs = {
    api     = cidrsubnet(var.vcn_cidr, 12, 0)
    workers = cidrsubnet(var.vcn_cidr, 8, 1)
    lb      = cidrsubnet(var.vcn_cidr, 8, 2)
  }

  need_private_rt = var.private_workers || !var.api_endpoint_public

  # Only the LB subnet goes dual-stack. The cluster stays IPv4 single-stack:
  # an OKE dual-stack *cluster* needs every subnet public AND a NAT gateway
  # for IPv4, which free-only tenancies can't have. An IPv4 cluster can still
  # front its Services with a dual-stack load balancer.
  lb_ipv6_cidr = var.enable_public_ingress && var.enable_ipv6 ? cidrsubnet(oci_core_vcn.this.ipv6cidr_blocks[0], 8, 2) : null
}

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  display_name   = "${var.name}-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = substr(replace(var.name, "-", ""), 0, 15)
  is_ipv6enabled = var.enable_ipv6 && var.enable_public_ingress # Oracle-allocated GUA /56, free
  freeform_tags  = var.freeform_tags

  lifecycle {
    precondition {
      condition     = var.enable_public_ingress || !var.enable_ipv6
      error_message = "enable_ipv6 only affects the load balancer subnet; it needs enable_public_ingress = true."
    }
    precondition {
      condition     = var.api_endpoint_public || var.private_workers
      error_message = "A private API endpoint needs a Service Gateway, which needs PAYG: set private_workers = true or keep api_endpoint_public = true."
    }
    precondition {
      condition     = !var.api_endpoint_public || length(var.api_allowed_cidrs) > 0 || var.enable_tailscale
      error_message = "api_endpoint_public = true requires at least one entry in api_allowed_cidrs (or enable_tailscale = true to reach the API via the Tailscale proxy instead)."
    }
  }
}

# Strip the default security list (it allows SSH from 0.0.0.0/0). All traffic
# policy lives in NSGs below.
resource "oci_core_default_security_list" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_security_list_id
  display_name               = "${var.name}-default-deny"
  freeform_tags              = var.freeform_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-igw"
  enabled        = true
  freeform_tags  = var.freeform_tags
}

data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_nat_gateway" "this" {
  count          = local.need_private_rt ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-nat"
  freeform_tags  = var.freeform_tags
}

resource "oci_core_service_gateway" "this" {
  count          = local.need_private_rt ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-sgw"
  freeform_tags  = var.freeform_tags

  services {
    service_id = data.oci_core_services.all.services[0].id
  }
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-rt-public"
  freeform_tags  = var.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  dynamic "route_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination       = "::/0"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_internet_gateway.this.id
    }
  }
}

resource "oci_core_route_table" "private" {
  count          = local.need_private_rt ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-rt-private"
  freeform_tags  = var.freeform_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this[0].id
  }

  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.this[0].id
  }
}

resource "oci_core_subnet" "api" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "${var.name}-api"
  dns_label                  = "api"
  cidr_block                 = local.cidrs.api
  prohibit_public_ip_on_vnic = !var.api_endpoint_public
  route_table_id             = var.api_endpoint_public ? oci_core_route_table.public.id : oci_core_route_table.private[0].id
  security_list_ids          = [oci_core_vcn.this.default_security_list_id]
  freeform_tags              = var.freeform_tags
}

resource "oci_core_subnet" "workers" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "${var.name}-workers"
  dns_label                  = "workers"
  cidr_block                 = local.cidrs.workers
  prohibit_public_ip_on_vnic = var.private_workers
  route_table_id             = var.private_workers ? oci_core_route_table.private[0].id : oci_core_route_table.public.id
  security_list_ids          = [oci_core_vcn.this.default_security_list_id]
  freeform_tags              = var.freeform_tags
}

resource "oci_core_subnet" "lb" {
  count                      = var.enable_public_ingress ? 1 : 0
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "${var.name}-lb"
  dns_label                  = "lb"
  cidr_block                 = local.cidrs.lb
  ipv6cidr_blocks            = var.enable_ipv6 ? [local.lb_ipv6_cidr] : null
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_vcn.this.default_security_list_id]
  freeform_tags              = var.freeform_tags
}

# The LB subnet became optional (count) with enable_public_ingress. Keep the
# existing subnet's identity instead of destroy/create on upgrade.
moved {
  from = oci_core_subnet.lb
  to   = oci_core_subnet.lb[0]
}
