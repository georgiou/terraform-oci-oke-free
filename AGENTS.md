# AGENTS.md: oci-oke-free library

Instructions for coding agents working in this repo. Read it fully before
changing anything. `README.md` covers the design for humans.

## What this repo is

A **versioned library**: OpenTofu modules plus reusable GitHub workflows for a
private OKE cluster on Oracle Cloud's Always Free tier. Users never edit this
repo. They scaffold a consumer repo from `templates/consumer/` that references
`modules/*` and `.github/workflows/{stack,apply-plan}.yml` at a release tag
(Renovate bumps it) or at `main` (tracking, pinned to a SHA per CI run).

**Every change here ships to other people's infrastructure,** often
automatically. Treat backwards compatibility as the top concern.

- Runtime: OpenTofu ≥ 1.13 (`.opentofu-version`). Provider: `oracle/oci` (modules: `>= 8.0`).
- Consumer roots pass module sources as `"${modules_source}/<m>?ref=${module_ref}"` (early evaluation).

## Layout

```
modules/network       VCN, subnets, gateways, default-deny SL, NSG rule table   (+ tests/)
modules/oke-cluster   BASIC OKE, A1 node pool, free-tier preconditions          (+ tests/)
modules/bootstrap     compartment, state bucket, quotas, budget, alarms, IAM    (+ tests/)
modules/cluster       composition: network + oke-cluster, settings + defaults   (+ tests/)
templates/consumer/   the user repo skeleton (roots, shared boilerplate, scripts, workflows)
make/consumer.mk      every make target consumers run (included by their bootstrap Makefile)
scripts/consumer/     configure, doctor, seed, github-setup, ci.sh (THE CI implementation)
scripts/new-consumer.sh  scaffolds templates/consumer, substituting UPSTREAM_* placeholders
.github/workflows/stack.yml       reusable GitHub wrapper: plan / deploy (+ safe auto-apply) / drift
.github/workflows/apply-plan.yml  reusable GitHub wrapper: manual apply of a saved plan
.github/workflows/ci.yml          this repo's CI
templates/consumer/ci-examples/   GitLab, Forgejo, Woodpecker, cron wrappers around make ci-*
tests/consumer-cluster.tftest.hcl mocked plan of a scaffolded consumer (make validate-template)
tests/ci/run.sh                   ci.sh end to end on a provider-free fixture (make test-ci)
examples/k8s/         manifests for the GitOps side (not applied by tofu)
```

## Commands and definition of done

```bash
tofu fmt -recursive
make test                # every module, mocked provider, no credentials
make test-ci             # ci.sh behaviour on a provider-free fixture
make validate-template   # scaffold against local modules, validate roots, mocked plan, Makefile bootstrap
```

A change is done when:

1. fmt is clean.
2. `make test`, `make test-ci` and `make validate-template` pass.
3. New behaviour has a `run` block that asserts it.
4. Docs are updated (the README here, plus the template README if users are affected).
5. `CHANGELOG.md` has an entry under Unreleased, with **Manual steps** (or "None").

Then report what was verified and what wasn't (nothing here runs against a real tenancy).

## Compatibility contract (never break silently)

1. **Settings objects are the public API.** `modules/bootstrap/settings.tf` and
   `modules/cluster/settings.tf` `local.defaults`:
   - Adding a key with a default that preserves today's behaviour is a minor release.
   - Renaming or removing a key, or changing a default's behaviour, is a **major** release.
   - Keep the unknown-key validation. Typos must fail.
2. **Resource addresses:** any change to an address, including moving
   resources between modules, ships with a `moved` block in the same change.
   Users apply your release via a Renovate PR, and a surprise destroy is the
   worst possible outcome.
3. **Consumer boilerplate** (`templates/consumer/shared/*`, root `main.tf`
   wiring, workflow caller inputs/secrets): existing users don't get template
   changes automatically. Any change they must copy by hand is **major**, with
   exact instructions in the CHANGELOG. Prefer solving things inside the modules
   or reusable workflows.
4. **`ci.sh` / `make ci-*` interface:** mode names, exit codes (drift = 2), the
   `.ci/` file names and `result.env` keys, and environment variable names are
   used by every CI wrapper, including users' copies of the `ci-examples`.
   Add, don't rename.
5. **The bootstrap `Makefile`** (`.lib/` fetch + include) is consumer
   boilerplate. Changing it is major. Put new targets in `make/consumer.mk`.
6. **Reusable workflow interface:** inputs, secrets and outputs of
   `stack.yml`/`apply-plan.yml` follow the same rule. Add only optional inputs
   with defaults.

## Invariants

1. **Always Free only.** Clusters stay `BASIC_CLUSTER`, `maximum_surge` stays `"0"`,
   and limits come only from `free_tier_limits`. No paid shapes and no Enhanced-only features.
2. **Private by default.** Defaults: no public ingress, no LB subnet, and no
   inbound internet except optional Tailscale UDP 41641.
3. **No secrets in state, outputs or logs.**
   - CI must never print plan or apply output, `tofu show`, or values. Addresses
     and counts only.
   - Keys and OAuth secrets are created outside tofu.
4. **One CI implementation.** Logic goes in `scripts/consumer/ci.sh`. GitHub
   workflows and the `ci-examples` only wire up secrets, artifacts, approvals
   and notifications. Never duplicate plan/apply logic in YAML.
5. **Saved plans only.** `apply` steps apply the uploaded plan file. The only
   exception is CIs that can't carry it: they re-plan in the apply run, and
   `EXPECT_CHANGES_SHA256` must gate the apply. Never an unconditional re-plan and apply.
   The tracking channel is resolved to a SHA once, in the plan job, and reused by apply.
6. **Never auto-apply** destroys, or changes to clusters, node pools, IAM or quotas.
7. **Tofu stops at the cluster boundary.** No kubernetes or helm providers.
8. **No third-party OCI modules** (evaluated: they can't express the free-only
   network mode, the guards or this NSG design).
9. **Bootstrap never runs in CI.**

## Conventions

- New settings go in `local.defaults` with a comment explaining them. Read them
  via `local.s.<key>`, and pass them to child modules as typed variables.
- Cross-setting rules: a `validation` on `var.settings` using
  `merge(local.defaults, var.settings)`, with an error message that says how to fix it.
- Tags: `local.common_tags` / `var.freeform_tags`. Every variable and output has a description.
- NSG rules: one line per rule in the maps in `modules/network/nsg.tf`.
- Template files use the `UPSTREAM_OWNER`, `UPSTREAM_REPO` and `UPSTREAM_REF` placeholders.
- `tofu test` can't `expect_failures` on resources inside child modules. Put
  user-facing checks at the module's own level.

## Known open issues (flag, don't silently fix)

- Whether OCI's S3-compatible API honours `use_lockfile` conditional writes is
  unverified. The callers' `concurrency` group is the real serialisation.
- CI identities need hand-made users and API keys. Workload Identity Federation
  (GitHub OIDC → OCI) would remove the static keys.
- Nothing is planned against a real tenancy in CI. All tests use a mocked provider.
- `examples/k8s/tailscale/argocd-application.yaml` has a deliberate chart version placeholder.
