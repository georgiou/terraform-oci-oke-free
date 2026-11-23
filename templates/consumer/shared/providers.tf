# Symlinked into both roots.
#
# Locally: an API key profile in ~/.oci/config (or `oci session authenticate`
# and oci_auth = "SecurityToken" for short-lived tokens).
# In CI: the workflow writes ~/.oci/config from repository secrets.
provider "oci" {
  region              = var.region
  auth                = var.oci_auth
  config_file_profile = var.oci_profile
}
