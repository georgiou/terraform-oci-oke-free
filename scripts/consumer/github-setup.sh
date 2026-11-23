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

# Repo-level: usable by plan jobs (PRs from this repo, drift checks).
if git -C "$ROOT" check-ignore -q config/settings.tfvars; then
  gh secret set TOFU_SETTINGS < "$SETTINGS"   # you chose to keep settings out of git
else
  git -C "$ROOT" ls-files --error-unmatch config/settings.tfvars >/dev/null 2>&1 \
    || warn "config/settings.tfvars isn't committed yet: commit it (CI reads it from the repo)."
fi
gh secret set STATE_PASSPHRASE          --body "${TF_VAR_state_passphrase:?}"
gh secret set STATE_S3_ACCESS_KEY_ID    --body "$AWS_ACCESS_KEY_ID"
gh secret set STATE_S3_SECRET_ACCESS_KEY --body "$AWS_SECRET_ACCESS_KEY"
gh secret set OCI_PLAN_USER_OCID        --body "$CI_PLAN_USER_OCID"
gh secret set OCI_PLAN_FINGERPRINT      --body "$(fingerprint "$CI_PLAN_KEY")"
gh secret set OCI_PLAN_KEY_PEM          < "$CI_PLAN_KEY"
gh variable set OCI_TENANCY_OCID        --body "$(setting tenancy_ocid)"
gh variable set OCI_REGION              --body "$(setting region)"
gh variable set AUTO_APPLY              --body "${AUTO_APPLY:-off}"

# Environment-level: only jobs in "production" (main branch only) get apply rights.
ME_ID="$(gh api user -q .id)"
cat > /tmp/env.json <<JSON
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true},
 "reviewers":[{"type":"User","id":$ME_ID}]}
JSON
if ! gh api -X PUT "repos/$REPO/environments/production" --input /tmp/env.json >/dev/null 2>&1; then
  warn "Required reviewers aren't available for this repo's plan (private repo on Free/Pro/Team)."
  warn "Creating the environment without them: applies then need AUTO_APPLY=safe or a manual 'apply' run."
  echo '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' > /tmp/env.json
  gh api -X PUT "repos/$REPO/environments/production" --input /tmp/env.json >/dev/null
fi
gh api -X POST "repos/$REPO/environments/production/deployment-branch-policies" -f name=main -f type=branch >/dev/null 2>&1 || true
rm -f /tmp/env.json
gh secret set OCI_APPLY_USER_OCID   --env production --body "$CI_APPLY_USER_OCID"
gh secret set OCI_APPLY_FINGERPRINT --env production --body "$(fingerprint "$CI_APPLY_KEY")"
gh secret set OCI_APPLY_KEY_PEM     --env production < "$CI_APPLY_KEY"

green "Done. Install the Renovate GitHub App on this repo for library updates:"
echo "  https://github.com/apps/renovate"
echo "Then push to main (or run the 'tofu' workflow) to plan."
