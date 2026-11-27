#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
profile=$(setting oci_profile); profile=${profile:-DEFAULT}
auth=$(oci_auth_mode "$profile" "$(setting oci_auth)")
region=$(setting region)
cluster_id=$("${TOFU:-tofu}" -chdir="$ROOT/stacks/cluster" output -var-file="$SETTINGS" -raw cluster_id)
[[ "$cluster_id" == ocid1.cluster.* ]] || die "no cluster in state"
# Existing output records the endpoint choice. Extract only that choice; do
# not execute the shell command stored in state or inherit its CI profile.
command=$("${TOFU:-tofu}" -chdir="$ROOT/stacks/cluster" output -var-file="$SETTINGS" -raw kubeconfig_command)
case "$command" in
  *' --kube-endpoint PRIVATE_ENDPOINT '*) endpoint=PRIVATE_ENDPOINT ;;
  *' --kube-endpoint PUBLIC_ENDPOINT '*) endpoint=PUBLIC_ENDPOINT ;;
  *) die "could not determine the Kubernetes API endpoint from state" ;;
esac
oci ce cluster create-kubeconfig --cluster-id "$cluster_id" --region "$region" \
  --token-version 2.0.0 --kube-endpoint "$endpoint" --file "$HOME/.kube/config" \
  --profile "$profile" --auth "$auth" --with-auth-context
