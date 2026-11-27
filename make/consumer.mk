# Targets for consumer repos, shipped with the library and included by the
# consumer's bootstrap Makefile (which sets LIB to the library checkout). Being
# part of the library, they update with module_ref like the modules do.
TOFU      ?= tofu
VARFILE   := $(CURDIR)/config/settings.tfvars
ROOTS     := bootstrap cluster
SCRIPTS   := $(LIB)/scripts/consumer
PLATFORMS := -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=darwin_amd64
TOFU_ARGS ?=
export CONSUMER_ROOT := $(CURDIR)
export CONSUMER_LIB := $(abspath $(LIB))
export TOFU
export CONSUMER_MAKE := $(MAKE)

.PHONY: help configure doctor seed github-setup check-env check-s3 fmt lock up kubeconfig review-plan \
        bootstrap-plan bootstrap-apply state-credentials session ci-check ci-plan ci-apply ci-apply-if-safe ci-drift
.DEFAULT_GOAL := help

# Plan and apply are separate operator decisions, not parallel Make goals.
ifneq ($(filter up plan-% bootstrap-plan,$(MAKECMDGOALS)),)
ifneq ($(filter apply-% bootstrap-apply,$(MAKECMDGOALS)),)
$(error Plan and apply must be run as separate commands with review between them)
endif
endif

help:
	@echo "First time (README.md):"
	@echo "  make bootstrap-plan     configure, seed and save a bootstrap plan"
	@echo "  make bootstrap-apply    review and apply the saved bootstrap plan"
	@echo "  make state-credentials  resume the dedicated state-key handoff"
	@echo "  make session            open a local shell with state credentials loaded"
	@echo "  make up                 plan the cluster; apply only after review"
	@echo "  make kubeconfig     write ~/.kube/config"
	@echo "  make github-setup   load CI secrets/variables into a GitHub repo"
	@echo "Per root: init-<r> plan-<r> apply-<r> destroy-<r>   (roots: $(ROOTS))"
	@echo "CI (any system, env-driven): ci-check ci-plan ci-apply ci-apply-if-safe ci-drift"
	@echo "Other:    fmt lock lib-update review-plan RUN=<github run id>"
	@echo "Library:  $$(readlink $(LIB) 2>/dev/null || echo $(LIB))"

configure:    ; @$(SCRIPTS)/configure.sh
doctor:       ; @$(SCRIPTS)/doctor.sh
seed:         ; @$(SCRIPTS)/seed.sh
github-setup: ; @$(SCRIPTS)/github-setup.sh

bootstrap-plan:   ; @$(SCRIPTS)/bootstrap-flow.sh plan
bootstrap-apply:  ; @$(SCRIPTS)/bootstrap-flow.sh apply
state-credentials: ; @$(SCRIPTS)/bootstrap-flow.sh credentials
session:           ; @$(SCRIPTS)/bootstrap-flow.sh session

ci-check:         ; @$(SCRIPTS)/ci.sh check
ci-plan:          ; @$(SCRIPTS)/ci.sh plan
ci-apply:         ; @$(SCRIPTS)/ci.sh apply
ci-apply-if-safe: ; @$(SCRIPTS)/ci.sh apply --if-safe
ci-drift:         ; @$(SCRIPTS)/ci.sh drift

check-env:
	@test -f $(VARFILE) || { echo "missing config/settings.tfvars (run: make configure)"; exit 1; }
	@test -n "$$TF_VAR_state_passphrase" || { echo "export TF_VAR_state_passphrase"; exit 1; }

check-s3:
	@test -n "$$AWS_ACCESS_KEY_ID" -a -n "$$AWS_SECRET_ACCESS_KEY" || { echo "export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (state Customer Secret Key)"; exit 1; }

# Routine commands keep the installed provider/module versions. Use lib-update
# and lock explicitly to update them.
init-%: check-env check-s3
	$(TOFU) -chdir=stacks/$* init -input=false -var-file="$(VARFILE)" $(TOFU_ARGS)

plan-%:
	@rm -f "stacks/$*/tfplan" "stacks/$*/pending.tfplan"
	+$(MAKE) init-$*
	@set -e; pending="$(CURDIR)/stacks/$*/pending.tfplan"; trap 'rm -f "$$pending"' EXIT; \
	 $(TOFU) -chdir=stacks/$* plan -var-file="$(VARFILE)" $(TOFU_ARGS) -out="$$pending"; \
	 if [ "$*" = cluster ]; then $(SCRIPTS)/check-cluster-access.sh "$$pending"; fi; \
	 mv -f "$$pending" "stacks/$*/tfplan"

apply-%: check-env check-s3
	@test -s "stacks/$*/tfplan" || { echo "No saved plan: run make plan-$* and review it first." >&2; exit 1; }
	$(TOFU) -chdir=stacks/$* apply tfplan && rm -f "stacks/$*/tfplan"

destroy-%: init-%
	$(TOFU) -chdir=stacks/$* destroy -var-file=$(VARFILE) $(TOFU_ARGS)

up: plan-cluster
	@echo 'Review the plan above, then run make apply-cluster.'

kubeconfig: init-cluster
	@$(SCRIPTS)/kubeconfig.sh

# Inspect a plan GitHub CI produced (OpenTofu-encrypted artifact; needs the passphrase).
review-plan:
	@test -n "$(RUN)" || { echo "usage: make review-plan RUN=<github run id>"; exit 1; }
	rm -rf .ci/review && gh run download $(RUN) -n tfplan-cluster -D .ci/review
	@ref=$$(cat .ci/review/module_ref) && [[ "$$ref" =~ ^([0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+)?$$ ]] && \
	 "$$CONSUMER_MAKE" init-cluster TOFU_ARGS="-var module_ref=$$ref" && \
	 $(TOFU) -chdir=stacks/cluster show -var-file="$(VARFILE)" -var "module_ref=$$ref" "$(CURDIR)/.ci/review/tfplan"

fmt:
	$(TOFU) fmt -recursive

# Commit the resulting .terraform.lock.hcl files (CI refuses to run without them).
lock: check-env
	@set -e; for r in $(ROOTS); do $(TOFU) -chdir=stacks/$$r init -backend=false -upgrade -var-file="$(VARFILE)" $(TOFU_ARGS) >/dev/null; $(TOFU) -chdir=stacks/$$r providers lock $(PLATFORMS); done
