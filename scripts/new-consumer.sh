#!/usr/bin/env bash
# Scaffold a consumer repo (your cluster's config) from templates/consumer.
#
#   scripts/new-consumer.sh <dir> [--upstream owner/repo] [--ref vX.Y.Z|main] [--local]
#
#   --upstream  library repo on GitHub (default: this checkout's origin)
#   --ref       release tag (default: newest tag here) or a branch to track
#   --local     point modules_source at this checkout (library development)
set -euo pipefail
LIB="$(cd "$(dirname "$0")/.." && pwd)"
dir="" upstream="" ref="" local=0
while [ $# -gt 0 ]; do
  case "$1" in
    --upstream) upstream="$2"; shift 2;;
    --ref) ref="$2"; shift 2;;
    --local) local=1; shift;;
    -h|--help) sed -n '2,9p' "$0"; exit 0;;
    *) dir="$1"; shift;;
  esac
done
[ -n "$dir" ] || { echo "usage: $0 <dir> [--upstream owner/repo] [--ref vX.Y.Z|main] [--local]"; exit 1; }
[ ! -e "$dir" ] || [ -z "$(ls -A "$dir")" ] || { echo "error: $dir exists and is not empty"; exit 1; }

if [ -z "$upstream" ]; then
  url="$(git -C "$LIB" config --get remote.origin.url || true)"
  upstream="$(sed -nE 's#^(git@github\.com:|https://github\.com/)([^/]+/[^/.]+)(\.git)?/?$#\2#p' <<<"$url")"
  [ -n "$upstream" ] || { echo "error: can't derive owner/repo from origin '$url'; pass --upstream"; exit 1; }
fi
if [ -z "$ref" ]; then
  ref="$(git -C "$LIB" tag -l 'v[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)"
  ref="${ref:-main}"
fi

mkdir -p "$dir"
cp -a "$LIB/templates/consumer/." "$dir/"
owner="${upstream%%/*}" repo="${upstream##*/}"
# Workflows can't take a variable ref; they're pinned here (Renovate bumps them).
grep -rl -e 'UPSTREAM_OWNER' -e 'UPSTREAM_REF' "$dir" | while IFS= read -r f; do
  sed -i.bak -e "s#UPSTREAM_OWNER#$owner#g" -e "s#UPSTREAM_REPO#$repo#g" -e "s#UPSTREAM_REF#$ref#g" "$f"
done
find "$dir" -name '*.bak' -delete

if [ "$local" -eq 1 ]; then
  rel="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$LIB/modules" "$dir/stacks/cluster")"
  sed -i.bak -E -e "s#^modules_source[[:space:]]*=.*#modules_source = \"$rel\" \# local library checkout#" \
               -e 's#^module_ref[[:space:]]*=.*#module_ref = ""#' "$dir/config/settings.tfvars.example"
  rm -f "$dir/config/settings.tfvars.example.bak"
fi

case "$ref" in v[0-9]*) chan="release $ref (Renovate opens a PR per release)";; *) chan="tracking '$ref' (each CI run pins a commit)";; esac
echo "Created $dir from $upstream @ $ref: $chan"
echo "Next: cd $dir && git init -b main && make configure   (see README.md)"
