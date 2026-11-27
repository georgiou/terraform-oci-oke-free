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

Install OpenTofu (see `.opentofu-version`), GNU Make, `oci`, `jq`, Git, and
Python 3. Use Linux/macOS or WSL (the roots use symlinks). Sign in to your
chosen tenancy with an OCI CLI profile that can bootstrap it. For an interactive
session use `oci session authenticate --profile-name ROOT --region YOUR_HOME_REGION`.

```sh
make bootstrap-plan   # select profile, enter settings and credentials, seed and save a plan
make bootstrap-apply  # confirm the exact saved plan, then set up the bucket-scoped key
```

Use a strong state passphrase from your password manager and keep the same one
for both stacks. The wizard can issue a temporary admin Customer Secret Key if
you don't already have one; when prompted, save it for the second command. Keys
are issued outside state and never written to disk by the wizard. Use a private
terminal if you opt to display a new key. Confirm the OCI alert subscription email.

If you're upgrading an existing checkout, run `make lib-update` after the new
library revision is published. Do not use `make up` with the old library; it
can apply without stopping for review.

If you already applied bootstrap or stopped during the key handoff, run
`make state-credentials` instead of reapplying. If the dedicated user already
has a key, use the saved pair rather than minting another. Never revoke the admin
key until you've saved and reloaded the dedicated pair and confirmed that a plan
can lock state with it. If setup fails partway, keep the existing state and
credentials; rerun the handoff, not bootstrap. OCI may take time to propagate IAM changes.

For normal local operation, `make session` prompts for the saved passphrase and
state key once and opens a shell. Inside that shell:

```sh
make plan-cluster   # also available as make up; make up never applies
make apply-cluster  # after review
make kubeconfig
```

For a new public API endpoint, set `cluster.api_allowed_cidrs` to your public
IPv4 `/32` before the first plan. Remove it only after testing the Tailscale
operator. Run `make lib-update` explicitly for tracking updates and `make lock`
when updating provider locks or before enabling CI. Use the committed locks
and don't run local and CI applies concurrently until locking has been verified
for your OCI backend.

## CI setup

1. **Identities.** Bootstrap created two groups (`… output ci_groups`):
   - `ci-plan`: read-only.
   - `ci-apply`: manage, but only inside the project compartment.

   Create one user per group, then add an API key to each:
   ```bash
   openssl genrsa -out ci-plan.pem 2048 && openssl rsa -in ci-plan.pem -pubout -out ci-plan.pub
   # console: user -> API keys -> Add -> paste ci-plan.pub   (repeat for ci-apply)
   ```
2. **Load GitHub:** In repository settings, create the `oci-plan` and `production`
   environments, restrict both to branch `main`, and protect `main`. Do not
   store OCI/state credentials as repository-wide secrets. `make github-setup`
   checks the environments, installs their secrets, and opts the repo into CI.
   For a private upstream or SSH module URL, the runner also needs separate
   module fetch access (a local SSH agent is not inherited).
   ```bash
   export CI_PLAN_USER_OCID=… CI_PLAN_KEY=ci-plan.pem CI_APPLY_USER_OCID=… CI_APPLY_KEY=ci-apply.pem
   export AUTO_APPLY=safe     # optional, see below
   make github-setup && rm ci-*.pem
   ```
3. **Install the [Renovate app](https://github.com/apps/renovate)** on this repo.

| Event | What happens |
|---|---|
| Pull request | Formatting check only. No OCI or state credentials. |
| Push to `main` | Plan and upload the encrypted plan. With `AUTO_APPLY=safe`, it's applied if it destroys nothing and leaves the cluster, node pool, IAM and quotas alone. |
| Plan waiting for approval | Review with `make review-plan RUN=<id>`, apply with `gh workflow run apply.yml -f run_id=<id>` (or Actions -> apply). Starting it is the approval. |
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
1. Restrict credentials to trusted jobs on a protected branch, not PR code.
2. Transfer `.ci/tfplan`, `module_ref`, and `result.env` from plan to apply and
   apply only that artifact, with `LIB_REF` set to the saved library ref.
   `CHANGES_SHA256` checks the address/action summary only. It cannot approve a re-plan.
3. Require a manual approval and report drift (exit 2).

`ci-examples/gitlab-ci.yml` transfers the saved artifact. The Forgejo and
Woodpecker examples are plan/drift only. `cron.sh` runs drift checks without CI.

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
| State passphrase | Password manager; `STATE_PASSPHRASE` in `oci-plan` and `production` |
| State Customer Secret Key (bucket-scoped) | Password manager and session; `STATE_S3_*` in `oci-plan` and `production` |
| CI plan key (provider read-only) | `oci-plan` environment secrets `OCI_PLAN_*` |
| CI apply key (compartment-scoped) | `production` environment secrets `OCI_APPLY_*` |
| Tailscale OAuth | In-cluster (SOPS / External Secrets), never GitHub |

`config/settings.tfvars` holds identifiers and choices, not secrets. If this repo
is public and you'd rather not publish them, gitignore the file before running
`make github-setup`, which then stores it as the `TOFU_SETTINGS` secret instead.
