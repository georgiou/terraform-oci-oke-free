# Library repo targets. Consumers use templates/consumer/Makefile instead.
SHELL  := /usr/bin/env bash
TOFU   ?= tofu
TESTED := modules/network modules/oke-cluster modules/bootstrap modules/cluster
# Example consumer wired to the local modules, used to validate the template.
EXAMPLE := $(CURDIR)/.ci/example-consumer

.PHONY: help fmt test test-ci validate-template
.DEFAULT_GOAL := help

help:
	@echo "make fmt | test | test-ci | validate-template"
	@echo "scripts/new-consumer.sh <dir> [--ref vX.Y.Z|main]   scaffold a consumer repo"

fmt:
	$(TOFU) fmt -recursive

test:
	@for m in $(TESTED); do echo "== $$m"; $(TOFU) -chdir=$$m init -backend=false -input=false >/dev/null && $(TOFU) -chdir=$$m test || exit 1; done

# Provider-free CI fixture and local bootstrap workflow mocks (no credentials).
test-ci:
	@tests/ci/run.sh
	@python3 tests/ci/onboarding.py
	@bash tests/ci/library-ref.sh

# Scaffold a consumer against the local modules and validate both roots with
# the template's example settings, so the template can't rot.
validate-template:
	@rm -rf $(EXAMPLE) && scripts/new-consumer.sh $(EXAMPLE) --upstream example/oci-oke-free --ref main --local >/dev/null
	@cp $(EXAMPLE)/config/settings.tfvars.example $(EXAMPLE)/config/settings.tfvars
	@for r in bootstrap cluster; do \
	  echo "== template root $$r"; \
	  TF_VAR_state_passphrase=validate-only-passphrase \
	    $(TOFU) -chdir=$(EXAMPLE)/stacks/$$r init -backend=false -input=false -var-file=$(EXAMPLE)/config/settings.tfvars >/dev/null && \
	  TF_VAR_state_passphrase=validate-only-passphrase \
	    $(TOFU) -chdir=$(EXAMPLE)/stacks/$$r validate -var-file=$(EXAMPLE)/config/settings.tfvars || exit 1; \
	done
	@echo "== template cluster root: mocked plan with the example settings"
	@mkdir -p $(EXAMPLE)/stacks/cluster/tests && cp tests/consumer-cluster.tftest.hcl $(EXAMPLE)/stacks/cluster/tests/
	@TF_VAR_state_passphrase=validate-only-passphrase \
	  $(TOFU) -chdir=$(EXAMPLE)/stacks/cluster test -var-file=$(EXAMPLE)/config/settings.tfvars
	@echo "== template Makefile: fetches the library and exposes its targets"
	@$(MAKE) -s -C $(EXAMPLE) help | grep 'ci-plan' >/dev/null && echo "consumer make targets ok"
	@test "$$(readlink $(EXAMPLE)/.lib/root)" = "$(CURDIR)" && echo "library resolved to this checkout"
	@$(TOFU) fmt -recursive -check $(EXAMPLE) >/dev/null && echo "template fmt ok"
