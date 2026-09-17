#!/usr/bin/env bash
# test/check-flavors.sh
# ──────────────────────────────────────────────────────────────────────────────
# Do the two capability declarations still differ in EXACTLY the ways they are ALLOWED to
# differ — and does the machinery that chooses between them still exist?
#
# WHY. One repo serves two editions of Fedora that install with different verbs. The dnf
# edition (Workstation, Server, WSL) installs LIVE; the ATOMIC edition (Silverblue,
# Kinoite, any bootc host) LAYERS with rpm-ostree into the next deployment, and nothing is
# live until a reboot — `dnf install` there resolves the whole transaction and then refuses
# (measured on fedora-bootc:42: dotgibson/dotfiles-core NON-MUTABLE-HOST-PROPOSAL.md §4.3,
# #186). So `os/fedora.capabilities` and `os/fedora.atomic.capabilities` are two
# declarations maintained BY HAND, mostly identical by design, and an edit to one and not
# the other is silent drift — the single most likely way this variant breaks.
#
# core/scripts/check-capabilities.sh validates each file against Core's SCHEMA (`make
# capabilities`), one at a time. It cannot see this, because the invariant is not about
# either file: it is about the DELTA between them. dotfiles-openSUSE's check-flavors.sh
# (Tumbleweed vs Leap) is the model; the delta here is wider, because the atomic edition
# changes more than one verb.
#
# THE CONTRACT, as the two files themselves state it:
#
#   ATOMIC_ONLY — keys the atomic file declares and the dnf file must not:
#     PROVISIONER=atomic       the token Core's `up`, nudge and maint runner branch on
#     PKG_APPLY                the verb that makes a STAGED change live (a reboot)
#     PKG_APPLY_PENDING(_EXIT) "is a change staged?" — an exit status, not a count
#   DNF_ONLY — keys the dnf file declares and the atomic file must not:
#     PKG_COUNT_PENDING        "is there something newer?" is root-only on an atomic host
#     PKG_ASSUME_YES           nothing prompts on rpm-ostree
#     PKG_UPGRADE_PARTIAL      the image updates as a whole
#     PKG_PENDING_MATCH        describes PKG_COUNT_PENDING's output, which is absent
#   DIVERGENT — declared in both, different by design:
#     PKG_REFRESH PKG_UPGRADE PKG_INSTALL PKG_REMOVE PKG_OWNS — dnf on one, rpm-ostree
#     (rpm for OWNS) on the other
#   DIVERGENT_NONVERB — declared in both, different by design, and NOT a command:
#     PKG_UNLISTED_TOOLS — the binaries each edition's verbs run that packages.txt does
#     not name. It differs because the VERBS differ: the dnf edition runs one binary,
#     the atomic edition four. Kept out of DIVERGENT because that list's check asserts
#     `dnf` on one side and never on the other, and this key's atomic value legitimately
#     CONTAINS dnf. Core's own validator already holds each file's value to its own
#     verbs from both ends (an unrun name FAILS, and so does a name packages.txt
#     installs), so this test only has to stop demanding the two be identical.
#   everything else — identical, key for key and value for value. That includes
#     MAINT_UNATTENDED_UPGRADE: a staged upgrade is inert until the operator reboots, so
#     unattended staging is SAFER than a mutable upgrade, and the atomic file keeps it.
#
# Plus the things that make the split reachable at all: bootstrap.sh's /run/ostree-booted
# probe, its BOOTSTRAP_PROVISIONER seam (what lets CI's container reach the staging path),
# its relink of the atomic file, and the closing line the CI leg asserts. And the
# user-facing `dnfi` alias in os/fedora.zsh, which must know the edition too.
#
# Needs no dnf, no rpm-ostree and no Fedora: it reads the repo, so it is the half of the
# suite that is true everywhere and runs in CI on a plain runner.
#
# Exit codes:
#   0  the two declarations differ in exactly the declared ways
#   1  usage/environment failure (a file this test needs is missing)
#   2  drift — the delta is not what it is declared to be
#
# Usage:
#   test/check-flavors.sh
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# `set -e` is deliberately off (the exit code IS the result), so guard the cd
# explicitly — continuing in the wrong directory would read the wrong declarations.
cd -- "$REPO_ROOT" || exit 1

if [[ -r core/lib/ux.sh ]]; then
  # shellcheck source=core/lib/ux.sh
  source core/lib/ux.sh
fi
say() { printf '%s::%s %s\n' "${UX_BLU:-}" "${UX_RST:-}" "$*"; }
ok() { printf '%s%s%s %s\n' "${UX_GRN:-}" "${UX_OK:-+}" "${UX_RST:-}" "$*"; }
bad() { printf '%s%s%s %s\n' "${UX_YEL:-}" "${UX_WARN:-!}" "${UX_RST:-}" "$*" >&2; }

DNF=os/fedora.capabilities
ATOMIC=os/fedora.atomic.capabilities

# The keys the two files are DECLARED to disagree on. Anything else that differs is the
# finding. Adding a key to any of these lists is a deliberate widening of the contract —
# it should arrive with the comment in both declarations that explains why.
ATOMIC_ONLY="PROVISIONER PKG_APPLY PKG_APPLY_PENDING PKG_APPLY_PENDING_EXIT"
DNF_ONLY="PKG_COUNT_PENDING PKG_ASSUME_YES PKG_UPGRADE_PARTIAL PKG_PENDING_MATCH"
DIVERGENT="PKG_REFRESH PKG_UPGRADE PKG_INSTALL PKG_REMOVE PKG_OWNS"
# Declared in both and different by design, but NOT a command — see the contract above.
DIVERGENT_NONVERB="PKG_UNLISTED_TOOLS"

fails=()
note_fail() { fails+=("$1"); }

for f in "$DNF" "$ATOMIC"; do
  [[ -r "$f" ]] || {
    bad "declaration not readable: $f"
    exit 1
  }
done

# cap_dump <file> → `KEY<TAB>value` per declared key, in file order.
#
# Mirrors core/scripts/check-capabilities.sh's reader, including the part that is easy to
# get wrong: a `#` INSIDE A VALUE IS NOT A COMMENT (both files say so in their headers),
# so only a line whose first non-blank character is `#` is dropped. The indent is
# stripped BEFORE the `#` test, so an indented comment is a comment and an indented
# assignment is still an assignment.
cap_dump() {
  local line k v
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in '' | '#'*) continue ;; esac
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    printf '%s\t%s\n' "$k" "$v"
  done <"$1"
}

DNF_DUMP="$(cap_dump "$DNF")"
ATOMIC_DUMP="$(cap_dump "$ATOMIC")"

# cap_get <dump> <key> — echo the declared value, status 1 when the key is absent.
#
# NO PIPE, deliberately, and for the reason Core's own cap_value documents: under
# `pipefail` a reader that exits on its match gives the writer EPIPE, and the pipeline
# reports failure on the SUCCESS path. A read loop over a herestring has neither the
# hazard nor a fork.
cap_get() {
  local _k _v
  while IFS=$'\t' read -r _k _v; do
    if [[ "$_k" == "$2" ]]; then
      printf '%s' "$_v"
      return 0
    fi
  done <<<"$1"
  return 1
}

cap_keys() { printf '%s' "$1" | cut -f1; }

# in_list <word> <list> — is <word> one of the space-separated <list>?
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# ── 1. PROVISIONER: the token every consumer branches on ──────────────────────
# Core's `up`, the shell-start nudge, the maint runner and core-doctor all branch on this
# one key (dotgibson/dotfiles-core#1049). The dnf file must NOT declare it: absent means
# mutable, and the nine mutable repos' behaviour is byte-identical only because they never
# do. The atomic file must say exactly `atomic` — `transactional` is MicroOS's word.
say "PROVISIONER — declared on the atomic file only, and as 'atomic'"
if dnf_prov="$(cap_get "$DNF_DUMP" PROVISIONER)"; then
  note_fail "$DNF declares PROVISIONER=$dnf_prov — the dnf edition is the MUTABLE default and must leave the key absent, or Core's consumers stop treating it as one"
else
  printf '  %-8s %s\n' "dnf" "absent (correct — mutable is the default)"
fi
atomic_prov="$(cap_get "$ATOMIC_DUMP" PROVISIONER)" || atomic_prov=""
if [[ "$atomic_prov" != atomic ]]; then
  note_fail "$ATOMIC: PROVISIONER is '${atomic_prov:-absent}', expected 'atomic' — without it \`up\` runs the mutable path over a host whose install verb stages, and the nudge counts instead of saying 'update staged'"
else
  printf '  %-8s %s\n' "atomic" "$atomic_prov"
fi

# ── 2. the verbs: dnf on one side, rpm-ostree on the other ───────────────────
# The whole reason there are two files. A dnf verb in the atomic file resolves and then
# refuses on a read-only root; an rpm-ostree verb in the dnf file is a command the dnf
# edition does not have.
say "the divergent verbs — dnf in $DNF, rpm-ostree in $ATOMIC"
for k in $DIVERGENT; do
  a="$(cap_get "$DNF_DUMP" "$k")" || a=""
  b="$(cap_get "$ATOMIC_DUMP" "$k")" || b=""
  if [[ -z "$a" ]]; then
    note_fail "$DNF declares no $k (Core requires it)"
  elif [[ ! "$a" =~ (^|[[:space:]])dnf([[:space:]]|$) ]]; then
    note_fail "$DNF: $k is '$a' — the dnf edition's verbs run dnf"
  fi
  if [[ -z "$b" ]]; then
    note_fail "$ATOMIC declares no $k (Core requires it)"
  elif [[ "$b" =~ (^|[[:space:]])dnf([[:space:]]|$) ]]; then
    note_fail "$ATOMIC: $k is '$b' — a dnf transaction on an atomic host resolves and then refuses ('configured to be read-only'); the verb there is rpm-ostree"
  elif [[ "$k" == PKG_OWNS ]]; then
    # OWNS is a query, not a transaction: `rpm -qf` reads the booted deployment's db.
    [[ "$b" =~ (^|[[:space:]])rpm(-ostree)?([[:space:]]|$) ]] ||
      note_fail "$ATOMIC: $k is '$b' — expected rpm (the rpmdb is readable on an atomic host; only transactions are refused)"
  elif [[ ! "$b" =~ (^|[[:space:]])rpm-ostree([[:space:]]|$) ]]; then
    note_fail "$ATOMIC: $k is '$b' — the atomic edition's verbs run rpm-ostree"
  fi
  [[ "$a" == "$b" ]] && note_fail "$k is identical in both files ('$a') — it is a declared divergence and must differ"
  printf '  %-20s %-32s %s\n' "$k" "$a" "$b"
done
# Two of them carry a load-bearing flag, measured on a booted guest.
atomic_install="$(cap_get "$ATOMIC_DUMP" PKG_INSTALL)" || atomic_install=""
if [[ -n "$atomic_install" && ! "$atomic_install" =~ (^|[[:space:]])--idempotent([[:space:]]|$) ]]; then
  note_fail "$ATOMIC: PKG_INSTALL is '$atomic_install' — without --idempotent a re-run over already-layered packages is an error, not a no-op"
fi
atomic_upgrade="$(cap_get "$ATOMIC_DUMP" PKG_UPGRADE)" || atomic_upgrade=""
if [[ -n "$atomic_upgrade" && ! "$atomic_upgrade" =~ rpm-ostree[[:space:]]+upgrade([[:space:]]|$) ]]; then
  note_fail "$ATOMIC: PKG_UPGRADE is '$atomic_upgrade' — expected 'rpm-ostree upgrade'; \`bootc upgrade\` refuses a host with a layered package (NON-MUTABLE-HOST-PROPOSAL.md §4.5), and this bootstrap layers"
fi

# ── 3. the staged pair, and the keys each edition must NOT have ───────────────
# On an atomic host "is a change staged?" is answered by an exit status
# (`rpm-ostree status --pending-exit-77` → 77), and "is there something newer?" has no
# unprivileged verb at all — so the atomic file declares PKG_APPLY_PENDING(+_EXIT) and
# PKG_APPLY, and drops PKG_COUNT_PENDING with the keys that describe its output.
say "the staged pair — PKG_APPLY_PENDING / _EXIT / PKG_APPLY on the atomic file"
pending="$(cap_get "$ATOMIC_DUMP" PKG_APPLY_PENDING)" || pending=""
pending_exit="$(cap_get "$ATOMIC_DUMP" PKG_APPLY_PENDING_EXIT)" || pending_exit=""
apply="$(cap_get "$ATOMIC_DUMP" PKG_APPLY)" || apply=""
if [[ -z "$pending" || -z "$pending_exit" || -z "$apply" ]]; then
  note_fail "$ATOMIC must declare all three of PKG_APPLY_PENDING, PKG_APPLY_PENDING_EXIT and PKG_APPLY — the nudge's 'update staged — reboot to apply' line reads the pair, and \`up\` prints PKG_APPLY after a staged upgrade"
else
  # The verb names its own exit status; the declared one must be that number, or the
  # probe answers "idle" over a staged deployment.
  if [[ "$pending" =~ --pending-exit-([0-9]+) ]] && [[ "${BASH_REMATCH[1]}" != "$pending_exit" ]]; then
    note_fail "$ATOMIC: PKG_APPLY_PENDING asks for exit ${BASH_REMATCH[1]} but PKG_APPLY_PENDING_EXIT is $pending_exit — the two must agree or a staged deployment reads as idle"
  fi
  printf '  %-24s %s\n' "PKG_APPLY_PENDING" "$pending (exit $pending_exit)"
  printf '  %-24s %s\n' "PKG_APPLY" "$apply"
fi
for k in $ATOMIC_ONLY; do
  cap_get "$ATOMIC_DUMP" "$k" >/dev/null ||
    note_fail "$ATOMIC declares no $k — it is one of the keys that make the file the atomic edition's"
  if v="$(cap_get "$DNF_DUMP" "$k")"; then
    note_fail "$DNF declares $k=$v — a staged-host key on the dnf edition tells Core's consumers to expect a reboot that never applies anything"
  fi
done
for k in $DNF_ONLY; do
  cap_get "$DNF_DUMP" "$k" >/dev/null ||
    note_fail "$DNF declares no $k — the dnf edition's count path needs it"
  if v="$(cap_get "$ATOMIC_DUMP" "$k")"; then
    note_fail "$ATOMIC declares $k=$v — no count verb (the AVAILABLE question is root-only on an atomic host), nothing prompts, and the image upgrades as a whole; the key belongs to the dnf file only"
  fi
done
for k in $DIVERGENT_NONVERB; do
  a="$(cap_get "$DNF_DUMP" "$k")" || a=""
  b="$(cap_get "$ATOMIC_DUMP" "$k")" || b=""
  # BOTH must declare it. Exempting a key from the identical-values sweep must not also
  # exempt it from existing: a file that simply dropped it would then pass silently, and
  # the warnings it suppresses would come back on that edition alone.
  [[ -n "$a" ]] || note_fail "$DNF declares no $k — it is a declared divergence, not an optional key here"
  [[ -n "$b" ]] || note_fail "$ATOMIC declares no $k — it is a declared divergence, not an optional key here"
  [[ -z "$a" || -z "$b" ]] || printf '  %-24s dnf %s | atomic %s\n' "$k" "'$a'" "'$b'"
done
printf '  %s\n' "atomic-only: $ATOMIC_ONLY"
printf '  %s\n' "dnf-only:    $DNF_ONLY"
printf '  %s\n' "divergent (non-verb): $DIVERGENT_NONVERB"

# ── 4. every OTHER key is identical, key for key and value for value ──────────
# The load-bearing check. The two files are kept in step BY HAND, so this is the one
# that catches "edited the dnf file, forgot the atomic one" — drift that no schema
# validator can see, because each file is individually valid.
say "the remaining keys — identical in both declarations"
diverged=0
while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  in_list "$k" "$DIVERGENT $DIVERGENT_NONVERB $ATOMIC_ONLY $DNF_ONLY" && continue
  a="$(cap_get "$DNF_DUMP" "$k")" || a=""
  if ! b="$(cap_get "$ATOMIC_DUMP" "$k")"; then
    note_fail "$k is declared in $DNF but not in $ATOMIC — every key outside the declared sets must exist in both"
    diverged=1
    continue
  fi
  if [[ "$a" != "$b" ]]; then
    note_fail "$k differs but is not a declared divergence: dnf '$a' vs atomic '$b'"
    diverged=1
  fi
done < <(cap_keys "$DNF_DUMP")

while IFS= read -r k; do
  [[ -n "$k" ]] || continue
  in_list "$k" "$DIVERGENT $DIVERGENT_NONVERB $ATOMIC_ONLY $DNF_ONLY" && continue
  cap_get "$DNF_DUMP" "$k" >/dev/null || {
    note_fail "$k is declared in $ATOMIC but not in $DNF — every key outside the declared sets must exist in both"
    diverged=1
  }
done < <(cap_keys "$ATOMIC_DUMP")
((diverged)) || printf '  %s\n' "the two declarations agree on every key outside the declared sets"

# ── 5. the split is reachable: bootstrap.sh still chooses ─────────────────────
# A declaration is DATA and cannot probe, so the choice is made in bootstrap.sh. Without
# these lines both files are still individually valid and every atomic box silently gets
# the dnf declaration — the failure this whole variant exists to prevent. Four things:
# the host marker, the CI seam, the relink, and the closing line the CI leg greps for.
say "bootstrap.sh still picks an edition"
if grep -q '/run/ostree-booted' bootstrap.sh; then
  printf '  %s\n' "/run/ostree-booted probe present (the marker; fedora-bootc reports ID=fedora and no VARIANT_ID)"
else
  note_fail "bootstrap.sh no longer probes /run/ostree-booted — nothing detects the atomic edition, so every Silverblue/Kinoite/bootc box gets the dnf branch and dnf refuses"
fi
if grep -q 'BOOTSTRAP_PROVISIONER' bootstrap.sh; then
  printf '  %s\n' "BOOTSTRAP_PROVISIONER seam present (how bootstrap.yml's fedora-bootc leg reaches the staging path in a container)"
else
  note_fail "bootstrap.sh no longer honours BOOTSTRAP_PROVISIONER — the fedora-bootc:42 CI leg (provisioner: atomic) can only ever test the dnf branch, and the reusable workflow fails it"
fi
if grep -q 'os/fedora.atomic.capabilities' bootstrap.sh; then
  printf '  %s\n' "relinks $ATOMIC on an atomic box"
else
  note_fail "bootstrap.sh no longer references $ATOMIC — blib_link_os_layer links the dnf file by default, so without the relink the atomic declaration is dead weight"
fi
if grep -q 'reboot to apply' bootstrap.sh; then
  printf '  %s\n' "closing line says 'reboot to apply' (what the CI leg asserts)"
else
  note_fail "bootstrap.sh no longer prints 'reboot to apply' — the operator is not told the layer is inert until a reboot, and bootstrap-test.yml's forced-provisioner leg fails on exactly that string"
fi

# ── 6. the user-facing install alias knows the edition ───────────────────────
# `dnfi` is the one dnf alias that TRANSACTS; on an atomic host it must be rpm-ostree.
# os/fedora.zsh branches on the declaration the shell already read (band 02), so both
# arms must survive: the rpm-ostree one and the dnf one it falls back to.
say "os/fedora.zsh keeps both dnfi arms"
if grep -qE "^[[:space:]]*alias dnfi=.*rpm-ostree install" os/fedora.zsh; then
  printf '  %s\n' "dnfi -> rpm-ostree install  (atomic)"
else
  note_fail "os/fedora.zsh: no 'dnfi' alias for 'rpm-ostree install' — on the atomic edition the alias runs a dnf transaction that resolves and then refuses"
fi
if grep -qE "^[[:space:]]*alias dnfi=.*dnf install" os/fedora.zsh; then
  printf '  %s\n' "dnfi -> dnf install         (dnf edition)"
else
  note_fail "os/fedora.zsh: no 'dnfi' alias for 'dnf install' — the dnf edition lost its install alias"
fi
if grep -qE '(^|[^[:alnum:]_])_core_cap([[:space:]]|$)' os/fedora.zsh; then
  printf '  %s\n' "the choice reads the declaration (_core_cap PROVISIONER), not a private probe"
else
  note_fail "os/fedora.zsh never calls _core_cap — the dnfi choice is not reading the linked declaration, so it can disagree with what bootstrap.sh decided"
fi

# ── 7. the WSL predicate is Core's, not this layer's ─────────────────────────
# os/fedora.zsh gates its WSL-only aliases (open/xdg-open/cdwin) on a WSL question that
# Core answers: _core_is_wsl in core/zsh/00-tools.zsh (dotfiles-core#449). The reusable
# lint workflow's Core-owned-block leg fails a private copy; this asserts both halves
# locally — the private copy stays gone, AND the Core call is still there.
#
# The pattern is the leg's own (core/scripts/lib/common.sh :: _core_owned_block_hits,
# rule `wsl-detect`), minus its comment-line skip; keep prose about the kernel version
# file out of os/fedora.zsh rather than teaching this grep to skip comments.
say "os/fedora.zsh asks Core whether this is WSL"
if grep -qE '/proc/version|(^|[^[:alnum:]_])_IS_WSL[[:space:]]*=' os/fedora.zsh; then
  note_fail "os/fedora.zsh re-implements WSL detection — Core owns it (core/zsh/00-tools.zsh :: _core_is_wsl); use 'if _core_is_wsl; then'"
else
  printf '  %s\n' "no local WSL detection"
fi
if grep -qE '(^|[^[:alnum:]_])_core_is_wsl($|[^[:alnum:]_])' os/fedora.zsh; then
  printf '  %s\n' "_core_is_wsl is called"
else
  note_fail "os/fedora.zsh never calls _core_is_wsl — the WSL-only aliases (open/xdg-open/cdwin) have no predicate gating them"
fi

echo
if ((${#fails[@]})); then
  bad "${#fails[@]} flavour-split finding(s):"
  printf '    %s\n' "${fails[@]}" >&2
  cat >&2 <<'EOF'

Both declarations document their own delta at length. If a divergence here is
INTENDED, say so in both files and add the key to the matching list in this test
(ATOMIC_ONLY / DNF_ONLY / DIVERGENT / DIVERGENT_NONVERB); if it is not, the fix is to bring the two files
back into step by hand.
EOF
  exit 2
fi
ok "the two capability declarations differ in exactly the declared ways."
