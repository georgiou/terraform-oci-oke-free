# Bootstrap only: fetches the oci-oke-free library at module_ref (no
# credentials needed) and includes its targets, so they update with the
# library. Run `make` for the list. You shouldn't need to edit this file.
SHELL    := /usr/bin/env bash
TOFU     ?= tofu
SETTINGS := $(if $(wildcard config/settings.tfvars),config/settings.tfvars,config/settings.tfvars.example)
LIB      := .lib/root

-include .lib/lib.mk

# Re-fetched whenever your settings change (e.g. a module_ref bump).
.lib/lib.mk: $(SETTINGS)
	@mkdir -p .lib
	@src=$$(sed -nE 's/^[[:space:]]*modules_source[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' $(SETTINGS) | head -n1); \
	 ref=$$(sed -nE 's/^[[:space:]]*module_ref[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' $(SETTINGS) | head -n1); \
	 echo "fetching library: $$src @ $${ref:-local}" >&2; \
	 $(TOFU) -chdir=stacks/cluster get -update -var "modules_source=$$src" -var "module_ref=$$ref" >/dev/null || exit 1; \
	 dir=$$(grep -o '"Key":"cluster"[^}]*' stacks/cluster/.terraform/modules/modules.json | sed -E 's/.*"Dir":"([^"]*)".*/\1/'); \
	 ln -sfn "$$(cd "stacks/cluster/$$dir/../.." && pwd)" $(LIB); \
	 echo 'include $(LIB)/make/consumer.mk' > $@

# Force a re-fetch (tracking channel: picks up the newest commit).
.PHONY: lib-update
lib-update:
	@rm -f .lib/lib.mk && $(MAKE) --no-print-directory -s help >/dev/null && echo "library: $$(readlink $(LIB))"
