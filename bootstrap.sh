#!/usr/bin/env bash
# dotfiles-Fedora/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision a Fedora box (Workstation or WSL) and wire up dotfiles. Idempotent —
# safe to re-run. This is the OS-NATIVE layer; Core (zsh/tmux/nvim/git) is
# vendored under core/ and symlinked in via the shared core/lib/bootstrap-lib.sh.
#
# Usage:
#   ./bootstrap.sh                 # full: dnf packages + extras + symlinks
#   ./bootstrap.sh --links-only    # just (re)create symlinks
#   ./bootstrap.sh --no-flatpak    # skip Flathub/GUI apps (recommended on WSL)
#   ./bootstrap.sh --only zsh,nvim # link ONLY these Core module groups
#   ./bootstrap.sh --skip tmux     # link everything EXCEPT these groups
#
# Module groups (for --only/--skip): zsh nvim tmux git prompt tools — they affect
# the wiring steps only, never package provisioning; combine with --links-only to
# re-wire a subset of configs without touching dnf.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0
DO_FLATPAK=1
# --only/--skip are validated by the shared lib (blib_select), which is sourced
# AFTER this loop — so capture the raw values now and apply them below.
ONLY_RAW="" SKIP_RAW="" ONLY_SEEN=0 SKIP_SEEN=0

while [[ $# -gt 0 ]]; do case "$1" in
  --links-only) LINKS_ONLY=1 ;;
  --no-flatpak) DO_FLATPAK=0 ;;
  --only) [[ $# -ge 2 ]] || { echo "--only requires module names, e.g. --only zsh,nvim" >&2; exit 1; }; ONLY_RAW="$2"; ONLY_SEEN=1; shift ;;
  --only=*) ONLY_RAW="${1#*=}"; ONLY_SEEN=1 ;;
  --skip) [[ $# -ge 2 ]] || { echo "--skip requires module names, e.g. --skip tmux" >&2; exit 1; }; SKIP_RAW="$2"; SKIP_SEEN=1; shift ;;
  --skip=*) SKIP_RAW="${1#*=}"; SKIP_SEEN=1 ;;
  -h | --help)
    sed -n '2,17p' "$0"
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 1
    ;;
  esac; shift; done

# ── core/ subtree present? (inline: can't source a lib out of core/ before this) ─
# Validate the SPECIFIC paths we depend on (zsh modules + the two libs sourced
# next) so a missing/partial subtree fails HERE with a precise message, not later
# with a cryptic `source: No such file`.
for _req in core/zsh/loader.zsh core/lib/ux.sh core/lib/bootstrap-lib.sh; do
  if [[ ! -e "$DOTFILES/$_req" ]]; then
    echo "core/ subtree missing or incomplete (need $_req). One-time, run:" >&2
    echo "  git subtree add  --prefix=core <dotfiles-core remote> main --squash   # first time" >&2
    echo "  git subtree pull --prefix=core <dotfiles-core remote> main --squash   # to update" >&2
    exit 1
  fi
done
unset _req

# Shared bash UX palette + provisioning scaffold (vendored under core/lib).
# shellcheck source=core/lib/ux.sh
source "$DOTFILES/core/lib/ux.sh"
# shellcheck source=core/lib/bootstrap-lib.sh
source "$DOTFILES/core/lib/bootstrap-lib.sh"

# Apply any --only/--skip module selection now the validator (blib_select) exists;
# it aborts on a malformed selector or an unknown group.
if ((ONLY_SEEN)); then blib_select --only "$ONLY_RAW"; fi
if ((SKIP_SEEN)); then blib_select --skip "$SKIP_RAW"; fi

# ── sanity: confirm we're on Fedora ───────────────────────────────────────────
if ! grep -qi fedora /etc/os-release 2>/dev/null; then
  echo "This bootstrap targets Fedora. /etc/os-release doesn't look like Fedora." >&2
  exit 1
fi

IS_WSL=0
if blib_is_wsl; then IS_WSL=1; fi

provision() {
  blib_say "dnf metadata refresh (makecache)"
  sudo dnf -y makecache >/dev/null

  blib_say "RPM Fusion (free + nonfree)"
  local rel
  rel="$(rpm -E %fedora)"
  sudo dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${rel}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${rel}.noarch.rpm" \
    >/dev/null 2>&1 || true

  blib_say "dnf packages (from install/packages.txt)"
  local -a pkgs=()
  mapfile -t pkgs < <(blib_read_pkgs "$DOTFILES/install/packages.txt")
  # dnf5 fails the WHOLE transaction if any single requested pkg is unavailable
  # (and is fussy about already-installed ones) — --skip-unavailable makes the
  # bulk install resilient: missing names are skipped instead of aborting.
  # Guard the empty case: an all-comment/blank packages.txt yields a zero-length
  # array, and `dnf install` with no args errors out — aborting the whole bootstrap
  # under `set -e`. Skip the install instead and carry on with the rest.
  if ((${#pkgs[@]})); then
    sudo dnf -y install --skip-unavailable "${pkgs[@]}"
    blib_ok "dnf packages installed (${#pkgs[@]} requested)"
  else
    blib_warn "install/packages.txt lists no packages — skipping dnf install"
  fi

  # Tools not reliably packaged on Fedora — match the other repos via upstream.
  if ! command -v starship >/dev/null; then
    blib_say "starship (official installer)"
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null || true
  fi
  if ! command -v atuin >/dev/null; then
    blib_say "atuin (official installer)"
    curl -fsSL https://setup.atuin.sh | sh >/dev/null 2>&1 || true
  fi
  # atuin's installer hard-codes ~/.atuin/bin (install.sh: ATUIN_BIN="$HOME/.atuin/bin/atuin")
  # and appends its own init line to ~/.zshrc — but wire_links() below REPLACES that file with
  # the managed loader, and core/zsh/00-tools.zsh prepends only ~/.local/bin before it probes
  # for tools. Without this link `atuin` is off PATH in a Core shell, so HAVE_ATUIN never gets
  # set and the whole integration (cached init, Ctrl+E, the daemon config) is silently absent
  # on a freshly bootstrapped box. Link it into the dir Core already prepends rather than
  # teaching the 00 band a new PATH entry.
  # Best-effort like the installers above: this script runs under `set -euo pipefail`, and a
  # convenience symlink must not abort a bootstrap because ~/.local/bin is read-only, HOME is
  # mounted oddly, or something already occupies the target.
  # Gate on the DESTINATION, never on `command -v atuin`. That probe reads the PATH of the
  # bash running THIS script, not the PATH a Core zsh will build — and atuin's installer
  # appends `. ~/.atuin/bin/env` to ~/.bashrc, so bootstrapping from a bash that has already
  # sourced it makes the probe succeed and silently skips the very link this block exists to
  # create. The failure is invisible until a login zsh (which never reads ~/.bashrc) starts
  # with ~/.atuin/bin off PATH and HAVE_ATUIN unset.
  if [[ -x "$HOME/.atuin/bin/atuin" ]] &&
    [[ "$(readlink -f "$HOME/.local/bin/atuin" 2>/dev/null)" != "$(readlink -f "$HOME/.atuin/bin/atuin" 2>/dev/null)" ]]; then
    # -n avoids dereferencing a symlink-to-directory destination (so we don't create ~/.local/bin/atuin/atuin).
    # If a real directory occupies the target path, ln will fail and we warn.
    if mkdir -p "$HOME/.local/bin" 2>/dev/null &&
      ln -sfn "$HOME/.atuin/bin/atuin" "$HOME/.local/bin/atuin" 2>/dev/null; then
      blib_ok "linked ~/.atuin/bin/atuin -> ~/.local/bin/atuin (so 00-tools.zsh can see it)"
    else
      blib_warn "could not link ~/.atuin/bin/atuin into ~/.local/bin — atuin stays invisible to Core's tool detection; add ~/.atuin/bin to PATH by hand"
    fi
  fi

  # ── atuin daemon: the systemd half of the opt-in (dotfiles-core#335) ─────────
  # Core ships atuin/config.toml with [daemon] OFF and the unit as an EXAMPLE, because the
  # launcher is OS-native. This is Fedora's: install the user unit and enable it. Guarded on
  # a real user manager — on WSL without `systemd=true` in /etc/wsl.conf there is none, and
  # os/fedora.zsh falls back to atuin's own autostart there instead.
  if command -v atuin >/dev/null 2>&1 && [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    local unit_src="$DOTFILES/core/examples/atuin-daemon.service"
    local unit_dst="$HOME/.config/systemd/user/atuin-daemon.service"
    # Capability probe, not a version parse: an atuin too old to know `daemon` would let the
    # unit start and fail on repeat, and the unit is Restart=on-failure/RestartSec=3 — i.e. a
    # restart loop for as long as the box is up. Ask the binary instead of trusting a number.
    if ! atuin daemon --help >/dev/null 2>&1; then
      blib_warn "installed atuin has no 'daemon' subcommand (too old) — skipping the unit; upgrade atuin to use daemon mode"
      unit_src=""
    fi
    if [[ -n "$unit_src" && -f "$unit_src" ]]; then
      blib_say "atuin daemon (systemd user unit)"
      # Also best-effort: an unwritable ~/.config or a read-only HOME must not take the whole
      # bootstrap down over an opt-in daemon. Only enable a unit we actually wrote.
      if (mkdir -p "${unit_dst%/*}" 2>/dev/null && install -m 0644 "$unit_src" "$unit_dst" 2>/dev/null); then
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        if systemctl --user enable --now atuin-daemon >/dev/null 2>&1; then
          blib_ok "atuin-daemon enabled — 'loginctl enable-linger \"\$USER\"' keeps it up outside a login session"
        else
          # Never fatal: 00-tools.zsh probes the socket and forces the daemon off for that
          # shell when nothing is listening, so a failed enable costs the lock relief, not a
          # working shell.
          blib_warn "atuin-daemon not enabled (no user systemd session?) — shells fall back to direct SQLite writes"
        fi
      else
        blib_warn "could not install the atuin-daemon unit into ~/.config/systemd/user — skipping; shells fall back to direct SQLite writes"
      fi
    fi
  fi
  # `yazi-build` is the ONLY crate that installs yazi from crates.io. This block previously
  # asked for `yazi-fs`, which is a library crate (no [[bin]]) and can never produce the
  # `yazi` binary the guard tests for — so the guard was permanently false and every single
  # bootstrap rebuilt the whole yazi workspace (a hundred-plus crates, many minutes) only to
  # discard it. Under the old `>/dev/null 2>&1` that is indistinguishable from a hang, and it
  # is why `./bootstrap.sh` "never completed" here.
  #
  # `yazi-fm` (which does declare [[bin]] name = "yazi") is NOT the fix either — verified by
  # building it: yazi-cli's build.rs panics on purpose with "Due to Cargo's limitations, the
  # `yazi-fm` and `yazi-cli` crates on crates.io must be built with
  # `cargo install --force yazi-build`". --force is upstream's own instruction, and harmless
  # here because the guard above already skips the block once `yazi` exists.
  #
  # Note ux_spin does its own output handling (it captures the build log and replays it only
  # on failure), so it must NOT be wrapped in >/dev/null 2>&1 — that would silence the
  # spinner itself and discard the log that explains a failed build. Same for every ux_spin
  # call below.
  if ! command -v yazi >/dev/null && command -v cargo >/dev/null; then
    ux_spin "yazi (cargo — builds from source)" \
      cargo install --force --locked yazi-build || true
  fi
  # mise — polyglot runtime manager (node/python/go/...). Portable; activated in
  # core/zsh/00-tools.zsh. Install the binary here; runtimes are fetched separately
  # with `mise install` (kept out of bootstrap so it stays fast/predictable).
  if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    blib_say "mise (official installer)"
    curl -fsSL https://mise.run | sh >/dev/null 2>&1 || true
  fi
  # lazygit isn't in Fedora's base repos — pull it from the well-known COPR.
  if ! command -v lazygit >/dev/null; then
    blib_say "lazygit (COPR atim/lazygit)"
    sudo dnf -y install dnf5-plugins >/dev/null 2>&1 || true
    sudo dnf -y copr enable atim/lazygit >/dev/null 2>&1 || true
    sudo dnf -y install lazygit >/dev/null 2>&1 ||
      echo "   lazygit COPR install failed; do it later: sudo dnf copr enable atim/lazygit && sudo dnf install lazygit"
  fi

  # ── doctor-probed tools not (reliably) in Fedora repos ─────────────────────
  # Round out core-doctor's modern-CLI set. All best-effort (|| true) + presence-
  # guarded — same discipline as starship/atuin/yazi above; a failure here never
  # aborts bootstrap. dust/xh via cargo (neither is packaged as of F45);
  # doggo/carapace/sesh via go install (using an ephemeral mise-provided go when the
  # toolchain isn't already present); op via 1Password's official dnf repo.
  # GOBIN → ~/.local/bin so go-installed binaries land on PATH (the Fedora shell
  # layer prefixes ~/.local/bin + ~/.cargo/bin, but NOT go's default ~/go/bin).
  _dotfiles_go_install() { # <import-path@version> <binary-name>
    [ "$#" -ge 2 ] || return 0
    if command -v "$2" >/dev/null 2>&1; then return 0; fi
    local gobin="$HOME/.local/bin"
    mkdir -p "$gobin" 2>/dev/null || true
    if command -v go >/dev/null 2>&1; then
      GOBIN="$gobin" ux_spin "$2 (go install)" go install "$1" ||
        echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
    elif command -v mise >/dev/null 2>&1; then
      # `mise exec go@latest` may first DOWNLOAD an entire Go toolchain, so this is the
      # slowest arm of the three and the one that most needs a visible elapsed time.
      GOBIN="$gobin" ux_spin "$2 (go install via mise)" mise exec go@latest -- go install "$1" ||
        echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
    else
      echo "   $2: needs Go — install later with: GOBIN=$gobin go install $1"
    fi
    return 0
  }
  # Each of these is a from-source Rust build costing minutes. Run them under ux_spin (which
  # keeps a live elapsed-time readout and replays the log only on failure) instead of
  # >/dev/null 2>&1, so a slow build reads as progress rather than as a wedged script.
  if ! command -v dust >/dev/null && command -v cargo >/dev/null; then
    ux_spin "dust (cargo — crate du-dust; not in Fedora repos as of F45)" \
      cargo install --locked du-dust || true
  fi
  if ! command -v xh >/dev/null && command -v cargo >/dev/null; then
    ux_spin "xh (cargo; not in Fedora repos)" \
      cargo install --locked xh || true
  fi
  # sd (sed replacement) was retired from Fedora after F41 — rust-sd's `sd` subpackage
  # last built 1.0.0-4.fc41, so `dnf install sd` fails on current releases. Same story
  # as gron below, just Rust instead of Go.
  if ! command -v sd >/dev/null && command -v cargo >/dev/null; then
    ux_spin "sd (cargo — retired from Fedora repos after F41)" \
      cargo install --locked sd || true
  fi
  # viddy (watch replacement; Core aliases watch->viddy, HAVE_VIDDY-guarded) is a Rust
  # CLI, not in Fedora repos — build from source via cargo like dust/xh above.
  if ! command -v viddy >/dev/null && command -v cargo >/dev/null; then
    ux_spin "viddy (cargo — watch replacement; not in Fedora repos)" \
      cargo install --locked viddy || true
  fi
  # tealdeer + procs are still in install/packages.txt and still install cleanly on
  # F43/F44, but both went orphan and neither was rebuilt for rawhide/F45 — the same
  # orphan→dropped path sd already finished. These two blocks are what makes that
  # transition a non-event: on F43/F44 dnf supplies the binary and the presence guard
  # skips the build; from F45 on, `--skip-unavailable` drops the name from the dnf
  # transaction and cargo picks it up here. Note the tealdeer guard probes `tldr` —
  # that's the binary the crate installs, `tealdeer` is only the package name.
  if ! command -v tldr >/dev/null && command -v cargo >/dev/null; then
    ux_spin "tealdeer (cargo — orphaned; last Fedora build F44)" \
      cargo install --locked tealdeer || true
  fi
  if ! command -v procs >/dev/null && command -v cargo >/dev/null; then
    ux_spin "procs (cargo — orphaned; last Fedora build F44)" \
      cargo install --locked procs || true
  fi
  blib_say "doggo / sesh / gron (go install where absent)"
  _dotfiles_go_install github.com/mr-karan/doggo/cmd/doggo@latest doggo
  _dotfiles_go_install github.com/joshmedeski/sesh/v2@latest sesh
  # gron was orphaned + dropped from Fedora (last in F41/42), so `dnf install gron`
  # fails on current releases — install it from source like the others above.
  _dotfiles_go_install github.com/tomnomnom/gron@latest gron

  # carapace: upstream's official RPM, NOT `go install`.
  #
  # `go install github.com/carapace-sh/carapace-bin/cmd/carapace@latest` cannot ever work,
  # and this is a permanent property of the module rather than a transient break. Its go.mod
  # carries two `replace` directives (spf13/pflag → carapace-pflag, kevinburke/ssh_config →
  # carapace-sh/ssh_config), and `go install pkg@version` refuses any module that does,
  # because a replace would make the build differ from building it as the main module:
  #   "The go.mod file for the module providing named packages contains one or more replace
  #    directives. It must not contain directives that would cause it to be interpreted
  #    differently than if it were the main module."
  # The old call therefore failed on EVERY bootstrap, and until the cargo/go steps moved onto
  # ux_spin it failed invisibly — `>/dev/null 2>&1` swallowed the explanation and the run just
  # never produced a `carapace`.
  #
  # Upstream publishes a signed-by-nobody-but-official .rpm per release, which is the native
  # answer here and lands in /usr/bin, so `dnf upgrade` (and `up`) maintain it from then on
  # instead of it drifting as an unmanaged ~/.local/bin binary. Resolve the newest asset for
  # THIS arch with grep/cut (no jq dependency) rather than pinning a version that would rot.
  if ! command -v carapace >/dev/null; then
    blib_say "carapace (upstream RPM — go install is impossible, see above)"
    local _cara_arch=""
    case "$(uname -m)" in
    x86_64) _cara_arch=amd64 ;;
    aarch64) _cara_arch=arm64 ;;
    esac
    if [[ -z "$_cara_arch" ]]; then
      blib_warn "carapace: no upstream RPM for $(uname -m) — skipping; see github.com/carapace-sh/carapace-bin/releases"
    else
      local _cara_url=""
      _cara_url="$(curl -fsSL --max-time 30 \
        https://api.github.com/repos/carapace-sh/carapace-bin/releases/latest 2>/dev/null |
        grep -o "\"browser_download_url\": *\"[^\"]*linux_${_cara_arch}\.rpm\"" |
        cut -d'"' -f4 | head -1)" || true
      if [[ -n "$_cara_url" ]]; then
        sudo dnf -y install "$_cara_url" >/dev/null 2>&1 ||
          blib_warn "carapace: RPM install failed — retry later: sudo dnf install $_cara_url"
      else
        blib_warn "carapace: could not resolve the latest linux_${_cara_arch} RPM (offline? API rate-limited?) — see github.com/carapace-sh/carapace-bin/releases"
      fi
    fi
  fi
  # op — 1Password CLI, via 1Password's official signed dnf repo.
  if ! command -v op >/dev/null; then
    blib_say "op (1Password CLI — official repo)"
    # This repo needs the signing key in TWO places, and they are not the same place.
    #
    #   gpgcheck=1      → PACKAGE signatures, checked against the rpm keyring
    #                     (`rpm --import`, below). Global, one copy, root-owned.
    #   repo_gpgcheck=1 → REPOSITORY METADATA signatures, which dnf5 checks against a
    #                     PER-REPO, PER-USER keyring at <cachedir>/<repo>/pubring —
    #                     /var/cache/libdnf5/... for root, ~/.cache/libdnf5/... for you.
    #
    # Seeding only the rpm keyring is what broke this box: root's dnf picked the key up on
    # its first transaction, the invoking user's never did, and so every NON-ROOT
    # `dnf --refresh` stopped to ask permission to import it. Those callers (`up`'s
    # post-upgrade refresh, the maintenance runner's upgradable count, the shell nudge) all
    # capture stdout and discard stderr, so the question was invisible — and because a
    # declined import is never persisted, it came back every single time. `up` and
    # `maint-run` both hung forever with no output.
    #
    # So: import to the rpm keyring, then warm the USER's dnf cache too. -y accepts the
    # key non-interactively and </dev/null guarantees this can never be the thing that
    # blocks a bootstrap, belt and braces.
    #
    # Writing the repo file after a FAILED import (the old `|| true`) leaves a repo that is
    # enabled but unverifiable, and every later dnf transaction — including ones that have
    # nothing to do with op — errors with "repomd.xml GPG signature verification error:
    # Signing key not found". Gate the repo file on the import so a transient network failure
    # costs us op, not the package manager.
    if sudo rpm --import https://downloads.1password.com/linux/keys/1password.asc >/dev/null 2>&1; then
      sudo sh -c 'cat >/etc/yum.repos.d/1password.repo' <<'REPO' 2>/dev/null || true
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
REPO
      sudo dnf -y install 1password-cli >/dev/null 2>&1 ||
        echo "   op install failed; see developer.1password.com/docs/cli/get-started"
    else
      blib_warn "could not import 1Password's signing key — skipping the repo (it would break every later dnf transaction); see developer.1password.com/docs/cli/get-started"
    fi
  fi
  # Warm the INVOKING USER's dnf keyring (no sudo — that is the entire point; see the
  # two-keyrings note above). Deliberately OUTSIDE the `command -v op` guard: the boxes that
  # need this most are the ones where op installed fine and only root ever got the key, so
  # gating it on a missing op would skip exactly the machines that are already broken.
  # Idempotent and cheap once the cache is warm, so it is safe on every run.
  if [[ -f /etc/yum.repos.d/1password.repo ]] && command -v dnf >/dev/null; then
    dnf -y makecache --repo=1password </dev/null >/dev/null 2>&1 ||
      blib_warn "could not warm the user dnf cache for the 1Password repo — if \`up\` or \`maint-run\` ever appear to hang, run: dnf -y --refresh makecache --repo=1password"
  fi

  # ── WSL: install /etc/wsl.conf (systemd + default user + interop) ───────────
  if ((IS_WSL)); then
    blib_say "installing /etc/wsl.conf (systemd + default user)"
    local user
    user="$(id -un)"
    sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf" | sudo tee /etc/wsl.conf >/dev/null
    blib_ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen, to apply"
  fi

  if ((DO_FLATPAK)) && ! ((IS_WSL)); then
    blib_say "Flathub"
    flatpak remote-add --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
  fi
}

wire_links() {
  # The shared symlink surface + the Fedora OS overlays + the managed .zshrc
  # loader + the default-login-shell switch all live in core/lib/bootstrap-lib.sh.
  blib_link_core "$DOTFILES" "$CONFIG"
  blib_link_os_layer "$DOTFILES" "$CONFIG" fedora
  # shellcheck disable=SC2119  # no args is intentional — writes the default module set
  blib_write_zshrc_loader
  blib_set_login_shell
  blib_ok "symlinks wired$(blib_selected_note)"
}

((LINKS_ONLY)) || provision
wire_links
blib_ok "Fedora bootstrap complete — open a new shell or: exec zsh"
