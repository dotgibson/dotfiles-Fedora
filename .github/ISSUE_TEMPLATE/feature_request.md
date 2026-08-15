---
name: Feature request
about: Suggest something for the Fedora layer
title: ''
labels: enhancement
assignees: ''
---

## What & why

<!-- The problem you're trying to solve, not only the solution you have in mind. -->

## Which layer?

- [ ] Genuinely **Fedora-specific** (dnf, RPM Fusion, COPR, Flatpak, SELinux, Wayland,
      WSL interop) — belongs here.
- [ ] Would be **identical on every distro** — belongs in
      [dotfiles-core](https://github.com/dotgibson/dotfiles-core/issues).
- [ ] Changes with the **operator** (offensive/defensive tooling) — belongs in
      `dotfiles-Kali` / `dotfiles-Defense`.

## If this adds a tool

- Package name on Fedora (or why it isn't packaged): <!-- `dnf provides` / `dnf search` -->
- If not packaged, the install route: cargo / go / COPR / upstream RPM / install script
- Does Core already probe for it (`core-doctor`)?

> Anything installed outside `dnf` is a trust decision that gets recorded in
> [SECURITY.md](../SECURITY.md) — please say which route you'd expect.

## Alternatives considered
