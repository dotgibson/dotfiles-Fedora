#!/usr/bin/env bash
# test/check-packages.sh
# ──────────────────────────────────────────────────────────────────────────────
# Does every package name in install/packages.txt still RESOLVE on this Fedora?
#
# bootstrap.sh installs with `dnf install --skip-unavailable`: a rename or drop upstream
# fails SILENTLY, by design, so someone's fresh install surfaces it months later.
# `install/packages.txt` also carries hand-maintained availability claims ("tealdeer is
# orphaned, last built F44", "wget is a virtual capability provided by wget2-wget"); the
# only auditor was the weekly /os-package-availability Claude routine, which is inert
# without CLAUDE_CODE_OAUTH_TOKEN. This is the deterministic half.
#
# TWO PROBES, and the SECOND is the whole correctness of the gate:
#
#   1. `dnf repoquery <name>` — matches package NAMES only.
#   2. `dnf repoquery --whatprovides <name>` — resolves VIRTUAL capabilities.
#
# `bootstrap.sh` installs with `dnf install`, which resolves `Provides:`, so the probe
# must ask the same question. Fedora 41 retired `wget` in favour of `wget2` with
# `wget2-wget` carrying `Provides: wget` — so `dnf install wget` works while a bare
# `dnf repoquery wget` fails. Name-only probing red-flags that working package on the
# first real run, which is the false-alarm failure this repo cannot afford. See the same
# reasoning in .github/workflows/bootstrap.yml (`packages_check: dnf -q provides`).
#
# RUN IT WHERE THE ANSWER IS TRUE. Availability is a property of the dnf repos on this
# box, so F43 and rawhide disagree by design. The authoritative run is the workflow
# (.github/workflows/packages.yml) in a pinned Fedora container per release; locally this
# is a smoke test against whatever release you happen to track, which is why the release
# in view is printed. On a non-Fedora host this skips cleanly (exit 0) rather than red —
# a Debian dev box cannot answer the question and should not pretend to.
#
# Exit codes:
#   0  every name resolved (or a clean skip: no dnf here, or BLOCKING=false on a red)
#   1  usage/environment failure
#   2  one or more names failed — the drift signal (unless BLOCKING=false demotes it)
#
# Env:
#   BLOCKING   default `true`. Set `false` to demote missing-package failures to warnings
#              (used by packages.yml for rawhide + pre-GA releases where a drop upstream
#              must not red the repo before it affects a supported release).
#   RELEASE    informational label to print, if set (packages.yml passes the matrix release).
#
# Usage:
#   test/check-packages.sh                        # install/packages.txt
#   test/check-packages.sh install/packages.txt
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# `set -e` is deliberately off (the exit code IS the result), so guard the cd — reading
# the wrong manifest from the wrong directory would be a silent misreport.
cd -- "$REPO_ROOT" || exit 1

say() { printf ':: %s\n' "$*"; }
ok()  { printf '\033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }

command -v dnf >/dev/null 2>&1 || {
  say "no dnf on this host — skipping (run .github/workflows/packages.yml for the real answer)"
  exit 0
}

manifest="${1:-install/packages.txt}"
[[ -f "$manifest" ]] || { bad "manifest not found: $manifest"; exit 1; }

# Same parse as bootstrap.sh's blib_read_pkgs: strip #-comments and all whitespace
# (package names contain none), drop blanks. Kept in sync with packages.yml, deliberately.
mapfile -t pkgs < <(sed 's/#.*//' "$manifest" | tr -d '[:blank:]' | grep -v '^$')
((${#pkgs[@]})) || { bad "$manifest parsed to zero package names"; exit 1; }

# Name the release so a local run's answer is interpretable. RELEASE from env wins so the
# matrix workflow's label is what appears in the log; fall back to /etc/os-release.
release="${RELEASE:-$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | head -1 | tr -d "\"'")}"
say "checking ${#pkgs[@]} package names on Fedora ${release:-unknown}"

# GitHub Actions annotation, harmless outside CI.
echo "::notice::checking ${#pkgs[@]} package names on Fedora ${release:-unknown}"

missing=()
for p in "${pkgs[@]}"; do
  if [ -n "$(dnf repoquery --qf '%{name}' "$p" 2>/dev/null)" ]; then
    continue
  fi
  if [ -n "$(dnf repoquery --whatprovides "$p" --qf '%{name}' 2>/dev/null)" ]; then
    echo "  $p -> provided virtually"
    continue
  fi
  missing+=("$p")
done

if ((${#missing[@]} == 0)); then
  ok "all ${#pkgs[@]} names resolve on Fedora ${release:-unknown}"
  exit 0
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### Unresolvable on Fedora %s\n\n' "${release:-unknown}"
    # shellcheck disable=SC2016  # backticks in a quoted format string are literal markdown, not command substitutions
    for m in "${missing[@]}"; do printf -- '- `%s`\n' "$m"; done
    cat <<'MD'

Each needs either a rename in `install/packages.txt` or a presence-guarded
cargo/go fallback in `bootstrap.sh` (the pattern already used for
`sd`, `gron`, `dust`, `xh`, `viddy`, `tealdeer` and `procs`).
MD
  } >> "$GITHUB_STEP_SUMMARY"
fi

bad "${#missing[@]} package name(s) did NOT resolve on Fedora ${release:-unknown}:"
printf '    %s\n' "${missing[@]}" >&2

if [ "${BLOCKING:-true}" != "true" ]; then
  echo "::warning::${#missing[@]} package(s) do not resolve on Fedora ${release:-unknown}: ${missing[*]} — add a fallback before this reaches a stable release"
  say "BLOCKING=false — advisory only, not failing"
  exit 0
fi

echo "::error::${#missing[@]} package(s) do not resolve on Fedora ${release:-unknown}: ${missing[*]}"
cat >&2 <<'EOF'

A non-resolving name is one of:
  • a rename       — find the new name and update install/packages.txt
  • a drop         — remove it, or move it to bootstrap.sh as a presence-guarded fallback
  • a typo         — fix it
  • release drift  — real on one release, absent on another; guard it per-release
EOF
exit 2
