# Repo tasks. shfmt, shellcheck and bashly come from Homebrew; prettier from mise.toml (docs/development.md).
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

FILES = git ls-files --cached --others --exclude-standard --deduplicate
# Shell files: what shfmt detects (extension or shebang) plus sourced files that only carry a
# `# shellcheck shell=` directive. bin/devbox is bashly output: format cli/, then `make build`.
SH_SRC := $(filter-out bin/devbox,$(sort \
	$(shell $(FILES) | xargs shfmt -f) \
	$(shell $(FILES) ':!*.md' ':!*.yml' | xargs grep -ls '^\# shellcheck shell=')))
# cli/ bodies only make sense assembled, so shellcheck lints bin/devbox instead.
SH_LINT := bin/devbox $(filter-out cli/%,$(SH_SRC))
# Run on the laptop under whatever bash it resolves, macOS's 3.2 included (docs/cli.md). The parse is a
# bash 3.2 check on macOS only; elsewhere /bin/bash is newer.
SH_BASH32 := home/.local/libexec/devbox-identities home/.local/bin/devbox-gh-token \
	$(wildcard home/.local/libexec/devbox-agent/*)
# Markdown and YAML; .prettierignore keeps AGENTS.md out.
PRETTIER_SRC := $(wildcard $(shell $(FILES) '*.md' '*.yml' '*.yaml'))
PRETTIER := mise exec -- prettier --log-level warn
# Flags, not .editorconfig, so the style cannot drift with an editor setting.
SHFMT := shfmt -i 2

.PHONY: help build fmt lint check fmt-check build-check

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

build: ## Generate bin/devbox from cli/ with bashly
	bashly generate --quiet

fmt: ## Format shell (shfmt), Markdown and YAML (prettier)
	$(SHFMT) -w $(SH_SRC)
	$(PRETTIER) --write $(PRETTIER_SRC)

lint: ## Lint shell (shellcheck) and parse the laptop-side scripts with /bin/bash
	shellcheck $(SH_LINT)
	for f in $(SH_BASH32); do /bin/bash -n "$$f"; done

check: fmt-check lint build-check ## Everything CI would run; changes nothing

fmt-check:
	$(SHFMT) -d $(SH_SRC)
	$(PRETTIER) --check $(PRETTIER_SRC)

build-check:
	tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	BASHLY_TARGET_DIR="$$tmp" bashly generate --quiet; \
	cmp -s bin/devbox "$$tmp/devbox" || { echo 'bin/devbox does not match cli/: run make build' >&2; exit 1; }
