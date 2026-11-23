variable "tenancy_ocid" {
  description = "OCID of the tenancy."
  type        = string
}

variable "region" {
  description = "OCI region (home region); used in the kubeconfig command."
  type        = string
}

variable "project" {
  description = "Project name; must match the bootstrap module's (the compartment is looked up by it)."
  type        = string
}

variable "oci_profile" {
  description = "OCI CLI profile used in the generated kubeconfig command."
  type        = string
  default     = "DEFAULT"
}

variable "free_tier_limits" {
  description = "Tenancy-wide Always Free allowances; the node pool plan fails beyond these."
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

variable "availability_domain_index" {
  description = "AD (0-based) for the nodes; must match the bootstrap module's quota AD."
  type        = number
  default     = 0
}

variable "freeform_tags" {
  description = "Extra freeform tags for every resource."
  type        = map(string)
  default     = {}
}

variable "settings" {
  description = "Cluster settings; see local.defaults in settings.tf for keys and defaults."
  type        = any
  default     = {}

  validation {
    condition     = length(setsubtract(keys(var.settings), keys(local.defaults))) == 0
    error_message = "Unknown cluster setting(s): ${join(", ", setsubtract(keys(var.settings), keys(local.defaults)))}. Known: ${join(", ", sort(keys(local.defaults)))}."
  }

  validation {
    condition = !(
      merge(local.defaults, var.settings).api_endpoint_public &&
      length(merge(local.defaults, var.settings).api_allowed_cidrs) == 0 &&
      !merge(local.defaults, var.settings).enable_tailscale
    )
    error_message = "No way to reach the Kubernetes API: set cluster.enable_tailscale = true, or list your IP in cluster.api_allowed_cidrs."
  }
}
