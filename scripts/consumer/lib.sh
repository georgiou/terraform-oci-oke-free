# shellcheck shell=bash
# Shared helpers for scripts/*.sh. Sourced, not executed.
set -euo pipefail
# These scripts ship with the library and run from the consumer repo root
# (make exports CONSUMER_ROOT); they act on the consumer repo, not the library.
ROOT="${CONSUMER_ROOT:-$PWD}"
[ -f "$ROOT/config/settings.tfvars.example" ] || { echo "error: run from your cluster repo (via make), not the library" >&2; exit 1; }
SETTINGS="$ROOT/config/settings.tfvars"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
warn()  { printf '\033[33m%s\033[0m\n' "$*"; }
die()   { red "error: $*" >&2; exit 1; }
need()  { command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"; }

# Read a simple string setting (key = "value") from config/settings.tfvars.
setting() {
  [ -f "$SETTINGS" ] || die "missing config/settings.tfvars (run: make configure)"
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$SETTINGS" | head -n1
}

# Read a key from a profile section in ~/.oci/config.
oci_config_value() { # profile key
  awk -v p="[$1]" -v k="$2" '
    $0==p {inside=1; next} /^\[/ {inside=0}
    inside && $0 ~ "^[[:space:]]*"k"[[:space:]]*=" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
  ' "${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
}

# Translate the OpenTofu setting once for all local OCI CLI operations.
oci_auth_mode() { # profile [OpenTofu auth]
  case "${2:-}" in
    SecurityToken) echo security_token ;;
    ApiKey) echo api_key ;;
    InstancePrincipal) echo instance_principal ;;
    '')
      if [ -n "${OCI_CLI_AUTH:-}" ]; then printf '%s\n' "$OCI_CLI_AUTH"
      elif [ -n "$(oci_config_value "$1" security_token_file 2>/dev/null || true)" ]; then echo security_token
      else echo api_key; fi ;;
    *) die "unsupported local OCI auth mode: $2" ;;
  esac
}
