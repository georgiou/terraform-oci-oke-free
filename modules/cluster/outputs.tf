output "cluster_id" {
  description = "OCID of the OKE cluster."
  value       = module.oke.cluster_id
}

output "kubernetes_version" {
  description = "Kubernetes version of the control plane."
  value       = module.oke.kubernetes_version
}

output "node_image" {
  description = "Node image name (or pinned OCID) the pool was built from."
  value       = module.oke.node_image
}

output "free_tier_usage" {
  description = "How much of the Always Free allowance this cluster uses."
  value       = module.oke.free_tier_usage
}

output "vcn_id" {
  description = "OCID of the VCN."
  value       = module.network.vcn_id
}

output "subnet_ids" {
  description = "Map of subnet role => OCID (lb is null without public ingress)."
  value       = module.network.subnet_ids
}

output "lb_nsg_id" {
  description = "NSG to annotate LoadBalancer Services with; null without public ingress."
  value       = lookup(module.network.nsg_ids, "lb", null)
}

output "kubeconfig_command" {
  description = "Writes a kubeconfig that uses the oci exec plugin (no stored credentials)."
  value       = "oci ce cluster create-kubeconfig --cluster-id ${module.oke.cluster_id} --region ${var.region} --token-version 2.0.0 --kube-endpoint ${local.s.api_endpoint_public ? "PUBLIC_ENDPOINT" : "PRIVATE_ENDPOINT"} --file $HOME/.kube/config --profile ${var.oci_profile}"
}

output "settings" {
  description = "Effective cluster settings (defaults merged with yours)."
  value       = local.s
}
