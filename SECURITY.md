# Security Policy — dotfiles-Fedora

This repo provisions a workstation. `bootstrap.sh` runs as your user, escalates to root
for package installs, and fetches software from the internet. That makes its **trust
decisions** part of its security surface, so they are written down here rather than left
implicit in the script.

GitHub resolves `SECURITY.md` from the repo root, `.github/`, or `docs/` — the vendored
`core/SECURITY.md` governs `dotfiles-core` and is inert here.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's
[private vulnerability reporting](https://github.com/dotgibson/dotfiles-Fedora/security/advisories/new),
or email <garrettallen2@gmail.com>. Expect an acknowledgement within a few days.

## Secrets: none are stored here

This repository contains **no secrets, keys, or tokens**, and none should ever be added.

- Runtime secrets come from **1Password** via the `op` CLI (see `core/zsh/50-op.zsh`).
- **SSH keys are never tracked.** `.gitignore` excludes everything under `ssh/`, plus the
  usual key/credential filename patterns. Nothing there is tracked at all now — the ssh
  client config moved into Core as `core/ssh/config` (dotgibson/dotfiles-core#450).
- Your **git identity** (name/email) is *seeded once* to `~/.config/git/local.gitconfig`
  and edited there — it is never tracked back into this repo.
- **Push protection and secret scanning are enabled** on this repository. `gitleaks` also
  runs at author time via `.pre-commit-config.yaml`.

## Trust decisions made by `bootstrap.sh`

Provisioning a modern CLI stack on Fedora means going outside the distro repos. Each of
these is a deliberate choice with a real cost; none is hidden.

| What | Source | Why not `dnf` | Mitigation |
| --- | --- | --- | --- |
| **RPM Fusion** (free + nonfree) | `mirrors.rpmfusion.org` release RPMs | Codecs/firmware Fedora cannot ship | The de-facto standard third-party Fedora repo; GPG-signed |
| **lazygit** | COPR `atim/lazygit` | Not in Fedora base repos | COPR is Fedora-operated build infrastructure; the repo is added permanently |
| **carapace** | Upstream `.rpm` release asset | `go install` is *impossible* — the module has `replace` directives (see the comment in `bootstrap.sh`) | Arch-matched asset resolved from the GitHub API. **Not checksum-pinned, and nothing upgrades it afterwards** — see *Known gaps* |
| **1Password CLI** | `downloads.1password.com` dnf repo | Not packaged by Fedora | Signing key is **fingerprint-verified** before `rpm --import`; the repo file is only written *after* a successful import, so a failed/rotated key costs `op`, not your package manager |
| **starship / atuin / mise** | Official install scripts | Genuinely absent, or the packaged version trails a validated one | Downloaded to a temp file, sanity-checked, then run — never `curl \| sh`. starship installs to `~/.local/bin` so it needs no root at all |
| **tpm** (tmux plugins) | `github.com/tmux-plugins/tpm` | Not packaged | Shallow clone, one time, into `~/.config/tmux/plugins` |
| **Rust/Go CLIs** | `cargo install` / `go install` | Retired or never packaged (`sd`, `gron`, `dust`, `xh`, `viddy`, `doggo`, `sesh`, and `tealdeer`/`procs` on F45+) | Built from source with `--locked` (cargo), so the dependency set is the crate author's pinned one |

### Privilege escalation

`bootstrap.sh` resolves an escalator **once** (`BLIB_SU`: empty when already root, else
`sudo`, else `doas`) and refuses to start a provisioning run if it has none. When using
`sudo` it primes the timestamp up front and refreshes it in the background, so no
privileged call later in the run can stall on an invisible password prompt. Set
`BLIB_SU` explicitly to override. `--links-only` needs no privileges at all.

### Known gaps

Recorded honestly rather than papered over:

1. **The three upstream install scripts are not version-pinned or checksum-verified.**
   Downloading-then-running removes the truncated-script hazard, but a compromised
   upstream would still be executed. Proper fixes (pinned versions + published checksums,
   maintained by Renovate) are tracked as follow-up work.
2. **carapace never updates.** Installing from a release URL adds no repo, so neither
   `dnf upgrade` nor a later bootstrap moves it (the presence guard skips the block once
   the binary exists). Check `carapace --version` occasionally.
3. **Reusable workflows are pinned to the moving `@v4` tag**, not a commit SHA. This is
   the documented fleet policy (`core/RELEASE-STRATEGY.md`): a caller's contract then
   changes only via a Core *release*. All workflows are first-party (`dotgibson/*`), and
   third-party actions inside them (`actions/checkout`, `actions/cache`) *are* SHA-pinned.

## Supported versions

The tip of `main` is the only supported version. Fedora releases currently targeted are
those still receiving updates from Fedora; see `install/packages.txt` for per-package
availability notes.
