# Makefile — a discoverable façade over this repo's entry points.
# ──────────────────────────────────────────────────────────────────────────────
# Deliberately thin: it adds no logic beyond what CI already runs, so `make lint`
# == the reusable lint gate in dotfiles-core, and a green `make lint` means a green PR.
#
# NOT to be confused with core/Makefile — that is *dotfiles-core's* Makefile, which
# arrives with the vendored subtree. Its `audit` / `sync` / `release` targets operate on
# the Core repo and are meaningless from this vendored copy. This file is the entry point
# for THIS repo.
#
# The vendored core/ is excluded from every check here: it is gated upstream.
# ──────────────────────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help
.PHONY: help lint shellcheck syntax zsh-syntax markdown check dry-run links-only integrity hooks clean

# Repo-owned shell only — core/ is gated upstream. Mirrors the reusable gate's
# `git ls-files '*.sh' ':!:core/**'`.
SH_FILES  := $(shell git ls-files '*.sh' ':!:core/**' 2>/dev/null)
ZSH_FILES := $(shell git ls-files '*.zsh' ':!:core/**' 2>/dev/null)

help: ## Show this help
	@echo "dotfiles-Fedora — make targets:"
	@grep -E '^[a-z][a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| sed -E 's/:.*## /\t/' | sort | awk -F'\t' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

lint: shellcheck syntax zsh-syntax ## The gate: shellcheck + bash -n + zsh -n (what CI runs)
	@printf '\033[32m✓\033[0m lint clean\n'

shellcheck: ## ShellCheck the repo-owned bash (excludes the vendored core/)
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed: sudo dnf install ShellCheck"; exit 1; }
	@test -n "$(SH_FILES)" || { echo "no repo-owned .sh"; exit 0; }
	@echo "shellcheck -x $(SH_FILES)"
	@shellcheck -x $(SH_FILES)

syntax: ## bash -n the repo-owned bash, and check --help still works
	@test -n "$(SH_FILES)" || { echo "no repo-owned .sh"; exit 0; }
	@for f in $(SH_FILES); do echo "bash -n $$f"; bash -n "$$f" || exit 1; done
	@bash bootstrap.sh --help >/dev/null || { echo "bootstrap.sh --help failed"; exit 1; }

zsh-syntax: ## zsh -n the repo-owned zsh modules (shellcheck has no zsh mode)
	@command -v zsh >/dev/null 2>&1 || { echo "zsh not installed — skipping"; exit 0; }
	@test -n "$(ZSH_FILES)" || { echo "no repo-owned .zsh"; exit 0; }
	@for f in $(ZSH_FILES); do echo "zsh -n $$f"; zsh -n "$$f" || exit 1; done

markdown: ## markdownlint the repo-owned docs (shares .markdownlint.jsonc with Core)
	@command -v markdownlint-cli2 >/dev/null 2>&1 \
		|| { echo "markdownlint-cli2 not installed: npm i -g markdownlint-cli2 — skipping"; exit 0; }
	@markdownlint-cli2 '*.md' '!core/**'

dry-run: ## Preview the FULL bootstrap plan (packages + symlinks); changes nothing
	@./bootstrap.sh --dry-run

links-only: ## Re-wire the symlinks on THIS machine (no dnf, no downloads)
	@./bootstrap.sh --links-only

check: lint ## lint + a hermetic --links-only run against a throwaway HOME
	@tmp=$$(mktemp -d); \
	mkdir -p "$$tmp/.config/tmux/plugins/tpm"; \
	echo ":: bootstrap --links-only into $$tmp"; \
	HOME="$$tmp" ./bootstrap.sh --links-only >/dev/null || { echo "bootstrap failed"; rm -rf "$$tmp"; exit 1; }; \
	rc=0; \
	for l in .config/zsh/loader.zsh .config/zsh/80-os.zsh .config/starship.toml \
	         .config/lazygit/config.yml .config/nvim .vimrc .gitconfig; do \
	  test -L "$$tmp/$$l" || { echo "MISSING symlink: $$l"; rc=1; }; \
	done; \
	test -e "$$tmp/.config/zsh/loader.zsh" || { echo "loader.zsh is dangling"; rc=1; }; \
	test -f "$$tmp/.config/sesh/sesh.toml" || { echo "sesh.toml not seeded"; rc=1; }; \
	test -L "$$tmp/.config/sesh/sesh.toml" && { echo "sesh.toml must be a copy, not a link"; rc=1; }; \
	grep -q "dotfiles-managed v4" "$$tmp/.zshrc" || { echo "~/.zshrc not managed"; rc=1; }; \
	grep -q "source .*loader.zsh" "$$tmp/.zshrc" || { echo "~/.zshrc does not source the loader"; rc=1; }; \
	rm -rf "$$tmp"; \
	test $$rc -eq 0 && printf '\033[32m✓\033[0m symlink graph OK\n' || exit 1

integrity: ## Verify the vendored core/ is pristine vs core.lock (needs a sibling dotfiles-core)
	@ref=../dotfiles-core; \
	test -d "$$ref" || { echo "needs a sibling clone of dotfiles-core at $$ref"; echo "(the core_sha in core.lock only resolves in Core's object store — see core.lock)"; exit 1; }; \
	git -C "$$ref" cat-file -e "$$(sed -n 's/^core_sha=//p' core.lock)" 2>/dev/null || { \
	  echo ":: locked core_sha is not in $$ref yet — fetching (a stale reference clone reports"; \
	  echo "   UNVERIFIABLE, which reads like tampering but only means 'fetch Core')"; \
	  git -C "$$ref" fetch --quiet origin || true; }; \
	"$$ref/scripts/core-integrity.sh" --self "$(CURDIR)"

hooks: ## Install the pre-commit hooks into this clone
	@command -v pre-commit >/dev/null 2>&1 || { echo "pre-commit not installed: pip install pre-commit"; exit 1; }
	@pre-commit install
	@echo "run them all with: pre-commit run --all-files"

clean: ## Remove local scratch artifacts (never touches tracked files)
	@find . -name '*.pre-dotfiles.*' -maxdepth 2 -print -delete 2>/dev/null || true
