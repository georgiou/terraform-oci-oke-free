#!/usr/bin/env bash
# Preflight checks. Exits non-zero if anything blocking is wrong.
source "$(dirname "$0")/lib.sh"
fail=0
ok()   { green "  ok    $*"; }
bad()  { red   "  FAIL  $*"; fail=1; }
meh()  { warn  "  warn  $*"; }

echo "Tools"
if ! command -v "${TOFU:-tofu}" >/dev/null; then
  bad "tofu not installed"
else
  want=$(<"$ROOT/.opentofu-version")
  if version_json=$("${TOFU:-tofu}" version -json); then
    have=$(sed -nE 's/.*"terraform_version": *"([^"]+)".*/\1/p' <<<"$version_json")
    if python3 - "$have" "$want" <<'PY'
import re
import sys

def version(raw):
    fields = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:\+.*)?", raw)
    return tuple(map(int, fields.groups())) if fields else ()

sys.exit(not (version(sys.argv[2]) and version(sys.argv[1]) >= version(sys.argv[2])))
PY
    then ok "tofu $have"
    else bad "need tofu $want or newer (found ${have:-unknown})"; fi
  else bad "could not execute tofu version"; fi
fi
command -v oci >/dev/null && ok "oci CLI" || bad "oci CLI not installed"
command -v gh  >/dev/null && ok "gh CLI (for make github-setup)" || meh "gh CLI not installed (only needed for make github-setup)"
links_ok=true
for stack in bootstrap cluster; do
  for f in encryption locals providers variables versions; do
    link="$ROOT/stacks/$stack/_$f.tf"
    if [ ! -L "$link" ] || [ ! -f "$link" ] || [ "$(readlink "$link")" != "../../shared/$f.tf" ]; then
      bad "broken or unexpected stack link: stacks/$stack/_$f.tf"
      links_ok=false
    fi
  done
done
if [ "$links_ok" = true ]; then ok "symlinks intact"; fi

echo "Config"
if [ -f "$SETTINGS" ]; then
  ok "config/settings.tfvars"
  grep -q 'aaaa\.\.\.' "$SETTINGS" && bad "tenancy_ocid is still the placeholder"
  grep -q 'you@example.com' "$SETTINGS" && bad "budget_alert_emails is still the placeholder"
  grep -q '203.0.113' "$SETTINGS" && meh "api_allowed_cidrs contains the documentation IP 203.0.113.x"
  grep -q 'UPSTREAM_' "$SETTINGS" && bad "modules_source/module_ref still have UPSTREAM_ placeholders (re-scaffold with the library's scripts/new-consumer.sh)"
  grep -qE '^[[:space:]]*state_passphrase' "$SETTINGS" && bad "state_passphrase must not be in settings (use TF_VAR_state_passphrase)"
else bad "config/settings.tfvars missing (make configure)"; fi

echo "Secrets in your shell"
pp="${TF_VAR_state_passphrase:-}"; [ "${#pp}" -ge 16 ] && ok "TF_VAR_state_passphrase" || bad "export TF_VAR_state_passphrase (>= 16 chars, keep it in a password manager)"
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] && ok "state S3 credentials" \
  || meh "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY not set (needed before planning with the state backend)"

if [ -f "$SETTINGS" ] && command -v oci >/dev/null; then
  echo "OCI"
  PROFILE="$(setting oci_profile)"; PROFILE="${PROFILE:-DEFAULT}"
  AUTH="$(oci_auth_mode "$PROFILE" "$(setting oci_auth)")"
  TENANCY="$(setting tenancy_ocid)"; REGION="$(setting region)"; NAMESPACE="$(setting state_namespace)"
  args=(--profile "$PROFILE" --auth "$AUTH" --region "$REGION")
  if ns=$(oci os ns get "${args[@]}" --query data --raw-output 2>/dev/null) && [ -n "$ns" ] && [ "$ns" = "$NAMESPACE" ]; then
    ok "profile [$PROFILE] authenticates to the configured namespace"
  else bad "profile [$PROFILE] cannot access the configured namespace (oci os ns get)"; fi
  HOME_REGION="$(oci iam region-subscription list "${args[@]}" --tenancy-id "$TENANCY" \
    --query 'data[?"is-home-region"]."region-name" | [0]' --raw-output 2>/dev/null || true)"
  if [ -z "$HOME_REGION" ]; then bad "could not verify the tenancy home region"
  elif [ "$HOME_REGION" = "$REGION" ]; then ok "region $REGION is the home region"
  else bad "region $REGION is not the home region ($HOME_REGION)"; fi
fi

echo "Repo"
missing=0; for s in "$ROOT"/stacks/*/; do [ -f "$s.terraform.lock.hcl" ] || missing=1; done
[ $missing -eq 0 ] && ok "lock files present" || meh "lock files missing (make lock, then commit) - CI requires them"
ref="$(setting module_ref)"
case "$ref" in
  v[0-9]*) ok "library channel: release $ref (Renovate keeps it current)";;
  "")      meh "module_ref is empty: local-path development mode";;
  *)       meh "library channel: tracking '$ref' (CI pins each run to a commit)";;
esac

[ $fail -eq 0 ] && green "All blocking checks passed." || { red "Fix the FAIL items above."; exit 1; }
