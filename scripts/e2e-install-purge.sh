#!/usr/bin/env bash
#
# e2e-install-purge.sh — the epic's acceptance test, made executable.
#
#   install → inventory → purge → empty diff
#
# This drives the REAL arc verbs (`install`, `files`, `list`, `purge`) against
# THIS repo's arc-manifest.yaml, inside a hermetic $HOME, and asserts the
# composition is fully reversible. Nothing here is simulated: the five declared
# members are cloned from their public repos at the manifest's exact pins and
# actually installed.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY A HERMETIC $HOME, AND WHAT "HERMETIC" MEANS HERE
# ─────────────────────────────────────────────────────────────────────────────
#
# The composition's combined capability review declares writes to ~/.claude,
# ~/.config/metafactory/cortex, ~/.config/nats, ~/.local/{state,share}, and
# ~/Library/LaunchAgents. An e2e gate that ran against the operator's real $HOME
# would be a gate that installs and uninstalls the operator's machine. So every
# path class arc and its members can reach is redirected:
#
#   HOME, XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, XDG_CACHE_HOME,
#   ARC_BIN_DIR   → all under $WORKDIR/home
#   ARC_SHARED_HOST=1  → forces arc's chmod-600 FILE secret backend instead of
#                        the macOS login keychain, which `security` reaches by
#                        SESSION, not by $HOME (containment finding, #3 thread)
#   secret env scrubbed → the questionnaire has nothing to harvest
#   stdin < /dev/null + --yes → non-TTY, so every prompt returns empty rather
#                        than blocking or storing a real value
#
# ─────────────────────────────────────────────────────────────────────────────
# THE ONE THING $HOME CANNOT CONTAIN: launchctl / systemctl
# ─────────────────────────────────────────────────────────────────────────────
#
# cortex's postinstall renders service units (launchd on macOS, systemd on
# Linux) and then reloads them. `launchctl` addresses the login session BY UID,
# not by $HOME — a redirected $HOME does not follow it. So a postinstall that
# reached `render_stack_plist` could `bootout` REAL session jobs belonging to
# the operator.
#
# The stub was added as belt-and-braces on the argument that a fresh hermetic
# $HOME is already safe — cortex's `discover_stack_slugs` finds no configured
# stack in an empty config dir, so the plist render is never reached and
# launchctl is never called.
#
# THE ARGUMENT WAS RIGHT ABOUT INSTALL AND WRONG ABOUT PURGE. Measured: the
# install phase makes no launchctl call on any run, exactly as predicted. The
# PURGE phase makes one — cortex's `scripts.purge` hook (cortex#2338) enumerates
# plists under the redirected $HOME (contained, correctly) and then boots each
# one out of `gui/$(id -u)`, the operator's real Aqua session (not contained at
# all). The label in the plist it found is live on the development machine this
# was recorded on. The stub is the only reason that call did nothing.
#
# So the stub is LOAD-BEARING, not defensive, and it is kept as a hard
# requirement rather than a nicety. Every invocation is logged; A6.3 reports the
# log, A6.4 fails outright if any call names a real-$HOME path, and A6.1/A6.2
# check the real machine afterwards to prove the absorption actually worked.
# `systemctl` is stubbed identically because cortex takes that branch on Linux
# (cortex scripts/postinstall.sh §4 branches on `uname`).
#
# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────
#
#   scripts/e2e-install-purge.sh                  # the gate
#   scripts/e2e-install-purge.sh --strict         # the DoD: require an EMPTY diff
#   scripts/e2e-install-purge.sh --inject-residue  # fault-inject; MUST go RED
#   scripts/e2e-install-purge.sh --check-stub      # prove the launchctl stub bites
#   scripts/e2e-install-purge.sh --check-tripwire  # prove A6.4 is not blind (fast)
#
# The injection modes INVERT the exit code: they exit 0 when the detector they
# target behaved correctly, and they judge only that detector — not the gate's
# overall result, which may be red for unrelated reasons. Every detector here
# has one, because a detector nobody has watched fail is a detector nobody
# should trust. --check-tripwire needs no install and takes a second.
#   scripts/e2e-install-purge.sh --keep           # leave $WORKDIR for inspection
#
# The default gate fails on any regression — anything surviving the purge that
# is not already itemised, with a reason, in scripts/known-residue.txt. The
# epic's Definition of Done is stricter (an EMPTY diff, no baseline at all) and
# is reported on every run whether or not it is met; `--strict` makes it govern
# the exit code. See the A5 section for why the two are separate.
#
# Env:
#   ARC_SRC   path to an arc checkout to run from (skips the clone)
#   ARC_REPO  arc's git URL           (default: https://github.com/the-metafactory/arc)
#   ARC_REF   the ref to test against (default: main)
#   BUN       path to the bun binary  (default: whatever is on PATH)
#   E2E_WORKDIR  use this dir instead of a fresh mktemp -d
#
# Exit: 0 = every assertion green. 1 = an assertion failed (the gate).
#       2 = the harness could not run (missing tool, bad workspace).

set -euo pipefail

# ═════════════════════════════════════════════════════════════════════════════
# 0. Constants, arguments, plumbing
# ═════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${REPO_ROOT}/arc-manifest.yaml"

# The two reviewed baseline files. Declared together, up here, because preflight
# reads the waiver file before anything else happens (see the A6.4 guard).
WAIVERS="${SCRIPT_DIR}/known-failures.txt"
RESIDUE_BASELINE="${SCRIPT_DIR}/known-residue.txt"

# The composition under test. Read from the manifest rather than hardcoded, so
# a rename of the package cannot leave this harness silently testing nothing.
FACTORY=""

ARC_REPO="${ARC_REPO:-https://github.com/the-metafactory/arc}"
ARC_REF="${ARC_REF:-main}"
ARC_SRC="${ARC_SRC:-}"
BUN="${BUN:-bun}"

INJECT_RESIDUE=0
CHECK_STUB=0
CHECK_TRIPWIRE=0
KEEP=0
STRICT=0
WORKDIR="${E2E_WORKDIR:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --inject-residue) INJECT_RESIDUE=1 ;;
    --check-stub)     CHECK_STUB=1 ;;
    --check-tripwire) CHECK_TRIPWIRE=1 ;;
    --keep)           KEEP=1 ;;
    --strict)         STRICT=1 ;;
    --workdir)        shift; WORKDIR="${1:?--workdir needs a path}" ;;
    # Print the header block by delimiter rather than by line number: a fixed
    # range silently starts lying the moment the header grows, and it had.
    -h|--help)        awk 'NR>1 && /^set -euo pipefail$/{exit} NR>1' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'e2e: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ── Reporting ────────────────────────────────────────────────────────────────
# Every assertion prints one line, PASS or FAIL, with a stable id. Failures do
# NOT abort: the run continues so one invocation reports every problem, and the
# exit code is decided at the end. That matters for a gate — an operator should
# get the whole picture from one run, not peel it one failure at a time.

PASS_COUNT=0
FAIL_COUNT=0
FAILURES=()

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n══ %s\n' "$*"; }
info() { printf '   · %s\n' "$*"; }

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf '   ✅ %-6s %s\n' "$1" "$2"; }
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILURES+=("$1: $2")
  printf '   ❌ %-6s %s\n' "$1" "$2"
}
# assert <id> <description> <already-captured-exit-code>
assert() { if [ "$3" -eq 0 ]; then pass "$1" "$2"; else fail "$1" "$2"; fi; }
# assert_cmd <id> <description> <command...> — runs the command and grades it.
# Preferred over `cmd; assert id desc $?`, which under `set -e` aborts the whole
# run the moment the condition is false — i.e. exactly when a gate should report.
assert_cmd() {
  local id="$1" desc="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then pass "${id}" "${desc}"; else fail "${id}" "${desc}"; fi
}

die() { printf 'e2e: FATAL — %s\n' "$*" >&2; exit 2; }

# ═════════════════════════════════════════════════════════════════════════════
# 1. Preflight — the harness's own prerequisites, before anything is touched
# ═════════════════════════════════════════════════════════════════════════════

hdr "Preflight"

[ -f "${MANIFEST}" ] || die "no arc-manifest.yaml at ${MANIFEST} — run this from the factory repo"

for tool in git "${BUN}"; do
  command -v "${tool}" >/dev/null 2>&1 || die "required tool not on PATH: ${tool}"
done
# gh is declared in the manifest's tools: block, so arc checks for it before it
# fetches a byte. Absent, the install aborts at the tool gate and every later
# assertion is meaningless — so the harness refuses up front with a clear reason
# rather than reporting a confusing cascade of failures.
command -v gh >/dev/null 2>&1 \
  || die "gh is not on PATH — the manifest declares it in tools:, so arc will refuse the install"

# `uname` decides which service manager is the live hazard and which real
# binaries the untouched-host check should interrogate.
PLATFORM="$(uname -s)"
info "platform: ${PLATFORM}"
info "bun:      $("${BUN}" --version 2>/dev/null || echo '?')"
info "git:      $(git --version 2>/dev/null | head -1)"

# The real, un-redirected home. Captured BEFORE anything is exported, because
# every later phase overwrites $HOME.
REAL_HOME="${HOME}"
info "real \$HOME (must end untouched): ${REAL_HOME}"

# ── The un-waivable assertion, enforced before anything runs ─────────────────
#
# A6.4 is the tripwire for a service-manager call reaching outside the
# workspace. Waiving it would let a real containment failure land as a
# known-failure line nobody reads.
#
# Checked HERE, in preflight, and unconditionally — not down in the summary and
# not only when waivers are being honoured. Two reasons. A run that is going to
# refuse should refuse in the first second, not after fifteen minutes of
# cloning. And the earlier placement caught a subtler hole: the guard used to
# sit behind the same `STRICT -eq 0` condition that loads the waiver list, so
# `--strict` silently skipped it — meaning the file could acquire an A6.4 line,
# pass a --strict run, and only be refused later.
if [ -f "${WAIVERS}" ] \
  && sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "${WAIVERS}" | grep -qx 'A6.4'; then
  die "A6.4 is listed in ${WAIVERS}. That assertion may not be waived: it is the tripwire for a service-manager call reaching outside the workspace. Remove the line."
fi

# ── The manifest's declared members, at their declared pins ──────────────────
#
# Read from the file, never hardcoded. Assertion A1 compares what arc recorded
# against THIS list, so a pin bump in the manifest re-aims the gate with no edit
# here — and a member silently dropped from the manifest cannot pass by being
# absent from a hardcoded expectation too.
#
# The parse is deliberately literal rather than a YAML dependency: strip
# comments, then walk the `references:` block collecting `- name:` / `version:`
# pairs. The manifest is heavily commented, so comment-stripping is the whole
# trick; `#` only ever starts a comment in this file (no value contains one).
read_manifest_scalar() {
  # read_manifest_scalar <key> — a top-level `key: value`, comments stripped.
  sed -e 's/[[:space:]]*#.*$//' "${MANIFEST}" \
    | awk -v k="$1" '$1 == k":" { $1=""; sub(/^[[:space:]]+/,""); print; exit }'
}

read_manifest_members() {
  # Emits `name<TAB>version`, in manifest (install) order.
  sed -e 's/[[:space:]]*#.*$//' "${MANIFEST}" | awk '
    /^references:[[:space:]]*$/ { inrefs=1; next }
    inrefs && /^[^[:space:]]/   { inrefs=0 }
    !inrefs { next }
    /^[[:space:]]*-[[:space:]]*name:/ {
      if (name != "") { print name "\t" version }
      name=$0; sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", name)
      version=""
      next
    }
    /^[[:space:]]*version:/ {
      version=$0; sub(/^[[:space:]]*version:[[:space:]]*/, "", version)
      gsub(/["'"'"']/, "", version)
      next
    }
    END { if (name != "") print name "\t" version }
  '
}

FACTORY="$(read_manifest_scalar name)"
FACTORY_VERSION="$(read_manifest_scalar version)"
[ -n "${FACTORY}" ] || die "could not read 'name:' from ${MANIFEST}"

MEMBERS_FILE_SRC="$(read_manifest_members)"
MEMBER_COUNT="$(printf '%s\n' "${MEMBERS_FILE_SRC}" | grep -c . || true)"
[ "${MEMBER_COUNT}" -gt 0 ] || die "parsed zero members out of ${MANIFEST} — the parser or the manifest changed shape"

info "composition:  ${FACTORY} v${FACTORY_VERSION}"
info "declared members (${MEMBER_COUNT}), read from the manifest:"
while IFS=$'\t' read -r m_name m_version; do
  [ -n "${m_name}" ] || continue
  info "    ${m_name} @ ${m_version}"
done <<< "${MEMBERS_FILE_SRC}"

# ═════════════════════════════════════════════════════════════════════════════
# 2. The real host's fingerprint, taken BEFORE the workspace exists
# ═════════════════════════════════════════════════════════════════════════════
#
# Assertion A6 is "the real machine was not touched". It is taken here, with the
# real $HOME still in $HOME and the real service manager still first on PATH,
# and again at the very end. Two fingerprints, compared.
#
# WHAT IS COMPARED, AND WHY IT IS SPLIT IN TWO. A blanket stat-hash of the whole
# real $HOME is not merely slow, it is permanently and uselessly red. Measured,
# not assumed: on the machine this was written on, a `stat`-level comparison of
# ~/.config/metafactory failed because a LIVE service (blueprint) appended to
# its own log file during the ninety seconds the harness was running. That is
# the operator's machine working correctly, and a detector that calls it a
# containment leak is a detector nobody will believe the day it is right.
#
#   STRICT surfaces — path + size + mtime. Only things that are genuinely
#   quiet: nothing on a working machine writes to them on its own. A byte of
#   drift here is a real finding.
#
#   ARTIFACT existence — for each thing this composition installs, is it present
#   in the REAL home, and is that the same answer before and after? This is the
#   leak signature stated directly, and it is immune to the machine being used
#   while the harness runs.
#
# NOTE ON SCOPE, so A6.1 is not read as more than it is. Both lists are a NAMED
# SET, not the whole home directory. A6.1 proves "the service directories stayed
# byte-identical, and none of this composition's artifacts appeared in the real
# home". That is the useful claim, and it is not the same claim as "nothing
# anywhere under $HOME changed" — a live machine writes constantly, and any
# check that asserted otherwise would be red every run. A member writing
# somewhere it never declared would be invisible here, and would also be a
# manifest defect, which A5's diff over the hermetic $HOME is the detector for.

HOST_STRICT_PATHS=(
  "${REAL_HOME}/Library/LaunchAgents"          # cortex's launchd plists (macOS) — the file half of the launchd hazard
  "${REAL_HOME}/.config/systemd/user"          # cortex's systemd units (Linux) — the same hazard's Linux half
  "${REAL_HOME}/.config/nats"                  # cortex's bus config; nothing writes here unattended
  "${REAL_HOME}/.local/share/metafactory/arc/packages.db"  # arc's registry — a leaked install would write it
)

# ── The artifact list: WHAT would appear if containment failed ──────────────
#
# The name-set surfaces this replaces were too broad, and the gate caught the
# consequence itself: a run went red on
#
#   +/Users/andreas/.local/state/metafactory/luna-drafts/316-slices.md
#
# which is the operator's own assistant writing a note, mid-run, in a directory
# that merely shares an ancestor with cortex's state. Nothing to do with the
# composition. A containment check that goes red because the machine was being
# used is a flaky check, and a flaky check is one people learn to re-run until
# it is green — which is the same as not having it.
#
# So the question is asked precisely instead of broadly: not "did anything new
# appear under these directories", but "did any of the artifacts THIS
# COMPOSITION installs appear in the real $HOME". Every entry below is the
# real-home twin of something A3 asserts landed in the hermetic one.
#
# EXISTENCE IS COMPARED BEFORE AND AFTER, not merely tested. Several of these
# legitimately already exist on a machine that runs cortex — the check is that
# the run did not CHANGE that, which is the actual claim and is true whether or
# not the operator already has the package.
HOST_ARTIFACT_PATHS=(
  "${REAL_HOME}/.claude/skills/Governance"
  "${REAL_HOME}/.claude/skills/plan-breakdown"
  "${REAL_HOME}/.claude/skills/code-review"
  "${REAL_HOME}/.claude/relay/relay-policy.yaml"
  "${REAL_HOME}/.claude/events"
  "${REAL_HOME}/bin/discord"
  "${REAL_HOME}/.local/bin/cortex"
  "${REAL_HOME}/.local/bin/cortex-relay"
  "${REAL_HOME}/.local/bin/cldyo-live"
  "${REAL_HOME}/.config/metafactory/cortex"
  "${REAL_HOME}/.local/state/metafactory/cortex"
  "${REAL_HOME}/.local/share/metafactory/cortex"
  "${REAL_HOME}/.local/share/metafactory/arc/repos/cortex"
  "${REAL_HOME}/.local/share/metafactory/arc/repos/compass-core"
  "${REAL_HOME}/.local/share/metafactory/arc/repos/metafactory-bundle-discord"
  "${REAL_HOME}/.local/share/metafactory/arc/repos/metafactory-skill-code-review"
  "${REAL_HOME}/.local/share/metafactory/arc/repos/metafactory-cortex-adapter-discord"
)

# ── The service table, and why only OUR labels are compared ─────────────────
#
# `launchctl list` is not a stable fingerprint of a macOS session. Measured on
# an idle machine over the ~90s of one harness run, a dozen on-demand agents
# (com.apple.ReportCrash, com.apple.bird, com.apple.ctkd, …) came and went by
# themselves. Diffing the raw table produces a red light every single run, which
# trains the reader to ignore the one assertion in this file that guards against
# actual damage to the operator's session.
#
# So the ASSERTION compares only labels this ecosystem could plausibly own —
# which is exactly the hazard: cortex's plist renderer boots out
# `ai.meta-factory.cortex.*` / `com.metafactory.*` jobs by uid. The full table
# is still captured to a file both times, and the raw delta is reported as
# information, so a curious reader can look; it just does not decide the gate.
SERVICE_LABEL_RE='cortex|metafactory|meta-factory|grove|nats'

fingerprint_host() {
  # fingerprint_host <outfile>
  local out="$1" p
  : > "${out}"
  for p in "${HOST_STRICT_PATHS[@]}"; do
    printf '### STRICT %s\n' "${p}" >> "${out}"
    if [ -e "${p}" ]; then
      # -exec ... + would batch, but per-file keeps the output stable across
      # find implementations. maxdepth 4 bounds the cost; arc's `repos/` trees
      # are enormous and their existence (not their contents) is the signal.
      find "${p}" -maxdepth 4 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s %s\n' "$(stat_size "${f}")" "$(stat_mtime "${f}")" "${f}"
      done >> "${out}"
    else
      printf '(absent)\n' >> "${out}"
    fi
  done
  # Existence only, one line each. `-e` misses a dangling symlink, which is
  # exactly the kind of debris worth catching, so `-L` covers it too.
  for p in "${HOST_ARTIFACT_PATHS[@]}"; do
    if [ -e "${p}" ] || [ -L "${p}" ]; then
      printf '### ARTIFACT present %s\n' "${p}" >> "${out}"
    else
      printf '### ARTIFACT absent  %s\n' "${p}" >> "${out}"
    fi
  done
  # The live service table, filtered to labels this ecosystem could own. This is
  # the launchctl hazard's own witness: if a member's postinstall reached the
  # real session and booted a job out, the job list changes even though no file
  # under $HOME did.
  printf '### SERVICES\n' >> "${out}"
  service_table | grep -Ei "${SERVICE_LABEL_RE}" >> "${out}" || true
  # The unfiltered table, captured beside the fingerprint for a human to read.
  # Never compared — see the note above on macOS's on-demand agents.
  service_table > "${out}.services-raw" || true
}

# stat(1) is not portable between BSD (macOS) and GNU (Linux). One wrapper each,
# chosen once, rather than a `stat -f ... || stat -c ...` at every call site.
if stat -f '%z' . >/dev/null 2>&1; then
  stat_size()  { stat -f '%z' "$1" 2>/dev/null || echo '?'; }
  stat_mtime() { stat -f '%m' "$1" 2>/dev/null || echo '?'; }
else
  stat_size()  { stat -c '%s' "$1" 2>/dev/null || echo '?'; }
  stat_mtime() { stat -c '%Y' "$1" 2>/dev/null || echo '?'; }
fi

# ── The containment predicate behind A6.4 ───────────────────────────────────
#
# Given the stub's call log, print every path token that lives under the real
# $HOME but OUTSIDE the workspace. Empty output means every call was contained.
#
# TWO BUGS ARE DESIGNED OUT HERE, both of which shipped in earlier versions and
# both of which were found by running the thing rather than reading it.
#
# 1. SUBSTRING, NOT CONTAINMENT. The first version asked "does the call mention
#    $REAL_HOME?". On a GitHub runner the workspace lives INSIDE the home
#    directory — HOME=/Users/runner, WORKDIR=/Users/runner/work/_temp/e2e — so
#    every properly-contained path has $REAL_HOME as a prefix and the tripwire
#    fired on all of them, every run.
#
# 2. PREFIX-SIBLINGS. The fix for (1) stripped `${WORKDIR}[^[:space:]]*`, which
#    also erases any SIBLING sharing the prefix: with WORKDIR=…/e2e, a call
#    naming …/e2e-evil was scrubbed and the escape went unreported. Not
#    hypothetical in this repo — CI runs the injection modes in …/e2e-inject and
#    …/e2e-stub, exact prefix-siblings of the gate's own …/e2e. A tripwire that
#    silently ignores a whole class of path is worse than one that cries wolf.
#
# Both are avoided by comparing LITERALLY and anchoring on the separator: a
# token counts as contained only when it equals the workspace root or begins
# with the root plus "/". awk's `index()` and `==` do no pattern matching at
# all, so there is nothing to escape — which also disposes of a third latent
# bug, the unescaped "." in mktemp's `e2e-factory.XXXXXX` workspace name.
#
# Both spellings of the workspace are accepted because macOS hands out /tmp and
# /private/tmp for one directory.
escaping_calls() {
  # escaping_calls <logfile> <real-home> <workdir> <workdir-resolved>
  awk -v home="$2" -v wd="$3" -v wdr="$4" '
    function under(tok, root) {
      # Literal, separator-anchored. Never a regex.
      return (tok == root) || (index(tok, root "/") == 1)
    }
    {
      for (i = 1; i <= NF; i++) {
        tok = $i
        if (!under(tok, home)) continue        # not a real-$HOME path at all
        if (under(tok, wd) || under(tok, wdr)) continue   # inside the workspace
        printf "line %d: %s\n", FNR, tok
      }
    }
  ' "$1"
}

# ABSOLUTE PATHS ONLY. By the time this is called the second time, the stub dir
# is first on PATH — asking PATH for `launchctl` would interrogate the stub and
# always agree with itself. The whole point is to ask the REAL one.
service_table() {
  case "${PLATFORM}" in
    Darwin)
      if [ -x /bin/launchctl ]; then
        /bin/launchctl list 2>/dev/null | LC_ALL=C sort || echo '(launchctl list failed)'
      else
        echo '(no /bin/launchctl)'
      fi
      ;;
    Linux)
      if [ -x /usr/bin/systemctl ]; then
        /usr/bin/systemctl --user list-units --no-pager --no-legend 2>/dev/null | LC_ALL=C sort \
          || echo '(no systemd user session)'
      else
        echo '(no /usr/bin/systemctl)'
      fi
      ;;
    *) echo "(unknown platform ${PLATFORM})" ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════
# 3. The workspace
# ═════════════════════════════════════════════════════════════════════════════

hdr "Workspace"

if [ -z "${WORKDIR}" ]; then
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/e2e-factory.XXXXXX")"
else
  mkdir -p "${WORKDIR}"
fi
HERM="${WORKDIR}/home"
STUBS="${WORKDIR}/stubs"
LOGS="${WORKDIR}/logs"
STUB_LOG="${WORKDIR}/service-manager-calls.log"
mkdir -p "${HERM}" "${STUBS}" "${LOGS}"
: > "${STUB_LOG}"

WORKDIR_REAL="$(cd "${WORKDIR}" && pwd -P)"
info "workdir: ${WORKDIR}"

# shellcheck disable=SC2329  # invoked by the EXIT trap below, not by name
cleanup() {
  local rc=$?
  if [ "${KEEP}" -eq 1 ]; then
    printf '\ne2e: --keep set; workspace left at %s\n' "${WORKDIR}"
  elif [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ] && [ "${WORKDIR}" != "/" ]; then
    # Cloned repos arrive with read-only git objects; chmod first or the rm
    # fails on some filesystems and leaves gigabytes behind.
    chmod -R u+w "${WORKDIR}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
  fi
  exit "${rc}"
}
trap cleanup EXIT

# ═════════════════════════════════════════════════════════════════════════════
# --check-tripwire — the standing fault injection for A6.4
# ═════════════════════════════════════════════════════════════════════════════
#
# A6.4 is the only assertion that may never be waived, and until this existed it
# was also the only detector with no proof that it still worked. That is a bad
# combination: its healthy state is "found nothing", which is indistinguishable
# from "cannot find anything". Both bugs described above lived in it, and both
# reached CI.
#
# This drives the REAL predicate — `escaping_calls`, the same function A6.4
# uses — over synthetic logs with known answers. Synthetic values are used for
# home and workspace rather than the machine's, so the cases are identical on a
# laptop (workspace outside $HOME) and on a runner (workspace inside it), and
# the prefix-sibling case can be posed at all.
#
# It runs BEFORE the install and exits: it is a self-test of a detector, not a
# test of the composition, and it should stay answerable when everything else
# is broken.
if [ "${CHECK_TRIPWIRE}" -eq 1 ]; then
  hdr "TRIPWIRE CHECK — fault-injecting A6.4's containment predicate"
  T_HOME="/Users/runner"
  T_WD="/Users/runner/work/_temp/e2e"
  TDIR="${WORKDIR}/tripwire"; mkdir -p "${TDIR}"

  # tw <id> <description> <expect: FLAG|CLEAR> <log line...>
  tw() {
    local id="$1" desc="$2" want="$3"; shift 3
    local log="${TDIR}/${id}.log"
    printf '%s\n' "$@" > "${log}"
    local got=CLEAR
    [ -n "$(escaping_calls "${log}" "${T_HOME}" "${T_WD}" "${T_WD}")" ] && got=FLAG
    if [ "${got}" = "${want}" ]; then pass "${id}" "${desc} → ${got}"
    else fail "${id}" "${desc} → got ${got}, wanted ${want}"; fi
  }

  tw T1 "a real-\$HOME plist outside the workspace" FLAG \
    "ts launchctl bootout gui/501 ${T_HOME}/Library/LaunchAgents/ai.meta-factory.cortex.relay.plist"
  tw T2 "a contained workspace path (nested under \$HOME, the CI layout)" CLEAR \
    "ts launchctl bootout gui/501 ${T_WD}/home/Library/LaunchAgents/ai.meta-factory.cortex.relay.plist"
  # T3 is the regression guard for the prefix-sibling bug. CI genuinely creates
  # these siblings: e2e-inject and e2e-stub sit next to e2e.
  tw T3 "a PREFIX-SIBLING of the workspace (…/e2e-evil vs …/e2e)" FLAG \
    "ts launchctl bootout gui/501 ${T_WD}-evil/Library/LaunchAgents/x.plist"
  tw T4 "an escape sharing one LINE with a contained path" FLAG \
    "ts launchctl bootout gui/501 ${T_WD}/home/a.plist ${T_HOME}/Library/LaunchAgents/b.plist"
  tw T5 "the workspace root named bare, with no trailing slash" CLEAR \
    "ts launchctl bootout gui/501 ${T_WD}"
  tw T6 "no calls at all" CLEAR ""

  hdr "Result"
  if [ "${FAIL_COUNT}" -eq 0 ]; then
    say "   ✅ TRIPWIRE INTACT — ${PASS_COUNT} case(s): A6.4 flags an escape, ignores a"
    say "      contained path, and is NOT blinded by a prefix-sibling."
    exit 0
  fi
  say "   ❌ TRIPWIRE BLIND — ${FAIL_COUNT} case(s) wrong:"
  for f in ${FAILURES[@]+"${FAILURES[@]}"}; do say "        ${f}"; done
  say "      A6.4 cannot be trusted until these pass. It is the un-waivable one."
  exit 1
fi

# ── The service-manager stubs ────────────────────────────────────────────────
#
# Both exit 0 so a caller that IS reached does not itself fail — the harness
# wants the call recorded and the run continued, not a crash that hides what
# else would have happened. The record is the finding.
write_stub() {
  # write_stub <name>
  cat > "${STUBS}/$1" <<STUB
#!/usr/bin/env bash
# e2e stub — records the call and does nothing. See scripts/e2e-install-purge.sh.
printf '%s %s %s\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "\$*" >> "${STUB_LOG}"
exit 0
STUB
  chmod +x "${STUBS}/$1"
}
write_stub launchctl
write_stub systemctl
info "stubs on PATH: launchctl, systemctl → ${STUB_LOG}"

# ── arc ──────────────────────────────────────────────────────────────────────
#
# Self-contained by default: clone arc at ARC_REF into the workspace. ARC_SRC
# short-circuits that for a local iteration loop against an unmerged branch.
# Either way the harness carries no dependency on a directory outside this repo.

hdr "arc under test"

if [ -n "${ARC_SRC}" ]; then
  [ -f "${ARC_SRC}/src/cli.ts" ] || die "ARC_SRC=${ARC_SRC} has no src/cli.ts"
  ARC_DIR="${ARC_SRC}"
  info "using ARC_SRC: ${ARC_DIR}"
else
  ARC_DIR="${WORKDIR}/arc"
  info "cloning ${ARC_REPO} @ ${ARC_REF}"
  git clone --quiet --depth 1 --branch "${ARC_REF}" "${ARC_REPO}" "${ARC_DIR}" 2>/dev/null \
    || git clone --quiet "${ARC_REPO}" "${ARC_DIR}" || die "could not clone arc"
  git -C "${ARC_DIR}" checkout --quiet "${ARC_REF}" 2>/dev/null || true
fi
ARC_SHA="$(git -C "${ARC_DIR}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
info "arc HEAD: ${ARC_SHA} — $(git -C "${ARC_DIR}" log -1 --format=%s 2>/dev/null || echo '?')"

if [ ! -d "${ARC_DIR}/node_modules" ]; then
  info "bun install (arc deps)"
  ( cd "${ARC_DIR}" && "${BUN}" install --frozen-lockfile >/dev/null 2>&1 ) \
    || ( cd "${ARC_DIR}" && "${BUN}" install >/dev/null 2>&1 ) \
    || die "bun install failed in ${ARC_DIR}"
fi

# ── The hermetic invocation ──────────────────────────────────────────────────
#
# One function, so no phase can accidentally run arc with a leaked variable. The
# environment is built here and nowhere else.
#
# `env -i` is deliberately NOT used: bun needs a viable base environment, and an
# over-scrubbed one produces failures that look like arc bugs. Instead the
# variables that matter are set explicitly and the secret-bearing ones are
# unset, which is the containment that is actually load-bearing.
BUN_DIR="$(dirname "$(command -v "${BUN}")")"

arc() {
  # The subshell is the containment: every export below dies with it, so no
  # later phase can inherit a redirected HOME by accident. That locality is the
  # design, not an oversight.
  # shellcheck disable=SC2030,SC2031
  ( set +e
    export HOME="${HERM}"
    export XDG_CONFIG_HOME="${HERM}/.config"
    export XDG_DATA_HOME="${HERM}/.local/share"
    export XDG_STATE_HOME="${HERM}/.local/state"
    export XDG_CACHE_HOME="${HERM}/.cache"
    export ARC_BIN_DIR="${HERM}/bin"
    # Forces the chmod-600 file backend. The macOS login keychain is reached by
    # SESSION, not by $HOME, so it is the one secret store a redirected $HOME
    # does not contain.
    export ARC_SHARED_HOST=1
    # Stubs FIRST. Everything else is the system PATH plus bun's dir — the
    # operator's ~/.local/bin and friends are deliberately absent so a tool that
    # only exists on this developer's machine cannot make the run pass.
    export PATH="${STUBS}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${BUN_DIR}"
    # Temp files land in the workspace too. Without this, anything a member's
    # install script writes via mktemp goes to the system temp dir — outside
    # every redirect above, and surviving the workspace cleanup. A hermetic
    # $HOME sharing the host's /tmp is only most of the way hermetic.
    #
    # Deliberately ${WORKDIR}/tmp and NOT under ${HERM}: it must be contained,
    # but it must not be SNAPSHOTTED. arc mkdtemps `arc-purge-*` while running
    # its purge hooks, and randomly-named directories inside the snapshot root
    # would make the post-purge diff nondeterministic — every run reporting a
    # different unbaselined path, which no baseline file can ever describe.
    # Containment is the goal here; the diff is about the hermetic $HOME.
    export TMPDIR="${WORKDIR}/tmp"
    mkdir -p "${TMPDIR}"
    # The secrets questionnaire has nothing to harvest and no member can
    # authenticate as the operator. Combined with </dev/null, every prompt
    # returns empty.
    #
    # The list is deliberately wider than the manifest's declared secrets. Those
    # eight are what the composition ASKS for; these are what a member could
    # reach for without asking, and the whole point of a hermetic rig is that it
    # cannot be quietly used as the operator. SSH_AUTH_SOCK matters most and is
    # the least obvious: it is a socket path, so no amount of $HOME redirection
    # touches it, and leaving it set hands every `git clone` in the run the
    # operator's live agent keys.
    unset GH_TOKEN GITHUB_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN \
          NATS_TOKEN CTX_DISCORD_TOKEN CTX_WEB_TOKEN CLOUDFLARE_API_TOKEN \
          SSH_AUTH_SOCK GIT_SSH_COMMAND \
          AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE \
          OPENAI_API_KEY HOMEBREW_GITHUB_API_TOKEN NPM_TOKEN
    "${BUN}" "${ARC_DIR}/src/cli.ts" "$@" < /dev/null
  )
}

# ═════════════════════════════════════════════════════════════════════════════
# 4. Filesystem snapshots — the harness's own detector, independent of arc's
# ═════════════════════════════════════════════════════════════════════════════
#
# arc prints its own D6 untangle verdict during purge, and A4 asserts on it. But
# a gate that only asks the system under test whether it worked is not a gate.
# So the harness takes its own before/after listing of the hermetic $HOME and
# diffs them, with no knowledge of what arc thinks it removed.
#
# ── WHAT IS EXCLUDED FROM THE DIFF, AND WHY ─────────────────────────────────
#
# The first line of defence is not an exclusion at all: the BASELINE is taken
# after a warm-up `arc list`, so everything arc creates just by being run — its
# SQLite registry, the directory skeleton `ensureDirectories` writes on every
# invocation (paths.ts), the `.gitkeep` files it drops into each — is present in
# BOTH snapshots and cancels out. That is strictly better than a hand-maintained
# ignore list, which would grow stale the moment arc adds a directory.
#
# EXACTLY ONE prefix is excluded on top of that, and it is excluded on a
# principle rather than a convenience:
#
#   ./.cache — XDG_CACHE_HOME. A cache is by definition discardable, non-
#     authoritative state: nothing in it is a claim about what is installed, and
#     deleting it costs a re-download, not correctness. Two things land here and
#     neither is the composition's footprint — bun's transpiler cache (the
#     measuring instrument's own trace: arc is TypeScript run from source, so
#     merely invoking it writes here) and bun's content-addressed package cache,
#     which `bun install` populates inside each member and which is shared with
#     every other bun project on the host. A purge that swept the operator's bun
#     cache would be doing damage, not cleanup — apt does not empty
#     /var/cache/apt on purge either.
#
# Everything else — including arc's own SQLite registry and the directory
# skeleton it lays down — is deliberately NOT pattern-excluded. It is itemised,
# line by line with a reason, in scripts/known-residue.txt. That file is the
# honest artifact: a reader sees every path this factory does not yet reverse
# and who owns each one, instead of a regex that quietly swallows the same
# paths. See the A5 section for how the two assertions use it.

EXCLUDE_PREFIXES=(
  ".cache"
)

# RESIDUE_BASELINE is declared at the top of the file, alongside WAIVERS.
# Format: one path per line, `#` comments and blank lines ignored, trailing
# `# reason` stripped. Absent file = an empty baseline, the strictest gate.

snapshot() {
  # snapshot <outfile> — every path under the hermetic home, relative, sorted.
  # -mindepth 1 drops the root itself. Symlinks are listed, never followed: a
  # dangling shim left behind is precisely the debris this is looking for.
  ( cd "${HERM}" && find . -mindepth 1 2>/dev/null | LC_ALL=C sort ) > "$1"
}

# One array of grep patterns, built once from EXCLUDE_PREFIXES, used by both the
# "drop these" and the "show these" halves — so the two can never drift apart
# and quietly hide something the report claims to be printing.
EXCLUDE_GREP=()
for _p in "${EXCLUDE_PREFIXES[@]}"; do
  EXCLUDE_GREP+=(-e "^\./${_p}$" -e "^\./${_p}/")
done
unset _p

filter_excluded() { grep -v "${EXCLUDE_GREP[@]}" "$1" || true; }
only_excluded()   { grep    "${EXCLUDE_GREP[@]}" "$1" || true; }

# ═════════════════════════════════════════════════════════════════════════════
# 5. Baseline
# ═════════════════════════════════════════════════════════════════════════════

hdr "Baseline"

HOST_BEFORE="${LOGS}/host-before.txt"
fingerprint_host "${HOST_BEFORE}"
info "real-host fingerprint: $(wc -l < "${HOST_BEFORE}" | tr -d ' ') lines"

# ── The warm-up, and why the baseline is taken AFTER it ─────────────────────
#
# arc creates state just by running: the SQLite registry, and (on install) the
# directory skeleton `ensureDirectories` lays down with a `.gitkeep` in each.
# None of that is the composition's footprint, and `arc purge` correctly does
# not remove it — a package manager that deleted its own database on purge would
# be deleting the record of the purge.
#
# So the baseline is taken with arc already warmed up. Everything arc creates
# merely by existing is then in BOTH snapshots and cancels out of the diff. The
# alternative — a hand-written ignore list of arc's internal directories — goes
# stale the first time arc adds one, and goes stale SILENTLY, in the permissive
# direction. This way the harness learns arc's skeleton from arc.
info "warming arc up (so its own skeleton is in the baseline, not in the diff)"
arc list > "${LOGS}/list-warmup.txt" 2>&1 || true

PRE_SNAP="${LOGS}/pre-install.txt"
snapshot "${PRE_SNAP}"
info "hermetic \$HOME before install: $(wc -l < "${PRE_SNAP}" | tr -d ' ') path(s) (arc warmed up)"

# ═════════════════════════════════════════════════════════════════════════════
# A1. Install: exit 0, composition complete, all declared members at their pins
# ═════════════════════════════════════════════════════════════════════════════

hdr "A1 — hermetic install"

INSTALL_LOG="${LOGS}/install.log"
info "arc install file://${REPO_ROOT} --yes"
set +e
arc install "file://${REPO_ROOT}" --yes > "${INSTALL_LOG}" 2>&1
INSTALL_RC=$?
set -e
info "exit ${INSTALL_RC}; $(wc -l < "${INSTALL_LOG}" | tr -d ' ') lines → ${INSTALL_LOG}"
[ "${INSTALL_RC}" -eq 0 ] || { sed -n '1,60p' "${INSTALL_LOG}"; }

assert A1.1 "arc install exits 0" "${INSTALL_RC}"

LIST_JSON="${LOGS}/list-after-install.json"
set +e
arc list --json > "${LIST_JSON}" 2>"${LOGS}/list-after-install.err"
LIST_RC=$?
set -e
assert A1.2 "arc list --json succeeds after install" "${LIST_RC}"

# The composition record, and the members it says landed, read out of arc's own
# JSON. `bun` is already a hard requirement, so it is the JSON parser — no jq
# dependency, and no fragile grep over pretty-printed JSON.
# Arguments travel by ENVIRONMENT, not argv: `bun -e` and `node -e` disagree
# about where the script's own arguments start in process.argv, and a harness
# that silently read the wrong slot would report a missing composition as a
# failed install. Env vars are unambiguous in both.
composition_query() {
  # composition_query <json-file> <mode> — prints to stdout; exit 3 if the
  # composition is missing from the record entirely.
  # shellcheck disable=SC2016  # the single quotes are deliberate: this is JS,
  # and every value it needs arrives through the environment, not through $-
  # expansion by the shell.
  Q_FILE="$1" Q_FACTORY="${FACTORY}" Q_MODE="$2" "${BUN}" -e '
    const { Q_FILE, Q_FACTORY, Q_MODE } = process.env;
    const d = JSON.parse(require("fs").readFileSync(Q_FILE, "utf8"));
    if (Q_MODE === "pkgcount") { console.log((d.packages ?? []).length); process.exit(0); }
    if (Q_MODE === "pkgnames") {
      for (const p of (d.packages ?? [])) console.log(`${p.name}\t${p.version}`);
      process.exit(0);
    }
    const c = (d.compositions ?? []).find((x) => x.name === Q_FACTORY);
    if (!c) process.exit(3);
    if (Q_MODE === "status") console.log(c.status);
    if (Q_MODE === "members") {
      for (const m of c.members) console.log(`${m.name}\t${m.version}\t${m.state}`);
    }
  '
}

set +e
COMP_STATUS="$(composition_query "${LIST_JSON}" status)"
COMP_RC=$?
set -e
if [ "${COMP_RC}" -ne 0 ]; then
  fail A1.3 "composition '${FACTORY}' is recorded by arc (not found in arc list --json)"
else
  info "composition status: ${COMP_STATUS}"
  assert_cmd A1.3 "composition '${FACTORY}' status is 'complete'" \
    test "${COMP_STATUS}" = "complete"
fi

# Every declared member, at the manifest's exact pin, in state 'landed'.
LANDED="${LOGS}/landed-members.tsv"
composition_query "${LIST_JSON}" members > "${LANDED}" 2>/dev/null || : > "${LANDED}"

# NAMES ARE COMPARED CANONICALLY — scope stripped, lowercased — which is what
# arc itself does (`canonicalMemberKey`, src/lib/composition-identity.ts). The
# reason is concrete and lives in this very manifest: compass-core's own
# manifest declares `name: "@the-metafactory/compass-core"` (a known arc/v1
# violation it documents and deliberately does not fix), so arc records it under
# the scoped spelling while this manifest's reference label says `compass-core`.
# A literal comparison would report the factory's own governance member as
# missing, which is a harness bug wearing a finding's clothes.
canon() { printf '%s' "${1##*/}" | tr '[:upper:]' '[:lower:]'; }

MEMBER_MISSES=""
MEMBER_NOT_LANDED=""
while IFS=$'\t' read -r m_name m_version; do
  [ -n "${m_name}" ] || continue
  m_key="$(canon "${m_name}")"
  # Field-exact comparison via awk rather than a grep over a tab-joined string:
  # a literal tab inside a shell pattern is invisible in a diff and trivially
  # mangled by an editor, and getting it wrong here would silently pass.
  state="$(awk -F'\t' -v k="${m_key}" '
    { n = $1; sub(/^.*\//, "", n); if (tolower(n) == k) { print $3; exit } }' "${LANDED}")"
  version="$(awk -F'\t' -v k="${m_key}" '
    { n = $1; sub(/^.*\//, "", n); if (tolower(n) == k) { print $2; exit } }' "${LANDED}")"

  if [ "${version}" = "${m_version}" ]; then
    info "recorded at pin: ${m_name} @ ${m_version} (state: ${state})"
  else
    MEMBER_MISSES="${MEMBER_MISSES}${m_name} want ${m_version}, got ${version:-<absent>}; "
  fi
  if [ "${state}" != "landed" ]; then
    MEMBER_NOT_LANDED="${MEMBER_NOT_LANDED}${m_name}=${state:-<absent>}; "
  fi
done <<< "${MEMBERS_FILE_SRC}"

assert_cmd A1.4 "all ${MEMBER_COUNT} declared members recorded at the manifest's exact pins" \
  test -z "${MEMBER_MISSES}"
[ -z "${MEMBER_MISSES}" ] || info "MISMATCH: ${MEMBER_MISSES}"

# ── Why `state` gets its own assertion ───────────────────────────────────────
#
# A member can be present at the right version and still not be the
# composition's to remove. arc records `preexisting` for a member that was
# already installed when the composition reached it, and `memberReferents()`
# treats that as a referent — "the composition did not put it here" — so the
# member is deliberately RETAINED at purge.
#
# It fires on this factory, on a completely fresh machine: cortex's
# `depends_on` cascade installs metafactory-cortex-adapter-discord BEFORE the
# composition reaches it as a DECLARED member, so a member this factory
# explicitly ships is recorded as one the composition "did not put here".
#
# MEASURED, not predicted: on the observed runs that member is still removed at
# purge — cortex's own teardown drops its refcount to zero and it goes with the
# cascade. So this is a RECORD-FIDELITY defect, not (today) a reversibility one:
# `arc list --json` misdescribes how the member arrived, and the retention rule
# that consumes that field would keep it if the refcount ever landed differently
# (an operator who installed cortex first, say). It is asserted separately from
# the version so that distinction stays visible instead of being averaged into
# a single green tick.
assert_cmd A1.5 "every declared member is 'landed' (not 'preexisting' — a preexisting member survives its own factory's purge)" \
  test -z "${MEMBER_NOT_LANDED}"
[ -z "${MEMBER_NOT_LANDED}" ] || info "NOT LANDED: ${MEMBER_NOT_LANDED}"

# ── The dependency cascade, recorded rather than asserted ────────────────────
#
# cortex declares depends_on.packages, so installing five members lands more
# than five packages. arc#410 is open precisely because those cascade packages
# arrive UNPINNED — this manifest cannot pin them, and their resolved versions
# can move under the harness between runs.
#
# So the cascade is REPORTED, not gated: an assertion on "exactly nine packages"
# would go red the day cortex adds a dependency, which is a fact about cortex,
# not a regression in this factory. What IS gated is that they all disappear at
# purge (A5) — reversibility is the claim under test, not the count.
PKG_LIST="${LOGS}/packages-after-install.tsv"
composition_query "${LIST_JSON}" pkgnames > "${PKG_LIST}" 2>/dev/null || : > "${PKG_LIST}"
PKG_COUNT="$(grep -c . "${PKG_LIST}" || true)"
MEMBER_NAMES="$(printf '%s\n' "${MEMBERS_FILE_SRC}" | cut -f1 | tr '[:upper:]' '[:lower:]')"
CASCADE_COUNT=0
info "arc recorded ${PKG_COUNT} package(s) total (the ${MEMBER_COUNT} declared members"
info "  + cortex's depends_on cascade + the composition's own record). Detail:"
while IFS=$'\t' read -r p_name p_version; do
  [ -n "${p_name}" ] || continue
  # compass-core records itself under its own scoped manifest name
  # (`@the-metafactory/compass-core`) rather than this manifest's reference
  # label, so the scope is stripped before the membership test.
  p_bare="$(canon "${p_name}")"
  if [ "${p_name}" = "${FACTORY}" ]; then
    info "    ${p_name} ${p_version}  [the composition record itself]"
  elif printf '%s\n' "${MEMBER_NAMES}" | grep -qxF "${p_bare}"; then
    : # a declared member — already reported, at its asserted pin, above
  else
    CASCADE_COUNT=$((CASCADE_COUNT + 1))
    info "    ${p_name} ${p_version}  [CASCADE — unpinned, arc#410]"
  fi
done < "${PKG_LIST}"
info "  → ${CASCADE_COUNT} package(s) arrived via the cascade, at versions this"
info "    manifest does not and cannot pin. That is arc#410, recorded here as"
info "    evidence rather than smoothed over: their resolved versions can move"
info "    between runs, so the harness gates their REMOVAL (A5), never a count."

# ═════════════════════════════════════════════════════════════════════════════
# A2. arc files <factory> — the composition's footprint is a non-empty union
# ═════════════════════════════════════════════════════════════════════════════

hdr "A2 — arc files ${FACTORY}"

FILES_JSON="${LOGS}/files.json"
FILES_TXT="${LOGS}/files.txt"
set +e
arc files "${FACTORY}" --json > "${FILES_JSON}" 2>"${LOGS}/files.err"
FILES_RC=$?
arc files "${FACTORY}" > "${FILES_TXT}" 2>/dev/null
set -e
assert A2.1 "arc files ${FACTORY} exits 0" "${FILES_RC}"

FILES_COUNT=0
if [ "${FILES_RC}" -eq 0 ]; then
  # shellcheck disable=SC2016  # JS, not shell — see composition_query
  FILES_COUNT="$(Q_FILE="${FILES_JSON}" "${BUN}" -e '
    const d = JSON.parse(require("fs").readFileSync(process.env.Q_FILE, "utf8"));
    // artifacts[] and owns[] carry `path` / `entry`, and both appear again
    // nested under composition.members[]. Walk the whole document and count
    // every path-bearing row rather than hardcoding one level of the schema —
    // the assertion is "non-empty", and a shape change should not silently
    // turn that into "zero".
    let n = 0;
    const walk = (v) => {
      if (Array.isArray(v)) { v.forEach(walk); return; }
      if (v && typeof v === "object") {
        if (typeof v.path === "string" || typeof v.entry === "string") n++;
        Object.values(v).forEach(walk);
      }
    };
    walk(d);
    console.log(n);
  ' 2>/dev/null || echo 0)"
fi
info "arc files reports ${FILES_COUNT} path-bearing row(s); text output $(wc -l < "${FILES_TXT}" 2>/dev/null | tr -d ' ') lines"
assert_cmd A2.2 "arc files ${FACTORY} returns a NON-EMPTY union" \
  test "${FILES_COUNT}" -gt 0

# The union must actually be a UNION — a listing that named only the factory's
# own two files would be non-empty and still wrong. Members are named in the
# per-member `member:` attribution, so their presence is the real check.
# shellcheck disable=SC2016  # JS, not shell — see composition_query
UNION_MEMBERS="$(Q_FILE="${FILES_JSON}" "${BUN}" -e '
  const d = JSON.parse(require("fs").readFileSync(process.env.Q_FILE, "utf8"));
  console.log(((d.composition ?? {}).members ?? []).length);
' 2>/dev/null || echo 0)"
info "arc files attributes the union across ${UNION_MEMBERS} member listing(s)"
assert_cmd A2.3 "the union spans all ${MEMBER_COUNT} members, not just the factory" \
  test "${UNION_MEMBERS}" -eq "${MEMBER_COUNT}"

# ═════════════════════════════════════════════════════════════════════════════
# A3. The key drops actually landed on disk
# ═════════════════════════════════════════════════════════════════════════════
#
# A2 asks arc what it thinks it put down. A3 asks the filesystem. They are
# different questions, and the gap between them is the bug class this catches:
# a package manager that records an install it did not perform.
#
# The list is the epic's Definition of Done, item by item — the things an
# operator would go looking for after `arc install software-factory`.

hdr "A3 — key drops present on disk"

check_drop() {
  # check_drop <id> <path> <what it proves>
  if [ -e "$2" ] || [ -L "$2" ]; then
    pass "$1" "$3 → ${2#"${HERM}"/}"
  else
    fail "$1" "$3 → MISSING: ${2#"${HERM}"/}"
  fi
}

check_drop A3.1 "${HERM}/.claude/skills/Governance"     "compass-core's Governance skill"
check_drop A3.2 "${HERM}/.claude/skills/plan-breakdown" "compass-core's plan-breakdown skill (the reason 0.6.0 is the pin)"
check_drop A3.3 "${HERM}/.claude/skills/code-review"    "the code-review skill"
check_drop A3.4 "${HERM}/bin/discord"                   "the discord CLI shim (ARC_BIN_DIR)"

# ── Where binaries actually land, which is TWO places, not one ──────────────
#
# ARC_BIN_DIR governs generated CLI shims (`provides.cli`) — that is where the
# discord shim above goes. `provides.bin` symlinks go through arc's shimDir
# resolution instead, which prefers ~/.local/bin. cortex uses the latter, so its
# binaries land in ${HERM}/.local/bin even with ARC_BIN_DIR pointed elsewhere.
#
# Both directories are searched, because the assertion is "cortex's binaries are
# on disk", not "arc put them where I guessed". The names found are printed
# rather than named in advance: a cortex release may legitimately add or rename
# one, and a harness that pinned a single filename would fail on a rename and
# call it a reversibility bug.
BIN_DIRS=("${HERM}/bin" "${HERM}/.claude/bin" "${HERM}/.local/bin")
find_cortex_bins() {
  find "${BIN_DIRS[@]}" -maxdepth 1 \( -name 'cortex' -o -name 'cortex-*' \) 2>/dev/null \
    | LC_ALL=C sort || true
}
CORTEX_BINS="$(find_cortex_bins)"
if [ -n "${CORTEX_BINS}" ]; then
  pass A3.5 "cortex binaries shimmed: $(printf '%s' "${CORTEX_BINS}" | sed "s#${HERM}/##" | tr '\n' ' ')"
else
  fail A3.5 "no cortex binary found under $(printf '%s ' "${BIN_DIRS[@]#"${HERM}"/}")"
fi

info "everything under the hermetic \$HOME after install: $( ( cd "${HERM}" && find . -mindepth 1 2>/dev/null | wc -l ) | tr -d ' ') path(s)"

# ═════════════════════════════════════════════════════════════════════════════
# A4. Purge, and arc's own D6 untangle verdict
# ═════════════════════════════════════════════════════════════════════════════
#
# The verdict is arc's conclusion about its own work. It is asserted because a
# silent purge is worse than a loud failure, and because D6 is the design
# commitment this whole epic rests on — but it is NOT the only detector: A5 is
# the harness's independent look at the filesystem, and the two must agree.
#
# NOTE ON EXIT CODES, verified against arc's source (src/commands/purge.ts):
# purge exits 0 even when the verdict reports residue — the verdict is printed,
# not thrown. That is exactly why the verdict line is parsed here rather than
# trusted to the exit code.

hdr "A4 — arc purge ${FACTORY}"

PURGE_LOG="${LOGS}/purge.log"
set +e
arc purge "${FACTORY}" --yes > "${PURGE_LOG}" 2>&1
PURGE_RC=$?
set -e
info "exit ${PURGE_RC}; $(wc -l < "${PURGE_LOG}" | tr -d ' ') lines → ${PURGE_LOG}"
assert A4.1 "arc purge exits 0" "${PURGE_RC}"

# A CRASH is a different failure from a refusal, and conflating them wastes the
# reader's time: a refusal is arc declining to do something, a stack trace is
# arc falling over mid-cascade with the machine in a half-purged state. Named
# separately so the report says which happened.
if grep -qE '^\s+at [a-zA-Z]+ \(.*:[0-9]+:[0-9]+\)$' "${PURGE_LOG}"; then
  fail A4.0 "arc purge CRASHED — an unhandled exception, not a refusal"
  info "the throw and its top frames:"
  grep -m1 -B2 -A8 '^error: ' "${PURGE_LOG}" | sed 's/^/       /' || true
else
  pass A4.0 "arc purge ran to completion without an unhandled exception"
fi

# The literal strings arc emits (src/lib/composition-inventory.ts
# formatInventoryDiff, src/commands/purge.ts):
#   clean  → "  untangle: CLEAN — nothing the install-time inventory named is left on disk"
#   dirty  → "  untangle: N path(s) NOT removed (arc#401 D6):"
#   absent → "  untangle: NOT VERIFIED — no install-time inventory was recorded for '<name>' ..."
# A missing verdict line is its own failure: silence is not a pass.
verdict_is_clean() {
  # verdict_is_clean <file-containing-purge-output>
  grep -q '^  untangle: CLEAN' "$1"
}
VERDICT_LINE="$(grep -m1 '^  untangle:' "${PURGE_LOG}" || true)"
if [ -z "${VERDICT_LINE}" ]; then
  fail A4.2 "arc purge printed NO D6 untangle verdict at all"
else
  info "verdict: ${VERDICT_LINE}"
  assert_cmd A4.2 "the D6 untangle verdict reports CLEAN" verdict_is_clean "${PURGE_LOG}"
fi

# Named user-data refusals are the apt /home guarantee working, not a failure.
# They are reported, and their presence is the reason A5's diff is allowed a
# documented remainder rather than requiring literal emptiness.
REFUSALS="$(grep '^    · verified still present after purge (user data):' "${PURGE_LOG}" || true)"
if [ -n "${REFUSALS}" ]; then
  info "named user-data refusals (kept BY DESIGN):"
  printf '%s\n' "${REFUSALS}" | sed 's/^/     /'
else
  info "no user-data refusals reported"
fi
RETAINED="$(grep '^    · .* retained by design' "${PURGE_LOG}" || true)"
[ -z "${RETAINED}" ] || info "refcount retentions: ${RETAINED}"

# ── The D6 blind spot, surfaced rather than smoothed over ────────────────────
#
# The install-time snapshot D6 verifies against is built from the factory plus
# its recorded composition_members. Packages that arrived through a member's
# `depends_on` cascade are NOT in it: purge REMOVES them (repo, shims, hooks, DB
# row) but never PURGES them, so their own owns.config / owns.state survive —
# and `untangle: CLEAN` can be printed with that state still on disk. arc says
# so itself, both in the report line captured below and in its design doc's
# residual risk (c).
#
# This is exactly the seam arc#410 lives in. The harness prints the notes, and
# lets A5.8's independent filesystem diff be the thing that actually decides:
# if a cascaded dependency left state behind, the diff sees it and the gate goes
# red, whatever the verdict line said.
CASCADE_OWNS="$(grep "^  note: cascaded dependency" "${PURGE_LOG}" || true)"
if [ -n "${CASCADE_OWNS}" ]; then
  info "arc reports cascaded dependencies that declare owns — OUTSIDE D6's reach:"
  printf '%s\n' "${CASCADE_OWNS}" | sed 's/^/     /'
  info "  (their config/state is not covered by the verdict above; A5.8's"
  info "   independent diff is what decides whether any of it survived)"
else
  info "no cascaded dependency declared owns — D6's blind spot is empty this run"
fi

# ═════════════════════════════════════════════════════════════════════════════
# The fault injection — planted here, between the purge and the detector
# ═════════════════════════════════════════════════════════════════════════════
#
# "An e2e gate that has never failed is untrusted." So the gate is made to fail
# on demand, at the exact seam it is supposed to guard: after arc has finished
# and reported clean, a member's leftover state is planted by hand. Every A5
# detector must go red.
#
# WHAT THIS DOES AND DOES NOT PROVE, stated precisely. Planting AFTER the purge
# cannot change arc's D6 verdict — that verdict was computed and printed while
# the file did not exist, and A4 will still (correctly) read CLEAN. What it
# proves is the thing worth proving: that the HARNESS's independent detectors —
# the filesystem diff and the drop-absence checks, which are the only checks
# here that do not take arc's word for anything — actually fire on residue. The
# verdict PARSER is fault-injected separately, below, since its input cannot be
# faked by touching the disk.

if [ "${INJECT_RESIDUE}" -eq 1 ]; then
  hdr "FAULT INJECTION — planting residue the purge did not leave"
  mkdir -p "${HERM}/.claude/skills/Governance"
  printf 'planted by --inject-residue; simulates a member leaving state behind\n' \
    > "${HERM}/.claude/skills/Governance/LEFTOVER.md"
  mkdir -p "${HERM}/.config/metafactory/cortex"
  printf 'planted by --inject-residue\n' > "${HERM}/.config/metafactory/cortex/orphan-state.yaml"
  info "planted .claude/skills/Governance/LEFTOVER.md"
  info "planted .config/metafactory/cortex/orphan-state.yaml"
  info "A5.* MUST now report RED. A green run here means the detector is blind."

  # And the verdict parser, whose input lives in arc's stdout rather than on
  # disk: feed it a real dirty-verdict rendering and require it to refuse.
  SYNTH="${LOGS}/synthetic-dirty-verdict.txt"
  printf '  untangle: 2 path(s) NOT removed (arc#401 D6):\n    ✗ cortex [file] /x/y\n' > "${SYNTH}"
  if verdict_is_clean "${SYNTH}"; then
    fail A4.2i "verdict parser accepted a DIRTY verdict as clean — the parser is blind"
  else
    pass A4.2i "verdict parser correctly refuses a dirty verdict (injected)"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# A5. Post-purge: nothing installed, no drops, empty diff
# ═════════════════════════════════════════════════════════════════════════════

hdr "A5 — post-purge state"

LIST_AFTER="${LOGS}/list-after-purge.txt"
LIST_AFTER_JSON="${LOGS}/list-after-purge.json"
set +e
arc list > "${LIST_AFTER}" 2>&1
arc list --json > "${LIST_AFTER_JSON}" 2>/dev/null
set -e
info "arc list says: $(head -1 "${LIST_AFTER}")"

# arc's own empty-state string (src/commands/list.ts formatList).
assert_cmd A5.1 "arc list reports no packages installed" \
  grep -q '^No packages installed\.' "${LIST_AFTER}"

REMAINING_PKGS="$(composition_query "${LIST_AFTER_JSON}" pkgcount 2>/dev/null || echo '?')"
if [ "${REMAINING_PKGS}" = "0" ]; then
  pass A5.2 "arc list --json records 0 packages (was ${PKG_COUNT}) — the whole cascade went too"
else
  fail A5.2 "arc list --json still records ${REMAINING_PKGS} package(s) (was ${PKG_COUNT})"
fi

# The drops, checked in the negative. Same paths as A3, opposite expectation.
check_gone() {
  if [ -e "$2" ] || [ -L "$2" ]; then
    fail "$1" "$3 STILL PRESENT: ${2#"${HERM}"/}"
  else
    pass "$1" "$3 removed"
  fi
}
check_gone A5.3 "${HERM}/.claude/skills/Governance"     "Governance skill"
check_gone A5.4 "${HERM}/.claude/skills/plan-breakdown" "plan-breakdown skill"
check_gone A5.5 "${HERM}/.claude/skills/code-review"    "code-review skill"
check_gone A5.6 "${HERM}/bin/discord"                   "discord CLI shim"

CORTEX_BINS_AFTER="$(find_cortex_bins)"
assert_cmd A5.7 "no cortex binary left behind" test -z "${CORTEX_BINS_AFTER}"
[ -z "${CORTEX_BINS_AFTER}" ] || printf '%s\n' "${CORTEX_BINS_AFTER}" | sed 's/^/       /'

# ── The independent filesystem diff ──────────────────────────────────────────

POST_SNAP="${LOGS}/post-purge.txt"
snapshot "${POST_SNAP}"

PRE_FILTERED="${LOGS}/pre-install.filtered.txt"
POST_FILTERED="${LOGS}/post-purge.filtered.txt"
filter_excluded "${PRE_SNAP}"  > "${PRE_FILTERED}"
filter_excluded "${POST_SNAP}" > "${POST_FILTERED}"

DIFF_FILE="${LOGS}/filesystem.diff"
diff -u "${PRE_FILTERED}" "${POST_FILTERED}" > "${DIFF_FILE}" 2>&1 || true
# Only ADDED lines matter: a path that existed before install and is gone after
# purge would be a different (and worse) bug, but it is still a difference, so
# both directions are reported and both fail.
ADDED="$(grep -c '^+\./' "${DIFF_FILE}" || true)"
REMOVED="$(grep -c '^-\./' "${DIFF_FILE}" || true)"

info "post-purge diff vs pre-install: ${ADDED} added, ${REMOVED} removed (excluding arc's own state root)"

# The exclusion, accounted for rather than assumed. It is a cache tree with tens
# of thousands of entries, so printing it verbatim would bury the report — the
# count and the top-level shape are what a reader needs to confirm nothing but a
# cache is hiding in there, and the full listing is one file away.
EXCLUDED_FILE="${LOGS}/excluded-survivors.txt"
only_excluded "${POST_SNAP}" > "${EXCLUDED_FILE}"
EXCLUDED_COUNT="$(grep -c . "${EXCLUDED_FILE}" || true)"
info "EXCLUDED from the diff: ${EXCLUDED_COUNT} path(s) under XDG_CACHE_HOME —"
info "  discardable by definition (bun's transpiler cache, which is the measuring"
info "  instrument's own trace, and bun's shared package cache). Full list:"
info "  ${EXCLUDED_FILE}. Top-level shape, so nothing else can hide in there:"
cut -d/ -f1-3 "${EXCLUDED_FILE}" | LC_ALL=C sort | uniq -c \
  | LC_ALL=C sort -rn > "${LOGS}/excluded-shape.txt" || true
while IFS= read -r line; do info "       ${line}"; done < <(head -8 "${LOGS}/excluded-shape.txt")

# Materialise the two sides of the diff as files rather than piping a long
# producer into `head` — a `grep | head` over a 17k-line diff kills grep with
# SIGPIPE, and under `set -e` that took the whole harness down mid-report.
RESIDUE_ALL="${LOGS}/residue-all.txt"
VANISHED="${LOGS}/vanished.txt"
grep '^+\./' "${DIFF_FILE}" | sed 's/^+//' > "${RESIDUE_ALL}" || true
grep '^-\./' "${DIFF_FILE}" | sed 's/^-//' > "${VANISHED}" || true

# ── A5.8 — the DoD, asserted strictly and reported whatever it says ─────────
#
# The epic's Definition of Done is an EMPTY diff. This assertion is that
# sentence and nothing else. It is kept even while it is red, because the moment
# a gate's headline assertion is softened to match today's behaviour, the gate
# stops being a statement about the goal and becomes a statement about the
# status quo.
if [ "${ADDED}" -eq 0 ] && [ "${REMOVED}" -eq 0 ]; then
  pass A5.8 "DoD — filesystem diff vs pre-install is EMPTY"
else
  fail A5.8 "DoD — filesystem diff is NOT empty: ${ADDED} added, ${REMOVED} removed"
fi

# ── A5.9 — the regression gate, against an itemised, reviewed baseline ──────
#
# A5.8 alone would be a permanently red light, and a permanently red light gets
# unplugged. A5.9 is the question CI can usefully answer every day: is there
# anything here that we have not already looked at, named, and assigned an
# owner? Its baseline is a checked-in file, one path per line with a reason —
# reviewable in a diff, and shrinking it is the visible measure of progress
# toward A5.8.
#
# The two together are the honest arrangement: A5.9 governs the exit code so the
# gate is usable, A5.8 governs the headline so the gap can never be forgotten.
# `--strict` swaps that, for the run that proves the DoD is finally met.
BASELINE_PATHS="${LOGS}/baseline-paths.txt"
if [ -f "${RESIDUE_BASELINE}" ]; then
  sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "${RESIDUE_BASELINE}" \
    | grep -v '^$' | LC_ALL=C sort > "${BASELINE_PATHS}"
  info "baseline: $(grep -c . "${BASELINE_PATHS}" || true) known path(s) from ${RESIDUE_BASELINE#"${REPO_ROOT}"/}"
else
  : > "${BASELINE_PATHS}"
  info "baseline: none (${RESIDUE_BASELINE#"${REPO_ROOT}"/} absent) — every surviving path counts as new"
fi

NEW_RESIDUE="${LOGS}/residue-new.txt"
LC_ALL=C sort "${RESIDUE_ALL}" > "${RESIDUE_ALL}.sorted"
comm -23 "${RESIDUE_ALL}.sorted" "${BASELINE_PATHS}" > "${NEW_RESIDUE}"
NEW_COUNT="$(grep -c . "${NEW_RESIDUE}" || true)"

if [ "${NEW_COUNT}" -eq 0 ] && [ "${REMOVED}" -eq 0 ]; then
  pass A5.9 "no residue beyond the reviewed baseline, and nothing vanished"
else
  fail A5.9 "${NEW_COUNT} path(s) survived that are NOT in the reviewed baseline"
  info "unbaselined residue:"
  head -60 "${NEW_RESIDUE}" | sed 's/^/       /'
  [ "${NEW_COUNT}" -le 60 ] || info "       … and $((NEW_COUNT - 60)) more (full list: ${NEW_RESIDUE})"
  if [ "${REMOVED}" -gt 0 ]; then
    info "vanished (present before install, gone after purge — a worse bug than residue):"
    head -20 "${VANISHED}" | sed 's/^/       /'
  fi
fi

# A baseline that lists paths which no longer survive is a baseline rotting in
# the permissive direction: it would keep excusing a path long after the fix
# landed, and hide the next regression that reintroduces it. Stale entries do
# not fail the gate — they are not a defect in the factory — but they are said
# out loud so the file gets trimmed.
STALE="$(comm -13 "${RESIDUE_ALL}.sorted" "${BASELINE_PATHS}")"
if [ -n "${STALE}" ]; then
  info "STALE baseline entries (no longer survive the purge — delete them from"
  info "  ${RESIDUE_BASELINE#"${REPO_ROOT}"/}, they are now excusing nothing):"
  printf '%s\n' "${STALE}" | sed 's/^/       /'
fi

# ═════════════════════════════════════════════════════════════════════════════
# A6. The real machine, and the live service manager, untouched
# ═════════════════════════════════════════════════════════════════════════════

hdr "A6 — real \$HOME and live service manager untouched"

HOST_AFTER="${LOGS}/host-after.txt"
fingerprint_host "${HOST_AFTER}"

HOST_DIFF="${LOGS}/host.diff"
diff -u "${HOST_BEFORE}" "${HOST_AFTER}" > "${HOST_DIFF}" 2>&1 || true
HOST_CHANGES="$(grep -c '^[+-][^+-]' "${HOST_DIFF}" || true)"

if [ "${HOST_CHANGES}" -eq 0 ]; then
  pass A6.1 "real \$HOME unchanged: quiet service dirs byte-identical, no composition artifact appeared"
else
  fail A6.1 "real \$HOME fingerprint CHANGED (${HOST_CHANGES} line(s)) — containment leaked"
  while IFS= read -r line; do info "  ${line}"; done < <(head -60 "${HOST_DIFF}")
fi

# The service table is inside the fingerprint, but it gets its own assertion:
# it is the launchctl hazard's specific witness, and burying it in a general
# "something changed" would lose the one finding this harness exists to rule out.
SVC_BEFORE="${LOGS}/services-before.txt"
SVC_AFTER="${LOGS}/services-after.txt"
awk '/^### SERVICES$/{f=1;next} f' "${HOST_BEFORE}" > "${SVC_BEFORE}"
awk '/^### SERVICES$/{f=1;next} f' "${HOST_AFTER}"  > "${SVC_AFTER}"
if diff -q "${SVC_BEFORE}" "${SVC_AFTER}" >/dev/null 2>&1; then
  pass A6.2 "no ecosystem launchd/systemd job changed ($(grep -c . "${SVC_BEFORE}" || true) matching /${SERVICE_LABEL_RE}/)"
else
  fail A6.2 "an ECOSYSTEM service job changed — a member reached the real session"
  diff -u "${SVC_BEFORE}" "${SVC_AFTER}" > "${LOGS}/services.diff" 2>&1 || true
  while IFS= read -r line; do info "  ${line}"; done < <(head -30 "${LOGS}/services.diff")
fi
# Informational only: how much the WHOLE table moved. macOS starts and stops
# on-demand agents constantly, so a non-zero number here is normal and decides
# nothing — it is printed so the filtered assertion above is not mistaken for a
# claim that the entire session was frozen.
RAW_DELTA="$(diff "${HOST_BEFORE}.services-raw" "${HOST_AFTER}.services-raw" 2>/dev/null | grep -c '^[<>]' || true)"
info "whole-session service table moved by ${RAW_DELTA} line(s) (macOS on-demand agents; not asserted on)"

# The stub log. On a clean run this is empty, which is the finding: cortex's
# postinstall never reached its renderer because the hermetic config dir is
# stackless. A non-empty log is not necessarily damage — the stub absorbed the
# call — but it means the containment argument above is wrong and needs redoing.
STUB_CALLS="$(grep -c . "${STUB_LOG}" || true)"
if [ "${STUB_CALLS}" -eq 0 ]; then
  pass A6.3 "no launchctl/systemctl call was attempted"
else
  fail A6.3 "${STUB_CALLS} service-manager call(s) attempted — the stub absorbed them, and it had to"
  while IFS= read -r line; do info "  ${line}"; done < "${STUB_LOG}"
fi

# ── A6.4 — the assertion that is never waived ───────────────────────────────
#
# A6.3 records THAT a call happened. A6.4 asks the question that decides whether
# the harness is dangerous: did any of it name a path outside the workspace?
#
# Read the observed call before deciding this is paranoid (it comes from
# cortex's scripts.purge hook — see scripts/known-failures.txt, A6.3):
#
#   launchctl bootout gui/501 <WORKDIR>/home/Library/LaunchAgents/ai.meta-factory.cortex.relay.plist
#
# The PATH is hermetic. The DOMAIN is not — `gui/<uid>` is the operator's real
# Aqua session, and `bootout` resolves the service by the Label read out of that
# plist, not by where the file sits. The label in cortex's relay plist is
# `ai.meta-factory.cortex.relay`, which on this machine is a LIVE job. A
# hermetic path therefore buys nothing on its own: without the stub first on
# PATH, that call would have unloaded the operator's running relay.
#
# So A6.4 is not the safety property — the stub is, and A6.1/A6.2 are its
# evidence. A6.4 is the tripwire for the strictly worse case: a call naming a
# REAL $HOME path, which would mean containment failed before launchd was even
# reached. It is gating in every mode and appears in no waiver file.
ESCAPES="${LOGS}/stub-calls-outside-workspace.txt"
escaping_calls "${STUB_LOG}" "${REAL_HOME}" "${WORKDIR}" "${WORKDIR_REAL}" > "${ESCAPES}"
ESCAPE_COUNT="$(grep -c . "${ESCAPES}" || true)"

if [ "${STUB_CALLS}" -eq 0 ]; then
  pass A6.4 "no call to check (none attempted)"
elif [ "${ESCAPE_COUNT}" -gt 0 ]; then
  fail A6.4 "a service-manager call named a path in the REAL \$HOME, outside the workspace — containment failed upstream of launchd"
  info "offending path token(s):"
  while IFS= read -r line; do info "  ${line}"; done < "${ESCAPES}"
else
  pass A6.4 "every intercepted call named only workspace paths (the stub, not the path, is what kept the real session safe)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# The stub's own fault injection — prove the last line of defence bites
# ═════════════════════════════════════════════════════════════════════════════
#
# A6.3 passes on a clean run by finding an EMPTY log, which is exactly the shape
# of a detector that could be broken and never noticed: an unwritable log, a
# stub not on PATH, a typo in the filename would all produce the same green. So
# --check-stub deliberately invokes launchctl through the hermetic PATH and
# requires both that the stub recorded it and that A6.3's rule flags it.

if [ "${CHECK_STUB}" -eq 1 ]; then
  hdr "STUB CHECK — invoking launchctl deliberately through the hermetic PATH"
  BEFORE_N="$(grep -c . "${STUB_LOG}" || true)"
  # The arguments are a realistic bootout of a job that does not exist, aimed at
  # THIS uid's GUI domain — i.e. the shape of the call cortex's plist renderer
  # would make. It never reaches the real launchctl: the stub shadows it.
  # shellcheck disable=SC2030,SC2031  # the subshell IS the scoping
  ( export PATH="${STUBS}:${PATH}"
    launchctl bootout "gui/$(id -u)" /nonexistent-e2e-probe.plist ) || true
  AFTER_N="$(grep -c . "${STUB_LOG}" || true)"
  if [ "${AFTER_N}" -gt "${BEFORE_N}" ]; then
    pass S1 "the stub intercepted and logged the call ($(tail -1 "${STUB_LOG}"))"
  else
    fail S1 "launchctl was invoked but the stub logged NOTHING — the stub is not on PATH or the log is unwritable"
  fi
  # And the rule A6.3 applies, re-evaluated against the now-dirty log.
  if [ "${AFTER_N}" -eq 0 ]; then
    fail S2 "A6.3's rule would still report green over a dirty log — the rule is blind"
  else
    pass S2 "A6.3's rule flags the dirty log (${AFTER_N} call(s) recorded)"
  fi
  info "note: this deliberately dirties the log, so A6.3 above is the CLEAN-run"
  info "      reading and S1/S2 are the injected reading. Run without --check-stub"
  info "      for the gate."
fi

# ═════════════════════════════════════════════════════════════════════════════
# Verdict
# ═════════════════════════════════════════════════════════════════════════════

hdr "Result"
say "   arc:         ${ARC_SHA} (${ARC_REF})"
say "   composition: ${FACTORY} v${FACTORY_VERSION}, ${MEMBER_COUNT} declared members, ${PKG_COUNT} packages recorded"
say "   logs:        ${LOGS}"
say ""

# ── WHICH FAILURES DECIDE THE EXIT CODE ──────────────────────────────────────
#
# An assertion listed in scripts/known-failures.txt is REPORTED but does not
# gate. That file carries, per assertion, what is broken, who owns it, and why
# the rest of the run is still meaningful without it.
#
# The reasoning, since waiving assertions is exactly how gates rot: this harness
# tests a composition of five independently-released packages, and it found real
# defects in two of them on its first honest run. If every one of those makes
# the light red forever, the light gets ignored, and the next defect — the one
# nobody has looked at — arrives invisible. The waiver file is the difference
# between "known and owned" and "unknown". It is reviewed in a diff, it should
# only ever shrink, and `--strict` ignores it entirely.
#
# A6.4 is deliberately un-waivable and is refused if it appears in the file.
WAIVED_IDS=""
if [ -f "${WAIVERS}" ] && [ "${STRICT}" -eq 0 ]; then
  WAIVED_IDS="$(sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "${WAIVERS}" | grep -v '^$' || true)"
fi

WAIVED_FAILURES=0
GATING_FAILURES=0
WAIVED_LIST=()
GATING_LIST=()
for f in ${FAILURES[@]+"${FAILURES[@]}"}; do
  id="${f%%:*}"
  if printf '%s\n' "${WAIVED_IDS}" | grep -qx "${id}"; then
    WAIVED_FAILURES=$((WAIVED_FAILURES + 1)); WAIVED_LIST+=("${f}")
  else
    GATING_FAILURES=$((GATING_FAILURES + 1)); GATING_LIST+=("${f}")
  fi
done

if [ "${FAIL_COUNT}" -gt 0 ]; then
  say "   ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
  if [ "${GATING_FAILURES}" -gt 0 ]; then
    say ""
    say "   GATING failures — these turn the light red:"
    for f in ${GATING_LIST[@]+"${GATING_LIST[@]}"}; do say "        ${f}"; done
  fi
  if [ "${WAIVED_FAILURES}" -gt 0 ]; then
    say ""
    say "   KNOWN failures — waived by ${WAIVERS#"${REPO_ROOT}"/}, each with an owner"
    say "   and a reason in that file. They are still broken; they are just not news:"
    for f in ${WAIVED_LIST[@]+"${WAIVED_LIST[@]}"}; do say "        ${f}"; done
    say ""
    say "   ⚠️  This run is NOT proof that the epic is done. It is proof that nothing"
    say "      got worse. Shrink ${WAIVERS#"${REPO_ROOT}"/} and"
    say "      ${RESIDUE_BASELINE#"${REPO_ROOT}"/} to nothing, then run --strict:"
    say "      that run, and only that run, is the epic's acceptance test passing."
  fi
  say ""
fi

# ── The injection modes: red is the pass, and it must be the RIGHT red ───────
#
# Both modes are asked about SPECIFIC assertions, never about "did anything
# fail". The distinction matters more than it looks: while the environment is
# red for unrelated reasons — as it is today, with arc's purge crashing — a
# "some gating assertion fired" test passes without the injection having been
# detected at all. That is a detector proof that proves nothing, in exactly the
# circumstances where you most need it to mean something.
failed_id() {
  local entry
  for entry in ${FAILURES[@]+"${FAILURES[@]}"}; do
    if [ "${entry%%:*}" = "$1" ]; then return 0; fi
  done
  return 1
}

if [ "${INJECT_RESIDUE}" -eq 1 ]; then
  # The planted files are a leftover Governance skill (which A5.3 checks by
  # name) and an orphaned cortex state file (which only the independent
  # filesystem diff, A5.9, can see). Both must fire.
  MISSED=""
  failed_id A5.3 || MISSED="${MISSED}A5.3 (drop-absence check) "
  failed_id A5.9 || MISSED="${MISSED}A5.9 (independent filesystem diff) "
  if [ -n "${MISSED}" ]; then
    say "   ❌ INJECTION FAILED — residue was planted and these detectors did NOT fire:"
    say "        ${MISSED}"
    say "      Fix the harness before trusting any green run from it."
    exit 1
  fi
  say "   ✅ INJECTION OBSERVED RED — A5.3 and A5.9 both fired on planted residue."
  say "      The detectors are not decorative."
  exit 0
fi

if [ "${CHECK_STUB}" -eq 1 ]; then
  # Governed by S1/S2 alone, for the same reason: this mode asks one question —
  # does the launchctl interceptor still bite? — and the answer must not be
  # coloured by whatever else is broken in the composition today.
  if failed_id S1 || failed_id S2; then
    say "   ❌ STUB CHECK FAILED — launchctl was invoked through the hermetic PATH and"
    say "      the interceptor did not record it. The stub is the only thing standing"
    say "      between this harness and the operator's live launchd session."
    exit 1
  fi
  say "   ✅ STUB CHECK PASSED — the interceptor logged the call and A6.3's rule flagged it."
  say "      (The gate's own result is not judged in this mode; run without --check-stub.)"
  exit 0
fi

if [ "${GATING_FAILURES}" -eq 0 ]; then
  if [ "${WAIVED_FAILURES}" -gt 0 ]; then
    say "   ✅ GREEN — no regression. ${WAIVED_FAILURES} known failure(s) still open (above)."
  else
    say "   ✅ GREEN — ${PASS_COUNT} assertion(s) passed, nothing waived, nothing baselined."
  fi
  exit 0
fi

say "   ❌ RED — ${GATING_FAILURES} gating failure(s)."
exit 1
