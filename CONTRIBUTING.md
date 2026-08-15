# Contributing to dotfiles-Fedora

This is the **OS-native layer for Fedora** in a three-layer dotfiles system, and the
template the other Linux repos are stamped from. The contribution rules are therefore
mostly *boundary* rules: the hard part is not writing the change, it is knowing which
repo it belongs in.

GitHub resolves `CONTRIBUTING.md` from the repo root, `.github/`, or `docs/` — the
vendored `core/CONTRIBUTING.md` governs `dotfiles-core` and is inert here.

## The rule that bites: never hand-edit `core/`

`core/` is a **vendored `git subtree` copy** of
[`dotfiles-core`](https://github.com/dotgibson/dotfiles-core). It is overwritten on the
next sync, so an edit there is silent drift: it works until a sync clobbers it, and it
never reaches the source of truth.

To change shared config: edit it **in `dotfiles-core`**, run `make audit` there, then
`make sync` to fan it out to every OS repo.

Three things enforce this, deliberately overlapping:

1. A local `pre-commit` hook installed by `bootstrap.sh` (`blib_install_core_guard`).
2. The `core-integrity` workflow, which compares your `HEAD:core` **git tree object**
   against the SHA recorded in `core.lock` — so any byte-level change is caught at PR time.
3. `CODEOWNERS`, which routes `core/` diffs to the maintainer.

## Which layer does my change belong to?

| If the change… | It belongs in |
| --- | --- |
| is identical on every machine (zsh, tmux, nvim, git, starship) | `dotfiles-core` |
| changes with the **OS** (package manager, clipboard, paths, SELinux) | **here** |
| changes with the **operator** (offensive/defensive tooling) | `dotfiles-Kali` / `dotfiles-Defense` |

Structural changes to the OS-native layout **start here** and propagate per
[`core/PORTING-MATRIX.md`](core/PORTING-MATRIX.md). If your fix to `bootstrap.sh` would
be identical on Arch and openSUSE, that is a strong signal it belongs in
`core/lib/bootstrap-lib.sh` upstream instead.

## Local development

```bash
make help          # list every target
make lint          # shellcheck + bash -n + zsh -n, exactly as CI runs them
make check         # lint + a hermetic --links-only run in a throwaway HOME
make dry-run       # preview the full bootstrap plan; changes nothing
make hooks         # install the pre-commit hooks (needs `pre-commit`)
```

`make lint` is the gate. Green it before you push — CI runs the same checks via the
reusable workflow in `dotfiles-core`, plus `actionlint` on the workflows.

The vendored `core/` is **excluded** from this repo's linting: it is gated upstream by
`dotfiles-core`'s own `make audit`.

## Pull requests

`main` is protected: PRs are required, and the `lint`, `bootstrap`, and `core-integrity`
checks must pass.

- Branch names: `fix/…`, `feat/…`, `docs/…`, `chore/…`, or `sync/…` after the work.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):
  `type(scope): summary` — e.g. `fix(bootstrap): resolve the escalator once`.
- A user-visible change gets a `CHANGELOG.md` entry under `[Unreleased]` in the same commit.
- Keep the reasoning. This codebase deliberately carries long comments explaining *why* a
  guard exists (which crate actually ships the binary, which keyring dnf consults). If you
  change such a line, update the comment with it — those comments are the record of bugs
  that already cost someone an afternoon.

## Testing a bootstrap change

`bootstrap.sh` is the one file that can strand a fresh machine, so it gets the most care:

```bash
make lint                      # shellcheck -x, bash -n, --help
make dry-run                   # full plan, mutates nothing
make check                     # hermetic --links-only against a throwaway HOME
```

If you have a container runtime, the closest thing to a fresh box — and the case that
regressed most often — is a **root** run with no `sudo` present:

```bash
podman run --rm -v "$PWD:/repo" -w /repo fedora:latest bash -c './bootstrap.sh --links-only'
```

Re-run any full bootstrap **twice** and confirm the second run rebuilds nothing: the
cargo/go presence guards are easy to break in a way that silently costs minutes per run.

## Reporting bugs

Open an [issue](https://github.com/dotgibson/dotfiles-Fedora/issues). Security problems
go through [`SECURITY.md`](SECURITY.md) instead — please don't file those publicly.
