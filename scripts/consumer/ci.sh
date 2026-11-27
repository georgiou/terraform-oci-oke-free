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
# Never prints raw plan/apply output or diagnostics (logs may be public).
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
#   EXPECT_CHANGES_SHA256  obsolete approval for re-planned applies; rejected
set -euo pipefail

# The library (and this file) may be re-downloaded by `tofu init` mid-run, so
# run from a private copy.
if [ -z "${_CI_SH_COPY:-}" ]; then
  copy="$(mktemp)"; cp "$0" "$copy"; chmod +x "$copy"
  export _CI_SH_ORIG="$0"
  _CI_SH_COPY=1 _CI_SH_TMP="$copy" exec "$copy" "$@"
fi

mode="${1:-}"; flag="${2:-}"
STACK="${STACK:-cluster}"
CI_DIR="${CI_DIR:-.ci}"
ROOT="${CONSUMER_ROOT:-$PWD}"
cd "$ROOT"
DIR="stacks/$STACK"
SETTINGS="$ROOT/config/settings.tfvars"
umask 077
mkdir -p "$CI_DIR"
TOFU_HOME=""; WORK=""; PROFILE_ARGS=()
cleanup() {
  [ -z "$TOFU_HOME" ] || rm -rf -- "$TOFU_HOME"
  [ -z "$WORK" ] || rm -rf -- "$WORK"
  [ -z "${_CI_SH_TMP:-}" ] || rm -f -- "$_CI_SH_TMP"
}
trap cleanup EXIT
# A throwaway HOME (CI identity) must still see your tofu CLI config.
if [ -z "${TF_CLI_CONFIG_FILE:-}" ]; then
  for f in "$HOME/.tofurc" "$HOME/.terraformrc"; do [ -f "$f" ] && { export TF_CLI_CONFIG_FILE="$f"; break; }; done
fi

err()  { echo "::error::$*" >&2; echo "error: $*" >&2; }
fail() { err "$*"; exit 1; }
case "$mode" in
  plan|apply|drift)
    [[ "$STACK" =~ ^[a-zA-Z0-9_-]+$ && "$STACK" != bootstrap ]] || fail "invalid CI stack (bootstrap is local-only)"
    [ -z "${EXPECT_CHANGES_SHA256:-}" ] || fail "change-list hashes do not authorize re-plans; pass the exact saved plan"
    [[ "$CI_DIR" = /* ]] || CI_DIR="$ROOT/$CI_DIR"
    WORK=$(mktemp -d "$CI_DIR/.work.XXXXXX")
    ;;
esac

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
    PROFILE_ARGS=(-var "oci_profile=DEFAULT" -var "oci_auth=ApiKey")
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

library_head() {
  [ -n "${CONSUMER_LIB:-}" ] && [ -e "$CONSUMER_LIB/.git" ] && git -C "$CONSUMER_LIB" rev-parse HEAD
}

# Pin the checkout already supplying this driver, not a second read of the
# branch which could have advanced between the Makefile include and plan.
resolve_ref() {
  local src ref url pinned
  src="$(settings_value modules_source)"; ref="$(settings_value module_ref)"
  if [[ -z "$ref" || "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    pinned="$ref"
  elif [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pinned=$(library_head || printf '%s\n' "$ref")
  else
    url=$(sed -E 's#^git::##; s#(\.git)//.*$#\1#' <<<"$src")
    pinned=$(library_head || true)
    if [ -z "$pinned" ]; then pinned=$(git ls-remote "$url" "refs/heads/$ref" | cut -f1); fi
    [[ "$pinned" =~ ^[0-9a-f]{40}$ ]] || fail "module_ref '$ref' could not be resolved in $url"
  fi
  printf '%s\n' "$pinned" > "$CI_DIR/module_ref"
  echo "library: ${ref:-local} -> ${pinned:-local}"
}

init_stack() { # ref
  local args=(-chdir="$DIR" init -input=false -var-file="$SETTINGS" -var "module_ref=$1" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"})
  if [ "${CI:-}" = true ]; then
    # OpenTofu rejects -upgrade together with a read-only lockfile.
    args+=(-lockfile=readonly)
  fi
  tofu_ "${args[@]}" > /dev/null 2>&1 || fail "init failed for $STACK; check backend access and provider lockfiles"
}

do_plan() { # keep_artifacts: yes|no
  local keep="$1" ref rc deletes sensitive n summary
  rm -f "$CI_DIR/tfplan" "$CI_DIR/module_ref" "$CI_DIR/result.env" "$CI_DIR/summary.md" "$CI_DIR/changes.txt"
  require_state_env; materialise_settings; setup_identity plan
  resolve_ref; ref="$(cat "$CI_DIR/module_ref")"
  init_stack "$ref"
  set +e
  tofu_ -chdir="$DIR" plan -no-color -input=false -var-file="$SETTINGS" -var "module_ref=$ref" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} \
    -out="$WORK/tfplan" -detailed-exitcode > /dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || fail "plan failed for $STACK; inspect locally with the same settings"

  # Parse in memory; the decrypted plan never lands on disk. Diagnostics can
  # contain values, so neither Show nor jq writes to CI stderr.
  summary=$(tofu_ -chdir="$DIR" show -json -var-file="$SETTINGS" -var "module_ref=$ref" "$WORK/tfplan" 2>/dev/null |
    jq -ce '
      [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])]
      | {changes: map("\(.change.actions | join("+"))  \(.address)"),
         creates_cluster: any(.[]; .type == "oci_containerengine_cluster" and (.change.actions | contains(["create"]))),
         deletes: (map(select(.change.actions | index("delete"))) | length),
         sensitive: (map(select(.type | test("^oci_(containerengine_(cluster|node_pool)|identity_|limits_quota)"))) | length)}' 2>/dev/null) ||
    fail "could not summarize the saved plan for $STACK"
  if [ "$keep" = yes ] && jq -e .creates_cluster <<<"$summary" >/dev/null; then
    fail "initial cluster creation or replacement must be planned locally (make plan-cluster)"
  fi
  jq -r '.changes[]' <<<"$summary" > "$CI_DIR/changes.txt"
  deletes=$(jq -r .deletes <<<"$summary")
  sensitive=$(jq -r .sensitive <<<"$summary")

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
      echo "plan sha256: \`$(sha256sum "$WORK/tfplan" | cut -d' ' -f1)\`"
      echo "change list sha256: \`$CHANGES_SHA\` (summary checksum only)"
    fi
  } > "$CI_DIR/summary.md"
  cat "$CI_DIR/summary.md"

  if [ "$keep" = yes ] && [ "$CHANGES" = true ]; then mv "$WORK/tfplan" "$CI_DIR/tfplan"; fi
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
    grep -qx 'CHANGES=true' "$CI_DIR/result.env" && { echo "drift: $STACK differs from configuration"; exit 2; }
    echo "no drift"
    ;;

  apply)
    [ -f "$CI_DIR/tfplan" ] && [ -f "$CI_DIR/module_ref" ] || fail "no saved plan in $CI_DIR (run the plan job and pass its artifacts)"
    if [ "$flag" = --if-safe ]; then
      [ -f "$CI_DIR/result.env" ] || fail "no $CI_DIR/result.env from the plan job"
      if ! grep -qx 'SAFE=true' "$CI_DIR/result.env"; then echo "plan not classified safe: waiting for a manual apply"; exit 0; fi
    fi
    require_state_env; materialise_settings; setup_identity apply
    ref="$(cat "$CI_DIR/module_ref")"
    if [[ "${CI:-}" = true && "$ref" =~ ^[0-9a-f]{40}$ ]] && [ "$(library_head || true)" != "$ref" ]; then
      fail "loaded tooling does not match the plan; fetch with LIB_REF from the saved plan before apply"
    fi
    init_stack "$ref"
    echo "applying plan sha256 $(sha256sum "$CI_DIR/tfplan" | cut -d' ' -f1), library ${ref:-local}"
    if tofu_ -chdir="$DIR" apply -no-color -input=false "$CI_DIR/tfplan" > "$WORK/apply.log" 2>&1; then
      echo "Apply complete for $STACK."
      echo "APPLIED=true" >> "$CI_DIR/result.env"
    elif grep -q '^Error: Saved plan is stale' "$WORK/apply.log"; then
      fail 'Saved plan is stale; make a new plan and review it'
    else
      fail "apply failed for $STACK; inspect locally and re-plan from current state"
    fi
    ;;

  *) sed -n '2,24p' "${_CI_SH_ORIG:-$0}"; exit 64 ;;
esac
