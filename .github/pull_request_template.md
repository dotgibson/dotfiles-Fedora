## What & why

<!-- What changes, and what problem it solves. Link an issue if there is one. -->

## Layer check

<!-- The boundary rule this repo lives or dies by. Tick exactly one. -->

- [ ] **Fedora-specific** — dnf/RPM Fusion/COPR, clipboard, SELinux, paths. Belongs here.
- [ ] **Shared** — would be identical on Arch/openSUSE/Alpine/Gentoo. **This belongs in
      `dotfiles-core`** (`make audit` there, then `make sync`), not here.
- [ ] **Sync PR** — vendors a new Core release into `core/`. No hand-edits.

> `core/` is a vendored `git subtree` copy and is overwritten on the next sync. The
> `core-integrity` check compares its tree SHA against `core.lock` and will fail on any
> hand-edit. See [CONTRIBUTING.md](../CONTRIBUTING.md).

## Verification

<!-- Delete what doesn't apply; keep what you actually ran. -->

- [ ] `make lint` — shellcheck + `bash -n` + `zsh -n`
- [ ] `make check` — hermetic `--links-only` against a throwaway HOME
- [ ] `make dry-run` — full plan, mutated nothing
- [ ] Ran a real bootstrap; second run rebuilt nothing (no redundant cargo/go work)
- [ ] Touches `install/packages.txt` — package names verified against a current Fedora release

## Notes for the reviewer

<!-- Trade-offs, deferred work, anything surprising. If you changed a guard that has a
     long explanatory comment, say why the reasoning in that comment no longer holds. -->
