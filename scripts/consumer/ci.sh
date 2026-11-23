#!/usr/bin/env bash
# Portable CI driver for a consumer repo. Every CI (GitHub, GitLab, Forgejo,
# Woodpecker, cron) calls this through `make ci-<mode>`; only artifact storage,
# approval gates and notifications differ per CI.
#
#   ci.sh check              fmt, lock files, repo hygiene (no credentials)
#   ci.sh plan               plan STACK; writes $CI_DIR/{tfplan,module_ref,result.env,summary.md}
#   ci.sh apply [--if-safe]  apply $CI_DIR/tfplan from an earlier plan, with the same library ref;
#                            --if-safe skips (exit 0) unless the plan was classified safe
#   ci.sh drift              plan without artifacts; exit 2 if live infrastructure differs
#
# Never prints plan/apply output or values (logs may be public): resource
# addresses and counts only, plus error messages on failure.
#
# Environment:
#   TF_VAR_state_passphrase, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   state access (required)
#   OCI identity, either:
#     - an existing ~/.oci/config profile (oci_profile in settings), or
#     - OCI_TENANCY_OCID + OCI_REGION plus, per mode,
#       plan/drift: OCI_PLAN_USER_OCID, OCI_PLAN_FINGERPRINT, OCI_PLAN_KEY_PEM
#       apply:      OCI_APPLY_USER_OCID, OCI_APPLY_FINGERPRINT, OCI_APPLY_KEY_PEM
#     (written to a throwaway HOME; your real ~/.oci is never touched)
#   TOFU_SETTINGS   settings file contents, if config/settings.tfvars isn't committed
#   STACK           root under stacks/ (default: cluster)
#   CI_DIR          working/artifact directory (default: .ci)
#   CI=true         set by most CI systems: enables -lockfile=readonly
#   EXPECT_CHANGES_SHA256  apply only if the plan's change list (addresses + actions)
#                   hashes to this value: approval for CIs that re-plan in the apply
#                   run instead of passing the plan file along (Forgejo, Woodpecker)
set -euo pipefail

# The library (and this file) may be re-downloaded by `tofu init` mid-run, so
# run from a private copy.
if [ -z "${_CI_SH_COPY:-}" ]; then
  copy="$(mktemp)"; cp "$0" "$copy"; chmod +x "$copy"
  export _CI_SH_ORIG="$0"
  _CI_SH_COPY=1 exec "$copy" "$@"
fi

mode="${1:-}"; flag="${2:-}"
STACK="${STACK:-cluster}"
CI_DIR="${CI_DIR:-.ci}"
ROOT="${CONSUMER_ROOT:-$PWD}"
cd "$ROOT"
DIR="stacks/$STACK"
SETTINGS="$ROOT/config/settings.tfvars"
mkdir -p "$CI_DIR"
TOFU_HOME=""; PROFILE_ARGS=()
# A throwaway HOME (CI identity) must still see your tofu CLI config.
if [ -z "${TF_CLI_CONFIG_FILE:-}" ]; then
  for f in "$HOME/.tofurc" "$HOME/.terraformrc"; do [ -f "$f" ] && { export TF_CLI_CONFIG_FILE="$f"; break; }; done
fi

err()  { echo "::error::$*" >&2; echo "error: $*" >&2; }
fail() { err "$*"; exit 1; }
show_errors() { sed -n '/Error/,$p' "$1" | head -n 40 >&2; }

settings_value() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\\1/p" "$SETTINGS" | head -n1; }

materialise_settings() {
  if [ ! -f "$SETTINGS" ]; then
    [ -n "${TOFU_SETTINGS:-}" ] || fail "no config/settings.tfvars and no TOFU_SETTINGS"
    printf '%s\n' "$TOFU_SETTINGS" > "$SETTINGS"
  fi
}

# Sets TOFU_ENV (env prefix) and PROFILE_ARGS for tofu calls.
setup_identity() { # plan|apply
  local p; p=$(tr '[:lower:]' '[:upper:]' <<<"$1")
  local user_var="OCI_${p}_USER_OCID" fpr_var="OCI_${p}_FINGERPRINT" key_var="OCI_${p}_KEY_PEM"
  TOFU_HOME=""; PROFILE_ARGS=()
  if [ -n "${!user_var:-}" ]; then
    for v in "$fpr_var" "$key_var" OCI_TENANCY_OCID OCI_REGION; do
      [ -n "${!v:-}" ] || fail "$user_var is set but $v is missing"
    done
    TOFU_HOME="$(mktemp -d)"
    install -d -m 700 "$TOFU_HOME/.oci"
    printf '%s\n' "${!key_var}" > "$TOFU_HOME/.oci/key.pem"; chmod 600 "$TOFU_HOME/.oci/key.pem"
    printf '[DEFAULT]\nuser=%s\nfingerprint=%s\ntenancy=%s\nregion=%s\nkey_file=%s\n' \
      "${!user_var}" "${!fpr_var}" "$OCI_TENANCY_OCID" "$OCI_REGION" "$TOFU_HOME/.oci/key.pem" > "$TOFU_HOME/.oci/config"
    chmod 600 "$TOFU_HOME/.oci/config"
    PROFILE_ARGS=(-var "oci_profile=DEFAULT")
  fi
}

tofu_() { # runs tofu with the CI identity's HOME if one was set up
  if [ -n "$TOFU_HOME" ]; then HOME="$TOFU_HOME" tofu "$@"; else tofu "$@"; fi
}

require_state_env() {
  local pp="${TF_VAR_state_passphrase:-}"
  [ "${#pp}" -ge 16 ] || fail "TF_VAR_state_passphrase missing or shorter than 16 characters"
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || fail "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (state Customer Secret Key) missing"
}

# Release tags and SHAs pass through; a branch (tracking channel) is pinned to
# its current commit once, here, and recorded for the apply step.
resolve_ref() {
  local src ref url pinned
  src="$(settings_value modules_source)"; ref="$(settings_value module_ref)"
  if [[ -z "$ref" || "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    pinned="$ref"
  else
    url=$(sed -E 's#^git::##; s#(\.git)//.*$#\1#' <<<"$src")
    pinned=$(git ls-remote "$url" "refs/heads/$ref" | cut -f1)
    [ -n "$pinned" ] || fail "module_ref '$ref' not found in $url"
  fi
  printf '%s\n' "$pinned" > "$CI_DIR/module_ref"
  echo "library: ${ref:-local} -> ${pinned:-local}"
}

init_stack() { # ref
  local args=(-chdir="$DIR" init -upgrade -input=false -var-file="$SETTINGS" -var "module_ref=$1" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"})
  [ "${CI:-}" = true ] && args+=(-lockfile=readonly)
  tofu_ "${args[@]}" > "$CI_DIR/init.log" 2>&1 || { err "init failed for $STACK"; show_errors "$CI_DIR/init.log"; exit 1; }
}

do_plan() { # keep_artifacts: yes|no
  local keep="$1" ref rc deletes sensitive n
  require_state_env; materialise_settings; setup_identity plan
  resolve_ref; ref="$(cat "$CI_DIR/module_ref")"
  init_stack "$ref"
  set +e
  tofu_ -chdir="$DIR" plan -no-color -input=false -var-file="$SETTINGS" -var "module_ref=$ref" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} \
    -out=tfplan -detailed-exitcode > "$CI_DIR/plan.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 1 ]; then err "plan failed for $STACK"; show_errors "$CI_DIR/plan.log"; rm -f "$CI_DIR/plan.log"; exit 1; fi
  rm -f "$CI_DIR/plan.log"

  tofu_ -chdir="$DIR" show -json tfplan > "$CI_DIR/plan.json"
  jq -r '.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
         | "\(.change.actions | join("+"))  \(.address)"' "$CI_DIR/plan.json" > "$CI_DIR/changes.txt"
  deletes=$(jq '[.resource_changes[]? | select(.change.actions | index("delete"))] | length' "$CI_DIR/plan.json")
  # Cluster/node-pool (Kubernetes upgrades, node cycling), IAM and quota changes
  # never count as safe, even in place.
  sensitive=$(jq '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
             | select(.type | test("^oci_(containerengine_(cluster|node_pool)|identity_|limits_quota)"))] | length' "$CI_DIR/plan.json")
  rm -f "$CI_DIR/plan.json"   # holds values, including variables: never keep it

  CHANGES=$([ "$rc" -eq 2 ] && echo true || echo false)
  SAFE=$([ "$deletes" -eq 0 ] && [ "$sensitive" -eq 0 ] && echo true || echo false)
  CHANGES_SHA=$(sha256sum "$CI_DIR/changes.txt" | cut -d' ' -f1)
  printf 'CHANGES=%s\nSAFE=%s\nSTACK=%s\nMODULE_REF=%s\nCHANGES_SHA256=%s\n' "$CHANGES" "$SAFE" "$STACK" "$ref" "$CHANGES_SHA" > "$CI_DIR/result.env"
  n=$(wc -l < "$CI_DIR/changes.txt" | tr -d ' ')
  {
    echo "### $STACK (library ${ref:-local})"
    if [ "$CHANGES" = false ]; then echo "No changes."
    else
      echo "$n resource change(s); destroys/replacements: $deletes; cluster/IAM/quota changes: $sensitive; safe: $SAFE"
      echo '```'; cat "$CI_DIR/changes.txt"; echo '```'
      echo "plan sha256: \`$(sha256sum "$DIR/tfplan" | cut -d' ' -f1)\`"
      echo "changes sha256: \`$CHANGES_SHA\` (approve a re-planned apply with EXPECT_CHANGES_SHA256)"
    fi
  } > "$CI_DIR/summary.md"
  cat "$CI_DIR/summary.md"

  if [ "$keep" = yes ] && [ "$CHANGES" = true ]; then cp "$DIR/tfplan" "$CI_DIR/tfplan"; else rm -f "$CI_DIR/tfplan"; fi
  rm -f "$DIR/tfplan"
}

case "$mode" in
  check)
    tofu fmt -recursive -check -diff || fail "tofu fmt needed"
    for s in stacks/*/; do
      [ -f "$s.terraform.lock.hcl" ] || fail "missing $s.terraform.lock.hcl (run make lock and commit)"
    done
    if git rev-parse --git-dir >/dev/null 2>&1; then
      bad=$(git ls-files '*.pem' '*.key' '*.tfstate' '*.tfstate.*' '*tfplan' '.ci/*')
      [ -z "$bad" ] || fail "keys/state/plans committed: $bad"
    fi
    if [ -f "$SETTINGS" ] && grep -qE '^[[:space:]]*state_passphrase[[:space:]]*=' "$SETTINGS"; then
      fail "state_passphrase must never be in config/settings.tfvars"
    fi
    echo "checks passed"
    ;;

  plan)  do_plan yes ;;

  drift)
    do_plan no
    # shellcheck disable=SC1091
    . "$CI_DIR/result.env"
    [ "$CHANGES" = true ] && { echo "drift: $STACK differs from configuration"; exit 2; }
    echo "no drift"
    ;;

  apply)
    [ -f "$CI_DIR/tfplan" ] && [ -f "$CI_DIR/module_ref" ] || fail "no saved plan in $CI_DIR (run the plan job and pass its artifacts)"
    if [ "$flag" = --if-safe ]; then
      [ -f "$CI_DIR/result.env" ] || fail "no $CI_DIR/result.env from the plan job"
      # shellcheck disable=SC1091
      . "$CI_DIR/result.env"
      if [ "$SAFE" != true ]; then echo "plan not classified safe: waiting for a manual apply"; exit 0; fi
    fi
    if [ -n "${EXPECT_CHANGES_SHA256:-}" ]; then
      got=$(sed -n 's/^CHANGES_SHA256=//p' "$CI_DIR/result.env" 2>/dev/null)
      [ "$got" = "$EXPECT_CHANGES_SHA256" ] || fail "plan changed since you approved it (expected changes $EXPECT_CHANGES_SHA256, got ${got:-none}): review the new plan"
      echo "change list matches the approved one"
    fi
    require_state_env; materialise_settings; setup_identity apply
    ref="$(cat "$CI_DIR/module_ref")"
    init_stack "$ref"
    cp "$CI_DIR/tfplan" "$DIR/tfplan"
    echo "applying plan sha256 $(sha256sum "$DIR/tfplan" | cut -d' ' -f1), library ${ref:-local}"
    # OpenTofu refuses a stale plan (state changed since planning).
    if tofu_ -chdir="$DIR" apply -no-color -input=false tfplan > "$CI_DIR/apply.log" 2>&1; then
      grep -E '^Apply complete' "$CI_DIR/apply.log" || true
      rm -f "$CI_DIR/apply.log" "$DIR/tfplan"
      echo "APPLIED=true" >> "$CI_DIR/result.env"
    else
      err "apply failed for $STACK (a stale plan means state changed since planning: plan again)"
      show_errors "$CI_DIR/apply.log"; rm -f "$CI_DIR/apply.log" "$DIR/tfplan"
      exit 1
    fi
    ;;

  *) sed -n '2,24p' "${_CI_SH_ORIG:-$0}"; exit 64 ;;
esac
