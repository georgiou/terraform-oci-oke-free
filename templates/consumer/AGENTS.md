# AGENTS.md

This repo is the **configuration** of one OKE cluster built from the
oci-oke-free library (`modules_source` / `module_ref` in `config/settings.tfvars`).
The library holds the logic. This repo holds choices and any extra resources the owner adds.

## Rules

1. **Change behaviour through `config/settings.tfvars`.** The `bootstrap = {…}` and
   `cluster = {…}` objects take the keys in the library's `modules/*/settings.tf`.
   Unknown keys fail validation. Read those files at the version in `module_ref`
   rather than guessing key names.
2. **Don't copy library code into this repo,** and don't fork modules locally.
   If the library can't express something, add the resource next to the module
   call in `stacks/cluster/` (or propose a library change upstream).
3. **Don't edit `shared/*.tf` or the `Makefile`** unless a library release's
   CHANGELOG says to. They're boilerplate the library expects. Make targets come
   from the library (`.lib/`, gitignored), so never edit files under `.lib/`.
4. **Leave `module_ref` and the workflow `@ref`s to Renovate** on a release channel.
   On a tracking channel (`main`), they stay `main`.
5. **Never put secrets in tracked files.** The passphrase goes in
   `TF_VAR_state_passphrase`, keys in GitHub secrets, and nothing in
   `config/settings.tfvars` is secret.
6. **Never run the bootstrap root from CI,** and never apply without a reviewed
   saved plan (`make plan-<root>` then `make apply-<root>`, or CI's `apply` workflow).
7. **Stay inside Always Free.** Don't add resources that cost money; the plan
   guards and OCI quotas will reject A1 or storage beyond the allowance anyway.
   If you add resources, use `freeform_tags`.

## Commands

```bash
make                             # list targets (fetches the library on first run)
make doctor                      # preflight
make plan-cluster                # needs TF_VAR_state_passphrase and the state S3 keys
make apply-cluster
make fmt && make lock            # after adding providers or changing the library version
make ci-check ci-plan            # what CI runs (any CI); see README -> Without GitHub
```

Report what you verified (fmt, validate, plan) and what you couldn't (no credentials).
