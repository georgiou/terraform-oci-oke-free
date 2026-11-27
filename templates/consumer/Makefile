# Bootstrap only: fetches the oci-oke-free library at module_ref (no
# credentials needed) and includes its targets, so they update with the
# library. Run `make` for the list. You shouldn't need to edit this file.
SHELL    := /usr/bin/env bash
TOFU     ?= tofu
SETTINGS := $(if $(wildcard config/settings.tfvars),config/settings.tfvars,config/settings.tfvars.example)
LIB      := .lib/root$(if $(LIB_REF),-$(LIB_REF))
# Do not load the pre-upgrade .lib/lib.mk, which can still define an applying `up`.
LIB_MK   := .lib/tooling-v2$(if $(LIB_REF),-$(LIB_REF)).mk
BOOTSTRAP_MK := $(firstword $(MAKEFILE_LIST))
export LIB_REF

include $(LIB_MK)

# Re-fetch when either the module settings or this bootstrap Makefile changes.
$(LIB_MK): $(SETTINGS) $(BOOTSTRAP_MK)
	@mkdir -p .lib
	@src=$$(sed -nE 's/^[[:space:]]*modules_source[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' $(SETTINGS) | head -n1); \
	 ref=$$(sed -nE 's/^[[:space:]]*module_ref[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' $(SETTINGS) | head -n1); \
	 if [ -n "$$LIB_REF" ]; then [[ "$$LIB_REF" =~ ^([0-9a-f]{40}|v[0-9]+\.[0-9]+\.[0-9]+)$$ ]] || exit 1; ref=$$LIB_REF; fi; \
	 echo "fetching library: $$src @ $${ref:-local}" >&2; \
	 cache="$(CURDIR)/.lib/get$(if $(LIB_REF),-$(LIB_REF))"; \
	 TF_DATA_DIR="$$cache" $(TOFU) -chdir=stacks/cluster get -update -var "modules_source=$$src" -var "module_ref=$$ref" >/dev/null || exit 1; \
	 dir=$$(grep -o '"Key":"cluster"[^}]*' "$$cache/modules/modules.json" | sed -E 's/.*"Dir":"([^"]*)".*/\1/'); \
	 [ -n "$$dir" ] || exit 1; \
	 case "$$dir" in /*) ;; *) dir="stacks/cluster/$$dir" ;; esac; \
	 checkout=$$(cd "$$dir/../.." && pwd) && ln -sfn "$$checkout" $(LIB) && \
	 echo 'include $(LIB)/make/consumer.mk' > $@

# Force a re-fetch (tracking channel: picks up the newest commit).
.PHONY: lib-update
lib-update:
	@rm -f $(LIB_MK) && $(MAKE) --no-print-directory -s help >/dev/null && echo "library: $$(readlink $(LIB))"
	@set -e; if [ -f config/settings.tfvars ]; then for stack in bootstrap cluster; do \
	  if [ -d "stacks/$$stack/.terraform/modules" ]; then \
	    $(TOFU) -chdir="stacks/$$stack" get -update -var-file="$(CURDIR)/config/settings.tfvars" >/dev/null; fi; done; fi
