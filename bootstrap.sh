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
  if ! command -v yazi >/dev/null && command -v cargo >/dev/null; then
    blib_say "yazi (cargo)"
    cargo install --locked yazi-fs yazi-cli >/dev/null 2>&1 || true
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

  # ── doctor-probed tools not (reliably) in Fedora 41/42 repos ────────────────
  # Round out core-doctor's modern-CLI set. All best-effort (|| true) + presence-
  # guarded — same discipline as starship/atuin/yazi above; a failure here never
  # aborts bootstrap. dust/xh via cargo (dust lands in the F43 repo — revisit then);
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
      GOBIN="$gobin" go install "$1" >/dev/null 2>&1 ||
        echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
    elif command -v mise >/dev/null 2>&1; then
      GOBIN="$gobin" mise exec go@latest -- go install "$1" >/dev/null 2>&1 ||
        echo "   $2: go install failed — retry later: GOBIN=$gobin go install $1"
    else
      echo "   $2: needs Go — install later with: GOBIN=$gobin go install $1"
    fi
    return 0
  }
  if ! command -v dust >/dev/null && command -v cargo >/dev/null; then
    blib_say "dust (cargo — crate du-dust; not in F41/42 repos yet)"
    cargo install --locked du-dust >/dev/null 2>&1 || true
  fi
  if ! command -v xh >/dev/null && command -v cargo >/dev/null; then
    blib_say "xh (cargo; not in Fedora repos)"
    cargo install --locked xh >/dev/null 2>&1 || true
  fi
  # sd (sed replacement) was retired from Fedora after F41 — rust-sd's `sd` subpackage
  # last built 1.0.0-4.fc41, so `dnf install sd` fails on current releases. Same story
  # as gron below, just Rust instead of Go.
  if ! command -v sd >/dev/null && command -v cargo >/dev/null; then
    blib_say "sd (cargo — retired from Fedora repos after F41)"
    cargo install --locked sd >/dev/null 2>&1 || true
  fi
  # viddy (watch replacement; Core aliases watch->viddy, HAVE_VIDDY-guarded) is a Rust
  # CLI, not in Fedora repos — build from source via cargo like dust/xh above.
  if ! command -v viddy >/dev/null && command -v cargo >/dev/null; then
    blib_say "viddy (cargo — watch replacement; not in Fedora repos)"
    cargo install --locked viddy >/dev/null 2>&1 || true
  fi
  blib_say "doggo / carapace / sesh / gron (go install where absent)"
  _dotfiles_go_install github.com/mr-karan/doggo/cmd/doggo@latest doggo
  _dotfiles_go_install github.com/carapace-sh/carapace-bin/cmd/carapace@latest carapace
  _dotfiles_go_install github.com/joshmedeski/sesh/v2@latest sesh
  # gron was orphaned + dropped from Fedora (last in F41/42), so `dnf install gron`
  # fails on current releases — install it from source like the others above.
  _dotfiles_go_install github.com/tomnomnom/gron@latest gron
  # op — 1Password CLI, via 1Password's official signed dnf repo.
  if ! command -v op >/dev/null; then
    blib_say "op (1Password CLI — official repo)"
    # The repo file sets repo_gpgcheck=1, so it is only usable once the signing key is in the
    # rpm keyring. Writing it after a FAILED import (the old `|| true`) leaves a repo that is
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
