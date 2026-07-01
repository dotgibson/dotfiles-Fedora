# 🎩 dotfiles-Fedora

**Fedora — the template layer.** The Fedora layer (dnf + RPM Fusion) — the
template the other Linux repos are stamped from.

`dnf` · `zsh` · `nvim` · `tmux`

[![showcase](https://img.shields.io/badge/showcase-live-7aa2f7?style=flat-square)](https://dotgibson.github.io/dotfiles-web/) ![Linux](https://img.shields.io/badge/Linux-template-7aa2f7?style=flat-square)

---

The **OS-native layer** for Fedora. Core (zsh/tmux/nvim/git) is vendored under
`core/` from [`dotfiles-core`](../dotfiles-core); this repo adds only what is
genuinely Fedora — dnf, RPM Fusion, Flathub, Wayland clipboard, SELinux helpers.

This repo is also the **template** the other distro repos are stamped from:
swap the package manager and clipboard backend, keep the structure.

## Install (fresh Fedora)

```bash
git clone <you>/dotfiles-Fedora ~/dotfiles-Fedora
cd ~/dotfiles-Fedora
# one-time: vendor Core (skip if the repo already contains core/)
git subtree add --prefix=core <you>/dotfiles-core main --squash
./bootstrap.sh
exec zsh
```

Flags: `--links-only` (re-link without touching dnf), `--no-flatpak`.

## Layout

```
bootstrap.sh          dnf provision + Core/OS symlink wiring (idempotent)
install/packages.txt  dnf package list (modern CLI stack)
os/fedora.zsh         OS-native shell layer -> symlinked to ~/.config/zsh/os.zsh
ssh/config            hardened SSH client config -> ~/.ssh/config (keys never tracked)
core/                 vendored from dotfiles-core (git subtree; do not hand-edit)
```

Load order in `.zshrc`: `core/tools → core/aliases → core/functions → core/fzf →
core/bindings → core/plugins → core/op → os/fedora → local`.

## Fedora specifics baked in

- **dnf5** is the default engine since Fedora 41; the `dnf` command is unchanged.
  `dnf-undo` rolls back the last transaction — useful after a bad upgrade.
- **RPM Fusion** (free + nonfree) is enabled for codecs and extra packages.
- **Clipboard is Wayland-first** (`wl-copy`/`wl-paste`), shimmed to `pbcopy`/
  `pbpaste` so your Mac muscle memory carries over; X11 `xclip` fallback for SSH.
- **SELinux is enforcing** by default. `se-restore`, `se-denials`, and `se-why`
  helpers are included — worth knowing well, since SELinux context issues are a
  common real-world troubleshooting and privilege-escalation surface.
- **fd** is named `fd` here (not `fdfind` as on Debian); `core/zsh/tools.zsh`
  resolves the name automatically, so nothing breaks across distros.
- **starship / atuin / yazi** aren't reliably in Fedora repos, so `bootstrap.sh`
  installs them from upstream to match the other distro repos exactly.
