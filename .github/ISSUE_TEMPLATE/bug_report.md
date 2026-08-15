---
name: Bug report
about: Something in the Fedora layer is broken
title: ''
labels: bug
assignees: ''
---

## What happened

<!-- Include the actual output. If bootstrap.sh appeared to hang, say where it stopped —
     the last line it printed is usually the whole diagnosis. -->

## What you expected

## Reproduce

```bash
# the exact command
./bootstrap.sh
```

## Environment

- Fedora release: <!-- `cat /etc/os-release | head -3` -->
- WSL or bare metal / VM:
- Running as: <!-- your user + sudo, or root -->
- `core.lock` version: <!-- `grep core_version core.lock` -->
- Shell the bootstrap was launched from: <!-- bash or zsh; it matters for PATH -->

## Checks

- [ ] This is **not** about a file under `core/` (those belong in
      [dotfiles-core](https://github.com/dotgibson/dotfiles-core/issues))
- [ ] `make lint` output, if relevant
- [ ] `./bootstrap.sh --dry-run` output, if the problem is about what gets linked/installed
