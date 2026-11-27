# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/). Versions: semver.
Consumers receive each release as a Renovate PR (or immediately on the
tracking channel), so every entry has **Manual steps**, even if that's "None".

## [Unreleased]

### Added
- Local `make bootstrap-plan` and `make bootstrap-apply` guide configuration,
  bucket seeding, saved-plan review, and dedicated state credentials.
  `make state-credentials` resumes the handoff; `make session` loads saved credentials.

### Changed
- `make up` now plans only; local and CI plans have separate paths. Initial cluster
  provisioning is reviewed locally. Routine init does not upgrade providers.
- CI no longer authorizes a re-plan using `EXPECT_CHANGES_SHA256`. The checksum
  remains for summaries. CI uses the exact encrypted plan and library checkout,
  and fresh GitHub consumers keep state credentials out of repository-level secrets.

### Fixed
- Use OCI's current S3-compatible endpoint, explicit session auth and region, and
  fail closed on bucket collisions, unverified absence, and unsafe existing state.
- Remove Enhanced-only node cycling from Basic OKE without changing resource addresses.
- Suppress raw CI failure diagnostics, clean temporary credentials and files, and reject bootstrap in CI.
- CI initializes with a read-only provider lockfile without passing the incompatible
  `-upgrade` flag. Local upgrades are also explicit (`make lib-update`, `make lock`).
- Ignore legacy tooling caches on upgrade, keep bootstrap approval and credential
  issuance out of Make dry runs, and initialize state readers on fresh checkouts.
- Invalidate old bootstrap plans before preflight; report cluster recreation as
  drift without publishing an appliable CI plan.
- Keep `make -n review-plan` from displaying a cached plan. Use environment
  secrets directly in new GitHub workflows and keep credential handling inside
  the bootstrap wizard.

### Manual steps (breaking consumer boilerplate update)
- Existing consumers: copy the updated `Makefile`, `shared/locals.tf`, and GitHub
  caller workflows from the template (substitute owner/repo/ref in the workflows).
  Update to the new library ref, then run `make lib-update` before using the new
  commands. Do not use `make up` with older tooling; it can apply immediately.
  Keep your configured bucket, state keys and passphrase. Do not reseed or reapply
  an existing bootstrap solely to update tooling. If your old endpoint was working
  and init reports a configuration change, first confirm both endpoints address
  the same bucket and state keys, then use `init -reconfigure` for each affected
  root; never migrate to a different location as part of this update.
- For existing GitHub CI, disable deployment, scope secrets to the `oci-plan` and
  `production` environments restricted to `main`, remove legacy repo secrets,
  and rerun `make github-setup`. Protect `main` before opting in. Update copied
  non-GitHub examples if used. Regenerate any outstanding saved plans after upgrade.
- Existing bootstrap: use `make state-credentials` to resume only the credential
  handoff. Once the updated library is loaded, use `make session` instead of
  any local `load-state-keys.sh` copy; the old helper can then be deleted.

## [0.1.0]

First release as a library (modules + reusable workflows + consumer template).

### Added
- `modules/bootstrap`:
  - compartment, adoption of the CLI-seeded state bucket
  - OCI quotas capping A1 and block storage at `free_tier_limits`
  - budget alerts, egress alarms
  - least-privilege state and CI (plan/apply) groups
  - home-region check
- `modules/cluster`: network + OKE composition, settings object with defaults,
  unknown-key and access-path validation, compartment lookup (no remote state).
- `modules/network`: default-deny VCN with NSGs. Private-only by default.
  Optional: Tailscale direct UDP, public ingress, IPv6 LB subnet, private workers.
- `modules/oke-cluster`: BASIC OKE, A1 node pool, plan-time free-tier guards,
  zero-surge cycling.
- Reusable workflows:
  - `stack.yml`: plan / deploy / drift, with redacted output, encrypted plan
    artifacts, and safe auto-apply.
  - `apply-plan.yml`: manual apply of a saved plan.
  - The tracking channel is pinned to a SHA per run.
- `templates/consumer` + `scripts/new-consumer.sh`: two-root consumer repo with
  one settings file and Renovate config.
- `make/consumer.mk` + `scripts/consumer/`: every consumer `make` target
  (`configure`, `doctor`, `seed`, `github-setup`, plan/apply, `ci-*`), fetched with
  the library by the consumer's bootstrap Makefile.
- `scripts/consumer/ci.sh`: CI-agnostic check/plan/apply/drift with redaction,
  saved-plan apply, safe classification and a change-list approval hash
  (`EXPECT_CHANGES_SHA256`). GitHub workflows are thin wrappers around it.
  Examples for GitLab CI, Forgejo/Gitea, Woodpecker and cron.

### Manual steps
- New installs: scaffold with `scripts/new-consumer.sh`, then follow the generated README.
