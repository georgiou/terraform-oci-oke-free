#!/usr/bin/env bash
# Exercises scripts/consumer/ci.sh end to end against a provider-free fixture
# (terraform_data + local backend), so it runs anywhere without credentials.
# Checks: plan artifacts, safe/unsafe classification, saved-plan apply,
# --if-safe, drift exit codes, and that no values reach the output.
set -euo pipefail
LIB="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass() { printf '  ok    %s\n' "$*"; }
die()  { printf '  FAIL  %s\n' "$*"; exit 1; }

mkdir -p "$W/config" "$W/stacks/cluster"
cp "$LIB/templates/consumer/config/settings.tfvars.example" "$W/config/settings.tfvars.example"
cat > "$W/config/settings.tfvars" <<'S'
modules_source = "unused"
module_ref     = ""
secret_value   = "TOPSECRET-should-never-be-printed"
items          = ["a", "b"]
S
cat > "$W/stacks/cluster/main.tf" <<'T'
variable "modules_source" { type = string }
variable "module_ref" { type = string }
variable "oci_profile" {
  type    = string
  default = "DEFAULT"
}
variable "secret_value" { type = string }
variable "items" { type = list(string) }
resource "terraform_data" "item" {
  for_each = toset(var.items)
  input    = "${each.key}-${var.secret_value}"
}
T
cd "$W"
export CONSUMER_ROOT="$W" TF_VAR_state_passphrase=fixture-passphrase-123 AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y
CI_SH="$LIB/scripts/consumer/ci.sh"
tofu -chdir=stacks/cluster init -input=false >/dev/null   # local backend for the fixture

echo "ci.sh fixture tests"
out=$("$CI_SH" plan 2>&1)
grep -q 'CHANGES=true' .ci/result.env && grep -q 'SAFE=true' .ci/result.env || die "first plan: expected CHANGES=true SAFE=true"
[ -f .ci/tfplan ] && [ -f .ci/module_ref ] || die "plan artifacts missing"
grep -q 'create  terraform_data.item\["a"\]' .ci/summary.md || die "summary lacks addresses"
pass "plan: artifacts, summary with addresses, create-only classified safe"
! grep -q TOPSECRET <<<"$out$(cat .ci/summary.md)" || die "a value leaked into output"
[ ! -f .ci/plan.json ] && [ ! -f stacks/cluster/tfplan ] || die "plan.json or working tfplan left behind"
! grep -q TOPSECRET .ci/tfplan || true   # local fixture has no encryption; real roots encrypt
pass "no values in output; no plan JSON left behind"

"$CI_SH" apply >/dev/null 2>&1 || die "apply of saved plan failed"
grep -q 'APPLIED=true' .ci/result.env || die "apply not recorded"
pass "apply: applied exactly the saved plan"

set +e; "$CI_SH" drift >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 0 ] || die "drift after apply: expected 0, got $rc"
pass "drift: 0 when live matches configuration"

sed -i.bak 's/items          = \["a", "b"\]/items          = ["a"]/' config/settings.tfvars
set +e; "$CI_SH" drift >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 2 ] || die "drift with pending change: expected 2, got $rc"
pass "drift: 2 when something differs"

"$CI_SH" plan >/dev/null 2>&1
grep -q 'SAFE=false' .ci/result.env || die "a destroy must be classified unsafe"
pass "plan with a destroy classified unsafe"
out=$("$CI_SH" apply --if-safe 2>&1)
grep -q 'waiting for a manual apply' <<<"$out" || die "--if-safe should refuse an unsafe plan"
[ "$(tofu -chdir=stacks/cluster state list | wc -l | tr -d ' ')" -eq 2 ] || die "--if-safe changed state"
pass "--if-safe leaves an unsafe plan for a human"

"$CI_SH" apply >/dev/null 2>&1 || die "manual apply failed"
[ "$(tofu -chdir=stacks/cluster state list | wc -l | tr -d ' ')" -eq 1 ] || die "manual apply didn't apply the destroy"
pass "manual apply applies the unsafe plan"

"$CI_SH" plan >/dev/null 2>&1   # no changes now
sed -i.bak 's/items          = \["a"\]/items          = ["a", "c"]/' config/settings.tfvars
"$CI_SH" plan >/dev/null 2>&1; cp .ci/tfplan /tmp/.stale-plan-$$
"$CI_SH" apply >/dev/null 2>&1
cp /tmp/.stale-plan-$$ .ci/tfplan; rm -f /tmp/.stale-plan-$$
set +e; out=$("$CI_SH" apply 2>&1); rc=$?; set -e
[ "$rc" -ne 0 ] && grep -q 'Saved plan is stale' <<<"$out" || die "a stale plan must be refused (rc=$rc)"
pass "stale saved plan refused"

sed -i.bak 's/items          = \["a", "c"\]/items          = ["a", "c", "d"]/' config/settings.tfvars
"$CI_SH" plan >/dev/null 2>&1
approved=$(sed -n 's/^CHANGES_SHA256=//p' .ci/result.env)
"$CI_SH" plan >/dev/null 2>&1   # re-plan, as a Forgejo/Woodpecker apply run would
[ "$(sed -n 's/^CHANGES_SHA256=//p' .ci/result.env)" = "$approved" ] || die "change-list hash must be deterministic across re-plans"
set +e; EXPECT_CHANGES_SHA256=0000 "$CI_SH" apply >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || die "apply must refuse a change list that doesn't match the approval"
EXPECT_CHANGES_SHA256="$approved" "$CI_SH" apply >/dev/null 2>&1 || die "apply with the matching approval failed"
pass "re-planned apply: deterministic change hash, mismatches refused, match applied"

rm -f .ci/tfplan
set +e; "$CI_SH" apply >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || die "apply without a saved plan must fail"
pass "apply without a saved plan fails"

set +e; TF_VAR_state_passphrase=short "$CI_SH" plan >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || die "short passphrase must fail"
pass "rejects a short state passphrase"
echo "all ci.sh tests passed"
