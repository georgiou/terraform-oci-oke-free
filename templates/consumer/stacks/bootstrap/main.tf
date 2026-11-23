# Bootstrap root: compartment, state bucket, quotas, budget, alarms, IAM.
# Break-glass: run it locally (make plan-bootstrap / apply-bootstrap), never in CI.
# You can add your own tenancy-level resources below the module.

module "bootstrap" {
  source = local.module_source["bootstrap"]

  tenancy_ocid              = var.tenancy_ocid
  region                    = var.region
  project                   = var.project
  state_namespace           = var.state_namespace
  state_bucket              = var.state_bucket
  free_tier_limits          = var.free_tier_limits
  availability_domain_index = var.availability_domain_index
  freeform_tags             = var.freeform_tags
  settings                  = var.bootstrap
}

# `make seed` creates the state bucket with the oci CLI so the backend exists
# before the first init; this adopts it (import blocks are root-only).
import {
  to = module.bootstrap.oci_objectstorage_bucket.state
  id = "n/${var.state_namespace}/b/${var.state_bucket}"
}
