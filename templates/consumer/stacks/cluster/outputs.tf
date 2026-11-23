output "cluster_id" {
  description = "OCID of the OKE cluster."
  value       = module.cluster.cluster_id
}

output "kubernetes_version" {
  description = "Kubernetes version of the control plane."
  value       = module.cluster.kubernetes_version
}

output "free_tier_usage" {
  description = "How much of the Always Free allowance the cluster uses."
  value       = module.cluster.free_tier_usage
}

output "lb_nsg_id" {
  description = "NSG for LoadBalancer Services (null without public ingress)."
  value       = module.cluster.lb_nsg_id
}

output "kubeconfig_command" {
  description = "Writes ~/.kube/config using the oci exec plugin."
  value       = module.cluster.kubeconfig_command
}
