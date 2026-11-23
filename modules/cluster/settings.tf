# Settings with defaults. Consumers pass a plain object (`cluster = {...}` in
# their settings file): new keys added here reach them without touching their
# root module, and typos fail validation. Defaults are private-only.
locals {
  defaults = {
    # ---- access
    # Reach the cluster over Tailscale (operator + API server proxy); allows an
    # empty api_allowed_cidrs.
    enable_tailscale = false
    # CIDRs allowed to reach the Kubernetes API (6443). Empty with Tailscale.
    api_allowed_cidrs = []
    # Admit UDP 41641 on (public) workers for direct tailnet connections.
    tailscale_direct_udp = true
    # Public IP on the API endpoint (filtered by NSG). false needs private_workers.
    api_endpoint_public = true

    # ---- network
    vcn_cidr = "10.0.0.0/16"
    # Private worker subnet behind NAT + Service Gateway: Pay As You Go only.
    private_workers = false
    # LB subnet/NSG so Services can get OCI LB/NLBs. false = private-only.
    enable_public_ingress = false
    # Dual-stack LB subnet (cluster stays IPv4). Needs enable_public_ingress.
    enable_ipv6      = false
    lb_ingress_ports = [80, 443]
    lb_allowed_cidrs = ["0.0.0.0/0"]

    # ---- kubernetes
    # oci ce cluster-options get --cluster-option-id all
    kubernetes_version = "v1.36.4"
    # 2 x (1 OCPU / 6 GB) = the whole Always Free A1 allowance.
    node_count                 = 2
    node_ocpus                 = 1
    node_memory_gbs            = 6
    node_boot_volume_gbs       = 50
    reserved_block_storage_gbs = 100
    # Pin a node image OCID; null = newest aarch64 OKE image for the version.
    node_image_id  = null
    ssh_public_key = null
  }

  s = merge(local.defaults, var.settings)

  common_tags = merge({ "managed-by" = "opentofu", "project" = var.project }, var.freeform_tags)
}
