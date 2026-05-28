# dotfiles-Fedora/os/fedora.zsh
# ──────────────────────────────────────────────────────────────────────────────
# The Fedora OS-native shell layer. Symlinked to ~/.config/zsh/os.zsh and loaded
# AFTER Core (tools/aliases/functions). Everything here is Fedora-specific:
# clipboard, package manager, SELinux, flatpak. Nothing portable belongs here —
# portable things go up into dotfiles-core.
# ──────────────────────────────────────────────────────────────────────────────
[[ $- == *i* ]] || return 0

# ── Clipboard shim: give Fedora the pbcopy/pbpaste muscle memory from the Mac ─
# Wayland is the Workstation default; fall back to X11 tools over SSH/X11 sessions.
if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-copy >/dev/null; then
  alias pbcopy='wl-copy'
  alias pbpaste='wl-paste'
elif command -v xclip >/dev/null; then
  alias pbcopy='xclip -selection clipboard'
  alias pbpaste='xclip -selection clipboard -o'
fi

# ── Fedora ships fd as `fd` (not fdfind) — tools.zsh already resolved this. ───

# ── dnf quality-of-life (dnf5 default since F41; commands are identical) ──────
alias dnfi='sudo dnf install'
alias dnfs='dnf search'
alias dnfu='sudo dnf upgrade --refresh'
alias dnfr='sudo dnf remove'
alias dnfh='dnf history'              # transaction history — undo-able installs
alias dnfwhat='dnf provides'         # which package owns a file/command
# undo the last dnf transaction (handy after a bad upgrade):
dnf-undo() { sudo dnf history undo last; }

# ── Flatpak helpers ───────────────────────────────────────────────────────────
alias fpi='flatpak install flathub'
alias fpu='flatpak update'
alias fps='flatpak search'
alias fpl='flatpak list --app'

# ── SELinux helpers (Fedora is enforcing by default; relevant for security work)
alias se-status='sestatus'
alias se-denials='sudo ausearch -m AVC,USER_AVC -ts recent 2>/dev/null | tail -40'
# restore default SELinux context on a path after moving/copying a file:
se-restore() { sudo restorecon -Rv "${1:?usage: se-restore <path>}"; }
# explain the most recent denials in plain language (needs setroubleshoot):
alias se-why='sudo journalctl -t setroubleshoot --since "10 min ago" 2>/dev/null'

# ── machine-specific PATH (cargo-installed tools land here) ──────────────────
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
