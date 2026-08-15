# Changelog

All notable changes to **dotfiles-Fedora** (the OS-native layer) are recorded here.
Changes to the vendored `core/` subtree are *not* listed individually — they arrive as
Core releases; see [`core/CHANGELOG.md`](core/CHANGELOG.md) and the `core_version` in
[`core.lock`](core.lock).

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project uses [Conventional Commits](https://www.conventionalcommits.org/). Release tags
(`vX.Y.Z`) are cut automatically by the `auto-tag` workflow.

## [Unreleased]

### Fixed

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

### Added

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

### Removed

- A stale 4.5 MB orphaned worktree copy under `.claude/worktrees/`, and the obsolete
  `zsh/local.zsh` ignore entry (host overrides have lived at
  `~/.config/zsh/99-local.zsh` since v4).
