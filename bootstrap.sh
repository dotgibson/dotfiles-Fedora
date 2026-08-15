#!/usr/bin/env bash
# dotfiles-Fedora/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Provision a Fedora box (Workstation or WSL) and wire up dotfiles. Idempotent —
# safe to re-run. This is the OS-NATIVE layer; Core (zsh/tmux/nvim/git) is
# vendored under core/ and symlinked in via the shared core/lib/bootstrap-lib.sh.
#
# Run `./bootstrap.sh --help` for the flag list (usage() below is the one definition —
# do NOT re-add a `sed -n 'N,Mp' "$0"` help, which silently drifts when this header moves;
# core/scripts/sync-core.sh documents that exact trap).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
LINKS_ONLY=0
DO_FLATPAK=1
STRICT=0
FORCE_OS=0
# --only/--skip are validated by the shared lib (blib_select), which is sourced
# AFTER this loop — so capture the raw values now and apply them below.
ONLY_RAW="" SKIP_RAW="" ONLY_SEEN=0 SKIP_SEEN=0

# usage() is a real heredoc, NOT `sed -n '2,17p' "$0"`. The old form was coupled to this
# file's header line numbers, so editing the banner above silently drifted `--help` — the
# trap core/scripts/sync-core.sh calls out by name. This stays correct however the header moves.
usage() {
  cat <<'EOF'
bootstrap.sh — provision a Fedora box (Workstation, Server, or WSL) and wire up dotfiles.
Idempotent: safe to re-run.

  ./bootstrap.sh                  full: dnf packages + extras + symlinks
  ./bootstrap.sh --links-only     just (re)create symlinks (no dnf, no downloads)
  ./bootstrap.sh --dry-run        preview EVERYTHING; change nothing
  ./bootstrap.sh --no-flatpak     skip Flathub/GUI apps (recommended on WSL)
  ./bootstrap.sh --only zsh,nvim  link ONLY these Core module groups
  ./bootstrap.sh --skip tmux      link everything EXCEPT these groups
  ./bootstrap.sh --strict         exit non-zero if any best-effort step failed
  ./bootstrap.sh --force-os       run on a Fedora-LIKE distro (RHEL/Alma/Rocky/Nobara)
  ./bootstrap.sh -h, --help       show this help and exit

Module groups (for --only/--skip): zsh nvim tmux git prompt tools — they affect the
wiring steps only, never package provisioning; combine with --links-only to re-wire a
subset of configs without touching dnf.

Env:
  BLIB_SU   privilege escalator; auto-resolved (empty as root, else sudo, else doas).
            Set explicitly to override, e.g. BLIB_SU=doas or BLIB_SU= to run as root.
EOF
}

while [[ $# -gt 0 ]]; do case "$1" in
  --links-only) LINKS_ONLY=1 ;;
  --no-flatpak) DO_FLATPAK=0 ;;
  --dry-run | -n) BLIB_DRY=1 ;;
  --strict) STRICT=1 ;;
  --force-os) FORCE_OS=1 ;;
  --only) [[ $# -ge 2 ]] || { echo "--only requires module names, e.g. --only zsh,nvim" >&2; exit 1; }; ONLY_RAW="$2"; ONLY_SEEN=1; shift ;;
  --only=*) ONLY_RAW="${1#*=}"; ONLY_SEEN=1 ;;
  --skip) [[ $# -ge 2 ]] || { echo "--skip requires module names, e.g. --skip tmux" >&2; exit 1; }; SKIP_RAW="$2"; SKIP_SEEN=1; shift ;;
  --skip=*) SKIP_RAW="${1#*=}"; SKIP_SEEN=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    usage >&2
    exit 1
    ;;
  esac; shift; done
# BLIB_DRY is read by the shared lib's mutating helpers via ${BLIB_DRY:-0} at CALL time,
# so setting it here (before the lib is sourced) is enough. Default it so `set -u` is safe.
: "${BLIB_DRY:=0}"

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

# ── deferred failures ─────────────────────────────────────────────────────────
# ~20 steps below are deliberately best-effort (`|| true` / a warning): a COPR that is
# down, a rate-limited GitHub API, or a crate that fails to build must not strand the
# rest of a fresh box. But the old script then printed "Fedora bootstrap complete" and
# exited 0 regardless — so a machine missing carapace, op, lazygit AND every cargo tool
# reported success, and neither CI nor the operator had a signal. Record each miss and
# report them together at the end (and exit non-zero under --strict).
FAILED_STEPS=()
note_fail() {
  FAILED_STEPS+=("$1")
  blib_warn "$1"
}

# ── sanity: confirm we're on Fedora ───────────────────────────────────────────
# Parse the ID= / ID_LIKE= KEYS rather than grepping the whole file for "fedora": the old
# `grep -qi fedora /etc/os-release` matched ID_LIKE="fedora" (RHEL, Alma, Rocky, CentOS
# Stream, Nobara) and any incidental substring — e.g. a HOME_URL — so those distros sailed
# past the guard and got RPM Fusion plus a Fedora-only package list. A Fedora-LIKE distro
# is a legitimate but DELIBERATE target: it needs --force-os.
_osr_field() { # <KEY> — the unquoted value of KEY in /etc/os-release ("" when absent)
  [[ -r /etc/os-release ]] || return 0
  sed -n "s/^$1=//p" /etc/os-release | head -1 | tr -d '"'"'"
}
OS_ID="$(_osr_field ID)"
OS_ID_LIKE="$(_osr_field ID_LIKE)"
if [[ "$OS_ID" != fedora ]]; then
  if [[ " $OS_ID_LIKE " == *" fedora "* ]]; then
    if ((FORCE_OS)); then
      blib_warn "ID=$OS_ID is only fedora-LIKE — continuing under --force-os; package names may differ"
    else
      echo "This bootstrap targets Fedora (ID=fedora); this box reports ID=$OS_ID (ID_LIKE=$OS_ID_LIKE)." >&2
      echo "Package names and RPM Fusion releases differ there. Re-run with --force-os to proceed anyway." >&2
      exit 1
    fi
  else
    echo "This bootstrap targets Fedora. /etc/os-release reports ID=${OS_ID:-<none>}." >&2
    exit 1
  fi
fi

IS_WSL=0
if blib_is_wsl; then IS_WSL=1; fi

# ── privilege escalation ──────────────────────────────────────────────────────
# Resolve the escalator ONCE, the way the shared lib expects (it reads $BLIB_SU, defaulting
# to `sudo` only when the var is UNSET — so an explicit empty value means "run directly").
#
# The old script hard-coded `sudo` at a dozen call sites. That is wrong wherever there is no
# sudo to call: a `fedora:latest` container, a WSL distro's first boot (root, before wsl.conf
# installs the default user), and a minimal Server image all lack it — so `./bootstrap.sh`
# died at the FIRST dnf line with `sudo: command not found` (exit 127 under set -e), before
# doing anything at all. It is also why the reusable CI test can only exercise --links-only
# with BLIB_SU= . Resolving here fixes both, and keeps the lib's own escalations
# (blib_set_login_shell) in step with ours.
if [[ -z "${BLIB_SU+x}" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    BLIB_SU=""
  elif command -v sudo >/dev/null 2>&1; then
    BLIB_SU="sudo"
  elif command -v doas >/dev/null 2>&1; then
    BLIB_SU="doas"
  else
    BLIB_SU=""
    ((LINKS_ONLY)) || {
      echo "Not root and neither sudo nor doas is installed — cannot install packages." >&2
      echo "Re-run as root, install sudo, or use --links-only (which needs no privileges)." >&2
      exit 1
    }
  fi
fi
export BLIB_SU
# priv <cmd...> — run CMD under the resolved escalator, or directly when we are already
# root. Never invokes an empty-string command (which would be a "" not found error).
priv() {
  if [[ -n "$BLIB_SU" ]]; then "$BLIB_SU" "$@"; else "$@"; fi
}

# ── preflight: the commands this script assumes ───────────────────────────────
# Fail HERE with the whole list, instead of dying halfway through provisioning with a
# cryptic error from whichever one happened to be reached first.
preflight_cmds() {
  local -a need=() missing=()
  if ((LINKS_ONLY)); then
    need=(git) # only the tpm clone in blib_link_core
  else
    need=(dnf rpm curl sed awk git)
  fi
  local c
  for c in "${need[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    echo "Missing required command(s): ${missing[*]}" >&2
    echo "On Fedora: ${BLIB_SU:+$BLIB_SU }dnf install -y ${missing[*]}" >&2
    exit 1
  fi
}
preflight_cmds

# ── keep the sudo timestamp warm for the whole run ────────────────────────────
# Every `sudo` below sits AFTER cargo/go builds that take minutes — comfortably longer than
# sudo's 5-minute timestamp — and several of those calls redirected stderr to /dev/null.
# sudo writes its PROMPT to stderr and reads the password from the TTY, so the run stopped
# dead at an INVISIBLE prompt: no output, no progress, indistinguishable from a hang. (The
# same failure mode the 1Password note further down records for `up` / `maint-run`.)
#
# Prime the timestamp ONCE up front, with the prompt visible, then refresh it in the
# background so no later call can ever block. Only meaningful for sudo: doas has no
# refreshable timestamp API, and as root there is nothing to prime.
SUDO_KEEPALIVE_PID=""
sudo_keepalive_start() {
  [[ "$BLIB_SU" == sudo ]] || return 0
  blib_say "priming sudo (asks once; the timestamp is kept warm for the whole run)"
  sudo -v || {
    echo "sudo authentication failed — cannot provision packages." >&2
    exit 1
  }
  # kill -0 "$$" stops the refresher when this script exits even if the trap is missed
  # (e.g. SIGKILL), so it can never outlive the bootstrap as an orphan.
  while true; do
    sudo -n true 2>/dev/null || true
    sleep 50
    kill -0 "$$" 2>/dev/null || exit 0
  done &
  SUDO_KEEPALIVE_PID=$!
  # shellcheck disable=SC2064  # expand the PID NOW: the var is reset below on stop
  trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null || true" EXIT
}
sudo_keepalive_stop() {
  [[ -n "$SUDO_KEEPALIVE_PID" ]] || return 0
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  SUDO_KEEPALIVE_PID=""
  trap - EXIT
}

provision() {
  # ── PATH: make the presence guards below tell the TRUTH ─────────────────────
  # Every `command -v <tool>` guard in this function decides whether to spend MINUTES
  # building from source. But cargo installs into ~/.cargo/bin and GOBIN is ~/.local/bin,
  # and NEITHER is on the PATH of the bash running this script — ~/.cargo/bin is added
  # only by os/fedora.zsh, i.e. only inside a Core *zsh*. Run ./bootstrap.sh from bash (a
  # fresh box, before `exec zsh`; or CI) and every guard reported "missing", so all six
  # Rust crates plus yazi rebuilt from source on EVERY run — minutes of work thrown away,
  # and under the old >/dev/null 2>&1 it looked like a hang. The atuin block below already
  # documents this exact trap ("Gate on the DESTINATION, never on `command -v atuin`");
  # this makes the same truth available to every other guard at once.
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.atuin/bin:$PATH"

  sudo_keepalive_start

  blib_say "dnf metadata refresh (makecache)"
  priv dnf -y makecache >/dev/null

  blib_say "RPM Fusion (free + nonfree)"
  local rel
  rel="$(rpm -E %fedora)"
  priv dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${rel}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${rel}.noarch.rpm" \
    >/dev/null || note_fail "RPM Fusion repos not added (already present, or the release RPM 404'd for F${rel})"

  blib_say "dnf packages (from install/packages.txt)"
  local -a pkgs=()
  # Distinguish MISSING from EMPTY: a missing file made the process substitution fail
  # silently and the operator was told the file "lists no packages" — which is a very
  # different problem from the one they actually had.
  if [[ ! -f "$DOTFILES/install/packages.txt" ]]; then
    echo "install/packages.txt is missing from $DOTFILES — is this a complete clone?" >&2
    exit 1
  fi
  mapfile -t pkgs < <(blib_read_pkgs "$DOTFILES/install/packages.txt")
  # dnf5 fails the WHOLE transaction if any single requested pkg is unavailable
  # (and is fussy about already-installed ones) — --skip-unavailable makes the
  # bulk install resilient: missing names are skipped instead of aborting.
  # Guard the empty case: an all-comment/blank packages.txt yields a zero-length
  # array, and `dnf install` with no args errors out — aborting the whole bootstrap
  # under `set -e`. Skip the install instead and carry on with the rest.
  if ((${#pkgs[@]})); then
    priv dnf -y install --skip-unavailable "${pkgs[@]}"
    blib_ok "dnf packages installed (${#pkgs[@]} requested)"
  else
    blib_warn "install/packages.txt lists no packages — skipping dnf install"
  fi

  # ── upstream installers: tools not reliably packaged on Fedora ──────────────
  # These three are a deliberate, documented trust decision (see SECURITY.md): we execute
  # code fetched at run time from starship.rs / setup.atuin.sh / mise.run. Two mitigations
  # apply to all of them; neither pretends to be full supply-chain verification.
  #
  #  1. DOWNLOAD THEN RUN, never `curl … | sh`. Piping straight into a shell executes each
  #     byte as it arrives, so a connection cut halfway through runs a TRUNCATED script —
  #     and a half-applied installer is exactly the state nobody tests. Landing the file
  #     first makes the fetch atomic: a failed/short download runs nothing at all.
  #  2. Install USER-LOCAL (~/.local/bin) where the installer allows it, so none of them
  #     needs root at all. starship defaults to /usr/local/bin and escalates on its own;
  #     -b puts it alongside everything else and drops that escalation entirely.
  #
  # run_installer <label> <url> [args...] — fetch to a temp file, sanity-check it, run it.
  run_installer() {
    local label="$1" url="$2"
    shift 2
    local tmp rc=0
    tmp="$(mktemp)" || {
      note_fail "$label: could not create a temp file — skipped"
      return 0
    }
    if ! curl -fsSL --max-time 60 "$url" -o "$tmp"; then
      rm -f "$tmp"
      note_fail "$label: download failed (offline?) — retry later: curl -fsSL $url | sh"
      return 0
    fi
    # A proxy/captive portal that answers with an HTML error page is still a 200; refuse to
    # execute anything that is not recognisably a shell script.
    if [[ ! -s "$tmp" ]] || ! head -c 200 "$tmp" | grep -qE '^#!|^#'; then
      rm -f "$tmp"
      note_fail "$label: downloaded installer does not look like a shell script — refusing to run it"
      return 0
    fi
    sh "$tmp" "$@" >/dev/null || rc=$?
    rm -f "$tmp"
    ((rc == 0)) || note_fail "$label: installer exited $rc — retry later: curl -fsSL $url | sh"
    return 0
  }

  if ! command -v starship >/dev/null; then
    blib_say "starship (official installer → ~/.local/bin)"
    mkdir -p "$HOME/.local/bin"
    run_installer starship https://starship.rs/install.sh -y -b "$HOME/.local/bin"
  fi
  if ! command -v atuin >/dev/null; then
    blib_say "atuin (official installer)"
    run_installer atuin https://setup.atuin.sh
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
      note_fail "could not link ~/.atuin/bin/atuin into ~/.local/bin — atuin stays invisible to Core's tool detection; add ~/.atuin/bin to PATH by hand"
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
      cargo install --force --locked yazi-build || note_fail "yazi: cargo build failed (log above) — retry later: cargo install --force --locked yazi-build"
  fi
  # mise — polyglot runtime manager (node/python/go/...). Portable; activated in
  # core/zsh/00-tools.zsh. Install the binary here; runtimes are fetched separately
  # with `mise install` (kept out of bootstrap so it stays fast/predictable).
  if ! command -v mise >/dev/null && [[ ! -x "$HOME/.local/bin/mise" ]]; then
    blib_say "mise (official installer)"
    run_installer mise https://mise.run
  fi
  # lazygit isn't in Fedora's base repos — pull it from the well-known COPR.
  if ! command -v lazygit >/dev/null; then
    blib_say "lazygit (COPR atim/lazygit)"
    # stderr stays VISIBLE on every privileged call from here down (only stdout is
    # silenced). Hiding it is what made a mid-run sudo prompt invisible; it also hid the
    # reason a COPR install failed.
    priv dnf -y install dnf5-plugins >/dev/null || true
    priv dnf -y copr enable atim/lazygit >/dev/null || true
    priv dnf -y install lazygit >/dev/null ||
      note_fail "lazygit: COPR install failed — retry later: ${BLIB_SU:+$BLIB_SU }dnf copr enable atim/lazygit && ${BLIB_SU:+$BLIB_SU }dnf install lazygit"
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
        note_fail "$2: go install failed — retry later: GOBIN=$gobin go install $1"
    elif command -v mise >/dev/null 2>&1; then
      # `mise exec go@latest` may first DOWNLOAD an entire Go toolchain, so this is the
      # slowest arm of the three and the one that most needs a visible elapsed time.
      GOBIN="$gobin" ux_spin "$2 (go install via mise)" mise exec go@latest -- go install "$1" ||
        note_fail "$2: go install failed — retry later: GOBIN=$gobin go install $1"
    else
      note_fail "$2: needs Go — install later with: GOBIN=$gobin go install $1"
    fi
    return 0
  }
  # Each of these is a from-source Rust build costing minutes. Run them under ux_spin (which
  # keeps a live elapsed-time readout and replays the log only on failure) instead of
  # >/dev/null 2>&1, so a slow build reads as progress rather than as a wedged script.
  if ! command -v dust >/dev/null && command -v cargo >/dev/null; then
    ux_spin "dust (cargo — crate du-dust; not in Fedora repos as of F45)" \
      cargo install --locked du-dust || note_fail "dust: cargo build failed (log above) — retry later: cargo install --locked du-dust"
  fi
  if ! command -v xh >/dev/null && command -v cargo >/dev/null; then
    ux_spin "xh (cargo; not in Fedora repos)" \
      cargo install --locked xh || note_fail "xh: cargo build failed (log above) — retry later: cargo install --locked xh"
  fi
  # sd (sed replacement) was retired from Fedora after F41 — rust-sd's `sd` subpackage
  # last built 1.0.0-4.fc41, so `dnf install sd` fails on current releases. Same story
  # as gron below, just Rust instead of Go.
  if ! command -v sd >/dev/null && command -v cargo >/dev/null; then
    ux_spin "sd (cargo — retired from Fedora repos after F41)" \
      cargo install --locked sd || note_fail "sd: cargo build failed (log above) — retry later: cargo install --locked sd"
  fi
  # viddy (watch replacement; Core aliases watch->viddy, HAVE_VIDDY-guarded) is a Rust
  # CLI, not in Fedora repos — build from source via cargo like dust/xh above.
  if ! command -v viddy >/dev/null && command -v cargo >/dev/null; then
    ux_spin "viddy (cargo — watch replacement; not in Fedora repos)" \
      cargo install --locked viddy || note_fail "viddy: cargo build failed (log above) — retry later: cargo install --locked viddy"
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
      cargo install --locked tealdeer || note_fail "tealdeer: cargo build failed (log above) — retry later: cargo install --locked tealdeer"
  fi
  if ! command -v procs >/dev/null && command -v cargo >/dev/null; then
    ux_spin "procs (cargo — orphaned; last Fedora build F44)" \
      cargo install --locked procs || note_fail "procs: cargo build failed (log above) — retry later: cargo install --locked procs"
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
  # Upstream publishes an official .rpm per release, which lands in /usr/bin. Be exact about
  # what that does and does not buy, because an earlier revision of this comment claimed the
  # opposite: installing from a release URL does NOT add a repo, so NOTHING upgrades carapace
  # afterwards. Not `dnf upgrade`, not `up`, and not a later bootstrap either — the
  # `command -v carapace` guard below skips the whole block once the binary exists. Upstream
  # ships no yum/dnf repo and Fedora does not package it, so there is no upgrade source to
  # point at; updating is a deliberate manual step, and `carapace --version` is how you'd know
  # you are behind:
  #   sudo dnf -y install "$(curl -fsSL https://api.github.com/repos/carapace-sh/carapace-bin/releases/latest \
  #     | grep -o '"browser_download_url": *"[^"]*linux_amd64\.rpm"' | cut -d'"' -f4 | head -1)"
  # That is the real cost of this route. It is still the right one: `go install` cannot work
  # at all (see above), so the choice is a manually-updated binary or no carapace.
  # Resolve the newest asset for THIS arch with grep/cut (no jq dependency) rather than pinning a version that would rot.
  if ! command -v carapace >/dev/null; then
    blib_say "carapace (upstream RPM — go install is impossible, see above)"
    local _cara_arch=""
    case "$(uname -m)" in
    x86_64) _cara_arch=amd64 ;;
    aarch64) _cara_arch=arm64 ;;
    esac
    if [[ -z "$_cara_arch" ]]; then
      note_fail "carapace: no upstream RPM for $(uname -m) — skipping; see github.com/carapace-sh/carapace-bin/releases"
    else
      local _cara_url=""
      _cara_url="$(curl -fsSL --max-time 30 \
        https://api.github.com/repos/carapace-sh/carapace-bin/releases/latest 2>/dev/null |
        grep -o "\"browser_download_url\": *\"[^\"]*linux_${_cara_arch}\.rpm\"" |
        cut -d'"' -f4 | head -1)" || true
      if [[ -n "$_cara_url" ]]; then
        priv dnf -y install "$_cara_url" >/dev/null ||
          note_fail "carapace: RPM install failed — retry later: ${BLIB_SU:+$BLIB_SU }dnf install $_cara_url"
      else
        note_fail "carapace: could not resolve the latest linux_${_cara_arch} RPM (offline? API rate-limited?) — see github.com/carapace-sh/carapace-bin/releases"
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
    #
    # FINGERPRINT-VERIFIED. `rpm --import <https-url>` trusts whatever the TLS connection
    # returns: it establishes that *something at that host* served a key, not that it is
    # 1Password's key, and from then on that key validates every package the repo ships.
    # Fetch it, check the fingerprint against the published value, and only then import.
    # If 1Password rotates the key this check FAILS CLOSED (no op, loud warning) rather
    # than silently trusting the replacement — which is the entire point.
    local _op_fpr_want="3FEF9748469ADBE15DA7CA80AC2D62742012EA22"
    local _op_key="" _op_fpr_got=""
    _op_key="$(mktemp)" || _op_key=""
    if [[ -n "$_op_key" ]] && curl -fsSL --max-time 30 \
      https://downloads.1password.com/linux/keys/1password.asc -o "$_op_key" 2>/dev/null; then
      # gpg prints the fingerprint without needing a keyring (--with-colons field 10 of the fpr row).
      if command -v gpg >/dev/null 2>&1; then
        _op_fpr_got="$(gpg --show-keys --with-colons "$_op_key" 2>/dev/null |
          awk -F: '$1=="fpr"{print $10; exit}')"
      else
        note_fail "op: gpg is not installed — cannot verify 1Password's key fingerprint; skipping the repo"
        _op_fpr_got="SKIP"
      fi
    else
      note_fail "op: could not download 1Password's signing key (offline?) — skipping the repo"
      _op_fpr_got="SKIP"
    fi
    if [[ "$_op_fpr_got" != "$_op_fpr_want" ]]; then
      [[ "$_op_fpr_got" == "SKIP" ]] ||
        note_fail "op: 1Password key fingerprint MISMATCH (got ${_op_fpr_got:-<none>}, want $_op_fpr_want) — refusing to import; verify at developer.1password.com/docs/cli/get-started"
      rm -f "$_op_key"
      _op_key=""
    fi
    if [[ -n "$_op_key" ]] && priv rpm --import "$_op_key" >/dev/null; then
      rm -f "$_op_key"
      priv sh -c 'cat >/etc/yum.repos.d/1password.repo' <<'REPO' || true
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
REPO
      priv dnf -y install 1password-cli >/dev/null ||
        note_fail "op: install failed; see developer.1password.com/docs/cli/get-started"
    else
      rm -f "$_op_key"
      note_fail "op: signing key not imported — skipping the repo (an unverifiable repo breaks every later dnf transaction); see developer.1password.com/docs/cli/get-started"
    fi
  fi
  # Warm the INVOKING USER's dnf keyring (no sudo — that is the entire point; see the
  # two-keyrings note above). Deliberately OUTSIDE the `command -v op` guard: the boxes that
  # need this most are the ones where op installed fine and only root ever got the key, so
  # gating it on a missing op would skip exactly the machines that are already broken.
  # Idempotent and cheap once the cache is warm, so it is safe on every run.
  if [[ -f /etc/yum.repos.d/1password.repo ]] && command -v dnf >/dev/null; then
    dnf -y makecache --repo=1password </dev/null >/dev/null 2>&1 ||
      note_fail "could not warm the user dnf cache for the 1Password repo — if \`up\` or \`maint-run\` ever appear to hang, run: dnf -y --refresh makecache --repo=1password"
  fi

  # ── WSL: install /etc/wsl.conf (systemd + default user + interop) ───────────
  if ((IS_WSL)); then
    blib_say "installing /etc/wsl.conf (systemd + default user)"
    local user
    user="$(id -un)"
    # BACK UP FIRST. This was the one destructive write in the whole system with no backup:
    # a hand-tuned /etc/wsl.conf (custom mount options, a different default user, networking
    # tweaks) was silently overwritten. Everything else — ~/.zshrc, every symlink target —
    # goes to <file>.pre-dotfiles.<epoch> via blib_link; match that convention here.
    local wsl_write=1
    if [[ -f /etc/wsl.conf ]] && ! cmp -s <(sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf") /etc/wsl.conf; then
      local wsl_bak
      wsl_bak="/etc/wsl.conf.pre-dotfiles.$(date +%s)"
      if priv cp -p /etc/wsl.conf "$wsl_bak"; then
        blib_ok "backed up the existing /etc/wsl.conf → $wsl_bak"
      else
        note_fail "could not back up /etc/wsl.conf — leaving it untouched rather than overwriting it"
        wsl_write=0
      fi
    fi
    if ((wsl_write)); then
      sed "s/__WSL_USER__/$user/" "$DOTFILES/wsl/wsl.conf" | priv tee /etc/wsl.conf >/dev/null
      blib_ok "wsl.conf written — run 'wsl.exe --shutdown' from Windows, then reopen, to apply"
    fi
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
  # Install the local pre-commit guard that refuses hand-edits to the vendored core/
  # subtree. .git/hooks is NOT version-controlled, so a fresh clone has none — and
  # sync-core.sh only (re)installs it in repos it fans out INTO, which is no help to
  # someone who just cloned this one. The lib's own docstring says a bootstrap should
  # call this; it never did. The PR-time core-integrity workflow is the durable backstop,
  # but this catches the edit before it is ever committed.
  #
  # Dry-run guarded at the CALL SITE on purpose: blib_install_core_guard writes
  # .git/hooks/pre-commit unconditionally (it predates BLIB_DRY and does not consult it),
  # so calling it under --dry-run would mutate the repo during a run that promises not to.
  if ((BLIB_DRY)); then
    blib_say "would install the core/ pre-commit guard in $DOTFILES"
  else
    blib_install_core_guard "$DOTFILES" || true
  fi
  blib_ok "symlinks wired$(blib_selected_note)"
}

# ── run ───────────────────────────────────────────────────────────────────────
if ((BLIB_DRY)); then
  blib_say "DRY RUN — nothing below is executed or written"
fi

if ((LINKS_ONLY)); then
  :
elif ((BLIB_DRY)); then
  # A dry run must preview provisioning too, not silently skip half the script. Print the
  # plan (what dnf would be asked for, which extras are missing) without touching anything.
  blib_say "would refresh dnf metadata and install RPM Fusion (free + nonfree)"
  if [[ -f "$DOTFILES/install/packages.txt" ]]; then
    _dry_pkgs=()
    mapfile -t _dry_pkgs < <(blib_read_pkgs "$DOTFILES/install/packages.txt")
    blib_say "would dnf install ${#_dry_pkgs[@]} packages: ${_dry_pkgs[*]}"
  else
    blib_warn "install/packages.txt is missing — a real run would abort here"
  fi
  for _t in starship atuin mise lazygit yazi dust xh sd viddy tldr procs doggo sesh gron carapace op; do
    command -v "$_t" >/dev/null 2>&1 || blib_say "would install: $_t"
  done
  unset _t
else
  provision
  sudo_keepalive_stop
fi

wire_links
blib_wire_summary

# ── closing report ────────────────────────────────────────────────────────────
# Say plainly what did NOT work. The old script printed "complete" and exited 0 no matter
# how many best-effort steps had failed, so a half-provisioned box looked identical to a
# good one.
if ((${#FAILED_STEPS[@]})); then
  printf '\n%s%s%s %s\n' "${UX_YEL:-}" "${UX_WARN:-!}" "${UX_RST:-}" \
    "${#FAILED_STEPS[@]} step(s) did not complete:"
  printf '    - %s\n' "${FAILED_STEPS[@]}"
  echo
  if ((STRICT)); then
    blib_warn "exiting non-zero (--strict)"
    exit 1
  fi
  blib_ok "Fedora bootstrap finished WITH the warnings above — open a new shell or: exec zsh"
else
  blib_ok "Fedora bootstrap complete — open a new shell or: exec zsh"
fi
