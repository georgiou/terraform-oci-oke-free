#!/usr/bin/env bash
# Load everything CI needs into the current GitHub repo with the gh CLI.
#
# Required environment:
#   TF_VAR_state_passphrase, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   CI_PLAN_USER_OCID,  CI_PLAN_KEY   (path to the ci-plan user's API private key)
#   CI_APPLY_USER_OCID, CI_APPLY_KEY  (path to the ci-apply user's API private key)
# Optional:
#   AUTO_APPLY=safe|off        auto-apply plans that destroy nothing and don't touch
#                              the cluster, node pool, IAM or quotas (default off)
source "$(dirname "$0")/lib.sh"
need gh "Install the GitHub CLI and run: gh auth login"
need openssl "Needed to compute API key fingerprints."

for v in TF_VAR_state_passphrase AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CI_PLAN_USER_OCID CI_PLAN_KEY CI_APPLY_USER_OCID CI_APPLY_KEY; do
  [ -n "${!v:-}" ] || die "set $v (see the header of scripts/github-setup.sh)"
done
fingerprint() { openssl rsa -pubout -outform DER -in "$1" 2>/dev/null | openssl md5 -c | awk '{print $NF}'; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "Configuring $REPO"
[ "$(gh api "repos/$REPO/branches/main" --jq .protected)" = true ] || die "protect main before enabling deployment CI"

# Repository secrets are available to same-repository branches. Do not add or
# keep deployment secrets there, even when the checked-in PR workflow is dry.
legacy=$(gh secret list --json name --jq '.[].name')
if grep -qE '^(STATE_PASSPHRASE|STATE_S3_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)|OCI_(PLAN|APPLY)_(USER_OCID|FINGERPRINT|KEY_PEM)|TOFU_SETTINGS)$' <<<"$legacy"; then
  die "remove legacy repository-scoped OCI/state secrets before enabling CI; rotate previously exposed credentials"
fi
for env in oci-plan production; do
  path="repos/$REPO/environments/$env"
  restriction=$(gh api "$path" --jq '.deployment_branch_policy.custom_branch_policies == true and .deployment_branch_policy.protected_branches == false') ||
    die "create the $env environment in GitHub and restrict it to branch main first"
  [ "$restriction" = true ] || die "enable selected deployment branches for $env"
  policies=$(gh api "$path/deployment-branch-policies" --jq '.branch_policies | map([.type,.name] | join(":")) | join(",")')
  [ "$policies" = branch:main ] || die "restrict $env to exactly the main deployment branch before enabling CI"
done
if [ "${AUTO_APPLY:-off}" = safe ]; then
  gh api "repos/$REPO/environments/production" --jq '[.protection_rules[]? | select(.type == "required_reviewers")] | length' | grep -qx '[1-9][0-9]*' \
    || die "AUTO_APPLY=safe requires reviewers on the production environment"
fi
secret() { printf '%s' "$3" | gh secret set "$2" --env "$1"; }
for env in oci-plan production; do
  if git -C "$ROOT" check-ignore -q config/settings.tfvars; then
    gh secret set TOFU_SETTINGS --env "$env" < "$SETTINGS"
  else
    git -C "$ROOT" ls-files --error-unmatch config/settings.tfvars >/dev/null 2>&1 \
      || die "commit config/settings.tfvars or gitignore it before enabling CI"
  fi
  secret "$env" STATE_PASSPHRASE "${TF_VAR_state_passphrase:?}"
  secret "$env" STATE_S3_ACCESS_KEY_ID "$AWS_ACCESS_KEY_ID"
  secret "$env" STATE_S3_SECRET_ACCESS_KEY "$AWS_SECRET_ACCESS_KEY"
done
secret oci-plan OCI_PLAN_USER_OCID "$CI_PLAN_USER_OCID"
secret oci-plan OCI_PLAN_FINGERPRINT "$(fingerprint "$CI_PLAN_KEY")"
gh secret set OCI_PLAN_KEY_PEM --env oci-plan < "$CI_PLAN_KEY"
secret production OCI_APPLY_USER_OCID "$CI_APPLY_USER_OCID"
secret production OCI_APPLY_FINGERPRINT "$(fingerprint "$CI_APPLY_KEY")"
gh secret set OCI_APPLY_KEY_PEM --env production < "$CI_APPLY_KEY"
gh variable set OCI_TENANCY_OCID --body "$(setting tenancy_ocid)"
gh variable set OCI_REGION --body "$(setting region)"
gh variable set AUTO_APPLY --body "${AUTO_APPLY:-off}"
gh variable set OCI_CI_ENABLED --body true

green "Done. Push to main (or dispatch tofu on main) to plan."
