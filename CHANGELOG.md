# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/). Versions: semver.
Consumers receive each release as a Renovate PR (or immediately on the
tracking channel), so every entry has **Manual steps**, even if that's "None".

## [Unreleased]

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
