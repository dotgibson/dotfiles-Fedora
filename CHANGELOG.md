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

- **The tmux auto-attach honours `DOTFILES_NO_AUTOTMUX`, the fleet's one opt-out name**
  (dotgibson/dotfiles-core#877). MacBook, openSUSE and Gentoo already read it; this layer
  attached unconditionally for any interactive TTY, which is how dotfiles-core's README hero
  render — a vhs session that sources this layer — typed its whole tour into a fresh `main`
  session. Core's `gen-hero-tape.sh` now refuses to render a hero on a layer that does not
  honour the knob. Export `DOTFILES_NO_AUTOTMUX=1` for any harness that drives an interactive
  zsh and must not land in tmux.

- **`make markdown` probed for a global, unpinned `markdownlint-cli2` — so on a normal box it
  never linted anything** (dotgibson/dotfiles-core#873). Nothing in this repo's bootstrap
  installs `markdownlint-cli2` globally; it is npm-only. So unless the operator had
  separately run `npm i -g markdownlint-cli2`, the guard fired on every invocation and the
  target skipped, cleanly and with exit 0, forever. That is a correct guard doing exactly
  what it says — and a local mirror of a **blocking** CI gate that has never mirrored
  anything. dotgibson/dotfiles-core#775 fixed this target's skip guard and its file scope;
  neither defect could bite while the target never ran at all. And where the binary *was*
  installed it was whatever version npm last put there, while `lint-call.yml` installs the
  pinned `MARKDOWNLINT_VERSION` — so a rule that changes across a bump reds a required check
  against a green local run. It now runs the **pinned** version through `npx`, reading the
  number from the vendored `core/scripts/tool-versions.env` rather than restating it, and
  **refuses** rather than guess if that pin is unreadable — a silently-unpinned lint being
  the thing this fixes. `npx` needs only node, which is far likelier present than a global
  markdownlint install, and still self-skips without it so `make lint` works on a bare box.
  Converges on the shape `dotfiles-Offense` and `dotfiles-Defense` already run.

- **`bootstrap.sh`'s `PATH` is not the shell's `PATH` — adopt `blib_user_bindirs_on_path`**
  (dotgibson/dotfiles-core#748). Replaces the hand-rolled `export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.atuin/bin:$PATH"` prelude. `~/.local/bin`, `~/.cargo/bin` and `$GOBIN` reach
  `PATH` only through the zsh layer, i.e. only inside a Core shell — which does not exist
  while `bootstrap.sh` runs. So every `command -v <tool>` guard here was answered by the
  PATH of whatever shell launched the bootstrap: on a fresh box, bash, with none of them.
  That is wasted work when the guard picks whether to reinstall, and a **wrong answer** when
  it picks a branch — `dotfiles-openSUSE` probed `command -v mise` for a mise `mise.run` had
  written to `~/.local/bin` moments earlier, both arms of its Go fallback missed, and the run
  exited 2 on every bootstrap. No stubbed CI leg can see that: a stub installs nothing, so
  "is the tool present afterwards" can never fail under one. Core has shipped
  `blib_user_bindirs_on_path` for exactly this since dotgibson/dotfiles-core#425 — it resolves
  `CARGO_HOME` and `GOBIN`/`GOPATH` rather than hard-coding them, and adds only directories
  that **exist**, so it is called again after an installer creates one. The directory this script installs into is `mkdir -p`'d before the helper runs: the helper adds only directories that already **exist**, so a straight swap for the old unconditional `export` would have dropped `~/.local/bin` for the whole first run and made `command -v atuin` miss the binary the atuin block had just linked there, skipping the systemd user unit. A second call now runs after the `mise.run` install, so `_dotfiles_go_install`'s `command -v mise` arm sees the mise this script just installed.
- **`make check` was not hermetic, and wrote Core into your real config dir
  (dotgibson/dotfiles-core#852).** The target promises "a hermetic `--links-only` run
  against a throwaway HOME" and redirected only `HOME` — but `bootstrap.sh` resolves its
  target as `CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"`, and `core/lib/bootstrap-lib.sh`
  defaults `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `XDG_DATA_HOME` and
  `ZDOTDIR` the same way. A `:-`/`:=` default applies **only when the variable is unset**,
  so for anyone who exports `XDG_CONFIG_HOME` the run wired Core into their live config
  tree and then failed its own assertions, which look under the temp dir bootstrap never
  touched. Reproduced on Fedora 44: `zsh/`, `nvim`, `starship.toml`, `tmux`, `git`,
  `mise`, `lazygit`, `atuin`, `jj`, `sesh` and `tealdeer` all landed in the exported
  `XDG_CONFIG_HOME`, while the target reported `MISSING symlink` on a clean checkout —
  a gate that mutates the box it was only supposed to inspect, then blames the tree.
  `env -u` for the five variables the bootstrap path actually consults fixes both halves;
  verified with `XDG_CONFIG_HOME` *and* `ZDOTDIR` pointed at a decoy, which now stays
  empty while the check passes. `dotfiles-openSUSE` had already reached the same fix
  locally.
- **`make check`'s `mktemp -d` was unguarded**, so a failure left `$tmp` empty and the
  next line ran `mkdir -p "$tmp/.config/tmux/plugins/tpm"` — `/.config/…` on the real
  filesystem. It now refuses, and a `trap` replaces the two hand-placed `rm -rf`s so an
  interrupted run cleans up too.
- **`make check` accepted a commented-out loader line.** `grep -q "source .*loader.zsh"`
  matched `# source ~/.config/zsh/loader.zsh`, and its unescaped `.` also matched
  `loaderXzsh`. Now `grep -qE '^[^#]*source .*loader\.zsh'`, and both `~/.zshrc` greps
  are `2>/dev/null` so a missing file reports once instead of twice.

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

- **The atomic edition — Silverblue, Kinoite, any `bootc` host — as a variant of the same
  bootstrap** (#186; runbook step 3 of dotgibson/dotfiles-core's `NON-MUTABLE-HOST-PROPOSAL.md`
  §4.6, the R4 patch measured end to end on a booted `fedora-bootc:42` guest, runs
  34893435585 and 34895922848). On a booted ostree image `dnf install` resolves the whole
  transaction and then refuses ("configured to be read-only"), `rpm --import` cannot lock the
  rpmdb, and nothing installed is live until a reboot — so the old script died at its first
  dnf line there. The marker is `/run/ostree-booted`, not `VARIANT_ID` (the bootc image
  reports `ID=fedora` and no variant), and everything hangs off that one flag: the RPM Fusion
  release RPMs, the package list, the lazygit COPR (a repo file into `/etc/yum.repos.d` —
  `dnf copr` needs a plugin that is not live until a reboot), the carapace RPM and
  `1password-cli` all **layer** with `rpm-ostree install --idempotent` into the next
  deployment; the package list is filtered to the names `dnf repoquery` resolves and `rpm -q`
  does not already answer, because one base-provided name refuses the whole layer even under
  `--idempotent` (measured — it took the first 38-package layer down); 1Password's
  fingerprint-verified key is installed under `/etc/pki/rpm-gpg` and the repo's `gpgkey`
  points at it. A second declaration, `os/fedora.atomic.capabilities` (`PROVISIONER=atomic`,
  the rpm-ostree verbs, `PKG_APPLY_PENDING=rpm-ostree status --pending-exit-77`, `PKG_APPLY=sudo
  systemctl reboot`, no count verb — that question is root-only there), is relinked by
  `bootstrap_wire_pre_loader` the way dotfiles-openSUSE selects Leap's, so Core's `up`, nudge
  and maint runner (Core v7.6.0) see the staged host. The closing line says "N package(s)
  layered — reboot to apply, then re-run once": the cargo/go tools behind `command -v cargo`
  guards are skipped on the first run and picked up on the second, which is the edition's
  measured cost (a full second deployment plus the from-source builds). 118 code lines in
  `bootstrap.sh`, an 18-line declaration delta, no `install/` fork and no `os/*.zsh` fork —
  the atomic edition's packages *are* Fedora's packages. `BOOTSTRAP_PROVISIONER=atomic` forces
  the marker, which is how a container reaches the staging path at all.

- **`test/check-flavors.sh`, on dotfiles-openSUSE's model, and `make suite`.** Two
  hand-maintained declarations that are mostly identical by design are the most likely place
  for this variant to drift, and Core's schema validator checks each file alone. The test
  asserts the DELTA: `PROVISIONER` on the atomic file only; the five verbs dnf on one side and
  rpm-ostree on the other (`--idempotent` on the install, `rpm-ostree upgrade` — never `bootc
  upgrade`, which refuses a host with a layered package); the staged pair
  (`PKG_APPLY_PENDING` / `_EXIT` agreeing on 77, `PKG_APPLY`) present only there and the count
  keys present only on the dnf file; every other key identical both ways; and that the split
  is still reachable — the marker probe, the CI seam, the relink and the "reboot to apply"
  closing line survive in `bootstrap.sh`, and `os/fedora.zsh` keeps both `dnfi` arms. Runs
  anywhere (it reads the repo), so the new `test` workflow runs it on a plain runner on every
  PR; `make test` now runs the suite.

- **`bootstrap.yml` gains a `fedora-bootc:42` leg with `provisioner: atomic`** (Core v7.7.0's
  reusable input, dotgibson/dotfiles-core#1050). A container is not the host — the image has
  no `/run/ostree-booted` and a writable `/usr` — so without the seam every container leg
  walked the dnf branch and a green tick tested the wrong code (R6, measured). The forced
  run shims rpm-ostree, makes the `rpm` shim answer `-q` with 1 so the base-image filter
  keeps its names, and fails unless the run prints "reboot to apply"; `packages_check` runs
  the same `dnf -q provides` (38 of 38 in that image). It is not a required check, and the
  weekly unstubbed sweep skips it by design; `.github/core-gates.txt` declares
  `real-bootstrap none …` with the reason, so the coverage register says VM-only rather than
  reading green.

- **`dnfi` knows the edition.** `sudo dnf install` resolves and then refuses on an atomic
  host; the alias now reads the declaration `bootstrap.sh` linked (`_core_cap PROVISIONER`,
  band 02 read it first) and expands to `sudo rpm-ostree install --idempotent` there. The
  other dnf aliases are unchanged: search / provides / history are read-only and answer on
  both editions, and upgrading is Core's `up`, which dispatches through the same declaration.

- **The README opens with a rendered terminal hero** (dotgibson/dotfiles-core#948).
  `assets/demo.gif` is filmed from `assets/demo.tape`, which dotfiles-core generates from
  one shared template for all nine OS and role repos — the same tour everywhere, plus the
  one command that is this repo's own: `up -n` resolving to `sudo dnf upgrade --refresh`.
  The tape is generated (edit dotfiles-core's `assets/hero.tape.in`, not the tape); re-
  render with `vhs assets/demo.tape` on a Fedora box after a prompt or tooling change,
  then `gifsicle -O3 --lossy=80 --colors 64` — the raw render is over Core's 2 MiB
  ceiling, the optimised one is not.

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

### Changed

- **`bootstrap.sh` runs on Core's bootstrap driver, `blib_main`** (dotgibson/dotfiles-core#986).
  The shared half — the flag loop, the escalator, the sudo keepalive, the Core symlink
  surface, the OS overlays, the managed `~/.zshrc`, the login shell, the closing report — now
  runs from one definition in `core/lib/bootstrap-lib.sh` (vendored since v7.4.0). This file
  declares what it is (`BOOTSTRAP_OS=fedora`) and keeps only what is Fedora's: the OS guard
  and preflight as `bootstrap_guard`, the dnf provisioning as `bootstrap_provision` (its body
  is unchanged), the dry-run preview as `bootstrap_check`, and `--no-flatpak` / `--force-os`
  through `bootstrap_flag`. 753 → 660 lines. What the driver gives for free: one `--help`
  (this repo's half, then the shared flags), and `blib_user_bindirs_on_path` running before
  anything probes rather than only inside `provision()`. One convention change: an unknown
  flag exits **2** (usage error), not 1, which stays for real failures. Same links, same
  loader, same exit codes otherwise; `make check` (the vendored links gate) ran green through
  the driver on a Fedora box, and a real `--dry-run` printed the provisioning plan and wrote
  nothing.

- **`make check` runs Core's vendored `check-links.sh` instead of its own copy of the
  hermetic `--links-only` gate** (dotgibson/dotfiles-core#975, #852). The recipe carried one
  of four near-identical copies of that block across the fleet, and they drifted the way copies
  do: #852 found the same non-hermetic-HOME defect in three of them at once and had to fix it
  three times by hand. The script has been vendored as `core/scripts/check-links.sh` since
  then with its consumer named "as intent rather than as a file" — nine releases later no
  Makefile had followed. Now this one calls it: the Core graph is the script's own default,
  and `--require` adds the four things this repo's OS layer wires on top (`80-os.zsh`,
  `os.capabilities`, tmux `os.conf`, git `os.gitconfig`). Exit 2 is the drift signal, 1 means
  the check could not run.

- **`bootstrap.sh` runs on Core's escalation, sudo-keepalive and failure-tally helpers
  instead of private copies** (dotgibson/dotfiles-core#867). `blib_resolve_su` replaces the
  hand-rolled root/sudo/doas probe — the same `$EUID` string compare, plus an absolute path
  for the escalator, and `--require` only when packages will actually be installed, so
  `--dry-run` no longer demands one. `blib_sudo_keepalive_start` / `_stop` replace the
  private refresher loop and its trap. `note_fail` is now a one-line shim over
  `blib_note_fail`, and the closing report comes from `blib_failures_report` — which means
  the failures the shared lib records **itself** (the tpm clone, `blib_install_system_file`)
  finally appear in it instead of being dropped. Output and `--strict` semantics are
  unchanged; the one visible difference is that hint lines print the escalator's full path
  (`/usr/bin/sudo dnf remove …`). Closes this repo's four rows in Core's `audit-core.sh` §5f
  ledger, which had read 1/9 (Gentoo only) since dotgibson/dotfiles-core#748.

### Removed

- A stale 4.5 MB orphaned worktree copy under `.claude/worktrees/`, and the obsolete
  `zsh/local.zsh` ignore entry (host overrides have lived at
  `~/.config/zsh/99-local.zsh` since v4).
