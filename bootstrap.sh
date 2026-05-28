#!/usr/bin/env bash
# dotfiles-Fedora/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision a Fedora box (Workstation or WSL) and wire up dotfiles. Idempotent —
# safe to re-run. This is the OS-NATIVE layer; Core (zsh/tmux/nvim/git) is
# vendored under core/ via git subtree and symlinked in by this script.
#
# Usage:
#   ./bootstrap.sh                 # full: dnf packages + extras + symlinks
#   ./bootstrap.sh --links-only    # just (re)create symlinks
#   ./bootstrap.sh --no-flatpak    # skip Flathub/GUI apps (recommended on WSL)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0; DO_FLATPAK=1

for a in "$@"; do case "$a" in
  --links-only) LINKS_ONLY=1 ;;
  --no-flatpak) DO_FLATPAK=0 ;;
  -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a" >&2; exit 1 ;;
esac; done

say(){ printf '\e[36m::\e[0m %s\n' "$*"; }
ok(){  printf '\e[32m✓\e[0m %s\n' "$*"; }

# ── Detect WSL ────────────────────────────────────────────────────────────────
IS_WSL=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  IS_WSL=1
fi

# ── sanity: confirm we're on Fedora ───────────────────────────────────────────
if ! grep -qi fedora /etc/os-release 2>/dev/null; then
  echo "This bootstrap targets Fedora. /etc/os-release doesn't look like Fedora." >&2
  exit 1
fi

# ── core/ subtree present? ────────────────────────────────────────────────────
if [[ ! -d "$DOTFILES/core/zsh" ]]; then
  echo "core/ subtree missing. One-time, run:" >&2
  echo "  git subtree add --prefix=core <dotfiles-core remote> main --squash" >&2
  exit 1
fi

link(){  # link SRC -> DST, backing up any existing real file
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -L "$dst" ]]; then rm -f "$dst"
  elif [[ -e "$dst" ]]; then mv "$dst" "$dst.pre-dotfiles.$(date +%s)"; fi
  ln -s "$src" "$dst"
}

# ── read a package list, stripping inline (#...) comments + blank lines ───────
read_pkgs(){  # $1 = file; prints clean package names, one per line
  local line
  while IFS= read -r line; do
    line="${line%%#*}"               # drop everything from the first # onward
    line="${line//[[:space:]]/}"     # package names contain no whitespace
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done < "$1"
}

provision() {
  say "dnf upgrade refresh"
  sudo dnf -y makecache >/dev/null

  say "RPM Fusion (free + nonfree)"
  local rel; rel="$(rpm -E %fedora)"
  sudo dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${rel}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${rel}.noarch.rpm" \
    >/dev/null 2>&1 || true

  say "dnf packages (from install/packages.txt)"
  local -a pkgs=()
  mapfile -t pkgs < <(read_pkgs "$DOTFILES/install/packages.txt")
  # dnf5 fails the WHOLE transaction if any single requested pkg is unavailable
  # (and is fussy about already-installed ones) — --skip-unavailable makes the
  # bulk install resilient: missing names are skipped instead of aborting.
  sudo dnf -y install --skip-unavailable "${pkgs[@]}"
  ok "dnf packages installed (${#pkgs[@]} requested)"

  # Tools not reliably packaged on Fedora — match the other repos via upstream.
  if ! command -v starship >/dev/null; then
    say "starship (official installer)"
    curl -fsSL https://starship.rs/install.sh | sh -s -- -y >/dev/null
  fi
  if ! command -v atuin >/dev/null; then
    say "atuin (official installer)"
    curl -fsSL https://setup.atuin.sh | sh >/dev/null 2>&1 || true
  fi
  if ! command -v yazi >/dev/null && command -v cargo >/dev/null; then
    say "yazi (cargo)"
    cargo install --locked yazi-fs yazi-cli >/dev/null 2>&1 || true
  fi
  # lazygit isn't in Fedora's base repos — pull it from the well-known COPR.
  if ! command -v lazygit >/dev/null; then
    say "lazygit (COPR atim/lazygit)"
    sudo dnf -y install dnf5-plugins >/dev/null 2>&1 || true
    sudo dnf -y copr enable atim/lazygit >/dev/null 2>&1 || true
    sudo dnf -y install lazygit >/dev/null 2>&1 \
      || echo "   lazygit COPR install failed; do it later: sudo dnf copr enable atim/lazygit && sudo dnf install lazygit"
  fi

  # ── WSL: install /etc/wsl.conf (systemd + default user + interop) ───────────
  if (( IS_WSL )); then
    say "installing /etc/wsl.conf (systemd + default user)"
    local user; user="$(id -un)"
    sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf" | sudo tee /etc/wsl.conf >/dev/null
    ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen, to apply"
  fi

  if (( DO_FLATPAK )) && ! (( IS_WSL )); then
    say "Flathub"
    flatpak remote-add --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
  fi
}

wire_links() {
  say "symlinking Core"
  for f in "$DOTFILES"/core/zsh/*.zsh; do
    link "$f" "$CONFIG/zsh/$(basename "$f")"
  done
  [[ -f "$DOTFILES/core/tmux/tmux.conf" ]] && link "$DOTFILES/core/tmux/tmux.conf" "$CONFIG/tmux/tmux.conf"
  [[ -d "$DOTFILES/core/nvim" ]]           && link "$DOTFILES/core/nvim"           "$CONFIG/nvim"
  [[ -f "$DOTFILES/core/git/gitconfig" ]]  && link "$DOTFILES/core/git/gitconfig"  "$HOME/.gitconfig"

  # OS-specific git layer (credential helper) -> included by Core's gitconfig
  [[ -f "$DOTFILES/os/fedora.gitconfig" ]] && link "$DOTFILES/os/fedora.gitconfig" "$CONFIG/git/os.gitconfig"
  # private identity file, seeded ONCE from the example (never tracked)
  if [[ ! -f "$CONFIG/git/local.gitconfig" && -f "$DOTFILES/core/git/local.gitconfig.example" ]]; then
    mkdir -p "$CONFIG/git"
    cp "$DOTFILES/core/git/local.gitconfig.example" "$CONFIG/git/local.gitconfig"
    say "seeded ~/.config/git/local.gitconfig — FILL IN your name & email"
  fi

  # cross-OS helper scripts from Core onto PATH (~/.local/bin)
  if [[ -d "$DOTFILES/core/bin" ]]; then
    mkdir -p "$HOME/.local/bin"
    for s in clip clip-paste; do
      [[ -f "$DOTFILES/core/bin/$s" ]] && link "$DOTFILES/core/bin/$s" "$HOME/.local/bin/$s"
    done
  fi

  say "symlinking Fedora OS-native layer"
  link "$DOTFILES/os/fedora.zsh" "$CONFIG/zsh/os.zsh"

  if [[ ! -f "$HOME/.zshrc" ]] || ! grep -q "dotfiles-managed" "$HOME/.zshrc" 2>/dev/null; then
    say "writing .zshrc loader"
    cat > "$HOME/.zshrc" <<'ZRC'
# dotfiles-managed — do not hand-edit; put local tweaks in ~/.config/zsh/local.zsh
ZDOTDIR_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/zsh"
for m in tools aliases functions os local; do
  [[ -r "$ZDOTDIR_CFG/$m.zsh" ]] && source "$ZDOTDIR_CFG/$m.zsh"
done
ZRC
  fi

  # make zsh the default LOGIN shell — a fresh WSL/login session starts the
  # login shell, not `exec zsh`. Idempotent: only acts if it isn't already zsh.
  if command -v zsh >/dev/null; then
    local zsh_path; zsh_path="$(command -v zsh)"
    if ! getent passwd "$USER" | grep -q ":$zsh_path$"; then
      say "setting zsh as default login shell"
      grep -qxF "$zsh_path" /etc/shells || echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
      sudo chsh -s "$zsh_path" "$USER" && ok "default shell -> zsh (applies to NEW sessions)"
    fi
  fi
  ok "symlinks wired"
}

(( LINKS_ONLY )) || provision
wire_links
ok "Fedora bootstrap complete — open a new shell or: exec zsh"
