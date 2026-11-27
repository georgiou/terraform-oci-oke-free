#!/usr/bin/env bash
# Local-only guided setup. No credentials are persisted by this script.
# Reject tracing before sourcing code that can handle credentials.
case $- in *x*) printf '%s\n' 'Turn off shell tracing before loading credentials.' >&2; exit 1 ;; esac
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/state-keys.sh"
cd "$ROOT" || exit 1
[ "${CI:-}" != true ] || die "this command must be run locally"
mode=${1:-}
case "$mode" in plan|apply|credentials|session) ;; *) die "expected plan, apply, credentials or session" ;; esac
# Invalidate the previous plan before checking tools, settings or the passphrase.
if [ "$mode" = plan ]; then rm -f stacks/bootstrap/{tfplan,pending.tfplan}; fi
need "${TOFU:-tofu}" "Install OpenTofu."
need oci "Install OCI CLI and sign in before starting."
need jq "Install jq to process OCI responses."
make_cmd=${CONSUMER_MAKE:-make}
tofu_cmd=${TOFU:-tofu}


confirm() {
  local answer
  [ -t 0 ] || die "$1 (requires an interactive terminal)"
  read -rp "$1 [y/N] " answer || return 1
  [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}
passphrase() {
  if [ -z "${TF_VAR_state_passphrase:-}" ]; then
    [ -t 0 ] || die "export TF_VAR_state_passphrase from your password manager"
    IFS= read -rsp 'OpenTofu passphrase from your password manager (create one if new): ' TF_VAR_state_passphrase
    printf '\n' >&2
    export TF_VAR_state_passphrase
  fi
  [ "${#TF_VAR_state_passphrase}" -ge 16 ] || die "state passphrase must be at least 16 characters"
}
load_keys() {
  if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    [ -t 0 ] || die "export OCI state credentials before running non-interactively"
    prompt_state_keys
  fi
  unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
}
handoff() {
  local new_access new_secret actual_access actual_secret
  confirm 'Set up and save the dedicated state key now? The new pair will be displayed once in this terminal' || {
    echo 'Run make state-credentials when ready (no bootstrap reapply needed).'
    return 0
  }
  setup_dedicated_state_user || return 1
  new_access=$AWS_ACCESS_KEY_ID; new_secret=$AWS_SECRET_ACCESS_KEY
  echo 'Save the displayed pair in your password manager, then paste it back to verify you can reload it.'
  IFS= read -rsp 'Saved Access Key: ' actual_access; printf '\n' >&2
  IFS= read -rsp 'Saved Secret Key: ' actual_secret; printf '\n' >&2
  [ "$actual_access" = "$new_access" ] && [ "$actual_secret" = "$new_secret" ] ||
    die "the pasted pair did not match; keep the temporary bootstrap key and correct the saved pair"
  echo 'Dedicated key verified and reloaded. Verify the state lock with a plan before revoking the temporary bootstrap key.'
  echo 'Next: make plan-cluster, then make apply-cluster after review.'
}

if [ "$mode" = plan ] && [ ! -f "$SETTINGS" ]; then
  if [ -t 0 ] && [ -z "${OCI_PROFILE:-}" ]; then
    read -rp 'OCI config profile [DEFAULT]: ' OCI_PROFILE
    export OCI_PROFILE=${OCI_PROFILE:-DEFAULT}
  fi
  "$make_cmd" configure
fi
[ -f "$SETTINGS" ] || die "start with make bootstrap-plan"
passphrase
case "$mode" in
  plan)
    "$make_cmd" doctor
    confirm 'Prepare the configured bucket and create a bootstrap plan?' || die 'cancelled'
    "$make_cmd" seed
    if { [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; } && [ -t 0 ] && [ -t 1 ]; then
      # A declined offer falls through to the existing-key prompt.
      create_temporary_state_key
    fi
    load_keys
    "$make_cmd" plan-bootstrap
    echo 'Review the saved plan above. When ready, run make bootstrap-apply.'
    ;;
  apply)
    [ -s stacks/bootstrap/tfplan ] || die 'no saved bootstrap plan; run make bootstrap-plan first'
    load_keys
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    cp stacks/bootstrap/tfplan "$work/tfplan"
    "$tofu_cmd" -chdir=stacks/bootstrap show -var-file="$SETTINGS" "$work/tfplan"
    confirm 'Apply this exact saved bootstrap plan?' || die 'cancelled'
    "$tofu_cmd" -chdir=stacks/bootstrap apply "$work/tfplan"
    if cmp -s "$work/tfplan" stacks/bootstrap/tfplan; then rm -f stacks/bootstrap/tfplan; fi
    handoff
    ;;
  credentials)
    load_keys
    "$make_cmd" init-bootstrap
    handoff
    ;;
  session)
    [ -t 0 ] && [ -t 1 ] || die 'make session requires an interactive terminal'
    load_keys
    profile=$(setting oci_profile)
    OCI_CLI_AUTH=$(oci_auth_mode "${profile:-DEFAULT}" "$(setting oci_auth)")
    export OCI_CLI_AUTH
    "$make_cmd" init-bootstrap
    "$tofu_cmd" -chdir=stacks/bootstrap output -var-file="$SETTINGS" -raw state_access_group >/dev/null
    echo 'State credentials verified. Run make plan-cluster; exit this shell when done.'
    exec "${OKE_SHELL:-${SHELL:-/bin/bash}}" -i
    ;;
esac
