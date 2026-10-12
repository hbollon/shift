# Development entry points. Run `make help` for the list.
.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

LUAU_LSP := .tools/bin/luau-lsp
LUAU_SOURCES = $(shell find shift tests -name '*.luau')

.PHONY: help tools test analyze lint validate catalog catalog-check check dev-install dev-uninstall clean

# Keep output readable even with a global `make -j`.
.NOTPARALLEL:

help: ## Show available targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

tools: ## Install the pinned toolchain into .tools/
	@scripts/install-tools.sh

test: tools ## Run the Luau test suite (FILTER=name to select specs)
	@scripts/run-tests.sh $(FILTER)

analyze: tools ## Type-check with luau-lsp and check that only lib/host.luau uses noctalia
	@$(LUAU_LSP) analyze --platform standard --definitions=@noctalia=.tools/noctalia.d.luau \
		--base-luaurc=.luaurc $(LUAU_SOURCES)
	@scripts/check-host.sh

lint: ## Cross-check declared settings against code (needs a local Noctalia)
	@command -v noctalia >/dev/null || { echo "noctalia not installed, skipping"; exit 0; }; \
		noctalia plugins lint shift

validate: tools ## Run the community-plugins store validator
	@scripts/validate-store.sh

catalog: ## Regenerate catalog.toml from shift/plugin.toml
	@scripts/catalog.py

catalog-check: ## Fail if catalog.toml is out of date
	@scripts/catalog.py --check

check: test analyze validate catalog-check lint ## Run every check (what CI runs, plus lint)

dev-install: ## Run this checkout on the running Noctalia (source, enable, widget, tile)
	@scripts/dev-install.py install

dev-uninstall: ## Undo dev-install, keeping Shift's data
	@scripts/dev-install.py uninstall

clean: ## Remove build output
	@rm -rf build
