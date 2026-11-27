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
if EXPECT_CHANGES_SHA256="$approved" "$CI_SH" apply >/dev/null 2>&1; then
  die "even a matching change-list hash must not authorize a re-plan"
fi
"$CI_SH" apply >/dev/null 2>&1 || die "apply of the saved artifact failed"
pass "checksum of addresses and actions cannot approve a re-plan"

rm -f .ci/tfplan
set +e; "$CI_SH" apply >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || die "apply without a saved plan must fail"
pass "apply without a saved plan fails"

set +e; TF_VAR_state_passphrase=short "$CI_SH" plan >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || die "short passphrase must fail"
pass "rejects a short state passphrase"

# Verify failure observability without leaking diagnostic values or artifacts.
mkdir "$W/bin"
REAL_TOFU="$(command -v tofu)"
export REAL_TOFU
cat > "$W/bin/tofu" <<'T'
#!/usr/bin/env bash
if [ "${2:-}" = "${FAIL_STAGE:-}" ]; then
  printf 'Error: SECRET-CANARY in a raw diagnostic\n' >&2
  exit 1
fi
if [ "${2:-}" = show ] && [ -n "${MOCK_CLUSTER_CHANGE:-}" ]; then
  printf '{"resource_changes":[{"type":"oci_containerengine_cluster","address":"oci_containerengine_cluster.fixture","change":{"actions":%s}}]}\n' "$MOCK_CLUSTER_CHANGE"
  exit 0
fi
exec "$REAL_TOFU" "$@"
T
chmod +x "$W/bin/tofu"
for stage in init plan show; do
  touch .ci/tfplan
  if out=$(FAIL_STAGE="$stage" PATH="$W/bin:$PATH" "$CI_SH" plan 2>&1); then die "$stage should fail"; fi
  ! grep -q SECRET-CANARY <<<"$out" || die "$stage leaked a raw diagnostic"
  [ ! -e .ci/tfplan ] && [ -z "$(find .ci -name '.work.*' -print)" ] || die "$stage left a stale artifact or private workspace"
done
sed -i.bak 's/"d"/"e"/' config/settings.tfvars
"$CI_SH" plan >/dev/null
if out=$(FAIL_STAGE=apply PATH="$W/bin:$PATH" "$CI_SH" apply 2>&1); then die "apply should fail"; fi
! grep -q SECRET-CANARY <<<"$out" || die "apply leaked a raw diagnostic"
[ -z "$(find .ci -name '.work.*' -print)" ] || die "apply left a private workspace"
if out=$(STACK=bootstrap "$CI_SH" plan 2>&1); then die "CI accepted bootstrap"; fi
grep -q 'bootstrap is local-only' <<<"$out" || die "bootstrap rejection not reported"
pass "failure paths are redacted and cleaned; bootstrap is local-only"

for change in '["create"]' '["delete","create"]'; do
  if out=$(MOCK_CLUSTER_CHANGE="$change" PATH="$W/bin:$PATH" "$CI_SH" plan 2>&1); then die "CI published a cluster creation or replacement"; fi
  grep -q 'must be planned locally' <<<"$out" || die "missing first-cluster guard"
  [ ! -e .ci/tfplan ] || die "guard left an appliable plan"
  set +e; out=$(MOCK_CLUSTER_CHANGE="$change" PATH="$W/bin:$PATH" "$CI_SH" drift 2>&1); rc=$?; set -e
  [ "$rc" -eq 2 ] && grep -qx 'CHANGES=true' .ci/result.env && [ ! -e .ci/tfplan ] || die "cluster creation or replacement must report drift without publishing a plan"
done
pass "cluster creation and replacement count as drift but are not appliable from CI"
echo "all ci.sh tests passed"
