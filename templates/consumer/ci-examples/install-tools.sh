#!/usr/bin/env sh
# Installs what `make ci-*` needs on a bare Debian/Ubuntu or Alpine CI image:
# make, bash, git, jq, curl, and the OpenTofu version in .opentofu-version.
# Used by the GitLab, Forgejo and Woodpecker examples. Idempotent.
set -eu
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq --no-install-recommends make bash git jq curl unzip ca-certificates >/dev/null
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache make bash git jq curl unzip ca-certificates >/dev/null
fi
v="$(cat .opentofu-version)"
if ! command -v tofu >/dev/null 2>&1 || ! tofu version | grep -q "v$v"; then
  arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; esac
  curl -fsSL -o /tmp/tofu.zip "https://github.com/opentofu/opentofu/releases/download/v$v/tofu_${v}_linux_${arch}.zip"
  unzip -oq /tmp/tofu.zip tofu -d /usr/local/bin && rm -f /tmp/tofu.zip
fi
tofu version | head -n1
