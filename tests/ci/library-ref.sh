#!/usr/bin/env bash
# Actual Git/OpenTofu get: pin the tooling even when a tracking branch moves.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
up="$work/upstream"; consumer="$work/consumer"
mkdir -p "$up/modules/cluster" "$up/make" "$consumer/config" "$consumer/stacks/cluster"
git -C "$up" init -q -b main
touch "$up/modules/cluster/main.tf"
printf 'help:\n\t@echo first\n' > "$up/make/consumer.mk"
git -C "$up" add .
git -C "$up" -c user.name=Fixture -c user.email=fixture@example.test commit -qm first
ref=$(git -C "$up" rev-parse HEAD)
printf 'help:\n\t@echo second\nup:\n\t@echo plan-only\n' > "$up/make/consumer.mk"
git -C "$up" -c user.name=Fixture -c user.email=fixture@example.test commit -qam second
printf 'modules_source = "git::file://%s//modules"\nmodule_ref = "main"\n' "$up" > "$consumer/config/settings.tfvars"
cat > "$consumer/stacks/cluster/main.tf" <<'HCL'
variable "modules_source" { type = string }
variable "module_ref" { type = string }
module "cluster" { source = "${var.modules_source}/cluster?ref=${var.module_ref}" }
HCL
# Simulate a migrated consumer whose settings and legacy include are unchanged.
mkdir -p "$consumer/.lib"
printf 'up:\n\t@echo unsafe-legacy-target\n' > "$consumer/.lib/lib.mk"
touch -t 201901010000 "$consumer/config/settings.tfvars"
touch -t 202001010000 "$consumer/.lib/lib.mk"
cp "$root/templates/consumer/Makefile" "$consumer/Makefile"
[ "$(make -s -C "$consumer" up)" = plan-only ]
[ "$(make -s -C "$consumer" help)" = second ]
[ "$(make -s -C "$consumer" "LIB_REF=$ref" help)" = first ]
[ "$(git -C "$consumer/.lib/root-$ref" rev-parse HEAD)" = "$ref" ]
[ "$(make -s -C "$consumer" help)" = second ]
# Only the updated Makefile (not settings) is newer than this generated include.
printf 'help:\n\t@echo third\n' > "$up/make/consumer.mk"
git -C "$up" -c user.name=Fixture -c user.email=fixture@example.test commit -qam third
touch -t 202001010000 "$consumer/.lib/tooling-v2.mk"
[ "$(make -s -C "$consumer" help)" = third ]
echo 'library ref fixture: legacy cache ignored, Makefile changes refresh tooling, pinned checkout isolated'
