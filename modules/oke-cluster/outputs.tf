output "cluster_id" {
  description = "OCID of the OKE cluster."
  value       = oci_containerengine_cluster.this.id
}

output "node_pool_id" {
  description = "OCID of the A1 node pool."
  value       = oci_containerengine_node_pool.a1.id
}

output "kubernetes_version" {
  description = "Kubernetes version of the control plane."
  value       = oci_containerengine_cluster.this.kubernetes_version
}

output "node_image" {
  description = "Image the node pool was built from."
  value       = var.node_image_id != null ? var.node_image_id : local.newest_image_name
}

output "endpoints" {
  description = "Kubernetes API endpoints (private, and public if enabled)."
  value       = oci_containerengine_cluster.this.endpoints
}

output "free_tier_usage" {
  description = "What this cluster consumes of the Always Free allowance."
  value = {
    a1_ocpus          = "${local.total_ocpus}/${var.free_tier_limits.a1_ocpus}"
    a1_memory_gbs     = "${local.total_memory_gbs}/${var.free_tier_limits.a1_memory_gbs}"
    block_storage_gbs = "${local.total_block_gbs}/${var.free_tier_limits.block_storage_gbs} (incl. ${var.reserved_block_storage_gbs} GB reserved for PVs)"
  }
}
