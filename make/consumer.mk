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

.PHONY: help configure doctor seed github-setup check-env check-s3 fmt lock up kubeconfig review-plan \
        ci-check ci-plan ci-apply ci-apply-if-safe ci-drift
.DEFAULT_GOAL := help

help:
	@echo "First time (README.md):"
	@echo "  make configure      create config/settings.tfvars from your OCI CLI profile"
	@echo "  make doctor         preflight checks"
	@echo "  make seed           create the state bucket (once)"
	@echo "  make plan-bootstrap apply-bootstrap"
	@echo "  make up             plan + apply the cluster"
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

# -upgrade re-fetches the library, so a tracking channel picks up new commits.
init-%: check-env check-s3
	$(TOFU) -chdir=stacks/$* init -upgrade -var-file=$(VARFILE) $(TOFU_ARGS)

plan-%: init-%
	$(TOFU) -chdir=stacks/$* plan -var-file=$(VARFILE) $(TOFU_ARGS) -out=tfplan

apply-%:
	$(TOFU) -chdir=stacks/$* apply tfplan && rm -f stacks/$*/tfplan

destroy-%: init-%
	$(TOFU) -chdir=stacks/$* destroy -var-file=$(VARFILE) $(TOFU_ARGS)

up: plan-cluster apply-cluster

kubeconfig: init-cluster
	eval "$$($(TOFU) -chdir=stacks/cluster output -raw kubeconfig_command)"

# Inspect a plan GitHub CI produced (OpenTofu-encrypted artifact; needs the passphrase).
review-plan:
	@test -n "$(RUN)" || { echo "usage: make review-plan RUN=<github run id>"; exit 1; }
	rm -rf .ci/review && gh run download $(RUN) -n tfplan-cluster -D .ci/review
	$(MAKE) init-cluster TOFU_ARGS="-var module_ref=$$(cat .ci/review/module_ref)"
	cp .ci/review/tfplan stacks/cluster/tfplan
	$(TOFU) -chdir=stacks/cluster show tfplan

fmt:
	$(TOFU) fmt -recursive

# Commit the resulting .terraform.lock.hcl files (CI refuses to run without them).
lock: check-env
	@for r in $(ROOTS); do $(TOFU) -chdir=stacks/$$r init -backend=false -upgrade -var-file=$(VARFILE) $(TOFU_ARGS) >/dev/null && $(TOFU) -chdir=stacks/$$r providers lock $(PLATFORMS); done
