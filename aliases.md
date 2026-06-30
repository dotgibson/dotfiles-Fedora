# Fedora Aliases Cheat Sheet

OS-specific aliases from `os/fedora.zsh`. See [`core/aliases.md`](core/aliases.md) for the universal alias
reference (modern CLI, git, safety nets) that applies on every machine.

## Package Management (dnf)

| Alias | Expands to |
|-------|------------|
| `dnfi` | `sudo dnf install` |
| `dnfs` | `dnf search` |
| `dnfu` | `sudo dnf upgrade --refresh` |
| `dnfr` | `sudo dnf remove` |
| `dnfh` | `dnf history` |
| `dnfwhat` | `dnf provides` (what package provides a file/command) |
| `dnf-undo` | Undo last dnf transaction (function) |

## Flatpak

| Alias | Expands to |
|-------|------------|
| `fpi` | `flatpak install flathub` |
| `fpu` | `flatpak update` |
| `fps` | `flatpak search` |
| `fpl` | `flatpak list --app` |

## SELinux

| Alias | Expands to |
|-------|------------|
| `se-status` | `sestatus` (or message when not active) |
| `se-denials` | Recent AVC denials via `ausearch` |
| `se-why` | SELinux troubleshoot log via `journalctl` |
| `se-restore <path>` | `restorecon -Rv` — restore file context (function) |

## Clipboard / WSL2 / Navigation

| Alias | Expands to | Condition |
|-------|-----------|----------|
| `pbcopy` | `clip` | clip available |
| `pbpaste` | `clip-paste` | clip-paste available |
| `dotsync` | `cd ~/dotfiles-Fedora` | always |
| `opsignin` | `eval "$(op signin)"` | 1Password CLI |
| `localip` | `ip -brief -4 addr show scope global` | always |
| `open` | `explorer.exe` | WSL2 |
| `xdg-open` | `wslview` | WSL2 + wslview |
| `cdwin` | `cd "$WINHOME"` | WSL2 + WINHOME set |
