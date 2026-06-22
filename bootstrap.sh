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
LINKS_ONLY=0
DO_FLATPAK=1

for a in "$@"; do case "$a" in
	--links-only) LINKS_ONLY=1 ;;
	--no-flatpak) DO_FLATPAK=0 ;;
	-h | --help)
		sed -n '2,18p' "$0"
		exit 0
		;;
	*)
		echo "unknown arg: $a" >&2
		exit 1
		;;
	esac done

say() { printf '\e[36m::\e[0m %s\n' "$*"; }
ok() { printf '\e[32m✓\e[0m %s\n' "$*"; }

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

link() { # link SRC -> DST, backing up any existing real file
	local src="$1" dst="$2"
	mkdir -p "$(dirname "$dst")"
	if [[ -L "$dst" ]]; then
		rm -f "$dst"
	elif [[ -e "$dst" ]]; then mv "$dst" "$dst.pre-dotfiles.$(date +%s)"; fi
	ln -s "$src" "$dst"
}

# ── read a package list, stripping inline (#...) comments + blank lines ───────
read_pkgs() { # $1 = file; prints clean package names, one per line
	local line
	while IFS= read -r line; do
		line="${line%%#*}"           # drop everything from the first # onward
		line="${line//[[:space:]]/}" # package names contain no whitespace
		[[ -n "$line" ]] && printf '%s\n' "$line"
	done <"$1"
}

provision() {
	say "dnf upgrade refresh"
	sudo dnf -y makecache >/dev/null

	say "RPM Fusion (free + nonfree)"
	local rel
	rel="$(rpm -E %fedora)"
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
	# mise — polyglot runtime manager (node/python/go/...). Portable; activated in
	# core/zsh/tools.zsh. Install the binary here; runtimes are fetched separately
	# with `mise install` (kept out of bootstrap so it stays fast/predictable).
	if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
		say "mise (official installer)"
		curl -fsSL https://mise.run | sh >/dev/null 2>&1 || true
	fi
	# lazygit isn't in Fedora's base repos — pull it from the well-known COPR.
	if ! command -v lazygit >/dev/null; then
		say "lazygit (COPR atim/lazygit)"
		sudo dnf -y install dnf5-plugins >/dev/null 2>&1 || true
		sudo dnf -y copr enable atim/lazygit >/dev/null 2>&1 || true
		sudo dnf -y install lazygit >/dev/null 2>&1 ||
			echo "   lazygit COPR install failed; do it later: sudo dnf copr enable atim/lazygit && sudo dnf install lazygit"
	fi

	# ── WSL: install /etc/wsl.conf (systemd + default user + interop) ───────────
	if ((IS_WSL)); then
		say "installing /etc/wsl.conf (systemd + default user)"
		local user
		user="$(id -un)"
		sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf" | sudo tee /etc/wsl.conf >/dev/null
		ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen, to apply"
	fi

	if ((DO_FLATPAK)) && ! ((IS_WSL)); then
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
	# tmux popup scripts (prefix w/T/f) — symlink the dir + ensure they're runnable
	if [[ -d "$DOTFILES/core/tmux/scripts" ]]; then
		link "$DOTFILES/core/tmux/scripts" "$CONFIG/tmux/scripts"
		chmod +x "$DOTFILES"/core/tmux/scripts/*.sh 2>/dev/null || true
	fi
	# Fedora tmux bits (netspeed iface + battery) — optional; tmux.conf sources it
	# with `-q`, so it's fine if os/fedora.conf doesn't exist yet.
	[[ -f "$DOTFILES/os/fedora.conf" ]] && link "$DOTFILES/os/fedora.conf" "$CONFIG/tmux/os.conf"
	# tmux plugin manager (tpm) — clone once so the theme + resurrect/continuum
	# load. Plugins still need one install pass: `prefix+I` in tmux, or headless
	# ~/.config/tmux/plugins/tpm/bin/install_plugins
	if [[ ! -d "$CONFIG/tmux/plugins/tpm" ]]; then
		say "cloning tpm (tmux plugin manager)"
		git clone --depth=1 https://github.com/tmux-plugins/tpm "$CONFIG/tmux/plugins/tpm" >/dev/null 2>&1 &&
			ok "tpm cloned — run prefix+I in tmux to install plugins" ||
			say "tpm clone failed — clone it manually, then prefix+I"
	fi
	# starship prompt theme — symlink to the DEFAULT path (tools.zsh inits starship
	# against ~/.config/starship.toml with no STARSHIP_CONFIG, same as the Mac).
	[[ -f "$DOTFILES/core/starship/starship.toml" ]] && link "$DOTFILES/core/starship/starship.toml" "$CONFIG/starship.toml"
	[[ -d "$DOTFILES/core/nvim" ]] && link "$DOTFILES/core/nvim" "$CONFIG/nvim"
	[[ -f "$DOTFILES/core/mise/config.toml" ]] && link "$DOTFILES/core/mise/config.toml" "$CONFIG/mise/config.toml"
	[[ -f "$DOTFILES/core/git/gitconfig" ]] && link "$DOTFILES/core/git/gitconfig" "$HOME/.gitconfig"

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
			if [[ -f "$DOTFILES/core/bin/$s" ]]; then
				link "$DOTFILES/core/bin/$s" "$HOME/.local/bin/$s"
				chmod +x "$DOTFILES/core/bin/$s" 2>/dev/null || true
			fi
		done
	fi

	# SSH client config (keys are NEVER tracked — only ssh/config) ──────────────
	# ssh is strict about permissions: ~/.ssh must be 0700, and ControlMaster
	# needs the sockets dir to already exist or multiplexed connections fail.
	if [[ -f "$DOTFILES/ssh/config" ]]; then
		say "symlinking ssh/config"
		mkdir -p "$HOME/.ssh/sockets"
		chmod 700 "$HOME/.ssh" "$HOME/.ssh/sockets"
		chmod 600 "$DOTFILES/ssh/config" 2>/dev/null || true
		link "$DOTFILES/ssh/config" "$HOME/.ssh/config"
		ok "~/.ssh/config linked (generate a key with: ssh-keygen -t ed25519)"
	fi

	say "symlinking Fedora OS-native layer"
	link "$DOTFILES/os/fedora.zsh" "$CONFIG/zsh/os.zsh"

	if [[ ! -f "$HOME/.zshrc" ]] || ! grep -q "dotfiles-managed v2" "$HOME/.zshrc" 2>/dev/null; then
		say "writing .zshrc loader"
		[[ -f "$HOME/.zshrc" ]] && cp "$HOME/.zshrc" "$HOME/.zshrc.pre-dotfiles.$(date +%s)"
		cat >"$HOME/.zshrc" <<'ZRC'
# dotfiles-managed v2 — do not hand-edit; put local tweaks in ~/.config/zsh/local.zsh
# Fedora has no ~/.zshenv, so this entry file also sets the env the Core modules
# expect, then sources them in the ONE correct order. Mirror of the Mac's .zshrc.

# ── XDG + env (no zshenv on Fedora) ───────────────────────────────────────────
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
export EDITOR=nvim VISUAL=nvim
export NOTES_DIR="${NOTES_DIR:-$HOME/Notes}"

# ── Core modules + Fedora os layer + local overrides, in canonical order ──
# history.zsh owns HISTFILE/HISTSIZE + history setopts; options.zsh owns the nav/glob
# setopts + compinit + completion zstyles — so this entry file no longer hand-rolls
# them. It declares the load order and sources the vendored Core loader
# (core/zsh/loader.zsh -> $ZSH_CFG/loader.zsh), which byte-compiles + sources each
# module. Loading the FULL set (ui/git/maint/update were silently missing) is the fix.
: "${ZDOTDIR:=$XDG_CONFIG_HOME/zsh}"
export ZDOTDIR              # Core modules (history/options) key state off ZDOTDIR;
ZSH_CFG="$ZDOTDIR"          # align the loader to the SAME dir so state never splits
_CORE_MODULES=(tools ui options history aliases git functions fzf bindings plugins op maint update os local)
if [[ -r "$ZSH_CFG/loader.zsh" ]]; then
  source "$ZSH_CFG/loader.zsh"
else
  print -u2 -- "zshrc: Core loader not found at $ZSH_CFG/loader.zsh — re-run the dotfiles bootstrap to (re)link Core."
fi
unset _CORE_MODULES
ZRC
	fi

	# make zsh the default LOGIN shell — a fresh WSL/login session starts the
	# login shell, not `exec zsh`. Idempotent: only acts if it isn't already zsh.
	if command -v zsh >/dev/null; then
		local zsh_path
		zsh_path="$(command -v zsh)"
		if ! getent passwd "$USER" | grep -q ":$zsh_path$"; then
			say "setting zsh as default login shell"
			grep -qxF "$zsh_path" /etc/shells || echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
			sudo chsh -s "$zsh_path" "$USER" && ok "default shell -> zsh (applies to NEW sessions)"
		fi
	fi
	ok "symlinks wired"
}

((LINKS_ONLY)) || provision
wire_links
ok "Fedora bootstrap complete — open a new shell or: exec zsh"
