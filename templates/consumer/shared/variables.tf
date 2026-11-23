# Symlinked into both roots. Every value comes from config/settings.tfvars
# (plus TF_VAR_state_passphrase). You shouldn't need to edit this file:
# new library settings arrive through the `bootstrap` and `cluster` objects.

# ------------------------------------------------------------------ library
variable "modules_source" {
  description = "Where the library modules live, e.g. git::https://github.com/OWNER/oci-oke-free.git//modules (or a local path for development)."
  type        = string
}

variable "module_ref" {
  description = "Library version: a release tag (vX.Y.Z, Renovate keeps it current), a branch such as \"main\" (tracking; CI pins it to a commit per run), a commit SHA, or \"\" for a local path."
  type        = string
  default     = ""
}

# ----------------------------------------------------------------- identity
variable "tenancy_ocid" {
  description = "OCID of the tenancy (root compartment)."
  type        = string
}

variable "region" {
  description = "OCI region. Must be your home region (Always Free compute only exists there)."
  type        = string
}

variable "oci_profile" {
  description = "Profile in ~/.oci/config."
  type        = string
  default     = "DEFAULT"
}

variable "oci_auth" {
  description = "OCI provider auth: ApiKey, SecurityToken or InstancePrincipal."
  type        = string
  default     = "ApiKey"
}

variable "project" {
  description = "Short name for the compartment and resources. Same in both roots."
  type        = string
  default     = "oke-free"
}

# -------------------------------------------------------------------- state
variable "state_namespace" {
  description = "Object Storage namespace (`oci os ns get`)."
  type        = string
}

variable "state_bucket" {
  description = "Bucket holding state for both roots."
  type        = string
  default     = "tofu-state"
}

variable "state_passphrase" {
  description = "Passphrase for client-side state/plan encryption. Supply via TF_VAR_state_passphrase, never a file."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.state_passphrase) >= 16
    error_message = "state_passphrase must be at least 16 characters."
  }
}

# ------------------------------------------------------------------- shared
variable "free_tier_limits" {
  description = "Tenancy-wide Always Free allowances (quotas + plan-time guards). Oracle's current: 2 OCPU / 12 GB / 200 GB."
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
  description = "AD (0-based) for A1 nodes and the quota grant."
  type        = number
  default     = 0
}

variable "freeform_tags" {
  description = "Extra freeform tags for every resource."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------ per-root settings
variable "bootstrap" {
  description = "Bootstrap module settings (alerts, budget, quotas). Keys and defaults: library modules/bootstrap/settings.tf."
  type        = any
  default     = {}
}

variable "cluster" {
  description = "Cluster module settings (access, network, Kubernetes). Keys and defaults: library modules/cluster/settings.tf."
  type        = any
  default     = {}
}
