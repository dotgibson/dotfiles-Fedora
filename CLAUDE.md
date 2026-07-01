# CLAUDE.md — dotfiles-Fedora

Project memory for Claude Code, auto-loaded every session. For the shared Core
rules (the load order, the "is it Core?" test, the manifest contract) see
`core/README.md` and `core/CONTRIBUTING.md`.

## What this repo is

`dotfiles-Fedora` is the **OS-native layer for Fedora** in a **ten-repo dotfiles system** built on a three-layer
model (Core → OS-native → Role). Fedora is the **template** the other Linux repos are stamped from: OS-native structure changes start here, then propagate per `core/PORTING-MATRIX.md`. `dnf` + RPM Fusion.

## The rule that bites

`core/` is a **vendored `git subtree` copy of [dotfiles-core](https://github.com/dotgibson/dotfiles-core)** — it
is *not* editable here. Anything you change under `core/` is overwritten on the
next sync. To change shared Core config, edit it **in dotfiles-core**, run
`make audit` there, then `make sync` to fan it out to every OS repo.

What belongs **here** is only the OS-native layer: the `dnf` package list, clipboard + paths, and the bootstrap.

## Where things are

- `os/fedora.zsh` — clipboard + package-manager aliases for Fedora
- `os/fedora.conf`, `os/fedora.gitconfig` — tmux + git OS overlays
- `install/packages.txt` — Fedora package names
- `bootstrap.sh` — symlinks Core + OS files into place
- `core/` — vendored Core (read-only here; edit upstream in dotfiles-core)
