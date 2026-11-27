#!/usr/bin/env bash
# Do not save a local plan that would create a public endpoint with no way
# for the operator to reach it. Existing clusters can close their allowlist.
source "$(dirname "$0")/lib.sh"
need jq 'Install jq to check the cluster plan.'
result=$("${TOFU:-tofu}" -chdir="$ROOT/stacks/cluster" show -json -var-file="$SETTINGS" "$1" |
  jq -r '(.variables.cluster.value // {}) as $settings
    | any(.resource_changes[]?; .type == "oci_containerengine_cluster" and
      (.change.actions | contains(["create"])) and
      $settings.api_endpoint_public != false and
      (($settings.api_allowed_cidrs // []) | length == 0))') || die 'could not check the cluster plan for first-login access'
[ "$result" = false ] || die 'creating a public cluster requires cluster.api_allowed_cidrs (start with your IP/32; remove it after Tailscale works)'
