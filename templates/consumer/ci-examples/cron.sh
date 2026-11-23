#!/usr/bin/env bash
# No CI at all: a nightly drift check from any always-on Linux box.
#   crontab -e:  23 4 * * *  /path/to/my-oke/ci-examples/cron.sh
# Put the environment in ~/.config/oke-free.env (chmod 600):
#   TF_VAR_state_passphrase=…  AWS_ACCESS_KEY_ID=…  AWS_SECRET_ACCESS_KEY=…
#   (OCI access: your normal ~/.oci/config profile from settings)
# Exit 2 = drift. cron mails non-empty output if MAILTO is set; or hook a notifier below.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1090
. "${OKE_ENV_FILE:-$HOME/.config/oke-free.env}"
set +a
git pull --ff-only -q
set +e; out=$(make -s lib-update ci-drift 2>&1); rc=$?; set -e
case "$rc" in
  0) ;;                                   # no drift: stay quiet
  2) echo "OKE drift detected:"; echo "$out" ;;
  *) echo "OKE drift check failed (rc=$rc):"; echo "$out"; exit "$rc" ;;
esac
