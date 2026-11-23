# Cluster root: network + OKE. Run by CI (plan on PRs, apply on main).
# You can add your own resources below the module, e.g. a bucket for backups:
#   resource "oci_objectstorage_bucket" "backups" { compartment_id = ... }

module "cluster" {
  source = local.module_source["cluster"]

  tenancy_ocid              = var.tenancy_ocid
  region                    = var.region
  project                   = var.project
  oci_profile               = var.oci_profile
  free_tier_limits          = var.free_tier_limits
  availability_domain_index = var.availability_domain_index
  freeform_tags             = var.freeform_tags
  settings                  = var.cluster
}
