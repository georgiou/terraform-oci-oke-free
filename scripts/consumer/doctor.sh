#!/usr/bin/env bash
# Preflight checks. Exits non-zero if anything blocking is wrong.
source "$(dirname "$0")/lib.sh"
fail=0
ok()   { green "  ok    $*"; }
bad()  { red   "  FAIL  $*"; fail=1; }
meh()  { warn  "  warn  $*"; }

echo "Tools"
if command -v tofu >/dev/null; then
  want="$(cat "$ROOT/.opentofu-version")"; have="$(tofu version -json 2>/dev/null | sed -nE 's/.*"terraform_version": *"([^"]+)".*/\1/p')"
  [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1)" = "$want" ] && ok "tofu $have" || bad "tofu $have < $want (.opentofu-version)"
else bad "tofu not installed"; fi
command -v oci >/dev/null && ok "oci CLI" || bad "oci CLI not installed"
command -v gh  >/dev/null && ok "gh CLI (for make github-setup)" || meh "gh CLI not installed (only needed for make github-setup)"
[ -L "$ROOT/stacks/cluster/_versions.tf" ] && ok "symlinks intact" || bad "stacks/*/_*.tf are not symlinks (on Windows: git config core.symlinks true, re-clone)"

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
  || meh "AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY not set (needed after bootstrap; README -> Bootstrap)"

if [ -f "$SETTINGS" ] && command -v oci >/dev/null; then
  echo "OCI"
  PROFILE="$(setting oci_profile)"; TENANCY="$(setting tenancy_ocid)"; REGION="$(setting region)"
  if oci os ns get --profile "${PROFILE:-DEFAULT}" >/dev/null 2>&1; then ok "profile [$PROFILE] authenticates"
  else bad "profile [$PROFILE] cannot call OCI (oci os ns get)"; fi
  HOME_REGION="$(oci iam region-subscription list --profile "${PROFILE:-DEFAULT}" --tenancy-id "$TENANCY" \
    --query 'data[?"is-home-region"]."region-name" | [0]' --raw-output 2>/dev/null || true)"
  if [ -n "$HOME_REGION" ]; then
    [ "$HOME_REGION" = "$REGION" ] && ok "region $REGION is the home region" || bad "region $REGION is not the home region ($HOME_REGION)"
  fi
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
