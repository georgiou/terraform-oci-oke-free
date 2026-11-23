terraform {
  backend "s3" {
    key = "bootstrap/tofu.tfstate"

    bucket                      = local.state_backend.bucket
    region                      = local.state_backend.region
    endpoints                   = local.state_backend.endpoints
    use_path_style              = local.state_backend.use_path_style
    skip_region_validation      = local.state_backend.skip_region_validation
    skip_credentials_validation = local.state_backend.skip_credentials_validation
    skip_requesting_account_id  = local.state_backend.skip_requesting_account_id
    skip_metadata_api_check     = local.state_backend.skip_metadata_api_check
    skip_s3_checksum            = local.state_backend.skip_s3_checksum
    use_lockfile                = true
  }
}
