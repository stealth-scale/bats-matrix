# Container-first development. `make help` lists targets and configuration.
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

RUNTIME      ?= podman
IMAGE        ?= docker.io/bats/bats:latest
TARGET       ?= tests/
BATS         ?= bats
BATS_FLAGS   ?= --print-output-on-failure
SHELLCHECK   ?= shellcheck
PREFIX       ?= /usr/local
LIBDIR        = $(PREFIX)/lib/bats-matrix

SOURCES = load.bash $(wildcard src/*.bash)
TESTS   = $(wildcard tests/*.bats)

# Disable SELinux separation for this ephemeral container instead of relabelling
# the checkout. Sources are read-only; tests write temporary files in the container.
CONTAINER_USER ?= $(shell id -u):$(shell id -g)
USERNS_FLAGS = $(if $(filter podman,$(notdir $(RUNTIME))),--userns=keep-id)
RUN = "$(RUNTIME)" run --rm --network=none --cap-drop=ALL \
	--security-opt=no-new-privileges --security-opt=label=disable \
	$(USERNS_FLAGS) --user "$(CONTAINER_USER)" \
	--workdir /code --volume "$(CURDIR):/code:ro"

.PHONY: help test test-host lint check shell install uninstall

help: ## List targets and configurable defaults
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{ printf "  %-10s %s\n", $$1, $$2 }'
	@printf '\nDefaults (override with NAME=value):\n  RUNTIME=%s\n  IMAGE=%s\n  TARGET=%s\n  BATS=%s (test-host only)\n  BATS_FLAGS=%s\n  SHELLCHECK=%s\n' \
		"$(RUNTIME)" "$(IMAGE)" "$(TARGET)" "$(BATS)" "$(BATS_FLAGS)" "$(SHELLCHECK)"

test: ## Run TARGET in the official Bats container
	$(RUN) "$(IMAGE)" $(BATS_FLAGS) --recursive "$(TARGET)"

test-host: ## Run TARGET using the host's Bats and Bash
	"$(BATS)" $(BATS_FLAGS) --recursive "$(TARGET)"

lint: ## Run shellcheck over the loader, the sources and the tests
	"$(SHELLCHECK)" $(SOURCES) $(TESTS)

check: lint test ## Run lint and container tests

shell: ## Open an interactive shell with the checkout mounted read-only
	$(RUN) --interactive --tty --entrypoint bash "$(IMAGE)"

install: ## Copy the library to $(LIBDIR), for `load` by absolute path
	install -d "$(DESTDIR)$(LIBDIR)/src"
	install -m 0644 load.bash "$(DESTDIR)$(LIBDIR)/"
	install -m 0644 src/*.bash "$(DESTDIR)$(LIBDIR)/src/"

uninstall: ## Remove the library from $(LIBDIR)
	@[[ "$(DESTDIR)$(LIBDIR)" == */bats-matrix ]] || { echo 'Refusing an unsafe uninstall path' >&2; exit 1; }
	rm -rf -- "$(DESTDIR)$(LIBDIR)"
