# oci-oke-free

A versioned OpenTofu **library** for a private Kubernetes cluster on Oracle Cloud
that stays inside the **Always Free** allowance. Guardrails make leaving the
allowance a plan-time error and an OCI quota denial, rather than an invoice.

You don't fork or edit this repo. You **scaffold a small config repo** of your own
that calls these modules and these CI workflows at a version you choose. Renovate
keeps that version current (or you track `main`).

```
your repo (thin, yours)                        this repo (library, versioned)
├── config/settings.tfvars  ← all your choices    modules/bootstrap   compartment, state bucket, quotas,
├── stacks/bootstrap/main.tf ─────────────────►                       budget, egress alarms, CI/state IAM
├── stacks/cluster/main.tf   ─────────────────►   modules/cluster     network + OKE, settings with defaults
│                                                   ├ modules/network     VCN, default-deny SL, NSGs
│                                                   └ modules/oke-cluster BASIC OKE, A1 pool, free-tier guards
├── Makefile (fetch + include) ───────────────►   make/consumer.mk    every `make` target users run
│                                                 scripts/consumer/   configure, doctor, seed, ci.sh (all CI logic)
├── .github/workflows/*.yml  ─────────────────►   .github/workflows/  stack.yml, apply-plan.yml (thin, call make ci-*)
├── ci-examples/             (GitLab, Forgejo, Woodpecker, cron)
└── renovate.json            (bumps the refs)
```

What you get by default:

```
OKE BASIC cluster (free control plane, flannel)  2 × A1.Flex (1 OCPU / 6 GB / 50 GB boot)
VCN 10.0.0.0/16: api /28 (NSG-filtered), workers /24 (no inbound internet), no LB subnet
State: versioned bucket, client-side encrypted.  Quotas: hard cap at the allowance.
Alerts: budget (first penny), egress rate, nightly drift.  Access: Tailscale or an IP allowlist.
```

## Get started

```bash
git clone https://github.com/<owner>/oci-oke-free.git
oci-oke-free/scripts/new-consumer.sh my-oke            # newest release; or --ref main to track
cd my-oke && git init -b main && make configure        # then follow my-oke/README.md
```

The scaffold is an ordinary repo you own and commit. Its README covers
everything from `make configure` to CI and updates. You can add your own
resources next to the module calls.

## Release channels

| `module_ref` in your settings | Updates | Reproducibility |
|---|---|---|
| `"v1.4.0"` (default) | Renovate opens **one PR per release**, bumping `module_ref` and both reusable-workflow refs together. Merge it and CI plans it. Optionally auto-merge minor and patch releases. | Fully pinned |
| `"main"` (tracking) | Every CI run uses the latest commit. Nothing to merge. | CI resolves `main` to a **commit SHA once per run**. Plan and apply use that SHA, so a moving branch can't change code between them. The SHA appears in the run summary. |
| a commit SHA | Manual | Fully pinned |

Tracking is for people who want the newest guards and fixes immediately and accept
breaking changes without warning. On a tracking channel, the nightly drift check
also reports "library changed" as drift. Whatever the channel, destructive plans,
Kubernetes upgrades, and IAM or quota changes **never auto-apply**.

To track, set `module_ref = "main"` and change both workflow refs to `@main` (or
scaffold with `--ref main`). Workflow refs can't be variables, which is the one
place the choice lives in two files.

## Tooling ships with the library

The user's `Makefile` is a ~20-line bootstrap. It runs `tofu get` for the
library at `module_ref` (no credentials needed), links it at `.lib/root`, and
includes `make/consumer.mk`. Every target (`configure`, `doctor`, `plan-cluster`,
`ci-plan`, …) and the scripts behind them therefore update along with the modules,
at exactly the same version.

All CI logic is in **`scripts/consumer/ci.sh`** (`make ci-check|ci-plan|ci-apply|ci-apply-if-safe|ci-drift`):
- redaction
- resolving the tracking channel to a SHA
- saved-plan apply
- the safe/unsafe classification
- drift exit codes
- `EXPECT_CHANGES_SHA256`, an approval hash for CIs that re-plan in the apply run

It's driven by environment variables, so the GitHub reusable workflows are thin
wrappers around it, and so are the GitLab, Forgejo, Woodpecker and cron examples
in the consumer template. Without any CI, `make plan-cluster` / `apply-cluster` works locally.

## Settings

Each root passes **one object** to its module: `bootstrap = { … }` and
`cluster = { … }` in the user's settings file. The modules merge it over their
defaults (`modules/*/settings.tf`), so:

- New settings in a release reach users without any change to their repo.
- Unset keys follow library defaults, including Kubernetes version bumps.
  Pin a key to hold it.
- **Typos fail validation** (`Unknown cluster setting(s): enable_tailscle…`),
  so nothing is silently ignored.
- Rules that span several settings are validated up front. For example, a
  public API with no allowlist and no Tailscale is rejected with an explanation.

Cluster keys (defaults are private-only): `enable_tailscale`, `api_allowed_cidrs`,
`tailscale_direct_udp`, `api_endpoint_public`, `vcn_cidr`, `private_workers`,
`enable_public_ingress`, `enable_ipv6`, `lb_ingress_ports`, `lb_allowed_cidrs`,
`kubernetes_version`, `node_count`, `node_ocpus`, `node_memory_gbs`,
`node_boot_volume_gbs`, `reserved_block_storage_gbs`, `node_image_id`, `ssh_public_key`.

Bootstrap keys: `budget_alert_emails` (required), `budget_amount`,
`state_version_retention_days`, `enable_quotas`, `egress_alarm_gb_per_hour`.

Top-level (both roots): `free_tier_limits`, `availability_domain_index`, `project`, `freeform_tags`.

## Free-tier budget (as of Nov 2026)

On **15 June 2026, Oracle halved the Always Free Ampere A1 allowance from 4 OCPU / 24 GB
to 2 OCPU / 12 GB.** Many guides still assume 4/24. This library defaults to the new figures.

| Resource              | Allowance          | Used by default                  |
|-----------------------|--------------------|----------------------------------|
| A1 OCPU / memory      | 2 / 12 GB          | 2 nodes × (1 OCPU, 6 GB)         |
| Block + boot storage  | 200 GB             | 100 GB boot + 100 GB kept for PVs |
| OKE control plane     | BASIC is free      | BASIC                            |
| Network LB / Flexible LB (10 Mbps) | 1 each | only with `enable_public_ingress` |
| Object Storage        | 20 GB              | state only, old versions expire  |

The allowance is **per tenancy**: one free cluster per OCI account. Protection
works in two layers:

1. **Plan-time** preconditions in `modules/oke-cluster` reject node sizing, boot
   volumes plus reserved PV space, or surge nodes beyond `free_tier_limits`.
2. **OCI quotas** from `modules/bootstrap` zero A1 cores, A1 memory and block storage
   everywhere, then grant exactly the allowance in one AD (where the nodes are pinned).
   That catches console clicks and other tools too.

## How it's built

- **No remote state between roots.** The cluster module finds the bootstrap
  compartment by name, with a clear error if bootstrap hasn't run.
- **Network and OKE share one root**, which removes the plan-ordering problem and halves boilerplate.
- **State** uses the `s3` backend against OCI's S3-compatible API, since
  OpenTofu has no `oci` backend. Users seed the bucket with the CLI, and the
  bootstrap root's `import` block adopts it. There's no local-state phase.
- **State and plan files are encrypted client-side** (PBKDF2 + AES-GCM,
  enforced). The bucket and CI artifacts only hold ciphertext.
- **Variable module sources:** the user roots use
  `source = "${modules_source}/cluster?ref=${module_ref}"`, which OpenTofu
  evaluates early (≥ 1.8). A local path works for library development.
- **CI is one script plus thin wrappers,** with logic and fixes shipped like the modules:
  - **Redaction:** plan and apply output never reaches logs, summaries or
    issues. Only resource addresses do.
  - **Least privilege:** a read-only plan identity, and an apply identity that's
    only in the caller's `production` environment.
  - **Apply the saved plan:** whether auto-applied or applied manually, the
    exact plan file is applied. The manual path works on every GitHub plan.
- **Networking is default-deny** via NSGs. The default security list is
  emptied. Private-only is the default: no LB subnet, and no NodePort exposure.
- **No secrets in state:** the kubeconfig uses the `oci` exec plugin, and
  keys and OAuth secrets are created outside tofu.
- **Zero-surge node cycling,** because a surge node would exceed the A1 allowance.

## Things to know

- **The NAT gateway problem:** free-only tenancies have a service limit of 0
  for NAT and Service Gateways. By default, workers sit in a public subnet whose
  NSG admits nothing from the internet. `private_workers = true` (private subnet
  behind NAT) needs Pay As You Go. The gateways themselves are free.
- **Pay As You Go** often gets A1 capacity where free-only accounts see
  "Out of host capacity", and isn't subject to idle reclamation. Always Free
  resources stay free. The quotas are then what stops a bill.
- **Tailscale** (`enable_tailscale`): the public API endpoint admits nobody, and
  kubectl goes through the operator's API server proxy. `examples/k8s/tailscale/`
  has the ArgoCD install, tailnet policy and RBAC.
- **Public ingress** (`enable_public_ingress`): a LoadBalancer Service without
  annotations gets a **billed** 100 Mbps LB, and a second Service gets a second LB.
  Use one controller behind the free NLB (`examples/k8s/lb-service.yaml`), or the
  10 Mbps flexible LB for dual-stack (`enable_ipv6`).
- **IPv6** applies to the LB subnet only. An OKE dual-stack cluster would need a
  NAT gateway, and OCI has no egress-only IPv6 gateway.

## Developing the library

```bash
make test                # tofu test, all modules, mocked provider, no credentials
make test-ci             # ci.sh end to end against a provider-free fixture: plan artifacts,
                         # safe/unsafe classification, saved-plan and stale-plan handling,
                         # --if-safe, drift exit codes, approval hash, no values in output
make validate-template   # scaffold a consumer against local modules, validate both roots,
                         # run a mocked plan with the example settings, check the Makefile bootstrap
scripts/new-consumer.sh /tmp/dev --local   # consumer wired to this checkout (module_ref "")
```

CI (`.github/workflows/ci.yml`) runs fmt, all three targets above, and
actionlint on the library's and the template's GitHub workflows.

## Releasing

1. Update `CHANGELOG.md` with what changed and **Manual steps** for users (or "None").
2. Address changes need `moved` blocks, so a Renovate PR never plans a surprise destroy.
3. `git tag vX.Y.Z && git push --tags`. Renovate notices within hours, and
   tracking users get it on their next run.

Semver:
- **Patch:** fixes.
- **Minor:** new optional settings that default to today's behaviour.
- **Major:** anything that changes defaults or needs edits in users' repos,
  such as the root boilerplate, workflow inputs or required settings.

## Known trade-offs

- **The bootstrap root stores its state in the bucket it manages.** It's
  mitigated by `prevent_destroy`, versioning and encryption, and the root never
  runs in CI.
- **Each user repo carries about 30 lines of root boilerplate** (backend,
  encryption, provider). OpenTofu doesn't allow those inside modules. They only
  change in major releases.
- **The library repo must be public,** or users need a token to fetch modules
  and workflows.
- **Mocked tests aren't integration tests.** Only a real plan proves the OCI API agrees.
