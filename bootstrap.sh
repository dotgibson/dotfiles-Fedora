#!/usr/bin/env bash
# dotfiles-Fedora/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision a Fedora Workstation/Server box and wire up dotfiles. Idempotent —
# safe to re-run. This is the OS-NATIVE layer; Core (zsh/tmux/nvim/git) is
# vendored under core/ via git subtree and symlinked in by this script.
#
# Usage:
#   ./bootstrap.sh                 # full: dnf packages + extras + symlinks
#   ./bootstrap.sh --links-only    # just (re)create symlinks
#   ./bootstrap.sh --no-flatpak    # skip Flathub/GUI apps
#
# Fedora specifics handled here:
#   - dnf5 (default since Fedora 41) — `dnf` is the right command either way
#   - RPM Fusion (free + nonfree) for codecs / extra packages
#   - Flathub for GUI apps
#   - Wayland-first clipboard (wl-clipboard); X11 fallback handled in os/fedora.zsh
#   - a few modern CLI tools not always packaged are installed via official
#     scripts / cargo so behavior matches the other distro repos
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0; DO_FLATPAK=1

for a in "$@"; do case "$a" in
  --links-only) LINKS_ONLY=1 ;;
  --no-flatpak) DO_FLATPAK=0 ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a" >&2; exit 1 ;;
esac; done

say(){ printf '\e[36m::\e[0m %s\n' "$*"; }
ok(){  printf '\e[32m✓\e[0m %s\n' "$*"; }

# ── sanity: confirm we're on Fedora ───────────────────────────────────────────
if ! grep -qi fedora /etc/os-release 2>/dev/null; then
  echo "This bootstrap targets Fedora. /etc/os-release doesn't look like Fedora." >&2
  echo "Use the matching distro repo instead." >&2
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
  # shellcheck disable=SC2046
  sudo dnf -y install $(grep -vE '^\s*#|^\s*$' "$DOTFILES/install/packages.txt" | tr '\n' ' ')
  ok "dnf packages installed"

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

  if (( DO_FLATPAK )); then
    say "Flathub"
    flatpak remote-add --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
    # GUI apps you actually want go here:
    # flatpak install -y flathub com.github.tchx84.Flatseal
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

  say "symlinking Fedora OS-native layer"
  link "$DOTFILES/os/fedora.zsh" "$CONFIG/zsh/os.zsh"

  # .zshrc sources core (tools -> aliases -> functions) then os.zsh last.
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
  ok "symlinks wired"
}

(( LINKS_ONLY )) || provision
wire_links
ok "Fedora bootstrap complete — open a new shell or: exec zsh"
