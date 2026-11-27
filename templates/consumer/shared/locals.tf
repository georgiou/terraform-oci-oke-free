# Symlinked into both roots.
locals {
  # Library module address for a given module name.
  module_source = {
    for m in ["bootstrap", "cluster"] :
    m => var.module_ref == "" ? "${var.modules_source}/${m}" : "${var.modules_source}/${m}?ref=${var.module_ref}"
  }

  # OCI Object Storage through its S3-compatible API (OpenTofu has no native
  # oci backend). Credentials: a Customer Secret Key exported as
  # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
  state_backend = {
    bucket                      = var.state_bucket
    region                      = var.region
    endpoints                   = { s3 = "https://${var.state_namespace}.compat.objectstorage.${var.region}.oci.customer-oci.com" }
    use_path_style              = true
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
