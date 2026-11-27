# shellcheck shell=bash
# Private functions for bootstrap-flow.sh. Never write keys to disk.
state_oci_user() { # profile auth
  case "$2" in
    api_key) oci_config_value "$1" user ;;
    security_token)
      # The subject is used only for discovery; OCI authenticates the request.
      python3 - "$(oci_config_value "$1" security_token_file)" <<'PY'
import base64
import json
import pathlib
import re
import sys

try:
    payload = pathlib.Path(sys.argv[1]).expanduser().read_text().strip().split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    user = claims["sub"]
    if isinstance(user, str) and re.fullmatch(r"ocid1\.user\.[A-Za-z0-9._-]+", user):
        print(user)
except (OSError, ValueError, TypeError, KeyError, IndexError):
    pass
PY
      ;;
  esac
}

_oke_oci_list() {
  local response
  # OCI CLI sometimes emits no JSON at all for an empty list.
  response=$(oci "$@" --query 'data || `[]`') || return 1
  jq -ces 'if length == 0 then [] elif length == 1 and (.[0] | type == "array") then .[0] else error("Expected one OCI list response") end' <<<"$response"
}

setup_dedicated_state_user() {
  local profile auth tenancy region namespace live_namespace state_group state_groups group_id user_name description
  local users user_id groups keys email label result access_key secret_key attempt verified read_group
  local -a oci_args

  [ -t 1 ] || { printf '%s\n' 'Credential handoff requires terminal output.' >&2; return 1; }
  profile=$(setting oci_profile); profile=${profile:-DEFAULT}
  auth=$(oci_auth_mode "$profile" "$(setting oci_auth)") || return 1
  tenancy=$(setting tenancy_ocid)
  region=$(setting region)
  namespace=$(setting state_namespace)
  if [[ "$tenancy" != ocid1.tenancy.* ]] || [ -z "$region" ] || [ -z "$namespace" ]; then
    printf '%s\n' 'Set tenancy_ocid, region, and state_namespace in the settings file first.' >&2
    return 1
  fi
  oci_args=(--profile "$profile" --auth "$auth" --region "$region" --output json)
  live_namespace=$(oci os ns get "${oci_args[@]}" --query data --raw-output) || return 1
  if [ "$live_namespace" != "$namespace" ]; then
    printf '%s\n' 'The OCI profile does not match the configured Object Storage namespace.' >&2
    return 1
  fi

  state_group=$("${TOFU:-tofu}" -chdir=stacks/bootstrap output -var-file="$SETTINGS" -raw state_access_group) || return 1
  case "$state_group" in
    ?*-tofu-state) ;;
    *) printf '%s\n' 'Unexpected bootstrap state group; no changes made.' >&2; return 1 ;;
  esac
  state_groups=$(_oke_oci_list iam group list "${oci_args[@]}" --compartment-id "$tenancy" --name "$state_group" --all) || return 1
  group_id=$(jq -er 'if length == 1 then .[0].id | strings | select(startswith("ocid1.group.")) else empty end' <<<"$state_groups") || {
    printf 'Could not find exactly one state group named %s.\n' "$state_group" >&2; return 1;
  }
  user_name="${state_group%-tofu-state}-state"
  description="Managed by oci-oke-free state credential setup for ${state_group}"
  users=$(_oke_oci_list iam user list "${oci_args[@]}" --compartment-id "$tenancy" --name "$user_name" --all) || return 1
  user_id=$(jq -er 'if length == 0 then "" elif length == 1 then .[0].id | strings | select(startswith("ocid1.user.")) else empty end' <<<"$users") || {
    printf 'Could not identify OCI user %s from %s matches. No changes made.\n' "$user_name" "$(jq length <<<"$users")" >&2; return 1;
  }
  if [ -n "$user_id" ]; then
    printf 'Existing OCI user: %s (%s). Continue only if it is your dedicated state user.\n' "$user_name" "$user_id" >&2
    keys=$(_oke_oci_list iam customer-secret-key list "${oci_args[@]}" --user-id "$user_id" --all) || return 1
    if [ "$keys" != '[]' ]; then
      printf 'User %s already has a key. Load the existing pair from your password manager rather than creating another.\n' "$user_name" >&2
      return 1
    fi
  fi

  confirm "Set up state user $user_name in group $state_group using profile [$profile] in $region?" || {
    printf '%s\n' 'Cancelled; no changes made.' >&2; return 1;
  }
  if [ -z "$user_id" ]; then
    printf 'Unique email for the new OCI user (required by OCI Identity Domains): ' >&2
    IFS= read -r email || return 1
    [[ "$email" == ?*@?* ]] || { printf '%s\n' 'Enter a valid email; no changes made.' >&2; return 1; }
    user_id=$(oci iam user create "${oci_args[@]}" --compartment-id "$tenancy" --name "$user_name" \
      --description "$description" --email "$email" --query data.id --raw-output) || return 1
    [[ "$user_id" == ocid1.user.* ]] || return 1
  fi
  groups=$(_oke_oci_list iam user list-groups "${oci_args[@]}" --compartment-id "$tenancy" --user-id "$user_id" --all) || return 1
  if ! jq -e --arg id "$group_id" 'all(.[]; .id == $id)' <<<"$groups" >/dev/null; then
    printf 'User %s has unexpected IAM group memberships. No key created.\n' "$user_name" >&2
    return 1
  fi
  if [ "$groups" = '[]' ]; then
    oci iam group add-user "${oci_args[@]}" --group-id "$group_id" --user-id "$user_id" >/dev/null || return 1
  fi

  label="${user_name}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  result=$(oci iam customer-secret-key create "${oci_args[@]}" --user-id "$user_id" --display-name "$label") || {
    printf 'Check OCI for key %s before retrying.\n' "$label" >&2; return 1;
  }
  if ! access_key=$(jq -er '.data.id | strings | select(length > 0)' <<<"$result"); then
    printf 'Could not read the access key ID. Check OCI for key %s before retrying.\n' "$label" >&2
    return 1
  fi
  secret_key=$(jq -er '.data.key | strings | select(length > 0)' <<<"$result") || secret_key=''
  verified=false
  if [ -n "$secret_key" ]; then
    for attempt in 1 2 3 4 5; do
      if (
        unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
        export AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key"
        read_group=$("${TOFU:-tofu}" -chdir=stacks/bootstrap output -var-file="$SETTINGS" -raw state_access_group 2>/dev/null) &&
          [ "$read_group" = "$state_group" ]
      ); then
        verified=true
        break
      fi
      [ "$attempt" = 5 ] || sleep 5
    done
  fi
  if [ "$verified" != true ]; then
    printf '%s\n' 'New key could not read the bootstrap state. Existing shell credentials are unchanged.' >&2
    if ! oci iam customer-secret-key delete "${oci_args[@]}" --user-id "$user_id" \
      --customer-secret-key-id "$access_key" --force >/dev/null; then
      printf 'Could not revoke the failed key; check OCI for %s before retrying.\n' "$label" >&2
    fi
    return 1
  fi
  unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
  export AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key"
  printf 'Verified bootstrap state read with %s. The temporary bootstrap key was not revoked.\n' "$label" >&2
  printf 'Access key: %s\nSecret key: %s\n' "$access_key" "$secret_key"
}

create_temporary_state_key() {
  local profile auth user_id region namespace live_namespace label result access_key secret_key
  [ -t 1 ] || die 'creating a temporary key requires terminal output'
  profile=$(setting oci_profile); profile=${profile:-DEFAULT}
  auth=$(oci_auth_mode "$profile" "$(setting oci_auth)")
  user_id=$(state_oci_user "$profile" "$auth") || user_id=''
  if ! [[ "$user_id" =~ ^ocid1\.user\.[A-Za-z0-9._-]+$ ]]; then
    warn "could not detect the OCI user for [$profile]; load an existing key pair instead"
    return 0
  fi
  region=$(setting region); namespace=$(setting state_namespace)
  live_namespace=$(oci os ns get --profile "$profile" --auth "$auth" --region "$region" --query data --raw-output)
  [ -n "$namespace" ] && [ "$live_namespace" = "$namespace" ] || die 'OCI profile does not match the configured namespace'
  label="oke-bootstrap-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  confirm "Create temporary key $label using profile [$profile] for $user_id and display it?" || return 0
  if ! result=$(oci iam customer-secret-key create --profile "$profile" --auth "$auth" --region "$region" \
      --user-id "$user_id" --display-name "$label" --output json) ||
     ! access_key=$(jq -er '.data.id | strings | select(length > 0)' <<<"$result") ||
     ! secret_key=$(jq -er '.data.key | strings | select(length > 0)' <<<"$result"); then
    die "could not read the new credentials; check OCI for key $label before retrying"
  fi
  export AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key"
  printf 'Temporary Access Key: %s\nTemporary Secret Key: %s\n' "$access_key" "$secret_key"
  echo 'Save both for make bootstrap-apply. Revoke this key after verifying the dedicated key.'
}

prompt_state_keys() {
  local access_key secret_key
  printf 'OCI Access Key: ' >&2
  if ! IFS= read -rs access_key || [ -z "$access_key" ]; then
    printf '\nNo access key entered; credentials unchanged.\n' >&2
    return 1
  fi

  printf '\nOCI Secret Key: ' >&2
  if ! IFS= read -rs secret_key || [ -z "$secret_key" ]; then
    printf '\nNo secret key entered; credentials unchanged.\n' >&2
    return 1
  fi

  export AWS_ACCESS_KEY_ID="$access_key" AWS_SECRET_ACCESS_KEY="$secret_key"
  printf '\nOCI state credentials loaded for this shell.\n' >&2
}
