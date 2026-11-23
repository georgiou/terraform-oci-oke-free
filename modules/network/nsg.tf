# Network Security Groups for OKE (flannel overlay), modelled on Oracle's
# "Example Network Resource Configurations" for OKE. Peers are expressed as
# NSG-to-NSG references wherever possible so rules follow the VNICs, not CIDRs.

resource "oci_core_network_security_group" "this" {
  for_each       = toset(concat(["api", "workers"], var.enable_public_ingress ? ["lb"] : []))
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name}-nsg-${each.key}"
  freeform_tags  = var.freeform_tags
}

locals {
  nsg_ids = { for k, v in oci_core_network_security_group.this : k => v.id }

  # Without a Service Gateway, OCI service traffic leaves via the IGW.
  services_peer = local.need_private_rt ? {
    peer = data.oci_core_services.all.services[0].cidr_block, type = "service"
    } : {
    peer = "0.0.0.0/0", type = "cidr"
  }

  # Every rule: nsg, dir, proto ("6" tcp, "17" udp, "1" icmp, "all"), peer, type
  # ("cidr" | "nsg" | "service"), optional min/max ports or icmp type/code.
  rule_defaults = { min = null, max = null, icmp_type = null, icmp_code = null }

  static_rules = {
    # ---------------- API endpoint ----------------
    api-in-workers-6443  = { nsg = "api", dir = "INGRESS", proto = "6", peer = "workers", type = "nsg", min = 6443, max = 6443, desc = "Kubernetes API from workers" }
    api-in-workers-12250 = { nsg = "api", dir = "INGRESS", proto = "6", peer = "workers", type = "nsg", min = 12250, max = 12250, desc = "OKE control plane proxy from workers" }
    api-in-workers-pmtu  = { nsg = "api", dir = "INGRESS", proto = "1", peer = "workers", type = "nsg", icmp_type = 3, icmp_code = 4, desc = "Path MTU discovery" }
    api-out-workers-tcp  = { nsg = "api", dir = "EGRESS", proto = "6", peer = "workers", type = "nsg", desc = "Control plane to kubelet / webhooks" }
    api-out-workers-pmtu = { nsg = "api", dir = "EGRESS", proto = "1", peer = "workers", type = "nsg", icmp_type = 3, icmp_code = 4, desc = "Path MTU discovery" }
    api-out-services     = { nsg = "api", dir = "EGRESS", proto = "6", peer = local.services_peer.peer, type = local.services_peer.type, min = 443, max = 443, desc = "OKE endpoint to OCI services" }

    # ---------------- Workers ----------------
    workers-in-workers = { nsg = "workers", dir = "INGRESS", proto = "all", peer = "workers", type = "nsg", desc = "Node-to-node and pod-to-pod (flannel VXLAN)" }
    workers-in-api     = { nsg = "workers", dir = "INGRESS", proto = "6", peer = "api", type = "nsg", desc = "Control plane to kubelet / webhooks" }
    workers-in-pmtu    = { nsg = "workers", dir = "INGRESS", proto = "1", peer = "0.0.0.0/0", type = "cidr", icmp_type = 3, icmp_code = 4, desc = "Path MTU discovery" }
    workers-out-all    = { nsg = "workers", dir = "EGRESS", proto = "all", peer = "0.0.0.0/0", type = "cidr", desc = "Nodes to cluster, OCI services, registries" }
  }

  # ---------------- Load balancers (only with public ingress) ----------------
  lb_rules = var.enable_public_ingress ? {
    workers-in-lb-nodeports = { nsg = "workers", dir = "INGRESS", proto = "6", peer = "lb", type = "nsg", min = 30000, max = 32767, desc = "Load balancer to NodePorts" }
    workers-in-lb-healthz   = { nsg = "workers", dir = "INGRESS", proto = "6", peer = "lb", type = "nsg", min = 10256, max = 10256, desc = "Load balancer to kube-proxy health check" }
    lb-out-nodeports        = { nsg = "lb", dir = "EGRESS", proto = "6", peer = "workers", type = "nsg", min = 30000, max = 32767, desc = "To NodePorts" }
    lb-out-healthz          = { nsg = "lb", dir = "EGRESS", proto = "6", peer = "workers", type = "nsg", min = 10256, max = 10256, desc = "To kube-proxy health check" }
  } : {}

  kubectl_rules = {
    for c in(var.api_endpoint_public ? var.api_allowed_cidrs : []) :
    "api-in-kubectl-${c}" => { nsg = "api", dir = "INGRESS", proto = "6", peer = c, type = "cidr", min = 6443, max = 6443, desc = "kubectl from allowed client CIDR" }
  }

  lb_client_rules = merge([
    for c in(var.enable_public_ingress ? concat(var.lb_allowed_cidrs, var.enable_ipv6 ? var.lb_allowed_ipv6_cidrs : []) : []) : {
      for p in var.lb_ingress_ports :
      "lb-in-${p}-${c}" => { nsg = "lb", dir = "INGRESS", proto = "6", peer = c, type = "cidr", min = p, max = p, desc = "Clients to load balancer :${p}" }
    }
  ]...)

  # Direct WireGuard paths. Pointless behind NAT (private workers): no public IP.
  tailscale_rules = var.enable_tailscale && var.tailscale_direct_udp && !var.private_workers ? {
    workers-in-tailscale-udp = { nsg = "workers", dir = "INGRESS", proto = "17", peer = "0.0.0.0/0", type = "cidr", min = 41641, max = 41641, desc = "Tailscale direct connections (WireGuard)" }
  } : {}

  peer_types = { cidr = "CIDR_BLOCK", nsg = "NETWORK_SECURITY_GROUP", service = "SERVICE_CIDR_BLOCK" }

  nsg_rules = {
    for k, r in merge(local.static_rules, local.lb_rules, local.kubectl_rules, local.lb_client_rules, local.tailscale_rules) :
    k => merge(local.rule_defaults, r, {
      peer_id   = r.type == "nsg" ? local.nsg_ids[r.peer] : r.peer
      peer_type = local.peer_types[r.type]
    })
  }
}

resource "oci_core_network_security_group_security_rule" "this" {
  for_each = local.nsg_rules

  network_security_group_id = local.nsg_ids[each.value.nsg]
  direction                 = each.value.dir
  protocol                  = each.value.proto
  description               = each.value.desc
  stateless                 = false

  source           = each.value.dir == "INGRESS" ? each.value.peer_id : null
  source_type      = each.value.dir == "INGRESS" ? each.value.peer_type : null
  destination      = each.value.dir == "EGRESS" ? each.value.peer_id : null
  destination_type = each.value.dir == "EGRESS" ? each.value.peer_type : null

  dynamic "tcp_options" {
    for_each = each.value.proto == "6" && each.value.min != null ? [1] : []
    content {
      destination_port_range {
        min = each.value.min
        max = each.value.max
      }
    }
  }

  dynamic "udp_options" {
    for_each = each.value.proto == "17" && each.value.min != null ? [1] : []
    content {
      destination_port_range {
        min = each.value.min
        max = each.value.max
      }
    }
  }

  dynamic "icmp_options" {
    for_each = each.value.proto == "1" ? [1] : []
    content {
      type = each.value.icmp_type
      code = each.value.icmp_code
    }
  }
}
