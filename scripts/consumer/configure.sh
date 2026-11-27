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

AUTH=$(oci_auth_mode "$PROFILE")
case "$AUTH" in
  security_token) TOFU_AUTH=SecurityToken ;;
  api_key) TOFU_AUTH=ApiKey ;;
  *) die "make configure needs an OCI CLI API-key or session-token profile" ;;
esac
TENANCY="$(oci_config_value "$PROFILE" tenancy)"
[ -n "$TENANCY" ] || die "no tenancy in profile [$PROFILE] of ~/.oci/config (run: oci setup config)"

echo "Profile [$PROFILE], tenancy $TENANCY"
HOME_REGION="$(oci iam region-subscription list --profile "$PROFILE" --auth "$AUTH" --tenancy-id "$TENANCY" \
  --query 'data[?"is-home-region"]."region-name" | [0]' --raw-output)"
[ -n "$HOME_REGION" ] || die "could not determine the home region"
NS="$(oci os ns get --profile "$PROFILE" --auth "$AUTH" --region "$HOME_REGION" --query data --raw-output)" || die "OCI CLI call failed: check the profile works (oci os ns get)"
[[ "$TENANCY" =~ ^ocid1\.tenancy\.[a-zA-Z0-9.-]+$ && "$PROFILE" =~ ^[a-zA-Z0-9_.-]+$ && "$HOME_REGION" =~ ^[a-z0-9-]+$ && "$NS" =~ ^[a-z0-9-]+$ ]] || die "OCI profile or detected values have an unexpected format"

EMAIL="${ALERT_EMAIL:-}"
if [ -z "$EMAIL" ] && [ -t 0 ]; then read -rp "Email for budget/egress/drift alerts: " EMAIL; fi
[ -n "$EMAIL" ] || EMAIL="you@example.com"
[[ "$EMAIL" =~ ^[a-zA-Z0-9_.+%-]+@[a-zA-Z0-9.-]+$ ]] || die "use a valid budget alert email"
# Unique within the namespace, while remaining stable across retries.
BUCKET="${OKE_STATE_BUCKET:-tofu-state-$NS}"
[[ "$BUCKET" =~ ^[a-zA-Z0-9._-]+$ ]] || die "invalid OKE_STATE_BUCKET"
CIDR=${API_ALLOWED_CIDR:-}
if [ -z "$CIDR" ] && [ -t 0 ]; then read -rp 'Your public IPv4 CIDR for initial Kubernetes access (e.g. your IP/32; Enter to defer): ' CIDR; fi
[[ -z "$CIDR" || "$CIDR" =~ ^[0-9.]+/[0-9]+$ ]] || die "use an IPv4 CIDR, usually your IP/32"
CIDRS='[]'
if [ -n "$CIDR" ]; then CIDRS="[\"$CIDR\"]"; fi

mkdir -p "$ROOT/config"
sed -E \
  -e "s#^tenancy_ocid[[:space:]]*=.*#tenancy_ocid    = \"$TENANCY\"#" \
  -e "s#^region[[:space:]]*=.*#region          = \"$HOME_REGION\" \# home region (detected)#" \
  -e "/^oci_auth[[:space:]]*=/d" \
  -e "s#^oci_profile[[:space:]]*=.*#oci_profile     = \"$PROFILE\"#" \
  -e "/^oci_profile[[:space:]]*=/a\\
oci_auth        = \"$TOFU_AUTH\"" \
  -e "s#^state_namespace[[:space:]]*=.*#state_namespace = \"$NS\"#" \
  -e "s#^state_bucket[[:space:]]*=.*#state_bucket    = \"$BUCKET\"#" \
  -e "s#^([[:space:]]*)budget_alert_emails[[:space:]]*=.*#\1budget_alert_emails = [\"$EMAIL\"]#" \
  -e "s#^([[:space:]]*)api_allowed_cidrs[[:space:]]*=.*#\1api_allowed_cidrs = $CIDRS#" \
  "$ROOT/config/settings.tfvars.example" > "$SETTINGS"

"${TOFU:-tofu}" fmt "$SETTINGS" >/dev/null
green "Wrote config/settings.tfvars (home region: $HOME_REGION, namespace: $NS)."
