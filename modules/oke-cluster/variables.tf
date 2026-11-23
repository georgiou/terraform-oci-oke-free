variable "compartment_id" {
  description = "Compartment for the cluster and node pool."
  type        = string
}

variable "tenancy_ocid" {
  description = "Used to list availability domains."
  type        = string
}

variable "name" {
  description = "Cluster name; also the node pool name prefix."
  type        = string
}

variable "kubernetes_version" {
  description = "OKE Kubernetes version, e.g. v1.36.4. Pin explicitly; upgrade deliberately."
  type        = string

  validation {
    condition     = can(regex("^v1\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like v1.36.4."
  }
}

variable "vcn_id" {
  description = "VCN the cluster attaches to."
  type        = string
}

variable "subnet_ids" {
  description = "Map with keys api, workers and optionally lb (null/absent = no public ingress)."
  type        = map(string)
}

variable "nsg_ids" {
  description = "Map with keys api, workers, lb."
  type        = map(string)
}

variable "api_endpoint_public" {
  description = "Give the API endpoint a public IP (filtered by the api NSG)."
  type        = bool
  default     = true
}

variable "pods_cidr" {
  description = "Flannel pod CIDR; must not overlap the VCN."
  type        = string
  default     = "10.244.0.0/16"
}

variable "services_cidr" {
  description = "Kubernetes Service CIDR; must not overlap the VCN or pods_cidr."
  type        = string
  default     = "10.96.0.0/16"
}

# ---------------------------------------------------------------------------
# Node pool sizing. Defaults: 2 x (1 OCPU, 6 GB, 50 GB boot) = the whole
# current Always Free A1 allowance, leaving 100 GB block storage for PVCs.
# ---------------------------------------------------------------------------
variable "node_count" {
  description = "Number of A1 nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count == floor(var.node_count)
    error_message = "node_count must be a positive integer."
  }
}

variable "node_ocpus" {
  description = "OCPUs per node."
  type        = number
  default     = 1
}

variable "node_memory_gbs" {
  description = "Memory (GB) per node."
  type        = number
  default     = 6
}

variable "node_boot_volume_gbs" {
  description = "Boot volume per node. OCI minimum is 50 GB for OKE nodes."
  type        = number
  default     = 50

  validation {
    condition     = var.node_boot_volume_gbs >= 50
    error_message = "Boot volumes must be at least 50 GB."
  }
}

variable "reserved_block_storage_gbs" {
  description = "Block storage kept free for PersistentVolumes (OCI block volume minimum is 50 GB each)."
  type        = number
  default     = 100
}

variable "free_tier_limits" {
  description = <<-EOT
    Tenancy-wide Always Free allowances this module refuses to exceed.
    Oracle halved A1 from 4 OCPU / 24 GB to 2 OCPU / 12 GB on 2026-06-15.
    If your tenancy is grandfathered at a higher allowance, override here,
    and remember the limits also cover A1 instances OUTSIDE this cluster.
  EOT
  type = object({
    a1_ocpus          = number
    a1_memory_gbs     = number
    block_storage_gbs = number
  })
  default = {
    a1_ocpus          = 2
    a1_memory_gbs     = 12
    block_storage_gbs = 200
  }
}

variable "availability_domains" {
  description = "AD names to place nodes in. null = every AD in the region. Must match the quota AD when quotas are enabled."
  type        = list(string)
  default     = null
}

variable "node_image_id" {
  description = "Pin a specific OKE node image OCID. null = newest aarch64 OKE image for kubernetes_version."
  type        = string
  default     = null
}

variable "ssh_public_key" {
  description = "Optional SSH key for nodes. Prefer leaving null and using OCI Bastion/Run Command."
  type        = string
  default     = null
}

variable "freeform_tags" {
  description = "Freeform tags for the cluster, node pool, and CCM-created volumes/LBs."
  type        = map(string)
  default     = {}
}
