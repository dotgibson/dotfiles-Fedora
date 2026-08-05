# dotfiles-Fedora/os/fedora.zsh
# ──────────────────────────────────────────────────────────────────────────────
# The Fedora OS-native shell layer. Symlinked to ~/.config/zsh/80-os.zsh and loaded
# AFTER Core (tools/aliases/functions). Fedora-specific only.
# Works on Fedora Workstation (Wayland/X11) AND WSL.
#
# NOTE: clipboard logic no longer lives here — it moved to Core's cross-OS
# `clip`/`clip-paste` scripts, which zsh, tmux, and nvim all share. This layer
# just keeps the pbcopy/pbpaste muscle-memory names pointed at them.
# ──────────────────────────────────────────────────────────────────────────────
[[ $- == *i* ]] || return 0

# ── PATH: user-local bins first (Core's `clip` scripts + cargo tools land here)
[[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin${PATH:+:$PATH}"
[[ -d "$HOME/.cargo/bin" && ":$PATH:" != *":$HOME/.cargo/bin:"* ]] && export PATH="$HOME/.cargo/bin${PATH:+:$PATH}"
# ~/.atuin/bin: where atuin's own installer puts the binary (bootstrap.sh installs it that
# way — atuin is not reliably packaged on Fedora). The link bootstrap drops in ~/.local/bin
# is what Core's 00-tools.zsh actually detects, since THIS file is fragment 80 and tool
# detection already ran at 00; this entry is the belt-and-braces for a box where the link is
# missing (hand-installed atuin, or a bootstrap that predates it) so at least the command works.
[[ -d "$HOME/.atuin/bin" && ":$PATH:" != *":$HOME/.atuin/bin:"* ]] && export PATH="$HOME/.atuin/bin${PATH:+:$PATH}"

# ── Detect WSL once (for the niceties below) ──────────────────────────────────
_IS_WSL=0
if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
  _IS_WSL=1
elif [[ -r /proc/version ]]; then
  # zsh reads the file directly (no grep/cat fork) — WSL kernels tag /proc/version.
  _pv="$(</proc/version)"; _pv=${_pv:l}
  [[ "$_pv" == *microsoft* || "$_pv" == *wsl* ]] && _IS_WSL=1
  unset _pv
fi

# ── Clipboard: delegate to Core's cross-OS scripts (single implementation) ────
command -v clip       >/dev/null && alias pbcopy='clip'
command -v clip-paste >/dev/null && alias pbpaste='clip-paste'

# ── tool completions / shell hooks (parity with the Mac os layer) ────────────
# direnv/gh/uv/ty emit DETERMINISTIC scripts (the generated hook/completion TEXT is static
# for a given binary; only the runtime hooks vary per-dir/-shell), so route them through
# Core's _cache_eval (00-tools.zsh) — one cheap `source` of a cached file instead of forking
# each generator on EVERY interactive shell. _cache_eval self-guards on the binary being
# present and regenerates only when it's newer than the cache. Falls back to the eager
# eval if this OS layer is sourced without Core's 00-tools.zsh — the fallback
# keeps direnv's stderr visible, while the cached path suppresses the generator's
# stderr (as _cache_eval does); direnv's per-dir runtime warnings are unaffected.
if (( $+functions[_cache_eval] )); then
  _cache_eval direnv direnv hook zsh
  _cache_eval gh gh completion -s zsh
  _cache_eval uv uv generate-shell-completion zsh
  _cache_eval ty ty generate-shell-completion zsh
else
  command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"
  command -v gh >/dev/null 2>&1 && eval "$(gh completion -s zsh 2>/dev/null)"
  command -v uv >/dev/null 2>&1 && eval "$(uv generate-shell-completion zsh 2>/dev/null)"
  command -v ty >/dev/null 2>&1 && eval "$(ty generate-shell-completion zsh 2>/dev/null)"
fi

# ── conveniences ──────────────────────────────────────────────────────────────
alias dotsync='cd "$HOME/dotfiles-Fedora"'              # jump to this repo
command -v op >/dev/null 2>&1 && alias opsignin='eval "$(op signin)"'
alias localip='ip -brief -4 addr show scope global'     # iface + LAN IP(s)

# ── WSL-only niceties (interop reach-arounds into Windows) ───────────────────
if (( _IS_WSL )); then
  alias open='explorer.exe'                 # `open .` opens the dir in Explorer
  command -v wslview >/dev/null && alias xdg-open='wslview'
  # jump to your Windows user home: set WINHOME in 99-local.zsh, e.g.
  #   export WINHOME="/mnt/c/Users/<you>"
  [[ -n "${WINHOME:-}" ]] && alias cdwin='cd "$WINHOME"'
fi

# ── Fedora ships fd as `fd` (not fdfind) — 00-tools.zsh already resolved this. ───

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

# ── atuin daemon: the opt-in Core ships OFF (dotfiles-core#335) ───────────────
# Core's atuin/config.toml is vendored identically to eight repos, so the per-machine flip
# is atuin's own env override, set HERE — never by editing that file. The daemon owns the
# SQLite writes so shells stop contending for the DB lock.
#
# Which launcher we point it at depends on whether this box HAS one. Bootstrap installs a
# systemd user unit, but WSL only has a user manager when /etc/wsl.conf sets systemd=true
# (and the distro has been restarted since) — so probe rather than assume, because a daemon
# enabled with nothing to start it is the one state worth avoiding.
#
#   systemd present → the unit owns the lifecycle; enable the daemon and let it connect.
#   no systemd      → hand the lifecycle to atuin itself (autostart), the same path Alpine
#                     and macOS take. NOT compatible with systemd_socket, which we do not use.
#
# Either way Core's guard (00-tools.zsh) probes the socket once before the first prompt and
# forces the daemon off for that shell if nothing is listening — so a broken launcher costs
# the lock relief, never a working shell. `core-doctor` reports the degraded state.
if [[ -n ${HAVE_ATUIN:-} ]]; then
  export ATUIN_DAEMON__ENABLED=true
  [[ -d /run/systemd/system ]] || export ATUIN_DAEMON__AUTOSTART=true
fi

unset _IS_WSL

# ── auto-start/attach tmux for interactive terminals ─────────────────────────
# Skip inside an existing tmux, VS Code's integrated terminal, and non-TTYs.
if command -v tmux >/dev/null 2>&1 \
   && [[ -z "$TMUX" && -t 1 && "$TERM_PROGRAM" != "vscode" ]]; then
  tmux attach -t main 2>/dev/null || tmux new-session -s main
fi
