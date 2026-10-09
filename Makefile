# Development entry points. Run `make help` for the list.
.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

.PHONY: help tools

help: ## Show available targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

tools: ## Install the pinned toolchain into .tools/
	@scripts/install-tools.sh
