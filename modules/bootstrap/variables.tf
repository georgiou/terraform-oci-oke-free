variable "tenancy_ocid" {
  description = "OCID of the tenancy (root compartment)."
  type        = string

  validation {
    condition     = startswith(var.tenancy_ocid, "ocid1.tenancy.")
    error_message = "tenancy_ocid must be a tenancy OCID (ocid1.tenancy...)."
  }
}

variable "region" {
  description = "OCI region. Must be the tenancy's home region (checked)."
  type        = string
}

variable "project" {
  description = "Short name for the compartment and resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric/dashes, 2-21 chars."
  }
}

variable "state_namespace" {
  description = "Object Storage namespace of the tenancy (`oci os ns get`)."
  type        = string
}

variable "state_bucket" {
  description = "Name of the state bucket (seeded by the consumer, adopted here)."
  type        = string
  default     = "tofu-state"
}

variable "free_tier_limits" {
  description = "Tenancy-wide Always Free allowances; the quotas enforce exactly these."
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
  description = "AD (0-based) the quotas grant A1 and block storage in. Must match the cluster module's."
  type        = number
  default     = 0
}

variable "freeform_tags" {
  description = "Extra freeform tags for every resource."
  type        = map(string)
  default     = {}
}

variable "settings" {
  description = "Bootstrap settings; see local.defaults in settings.tf for keys and defaults. budget_alert_emails is required."
  type        = any
  default     = {}

  validation {
    condition     = length(setsubtract(keys(var.settings), keys(local.defaults))) == 0
    error_message = "Unknown bootstrap setting(s): ${join(", ", setsubtract(keys(var.settings), keys(local.defaults)))}. Known: ${join(", ", sort(keys(local.defaults)))}."
  }
}
