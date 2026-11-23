output "vcn_id" {
  description = "OCID of the VCN."
  value       = oci_core_vcn.this.id
}

output "subnet_ids" {
  description = "Map of subnet role => OCID (api, workers, lb). lb is null without public ingress."
  value = {
    api     = oci_core_subnet.api.id
    workers = oci_core_subnet.workers.id
    lb      = try(oci_core_subnet.lb[0].id, null)
  }
}

output "subnet_cidrs" {
  description = "Map of subnet role => IPv4 CIDR."
  value       = local.cidrs
}

output "nsg_ids" {
  description = "Map of NSG role => OCID (api, workers, and lb with public ingress)."
  value       = local.nsg_ids
}

output "private_workers" {
  description = "Whether workers are in a private subnet (echo of the input)."
  value       = var.private_workers
}

output "api_endpoint_public" {
  description = "Whether the Kubernetes API endpoint has a public IP (echo of the input)."
  value       = var.api_endpoint_public
}

output "lb_ipv6_cidr" {
  description = "IPv6 /64 of the load balancer subnet (null when IPv6 is off)."
  value       = local.lb_ipv6_cidr
}
