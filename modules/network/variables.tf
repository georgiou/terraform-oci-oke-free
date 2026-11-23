variable "compartment_id" {
  description = "Compartment for all network resources."
  type        = string
}

variable "name" {
  description = "Name prefix for resources."
  type        = string
}

variable "vcn_cidr" {
  description = "VCN CIDR. Subnets are carved from it with cidrsubnet()."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vcn_cidr, 0)) && tonumber(split("/", var.vcn_cidr)[1]) <= 20
    error_message = "vcn_cidr must be a valid CIDR of /20 or larger."
  }
}

variable "private_workers" {
  description = <<-EOT
    Place worker nodes in a private subnet behind a NAT + Service Gateway.
    Free-only tenancies have a service limit of 0 for NAT and Service Gateways,
    so this only works after upgrading to Pay As You Go (the gateways themselves
    are free). With false, workers get ephemeral public IPs but the NSG admits
    nothing from the internet.
  EOT
  type        = bool
  default     = false
}

variable "api_endpoint_public" {
  description = "Expose the Kubernetes API on a public IP, restricted to api_allowed_cidrs. A private endpoint requires private_workers = true (needs a Service Gateway)."
  type        = bool
  default     = true
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API (6443). Your home IP /32, a VPN egress, etc."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.api_allowed_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "api_allowed_cidrs must be valid CIDRs and must not include 0.0.0.0/0."
  }
}

variable "enable_public_ingress" {
  description = <<-EOT
    Create the load balancer subnet, its NSG and the LB -> NodePort rules, so
    Services of type LoadBalancer can get an OCI LB/NLB. Set false when all
    access is over Tailscale: nothing then admits internet traffic except the
    optional Tailscale UDP port.
  EOT
  type        = bool
  default     = true
}

variable "enable_ipv6" {
  description = <<-EOT
    Make the VCN and the load balancer subnet dual-stack so Services can be
    reached over IPv6. Workers, API endpoint and pods stay IPv4. Turning this
    on for an existing VCN adds an IPv6 prefix in place; check the plan.
  EOT
  type        = bool
  default     = false
}

variable "lb_allowed_ipv6_cidrs" {
  description = "IPv6 client prefixes allowed to reach load balancers when enable_ipv6 = true."
  type        = list(string)
  default     = ["::/0"]
}

variable "enable_tailscale" {
  description = <<-EOT
    You reach the cluster over Tailscale (operator + API server proxy).
    Allows an empty api_allowed_cidrs, i.e. the public Kubernetes API endpoint
    stays up (OKE needs it on free-only tenancies) but admits nobody from the
    internet. Workers still reach it inside the VCN, so the operator's proxy works.
  EOT
  type        = bool
  default     = false
}

variable "tailscale_direct_udp" {
  description = "With enable_tailscale and public workers, admit UDP 41641 so peers connect directly instead of via DERP relays."
  type        = bool
  default     = true
}

variable "lb_ingress_ports" {
  description = "TCP ports load balancers accept from lb_allowed_cidrs."
  type        = list(number)
  default     = [80, 443]
}

variable "lb_allowed_cidrs" {
  description = "Client CIDRs allowed to reach load balancers."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "freeform_tags" {
  description = "Freeform tags applied to every network resource."
  type        = map(string)
  default     = {}
}
