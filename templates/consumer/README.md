# My OKE cluster

The configuration for a private Kubernetes cluster on Oracle Cloud's Always Free
tier, built from the
[oci-oke-free](https://github.com/UPSTREAM_OWNER/UPSTREAM_REPO) library.
All the logic lives in the library. This repo holds **your choices** in
`config/settings.tfvars` and two small roots that call the library at the
version in `module_ref`.

```
config/settings.tfvars   your settings (committed; no secrets)
stacks/bootstrap/        compartment, state bucket, quotas, alerts, IAM (run locally)
stacks/cluster/          network + OKE (run by CI)
shared/                  backend/encryption/provider boilerplate, symlinked into both roots
Makefile                 fetches the library at module_ref and includes its targets
.github/workflows/       thin callers of the library's reusable workflows (GitHub)
ci-examples/             GitLab CI, Forgejo/Gitea, Woodpecker, cron (no CI)
renovate.json            keeps the library version current
```

Every command is a `make` target that **comes from the library** at your
`module_ref` (the first `make` fetches it into `.lib/`, which needs no
credentials). So improvements to the tooling arrive with library updates, just
like the modules. Run `make` to list them.

## Quick start

You need an OCI account (free-only or Pay As You Go), the `oci` CLI with an
API-key profile for an admin user (`oci setup config`), OpenTofu ≥ 1.13, `make`,
and `gh` for CI. Linux and macOS work as is. On Windows, use WSL (the roots use symlinks).

```bash
make configure                 # tenancy, namespace and HOME region detected from your OCI profile
$EDITOR config/settings.tfvars # access mode (Tailscale or allowlist), alert email
git add -A && git commit -m "Initial configuration"

export TF_VAR_state_passphrase='…'   # ≥ 16 chars, in your password manager. Losing it loses state.
make doctor                    # preflight checks
make seed                      # create the state bucket (once)

# First run only: a Customer Secret Key on your own user (Profile -> Customer secret keys)
export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…
make plan-bootstrap            # review it, then:
make apply-bootstrap

make up                        # the cluster, about 10 minutes
make kubeconfig && kubectl get nodes -o wide
make lock && git add stacks/*/.terraform.lock.hcl && git commit -m "Lock providers"
# tracking channel: `make lib-update` refreshes the library (and these targets)
```

Then **replace the bootstrap credential with a least-privilege one.** Create a
user, add it to the group in `tofu -chdir=stacks/bootstrap output state_access_group`,
create a Customer Secret Key for **that** user, use it from now on, and delete the
one on your admin user.

Confirm the subscription email OCI sends to each alert address, or no alerts arrive.

## CI setup

1. **Identities.** Bootstrap created two groups (`… output ci_groups`):
   - `ci-plan`: read-only.
   - `ci-apply`: manage, but only inside the project compartment.

   Create one user per group, then add an API key to each:
   ```bash
   openssl genrsa -out ci-plan.pem 2048 && openssl rsa -in ci-plan.pem -pubout -out ci-plan.pub
   # console: user -> API keys -> Add -> paste ci-plan.pub   (repeat for ci-apply)
   ```
2. **Load GitHub:**
   ```bash
   export CI_PLAN_USER_OCID=… CI_PLAN_KEY=ci-plan.pem CI_APPLY_USER_OCID=… CI_APPLY_KEY=ci-apply.pem
   export AUTO_APPLY=safe     # optional, see below
   make github-setup && rm ci-*.pem
   ```
3. **Install the [Renovate app](https://github.com/apps/renovate)** on this repo.

| Event | What happens |
|---|---|
| Pull request | Plan with the read-only identity. The summary lists resource addresses, never values. |
| Push to `main` | Plan and upload the encrypted plan. With `AUTO_APPLY=safe`, it's applied if it destroys nothing and leaves the cluster, node pool, IAM and quotas alone. |
| Anything else | Waits for you: review with `make review-plan RUN=<id>`, apply with `gh workflow run apply.yml -f run_id=<id>` (or Actions -> apply). Starting it is the approval. |
| Nightly | Drift check. Opens or closes a `drift` issue, with no details in it. |

## Without GitHub

Nothing here needs GitHub except the files in `.github/`. All CI logic is one
library script behind `make` targets, driven by environment variables:

| Target | Does | Exit |
|---|---|---|
| `make ci-check` | fmt, lock files, nothing secret committed | non-zero on problems |
| `make ci-plan` | plan, then write `.ci/{tfplan, module_ref, result.env, summary.md}` | 0 (see `result.env`: `CHANGES`, `SAFE`, `CHANGES_SHA256`) |
| `make ci-apply` | apply `.ci/tfplan` with the same library version | 0, or 1 if stale or failed |
| `make ci-apply-if-safe` | same, but only if the plan destroys nothing and doesn't touch the cluster, IAM or quotas | 0 (skips unsafe plans) |
| `make ci-drift` | plan with no artifacts | 0 if no drift, 2 if drift |

Environment: `TF_VAR_state_passphrase`, `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`
(state), and either your `~/.oci/config` profile or `OCI_TENANCY_OCID`,
`OCI_REGION` plus `OCI_PLAN_*` (plan/drift) or `OCI_APPLY_*` (apply). Output is
redacted: addresses and counts only, never values. With `CI=true`, OpenTofu
uses the committed provider lockfiles without upgrading providers. If a lockfile
needs updating, run `make lock` locally and commit the result.

What each system needs to add:
1. carry `.ci/` from the plan job to the apply job (artifacts), **or**
   re-plan in the apply run and pass `EXPECT_CHANGES_SHA256` (the "changes
   sha256" from the plan you reviewed). Apply then refuses anything that differs.
2. an approval: a manual job or a manual pipeline.
3. drift notification: a failed scheduled job (exit 2) is usually enough.

Ready-made: `ci-examples/gitlab-ci.yml` (artifacts plus a manual apply job),
`forgejo.yml` and `woodpecker.yml` (approval by hash), and `cron.sh` (a nightly
drift check on any always-on box, with no CI at all). Renovate runs on GitLab,
Forgejo/Gitea and Bitbucket too.

**Fully manual** works as well: `make plan-cluster`, read it, then `make apply-cluster`.

## Updates

- **Release channel** (`module_ref = "vX.Y.Z"`): Renovate opens one PR per library
  release, bumping `module_ref` and both workflow refs together. Read the
  library's CHANGELOG (manual steps are called out), merge, and CI plans it.
  To auto-merge minor and patch releases, set `"automerge": true` in `renovate.json`.
- **Tracking channel** (`module_ref = "main"` and both workflows `@main`): every run
  uses the latest library commit, pinned to a SHA for that run. No PRs, no lag, and no
  warning before breaking changes.

## Changing things

- **Settings:** edit `config/settings.tfvars` and open a PR. Typos are rejected
  with the list of valid keys. Keys and defaults are in the library's
  `modules/*/settings.tf`.
- **Your own resources:** add them to `stacks/cluster/main.tf` (or a new `.tf`
  file in that root) next to the module call. They're planned and applied like
  everything else.
- **Kubernetes version:** follows the library's default unless you pin
  `cluster.kubernetes_version`. Upgrades never auto-apply.
- **Teardown:** delete LoadBalancer Services and PVCs first, then `make destroy-cluster`.

## Where secrets live

| Secret | Location |
|---|---|
| State passphrase | Password manager; repo secret `STATE_PASSPHRASE` |
| State Customer Secret Key (bucket-only) | Shell; repo secrets `STATE_S3_*` |
| CI plan key (read-only) | Repo secrets `OCI_PLAN_*` |
| CI apply key (compartment-scoped) | `production` environment secrets `OCI_APPLY_*` |
| Tailscale OAuth | In-cluster (SOPS / External Secrets), never GitHub |

`config/settings.tfvars` holds identifiers and choices, not secrets. If this repo
is public and you'd rather not publish them, gitignore the file before running
`make github-setup`, which then stores it as the `TOFU_SETTINGS` secret instead.
