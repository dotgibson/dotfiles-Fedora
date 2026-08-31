# Changelog

All notable changes to **dotfiles-Fedora** (the OS-native layer) are recorded here.
Changes to the vendored `core/` subtree are *not* listed individually — they arrive as
Core releases; see [dotfiles-core's CHANGELOG](https://github.com/dotgibson/dotfiles-core/blob/main/CHANGELOG.md) and the
`core_version` in [`core.lock`](core.lock).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project uses [Conventional Commits](https://www.conventionalcommits.org/). Release tags
(`vX.Y.Z`) are cut automatically by the `auto-tag` workflow.

## [Unreleased]

### Fixed

- **`make zsh-syntax` and `make markdown` announced a skip and then ran anyway.** Each
  `make` recipe line runs in its own shell, so each guard's `exit 0` only ended that
  line: with `zsh` absent, `zsh-syntax` printed "zsh not installed — skipping" and then
  ran `zsh -n` (`Error 1`); with no global `markdownlint-cli2`, `markdown` printed its
  own skip and then ran the linter (`Error 127`). Both collapsed into one recipe line, so
  a skip is a real skip. This is the defect `dotfiles-Debian` recorded and fixed for its
  `zsh-syntax`, noting the shape survived in the other OS repos' Makefiles — this is that
  repo, and it had both (dotgibson/dotfiles-core#775).
- **`make markdown` also scanned the wrong files.** It globbed `'*.md'`, which is
  top-level only, while the reusable gate's markdown leg — **blocking** since
  dotgibson/dotfiles-core#592 — lints `git ls-files '*.md' ':!:core/**'`, recursively. The
  three `.github/` markdown files were therefore enforced by a required check and
  invisible locally, so this target could read green against a red PR. Now uses the same
  pathspec via a new `MD_FILES`. All nine files lint clean, so nothing was hiding.
- `.markdownlint.jsonc`'s header claimed the rules were "mirrored from Core rather than
  CI-enforced" and that "lint.yml skips `**.md` entirely". Both were true when written and
  neither survived dotgibson/dotfiles-core#592.

- **`bootstrap.sh` no longer fails on a machine without `sudo`.** The escalator is now
  resolved once (`BLIB_SU`: empty as root, else `sudo`, else `doas`) and used everywhere,
  instead of a hard-coded `sudo` at a dozen call sites. A container, a WSL first boot, or
  a minimal Server image previously died at the first `dnf` line with
  `sudo: command not found` (exit 127) before doing anything.
- **`bootstrap.sh` can no longer stall on an invisible password prompt.** The `sudo`
  timestamp is primed up front and refreshed in the background for the life of the run,
  and privileged calls no longer discard stderr. Previously, calls placed after the
  multi-minute cargo/go builds outlived the 5-minute timestamp and blocked on a prompt
  written to `/dev/null` — indistinguishable from a hang.
- **Re-running `bootstrap.sh` no longer rebuilds the Rust/Go tools from source.** The
  presence guards probed `PATH`, but `~/.cargo/bin` and `~/.local/bin` are only added by
  `os/fedora.zsh` — i.e. only inside a Core *zsh* — so a run from bash rebuilt all six
  crates plus yazi every time. `provision()` now puts both bindirs on `PATH` first.
- **A failed step is now reported.** Best-effort failures are collected and printed as a
  closing summary instead of being swallowed, so a box missing carapace, `op`, lazygit and
  every cargo tool no longer reports `bootstrap complete`. `--strict` exits non-zero.
- **`/etc/wsl.conf` is backed up before it is overwritten** (`.pre-dotfiles.<epoch>`,
  matching every other managed file). It was the one destructive write with no backup.
- **OS detection no longer matches Fedora-*like* distros by accident.** `ID=`/`ID_LIKE=`
  are parsed as keys; the old `grep -qi fedora /etc/os-release` also matched Rocky, Alma,
  CentOS Stream, Nobara, and any incidental substring such as a URL. Fedora-like distros
  are now an explicit `--force-os` opt-in.
- **`--help` no longer drifts.** It was `sed -n '2,17p' "$0"`, coupled to the header's line
  numbers — the exact trap `core/scripts/sync-core.sh` documents. It is a heredoc now.
- **`.gitignore` no longer ignores the tracked `core/.claude/` files.** The `.claude/`
  pattern was unanchored, so it matched at any depth — a hazard for a vendored tree whose
  git tree SHA must match `core.lock`.
- **Three availability claims in `bootstrap.sh` that stopped being true.** The section
  header, the `dust` spinner label and the `viddy` comment all said dust is not packaged
  on Fedora; `du-dust` has shipped continuously (F43 `1.2.4-2`, F44 `1.2.4-5`, rawhide
  `1.2.5-1.fc46`). They now name only the tools that genuinely need a source build.
- **`install/packages.txt` dates the `wget` virtualisation to F40, not F42.** Fedora's
  [Wget2asWget](https://fedoraproject.org/wiki/Changes/Wget2asWget) change targeted
  Fedora Linux 40 — the note was two releases late. The rest of it (no package literally
  named `wget`, default provider `wget2-wget`, pin `wget1-wget` for classic semantics)
  was already correct.

### Added

- **`os/fedora.capabilities`** — this repo's Core v5 capability declaration
  (dotgibson/dotfiles-core#663, #667). Core's `up`, maint runner and `core-doctor` now
  dispatch through it rather than through package-manager branches inside portable Core
  modules. Fedora is the repo `core/examples/os.capabilities.example` was written from,
  so this is that example made real. `MAINT_UNATTENDED_UPGRADE=1` — a versioned,
  non-rolling distro whose stable updates are what an unattended nightly is for, and what
  this box already did; the operator's `MAINT_SYSTEM_UPGRADE=1` is still the first of the
  two gates.
- **`make capabilities`** — validates `os/*.capabilities` against Core's schema via the
  vendored `core/scripts/check-capabilities.sh`, and runs as part of `make lint`.
- `bootstrap.sh --dry-run` — previews the whole plan (packages *and* the symlink graph)
  and changes nothing, via the shared lib's `BLIB_DRY`; prints the wiring tally.
- `bootstrap.sh --strict` and `--force-os`; a preflight that checks for the commands the
  script assumes and fails once with the full list.
- `bootstrap.sh` now installs the `core/` pre-commit guard on a fresh clone
  (`blib_install_core_guard`), which the shared lib always intended but was never called.
- **1Password's signing key is fingerprint-verified** before `rpm --import`; a mismatch
  fails closed. The three upstream install scripts are downloaded, sanity-checked, then
  run — never `curl | sh` — and starship installs to `~/.local/bin`, needing no root.
- Root repo scaffolding that GitHub can actually see (it previously existed only under
  `core/`, where GitHub ignores it): `CONTRIBUTING.md`, `SECURITY.md`, `CODEOWNERS`, PR and
  issue templates, `.editorconfig`, `.shellcheckrc`, `.gitattributes`,
  `.pre-commit-config.yaml`, this changelog, and a thin `Makefile`
  (`make lint` / `check` / `dry-run` / `integrity` / `hooks`).
- `packages` workflow — resolves every name in `install/packages.txt` against a matrix of
  supported Fedora releases, replacing hand-maintained availability prose with a check.
- **`du-dust` to `install/packages.txt` — `dust` is an RPM, not a from-source build.**
  Fedora packages it under the same name Debian does (`du-dust`, binary `/usr/bin/dust`),
  and every fresh box was instead spending minutes on `cargo install --locked du-dust` for
  a tool `dnf` already had. The cargo block stays as a presence-guarded fallback: it is a
  no-op once the RPM is in, and it is what catches `dnf --skip-unavailable` silently
  dropping the name if `du-dust` ever follows `sd`/`gron` out of the repos.

### Removed

- A stale 4.5 MB orphaned worktree copy under `.claude/worktrees/`, and the obsolete
  `zsh/local.zsh` ignore entry (host overrides have lived at
  `~/.config/zsh/99-local.zsh` since v4).
