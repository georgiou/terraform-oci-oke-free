# Offline: `tofu test` in modules/network. No OCI credentials needed.
mock_provider "oci" {
  mock_resource "oci_core_vcn" {
    defaults = {
      ipv6cidr_blocks = ["2603:c020:4000:1200::/56"]
    }
  }

  mock_data "oci_core_services" {
    defaults = {
      services = [{
        id          = "ocid1.service.oc1.uk-london-1.mock"
        name        = "All LHR Services In Oracle Services Network"
        cidr_block  = "all-lhr-services-in-oracle-services-network"
        description = "mock"
      }]
    }
  }
}

variables {
  compartment_id    = "ocid1.compartment.oc1..mock"
  name              = "oke-free"
  api_allowed_cidrs = ["203.0.113.7/32"]
}

run "free_tier_defaults_need_no_gateways" {
  command = plan

  assert {
    condition     = length(oci_core_nat_gateway.this) == 0 && length(oci_core_service_gateway.this) == 0
    error_message = "Free-only tenancies cannot create NAT/Service gateways; none should be planned."
  }

  assert {
    condition     = oci_core_subnet.workers.prohibit_public_ip_on_vnic == false
    error_message = "In free mode workers must be allowed public IPs for egress."
  }

  assert {
    condition     = local.cidrs.api == "10.0.0.0/28" && local.cidrs.workers == "10.0.1.0/24" && local.cidrs.lb == "10.0.2.0/24"
    error_message = "Unexpected subnet layout."
  }

  assert {
    condition     = local.nsg_rules["api-in-kubectl-203.0.113.7/32"].min == 6443
    error_message = "kubectl allowlist rule missing."
  }

  assert {
    condition     = !contains([for k, r in local.nsg_rules : r.peer if r.nsg == "workers" && r.dir == "INGRESS" && r.proto != "1"], "0.0.0.0/0")
    error_message = "Workers must not accept TCP/UDP from the internet."
  }
}

run "payg_private_workers" {
  command = plan

  variables {
    private_workers = true
  }

  assert {
    condition     = length(oci_core_nat_gateway.this) == 1 && length(oci_core_service_gateway.this) == 1
    error_message = "Private workers need NAT + Service gateways."
  }

  assert {
    condition     = oci_core_subnet.workers.prohibit_public_ip_on_vnic == true
    error_message = "Private workers must not get public IPs."
  }

  assert {
    condition     = local.nsg_rules["api-out-services"].peer_type == "SERVICE_CIDR_BLOCK"
    error_message = "With a Service Gateway, OCI service egress should target the service CIDR."
  }
}

run "private_api_requires_payg" {
  command = plan

  variables {
    api_endpoint_public = false
    private_workers     = false
  }

  expect_failures = [oci_core_vcn.this]
}

run "public_api_requires_allowlist" {
  command = plan

  variables {
    api_allowed_cidrs = []
  }

  expect_failures = [oci_core_vcn.this]
}

run "api_open_to_world_rejected" {
  command = plan

  variables {
    api_allowed_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.api_allowed_cidrs]
}

run "ipv6_dual_stack_lb_only" {
  command = apply # needs the mocked VCN prefix to be known

  variables {
    enable_ipv6 = true
  }

  assert {
    condition     = oci_core_vcn.this.is_ipv6enabled == true
    error_message = "VCN must be IPv6-enabled."
  }

  assert {
    condition     = local.lb_ipv6_cidr == "2603:c020:4000:1202::/64"
    error_message = "LB subnet should get the third /64 of the VCN /56."
  }

  assert {
    condition     = oci_core_subnet.workers.ipv6cidr_blocks == null || length(oci_core_subnet.workers.ipv6cidr_blocks) == 0
    error_message = "Workers stay IPv4: a dual-stack OKE cluster would need a NAT gateway."
  }

  assert {
    condition     = contains(keys(local.nsg_rules), "lb-in-443-::/0")
    error_message = "LB NSG must admit IPv6 clients."
  }

  assert {
    condition     = contains([for r in oci_core_route_table.public.route_rules : r.destination], "::/0")
    error_message = "Public route table needs ::/0 via the internet gateway."
  }
}

run "ipv6_off_adds_nothing" {
  command = plan

  assert {
    condition     = local.lb_ipv6_cidr == null && !contains(keys(local.nsg_rules), "lb-in-443-::/0")
    error_message = "No IPv6 artefacts when disabled."
  }
}

run "tailscale_allows_closed_api" {
  command = plan

  variables {
    enable_tailscale  = true
    api_allowed_cidrs = []
  }

  assert {
    condition     = length([for k, r in local.nsg_rules : k if startswith(k, "api-in-kubectl-")]) == 0
    error_message = "No internet CIDR should reach the API."
  }

  assert {
    condition     = local.nsg_rules["workers-in-tailscale-udp"].min == 41641 && local.nsg_rules["workers-in-tailscale-udp"].proto == "17"
    error_message = "Direct-connection UDP rule missing."
  }
}

run "tailscale_udp_skipped_behind_nat" {
  command = plan

  variables {
    enable_tailscale  = true
    private_workers   = true
    api_allowed_cidrs = []
  }

  assert {
    condition     = !contains(keys(local.nsg_rules), "workers-in-tailscale-udp")
    error_message = "Private workers have no public IP; the UDP rule would be dead weight."
  }
}

run "private_only_no_public_ingress" {
  command = plan

  variables {
    enable_public_ingress = false
    enable_tailscale      = true
    api_allowed_cidrs     = []
  }

  assert {
    condition     = length(oci_core_subnet.lb) == 0 && !contains(keys(local.nsg_ids), "lb")
    error_message = "No LB subnet or NSG without public ingress."
  }

  assert {
    condition     = length([for k, r in local.nsg_rules : k if r.dir == "INGRESS" && r.type == "cidr" && r.proto != "1"]) == 1
    error_message = "Only the Tailscale UDP rule may admit internet traffic."
  }

  assert {
    condition     = length([for k, r in local.nsg_rules : k if strcontains(k, "nodeport")]) == 0
    error_message = "NodePorts must not be reachable from anywhere outside the workers."
  }
}

run "ipv6_requires_public_ingress" {
  command = plan

  variables {
    enable_public_ingress = false
    enable_ipv6           = true
  }

  expect_failures = [oci_core_vcn.this]
}

run "lb_subnet_identity_preserved" {
  # Guards the moved block: with public ingress the subnet lives at lb[0].
  command = plan

  assert {
    condition     = length(oci_core_subnet.lb) == 1
    error_message = "Public ingress keeps exactly one LB subnet at oci_core_subnet.lb[0]."
  }
}
