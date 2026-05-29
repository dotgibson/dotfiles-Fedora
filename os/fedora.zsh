# dotfiles-Fedora/os/fedora.zsh
# ──────────────────────────────────────────────────────────────────────────────
# The Fedora OS-native shell layer. Symlinked to ~/.config/zsh/os.zsh and loaded
# AFTER Core (tools/aliases/functions). Fedora-specific only.
# Works on Fedora Workstation (Wayland/X11) AND WSL.
#
# NOTE: clipboard logic no longer lives here — it moved to Core's cross-OS
# `clip`/`clip-paste` scripts, which zsh, tmux, and nvim all share. This layer
# just keeps the pbcopy/pbpaste muscle-memory names pointed at them.
# ──────────────────────────────────────────────────────────────────────────────
[[ $- == *i* ]] || return 0

# ── PATH: user-local bins first (Core's `clip` scripts + cargo tools land here)
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
[[ -d "$HOME/.cargo/bin"  ]] && export PATH="$HOME/.cargo/bin:$PATH"

# ── Detect WSL once (for the niceties below) ──────────────────────────────────
_IS_WSL=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  _IS_WSL=1
fi

# ── Clipboard: delegate to Core's cross-OS scripts (single implementation) ────
command -v clip       >/dev/null && alias pbcopy='clip'
command -v clip-paste >/dev/null && alias pbpaste='clip-paste'

# ── WSL-only niceties (interop reach-arounds into Windows) ───────────────────
if (( _IS_WSL )); then
  alias open='explorer.exe'                 # `open .` opens the dir in Explorer
  command -v wslview >/dev/null && alias xdg-open='wslview'
  # jump to your Windows user home: set WINHOME in local.zsh, e.g.
  #   export WINHOME="/mnt/c/Users/<you>"
  [[ -n "${WINHOME:-}" ]] && alias cdwin='cd "$WINHOME"'
fi

# ── Fedora ships fd as `fd` (not fdfind) — tools.zsh already resolved this. ───

# ── dnf quality-of-life (dnf5 default since F41; commands are identical) ──────
alias dnfi='sudo dnf install'
alias dnfs='dnf search'
alias dnfu='sudo dnf upgrade --refresh'
alias dnfr='sudo dnf remove'
alias dnfh='dnf history'              # transaction history — undo-able installs
alias dnfwhat='dnf provides'         # which package owns a file/command
dnf-undo() { sudo dnf history undo last; }

# ── Flatpak helpers (mostly inert on WSL without WSLg; harmless) ─────────────
alias fpi='flatpak install flathub'
alias fpu='flatpak update'
alias fps='flatpak search'
alias fpl='flatpak list --app'

# ── SELinux helpers ───────────────────────────────────────────────────────────
# NOTE: WSL kernels usually run with SELinux DISABLED, so these are inert there.
# They matter once you also run this repo on bare-metal / VM Fedora (enforcing).
alias se-status='sestatus 2>/dev/null || echo "SELinux not active (expected on WSL)"'
alias se-denials='sudo ausearch -m AVC,USER_AVC -ts recent 2>/dev/null | tail -40'
se-restore() { sudo restorecon -Rv "${1:?usage: se-restore <path>}"; }
alias se-why='sudo journalctl -t setroubleshoot --since "10 min ago" 2>/dev/null'

unset _IS_WSL

# ── auto-start/attach tmux for interactive terminals ─────────────────────────
# Skip inside an existing tmux, VS Code's integrated terminal, and non-TTYs.
if command -v tmux >/dev/null 2>&1 \
   && [[ -z "$TMUX" && -t 1 && "$TERM_PROGRAM" != "vscode" ]]; then
  tmux attach -t main 2>/dev/null || tmux new-session -s main
fi
