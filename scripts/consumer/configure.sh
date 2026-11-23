#!/usr/bin/env bash
# Create config/settings.tfvars from the example, filling in tenancy,
# namespace, HOME region and alert email from your OCI CLI profile.
# Never overwrites. The result holds no secrets: commit it.
source "$(dirname "$0")/lib.sh"
need oci "Install the OCI CLI: https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm"

PROFILE="${OCI_PROFILE:-DEFAULT}"
if [ -f "$SETTINGS" ]; then
  warn "config/settings.tfvars already exists; not touching it."
  exit 0
fi

TENANCY="$(oci_config_value "$PROFILE" tenancy)"
[ -n "$TENANCY" ] || die "no tenancy in profile [$PROFILE] of ~/.oci/config (run: oci setup config)"

echo "Profile [$PROFILE], tenancy $TENANCY"
NS="$(oci os ns get --profile "$PROFILE" --query data --raw-output)" || die "OCI CLI call failed: check the profile works (oci os ns get)"
HOME_REGION="$(oci iam region-subscription list --profile "$PROFILE" --tenancy-id "$TENANCY" \
  --query 'data[?"is-home-region"]."region-name" | [0]' --raw-output)"
[ -n "$HOME_REGION" ] || die "could not determine the home region"

EMAIL="${ALERT_EMAIL:-}"
if [ -z "$EMAIL" ] && [ -t 0 ]; then read -rp "Email for budget/egress/drift alerts: " EMAIL; fi
[ -n "$EMAIL" ] || EMAIL="you@example.com"

mkdir -p "$ROOT/config"
sed -E \
  -e "s#^tenancy_ocid[[:space:]]*=.*#tenancy_ocid    = \"$TENANCY\"#" \
  -e "s#^region[[:space:]]*=.*#region          = \"$HOME_REGION\" \# home region (detected)#" \
  -e "s#^oci_profile[[:space:]]*=.*#oci_profile     = \"$PROFILE\"#" \
  -e "s#^state_namespace[[:space:]]*=.*#state_namespace = \"$NS\"#" \
  -e "s#^([[:space:]]*)budget_alert_emails[[:space:]]*=.*#\1budget_alert_emails = [\"$EMAIL\"]#" \
  "$ROOT/config/settings.tfvars.example" > "$SETTINGS"

green "Wrote config/settings.tfvars (home region: $HOME_REGION, namespace: $NS)."
echo "Review the cluster section (access mode), commit the file, then: make doctor"
