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
.PHONY: help lint shellcheck syntax zsh-syntax markdown check dry-run links-only packages-check core-verify integrity hooks clean capabilities

# Repo-owned shell only — core/ is gated upstream. Mirrors the reusable gate's
# `git ls-files '*.sh' ':!:core/**'`.
SH_FILES  := $(shell git ls-files '*.sh' ':!:core/**' 2>/dev/null)
ZSH_FILES := $(shell git ls-files '*.zsh' ':!:core/**' 2>/dev/null)
# Same pathspec the reusable gate's markdown leg uses, so `make markdown` scans exactly
# what CI scans — including the .github/ files a top-level '*.md' glob never saw.
MD_FILES  := $(shell git ls-files '*.md' ':!:core/**' 2>/dev/null)

help: ## Show this help
	@echo "dotfiles-Fedora — make targets:"
	@grep -E '^[a-z][a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
		| sed -E 's/:.*## /\t/' | sort | awk -F'\t' '{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

lint: shellcheck syntax zsh-syntax capabilities ## The gate: shellcheck + bash -n + zsh -n (what CI runs)
	@printf '\033[32m✓\033[0m lint clean\n'

shellcheck: ## ShellCheck the repo-owned bash (excludes the vendored core/)
	@command -v shellcheck >/dev/null 2>&1 || { \
	  if [ "$$(id -u 2>/dev/null)" = 0 ]; then p=""; elif command -v sudo >/dev/null 2>&1; then p="sudo "; else p="<as root> "; fi; \
	  echo "shellcheck not installed: $${p}dnf install ShellCheck"; exit 1; }
	@test -n "$(SH_FILES)" || { echo "no repo-owned .sh"; exit 0; }
	@echo "shellcheck -x $(SH_FILES)"
	@shellcheck -x $(SH_FILES)

syntax: ## bash -n the repo-owned bash, and check --help still works
	@test -n "$(SH_FILES)" || { echo "no repo-owned .sh"; exit 0; }
	@for f in $(SH_FILES); do echo "bash -n $$f"; bash -n "$$f" || exit 1; done
	@bash bootstrap.sh --help >/dev/null || { echo "bootstrap.sh --help failed"; exit 1; }

zsh-syntax: ## zsh -n the repo-owned zsh modules (shellcheck has no zsh mode)
	@# ONE recipe line, deliberately. make runs each line in its own shell, so the
	@# `exit 0` in a multi-line version only ends THAT line — the guard printed
	@# "skipping" and then the next line ran `zsh -n` anyway and failed. Joining them
	@# makes the skip a real skip.
	@if ! command -v zsh >/dev/null 2>&1; then echo "zsh not installed — skipping"; \
	elif test -z "$(ZSH_FILES)"; then echo "no repo-owned .zsh"; \
	else for f in $(ZSH_FILES); do echo "zsh -n $$f"; zsh -n "$$f" || exit 1; done; fi

markdown: ## markdownlint the repo-owned docs (shares .markdownlint.jsonc with Core)
	@# Same one-line reason as zsh-syntax above.
	@#
	@# The file list is `git ls-files`, not a `'*.md'` glob, to match what the gate
	@# actually scans: lint-call.yml's markdown leg has been BLOCKING since dotfiles-core#592
	@# and lints `git ls-files '*.md' ':!:core/**'` — which is recursive. The glob was
	@# top-level only, so the three .github/ markdown files were CI-enforced and locally
	@# invisible, and this target could read green against a red required check.
	@if ! command -v markdownlint-cli2 >/dev/null 2>&1; then \
	  echo "markdownlint-cli2 not installed: npm i -g markdownlint-cli2 — skipping"; \
	elif test -z "$(MD_FILES)"; then echo "no repo-owned .md"; \
	else echo "markdownlint-cli2 $(MD_FILES)"; markdownlint-cli2 $(MD_FILES); fi

dry-run: ## Preview the FULL bootstrap plan (packages + symlinks); changes nothing
	@./bootstrap.sh --dry-run

links-only: ## Re-wire the symlinks on THIS machine (no dnf, no downloads)
	@./bootstrap.sh --links-only

# ── the canonical fleet verbs (dotgibson/dotfiles-core#691) ───────────────────
# `packages-check` and `core-verify` are two of the seven names every repo that vendors
# Core must answer to (Core's scripts/make-vocabulary.txt; the register that checks it is
# `make fleet-vocabulary` there). Before that list, "verify core" had five spellings across
# nine repos and only `help` was common to every Makefile — a contributor re-learned the
# verbs in each repo and no gate noticed. The requirement is that the CANONICAL name
# exists, not that a historical one dies, so `integrity` below stays as an alias.

packages-check: ## Do all install/packages.txt names still resolve against dnf?
	@# The local half of the question two CI legs already ask — bootstrap.yml's
	@# `packages_check: dnf -q provides` and packages.yml's per-release matrix, both in a
	@# Fedora container. This runs against whatever dnf is in front of you: on a Fedora box
	@# it is the same answer, and off one it says so and STOPS rather than reporting a green
	@# it did not earn. The authoritative answer is per-release and lives in CI.
	@#
	@# `dnf provides`, NOT `dnf info`. bootstrap.sh installs these names with `dnf install`,
	@# which resolves `Provides:`, so the probe has to ask the same question. F41 retired
	@# `wget` in favour of wget2-wget carrying `Provides: wget` — `dnf install wget` works
	@# while `dnf info wget` fails, so a name-only probe red-flags a working package. That
	@# false alarm is the exact reason bootstrap.yml spells it `provides`; do not "fix" it.
	@command -v dnf >/dev/null 2>&1 || { echo "dnf not found — run this on Fedora (CI covers every supported release: .github/workflows/packages.yml)"; exit 1; }
	@set -e; \
	. core/lib/bootstrap-lib.sh; \
	pkgs=$$(blib_read_pkgs install/packages.txt); \
	[ -n "$$pkgs" ] || { echo "no packages parsed from install/packages.txt"; exit 1; }; \
	echo ":: resolving $$(echo "$$pkgs" | wc -l) package names (no download, no install)"; \
	rc=0; \
	for p in $$pkgs; do \
	  dnf -q provides "$$p" >/dev/null 2>&1 || { echo "  UNRESOLVED: $$p"; rc=1; }; \
	done; \
	if [ $$rc -eq 0 ]; then printf '\033[32m✓\033[0m all package names resolve\n'; else \
	  echo "^^ renamed, orphaned or retired upstream — each needs a rename in install/packages.txt"; \
	  echo "   or a presence-guarded cargo/go fallback in bootstrap.sh (the pattern already used"; \
	  echo "   for sd, gron, dust, xh, viddy, tealdeer and procs)"; fi; \
	exit $$rc

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

core-verify: ## Verify the vendored core/ is pristine vs core.lock (needs a sibling dotfiles-core)
	@ref=../dotfiles-core; \
	test -d "$$ref" || { echo "needs a sibling clone of dotfiles-core at $$ref"; echo "(the core_sha in core.lock only resolves in Core's object store — see core.lock)"; exit 1; }; \
	git -C "$$ref" cat-file -e "$$(sed -n 's/^core_sha=//p' core.lock)" 2>/dev/null || { \
	  echo ":: locked core_sha is not in $$ref yet — fetching (a stale reference clone reports"; \
	  echo "   UNVERIFIABLE, which reads like tampering but only means 'fetch Core')"; \
	  git -C "$$ref" fetch --quiet origin || true; }; \
	"$$ref/scripts/core-integrity.sh" --self "$(CURDIR)"

# This repo's historical spelling for the target above, kept so anything that already
# calls it — muscle memory, a local script, a runbook line — keeps working. Two lines is
# the whole cost of not breaking those; see the vocabulary note at `packages-check`.
integrity: core-verify ## (alias) the pre-#691 spelling of core-verify

hooks: ## Install the pre-commit hooks into this clone
	@command -v pre-commit >/dev/null 2>&1 || { echo "pre-commit not installed: pip install pre-commit"; exit 1; }
	@pre-commit install
	@echo "run them all with: pre-commit run --all-files"

clean: ## Remove local scratch artifacts (never touches tracked files)
	@find . -name '*.pre-dotfiles.*' -maxdepth 2 -print -delete 2>/dev/null || true

# ── the OS capability declaration (Core v5, #663/#667) ────────────────────────
# ONE definition of the schema gates all seven declaring repos: the validator is
# core/scripts/check-capabilities.sh, vendored with Core, so a schema change arrives
# with the next sync instead of needing seven hand-written greps to be updated in
# step. Core's own `make audit` runs the same script over its shipped example and
# sweeps the fleet for these files; this is the local half of that gate.
#
# The glob is guarded because an unmatched glob stays LITERAL in sh — without the
# test this would "validate" a file named `os/*.capabilities` and pass on nothing,
# which is the failure mode a gate must never have.
capabilities: ## Validate os/*.capabilities against Core's schema
	@rc=0; found=0; \
	for f in os/*.capabilities; do \
	  [ -e "$$f" ] || continue; found=1; \
	  core/scripts/check-capabilities.sh "$$f" --packages install/packages.txt || rc=1; \
	done; \
	if [ "$$found" -eq 0 ]; then echo "!! no os/*.capabilities — this repo must declare one (see core/examples/os.capabilities.example)"; rc=1; fi; \
	exit $$rc

