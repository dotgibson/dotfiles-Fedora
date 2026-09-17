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
# a Debian dev box cannot answer the question and should not pretend to, and neither can
# a RHEL/CentOS/Rocky box whose dnf resolves against a different archive (see the
# /etc/os-release ID/ID_LIKE guard below).
#
# VERSION FLOORS ARE CHECKED TOO, per release. A name resolving is not the whole story for
# a floored entry: dnf resolves `neovim` and `tree-sitter-cli` on every supported release
# and clears their `# min:` floors on only some. Those are two different facts and this
# gate reports both (#192).
#
# TWO TIERS, AND THEY POINT OPPOSITE WAYS. That is not an oversight:
#   • a NAME that stops resolving on rawhide is EARLY WARNING (BLOCKING=false, advisory):
#     the package is on its way out, and the fix — a cargo/go fallback — is needed before
#     the next Fedora ships, not today. On a stable release it is a real break, and blocks.
#   • a FLOOR unmet on rawhide is a DEAD END (exit 3): rawhide is the newest thing Fedora
#     has, so below the floor HERE means the requirement is unsatisfiable on every Fedora
#     there will ever be — Core's pin outran the ecosystem, or the package regressed.
#   • a FLOOR unmet on a NUMBERED release is a documented FACT (report only): F43 ships
#     tree-sitter-cli 0.25.10 and neovim 0.11.6, and dnf has no lever there. bootstrap.sh
#     handles that box. Red CI would be permanent and would therefore mean nothing.
# The floor tier is keyed on RELEASE and NOT on BLOCKING, because one knob cannot spell two
# opposite policies. Do not add a matrix input for it either — see packages.yml.
#
# Exit codes:
#   0  every name resolved and every declared floor is met (or a clean skip: no dnf here,
#      or BLOCKING=false on a red)
#   1  usage/environment failure, or a floor that disagrees with bootstrap.sh
#   2  one or more names failed — the drift signal (unless BLOCKING=false demotes it)
#   3  a declared `# min:` floor is unmet on rawhide, or cannot be judged at all
#
# Env:
#   BLOCKING   default `true`. Set `false` to demote missing-package failures to warnings
#              (used by packages.yml for rawhide + pre-GA releases where a drop upstream
#              must not red the repo before it affects a supported release).
#   RELEASE    the release label to print AND the floor tier key (packages.yml passes the
#              matrix release). RELEASE=rawhide makes an unmet floor a FAILURE (exit 3);
#              any other value — 43/44/45, or unset — makes it a REPORT.
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

# ── the manifest, and the facts that need no package manager ──────────────────
# Read the list BEFORE the dnf / os-release guards below, deliberately. Everything down to
# the floor-agreement assertion is a pure file-vs-file check — no repos, no network, no
# Fedora — so it is true on a plain ubuntu runner. That is what makes
# .github/workflows/test.yml (`make suite`, NO path filter, every PR) the gate that catches
# a floor deleted from bootstrap.sh: packages.yml is path-filtered to install/packages.txt
# and would never run on such a PR. The cost is that a malformed manifest now fails on a
# Debian box too, which is an improvement — malformed is malformed everywhere.
manifest="${1:-install/packages.txt}"
[[ -f "$manifest" ]] || { bad "manifest not found: $manifest"; exit 1; }

# Same parse as bootstrap.sh's blib_read_pkgs: strip #-comments and all whitespace
# (package names contain none), drop blanks. Kept in sync with packages.yml, deliberately.
mapfile -t pkgs < <(sed 's/#.*//' "$manifest" | tr -d '[:blank:]' | grep -v '^$')
((${#pkgs[@]})) || { bad "$manifest parsed to zero package names"; exit 1; }

# A SECOND pass over the same file, reading the annotation the parse above throws away:
#
#   <name>  # min:X.Y.Z   — a version floor. The name RESOLVING is not the whole story;
#                           the candidate dnf would install has to clear the floor too.
#
# Only a line that carries a package NAME is inspected, so a `min:` inside one of this
# manifest's prose comment blocks cannot invent a floor out of nothing.
declare -A PKG_MIN=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  name="${line%%#*}"; name="${name//[[:space:]]/}"
  [[ -n "$name" ]] || continue
  cmt="${line#*#}"
  [[ "$cmt" == "$line" ]] && continue # no inline comment on this line
  [[ "$cmt" =~ min:([0-9][0-9.]*) ]] && PKG_MIN["$name"]="${BASH_REMATCH[1]}"
done <"$manifest"

# _ver_lt <a> <b> — true when version a sorts BELOW version b.
#
# RPM's own comparator first, via rpm.vercmp: it is what libsolv uses to decide what
# `dnf install` actually picks, so this gate and dnf cannot disagree about the same two
# strings — and it is the only form that reads Fedora's pre-release tilde correctly.
# Measured on F44: rpm.vercmp("0.12.0~rc1","0.12.0") = -1, while a field-wise compare splits
# on ".", finds "0~rc1" unparsable, coerces it to 0 and calls the two EQUAL — turning a
# genuine below-floor rawhide candidate into a silent pass, in the one lane where an unmet
# floor is supposed to FAIL.
#
# The field-wise fallback is not dead code: this function is defined ABOVE the dnf guard so
# the assertion below can live there, and `make suite` runs this script on hosts with no rpm
# at all. It mirrors bootstrap.sh's _dotfiles_ver_lt — field-wise so 0.26.10 does not rank
# below 0.26.9, non-numeric fields read as 0.
_ver_lt() { # <a> <b>
  local out
  case "$1$2" in
  # Never interpolate anything an RPM version cannot legally contain into a lua expression.
  *[!0-9A-Za-z.~^+_:-]*) : ;;
  *)
    if out="$(rpm --eval "%{lua:print(rpm.vercmp(\"$1\",\"$2\"))}" 2>/dev/null)"; then
      case "$out" in
      -1) return 0 ;;
      0 | 1) return 1 ;;
      esac
    fi
    ;;
  esac
  local i x y
  local -a A B
  local IFS=.
  # shellcheck disable=SC2206  # deliberate word-splitting on IFS=. — that IS the parse
  A=(${1%%-*})
  # shellcheck disable=SC2206
  B=(${2%%-*})
  unset IFS
  for ((i = 0; i < 4; i++)); do
    x="${A[i]:-0}"
    y="${B[i]:-0}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0
    [[ "$y" =~ ^[0-9]+$ ]] || y=0
    ((10#$x < 10#$y)) && return 0
    ((10#$x > 10#$y)) && return 1
  done
  return 1 # equal is NOT below a >= floor
}

# ── the floors must agree with bootstrap.sh ───────────────────────────────────
# A `# min:` here restates a constant whose authoritative value lives in bootstrap.sh, so
# the copy can drift the moment someone bumps one and not the other — and a stale floor is
# worse than no floor, because it reads as verified. Assert the two agree; this is the
# piece that keeps the rest from rotting.
[[ -f bootstrap.sh ]] || { bad "bootstrap.sh is not beside this test — the floors cannot be anchored"; exit 1; }
declare -A FLOOR_SOURCE=([tree-sitter-cli]=TREESITTER_FLOOR [neovim]=NEOVIM_FLOOR)
for p in "${!FLOOR_SOURCE[@]}"; do
  var="${FLOOR_SOURCE[$p]}"
  # FLUSH-LEFT and DOUBLE-QUOTED in bootstrap.sh is a contract, not a style: indent it,
  # single-quote it or move it into a function and this reads empty — at which point the
  # gate declares itself unanchored and fails loud rather than passing on nothing.
  want="$(sed -n "s/^${var}=\"\([^\"]*\)\".*/\1/p" bootstrap.sh | head -1)"
  have="${PKG_MIN[$p]:-}"
  [[ -n "$want" ]] || { bad "bootstrap.sh no longer defines $var — this gate's floor for $p is unanchored"; exit 1; }
  [[ -n "$have" ]] || { bad "install/packages.txt dropped the '# min:' on $p, but bootstrap.sh still sets $var=$want"; exit 1; }
  [[ "$have" == "$want" ]] || {
    bad "floor disagreement on $p: install/packages.txt says min:$have, bootstrap.sh says $var=$want"
    bad "One of the two was bumped without the other. They must match."
    exit 1
  }
done
say "floors anchored to bootstrap.sh: tree-sitter-cli>=${PKG_MIN[tree-sitter-cli]} neovim>=${PKG_MIN[neovim]}"

command -v dnf >/dev/null 2>&1 || {
  say "no dnf on this host — skipping (run .github/workflows/packages.yml for the real answer)"
  exit 0
}

# Presence of `dnf` is necessary but not sufficient: RHEL, CentOS Stream, Rocky, Alma and
# Amazon Linux all ship dnf against DIFFERENT repos. Running these probes there would
# label the result "Fedora <VERSION_ID>" and flag names that only Fedora carries (RPM
# Fusion, COPR-only tools) as broken — a real Fedora question answered against the wrong
# archive. Skip unless ID or ID_LIKE names fedora.
if [ -r /etc/os-release ]; then
  # shellcheck source=/etc/os-release
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
  *" fedora "*) : ;;
  *)
    say "dnf present but this is ${ID:-unknown} (not Fedora / fedora-derived) — skipping"
    exit 0
    ;;
  esac
fi

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

# ── declared version floors ───────────────────────────────────────────────────
# Resolution is not the whole story for a floored name: dnf resolves `neovim` and
# `tree-sitter-cli` on every supported release and clears their floors on only some. This
# is the check that separates those two facts, per release — the entire reason packages.yml
# is a matrix instead of one run on the newest image.
#
# THE PROBE, and why it is not `head -1`. `dnf repoquery` answers once per REPO and once per
# ARCH, not once. Measured on F44: `repoquery neovim` prints 0.11.6 (fedora) AND 0.12.5
# (fedora-updates) — and the FIRST line is the one below the floor, so a naive head -1 would
# report a false failure for the very package dnf would install correctly. That is not a
# hypothetical: F44 crossed 0.11 -> 0.12 inside the release, and F44 is a BLOCKING lane.
# `--latest-limit 1` keeps the newest per name.arch, which collapses the repo axis; the fold
# below collapses whatever arches remain (a multilib name still prints i686 AND x86_64).
# What we compare is then what `dnf install` would actually pick.
#
# NOT `--whatprovides "<name> >= <floor>"`, tempting as the native libsolv compare is: it
# prints nothing both when the floor is unmet AND when the name does not exist, so it cannot
# tell a below-floor release from a dropped package, and it cannot report the version an
# operator needs in order to act. _ver_lt above already IS libsolv's comparator.
#
# A floored name that resolves only VIRTUALLY has no %{version} of its own. `wget` is the
# standing example: `repoquery wget` is empty while `--whatprovides wget` returns
# wget1-wget 1.25.0 and wget2-wget 2.2.1 — two providers on two unrelated version scales,
# with nothing saying which dnf would pick. A floor there is unanswerable; say so, and put
# the floor on the providing package's real name instead.
_pkg_candidate() { # <name> → the newest version dnf would install, or nothing
  local v best=""
  while read -r v; do
    [[ -n "$v" ]] || continue
    if [[ -z "$best" ]] || _ver_lt "$best" "$v"; then best="$v"; fi
  done < <(dnf -q repoquery --available --latest-limit 1 --qf '%{version}\n' -- "$1" 2>/dev/null)
  [[ -n "$best" ]] || return 1
  printf '%s' "$best"
}

floor_met=()
floor_below=()
floor_fail=()
for p in "${!PKG_MIN[@]}"; do
  floor="${PKG_MIN[$p]}"
  if ! cand="$(_pkg_candidate "$p")"; then
    # An absent name is the resolve pass's finding, not this one's — never report one
    # absence twice. What is left is a name that resolves ONLY virtually, which is a
    # manifest-authoring bug rather than release drift: it is wrong on every release.
    if ((${#missing[@]})) && [[ " ${missing[*]} " == *" $p "* ]]; then continue; fi
    floor_fail+=("$p — declares min:$floor but has no %{version} of its own (it resolves only as a virtual capability); a floor cannot be judged there — move it onto the providing package's name")
    continue
  fi
  if _ver_lt "$cand" "$floor"; then
    if [ "${RELEASE:-}" = "rawhide" ]; then
      floor_fail+=("$p $cand is BELOW its min:$floor on rawhide — unsatisfiable fleet-wide")
    else
      floor_below+=("$p $cand < min:$floor")
    fi
  else
    floor_met+=("$p $cand >= min:$floor")
  fi
done

if ((${#floor_met[@]})); then
  echo
  say "floors met on Fedora ${release:-unknown}:"
  printf '    %s\n' "${floor_met[@]}"
fi
if ((${#floor_below[@]})); then
  echo
  say "below floor on Fedora ${release:-unknown} — expected on an older release, NOT a failure here:"
  printf '    %s\n' "${floor_below[@]}"
  say "bootstrap.sh covers such a box: it cargo-builds tree-sitter-cli (VERSION-guarded, so"
  say "dnf's older RPM does not short-circuit it) and warns about neovim (NEOVIM_FLOOR)."
  say "dnf has no lever on a numbered release, so red CI here would be permanent."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    # shellcheck disable=SC2016  # backticks are literal markdown here, not substitutions
    {
      printf '### Below their `# min:` floor on Fedora %s\n\n' "${release:-unknown}"
      for m in "${floor_below[@]}"; do printf -- '- `%s`\n' "$m"; done
      printf '\nExpected on an older release; bootstrap.sh handles this box. Not a failure.\n'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi

# ── the resolve pass's report ─────────────────────────────────────────────────
if ((${#missing[@]} == 0)); then
  ok "all ${#pkgs[@]} names resolve on Fedora ${release:-unknown}"
else
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
fi

# ── verdict ───────────────────────────────────────────────────────────────────
# Name resolution is judged FIRST: a name that does not resolve is the more fundamental
# break, and its BLOCKING tier is the one packages.yml has keyed on since it existed. In
# practice the two tiers cannot fight over the exit code — rawhide, the only lane where a
# floor fails, is also the lane where BLOCKING is false — but the order is written down so
# that stays deliberate rather than accidental.
if ((${#missing[@]})); then
  if [ "${BLOCKING:-true}" != "true" ]; then
    echo "::warning::${#missing[@]} package(s) do not resolve on Fedora ${release:-unknown}: ${missing[*]} — add a fallback before this reaches a stable release"
    say "BLOCKING=false — advisory only, not failing"
  else
    echo "::error::${#missing[@]} package(s) do not resolve on Fedora ${release:-unknown}: ${missing[*]}"
    cat >&2 <<'EOF'

A non-resolving name is one of:
  • a rename       — find the new name and update install/packages.txt
  • a drop         — remove it, or move it to bootstrap.sh as a presence-guarded fallback
  • a typo         — fix it
  • release drift  — real on one release, absent on another; guard it per-release
EOF
    exit 2
  fi
fi

if ((${#floor_fail[@]})); then
  echo
  bad "${#floor_fail[@]} floor failure(s) on Fedora ${release:-unknown}:"
  printf '    %s\n' "${floor_fail[@]}" >&2
  echo "::error::floor failure on Fedora ${release:-unknown}: ${floor_fail[*]}"
  bad "rawhide is the newest Fedora there is — below a floor HERE means the requirement is"
  bad "unsatisfiable on every Fedora, not just this one. Either Core's pin outran the"
  bad "ecosystem (lower TREESITTER_FLOOR/NEOVIM_FLOOR in bootstrap.sh and the matching"
  bad "'# min:' in install/packages.txt, together) or the package regressed upstream."
  exit 3
fi

exit 0
