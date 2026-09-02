#!/usr/bin/env bash
#
# check-baseline-shrink.sh — the baseline files may only ever SHRINK.
#
# scripts/known-residue.txt and scripts/known-failures.txt are waivers: one
# excuses paths that survive a purge, the other excuses failing assertions.
# Their entire value rests on the promise that they get smaller over time.
# Nothing but this check enforces that promise, and the pressure to add a line
# is highest exactly when someone is trying to turn a red build green.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE RULE, AND THE BUG THAT MADE IT NECESSARY TO WRITE DOWN
# ─────────────────────────────────────────────────────────────────────────────
#
# A baseline file that does NOT EXIST at the comparison base is being
# INTRODUCED. Every line in it is "new" in the diff sense, and that is not
# growth — it is the file's first appearance, and the review that introduced it
# is its review. Enforcing shrink-only against a base that has no file to shrink
# from is enforcing "this file may not be created".
#
# That is not hypothetical. The first version of this check lived inline in the
# workflow without the rule, and on the squash-merge to main it compared against
# a parent commit predating the files, read all 40 entries as additions, and
# failed. Because it sat BEFORE the E2E step, the failure skipped the gate
# entirely — the harness never ran on main. A guard that silently disables the
# thing it guards is worse than no guard. Hence both the rule below and the step
# ordering in the workflow.
#
# So: compare against the base version of a file ONLY when the file exists
# there. Otherwise report it as introduced and move on.
#
# ─────────────────────────────────────────────────────────────────────────────
# USAGE
# ─────────────────────────────────────────────────────────────────────────────
#
#   check-baseline-shrink.sh [--base <ref>] [--allow-growth] [file...]
#   check-baseline-shrink.sh --self-test
#
#   --base <ref>     what to compare against. Default: HEAD's FIRST PARENT.
#                    On a push that is the previous commit on the branch; on a
#                    pull_request checkout (a merge commit whose first parent is
#                    the base branch) it is the base. The workflow passes the
#                    event's base sha explicitly for pull_request rather than
#                    relying on that second property.
#   --allow-growth   report additions but exit 0. The workflow sets this from a
#                    PR label, so admitting a new gap is possible but must be
#                    deliberate and visible in review.
#   --self-test      run the check against synthetic git history and verify it
#                    gives the right answer in each case. Needs no network and
#                    touches nothing outside a temp dir.
#
# Exit: 0 clean (or growth explicitly allowed) · 1 a baseline grew · 2 the check
# could not run (bad ref, not a git repo).

set -euo pipefail

DEFAULT_FILES=(scripts/known-residue.txt scripts/known-failures.txt)

BASE=""
ALLOW_GROWTH=0
SELF_TEST=0
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --base)         shift; BASE="${1:?--base needs a ref}" ;;
    --allow-growth) ALLOW_GROWTH=1 ;;
    --self-test)    SELF_TEST=1 ;;
    -h|--help)      awk 'NR>1 && /^set -euo pipefail$/{exit} NR>1' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)             printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)              FILES+=("$1") ;;
  esac
  shift
done
[ "${#FILES[@]}" -gt 0 ] || FILES=("${DEFAULT_FILES[@]}")

# The EFFECTIVE entries: comments and blank lines removed, sorted. Comparing
# these rather than raw lines means rewording a reason — which is encouraged,
# since the reasons are the point of the files — never trips the check.
entries() {
  sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' | grep -v '^$' | LC_ALL=C sort || true
}

# ── The check ────────────────────────────────────────────────────────────────

check_baselines() {
  # check_baselines <base-ref> <file...>  → 0 clean, 1 grew
  local base="$1"; shift
  local grew=0 f added removed tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand tmp now: it is what we want removed
  trap "rm -rf '${tmp}'" RETURN

  for f in "$@"; do
    if [ ! -f "${f}" ]; then
      printf '  %s: absent at HEAD — nothing to check\n' "${f}"
      continue
    fi
    # THE RULE. `git cat-file -e` asks "does this path exist at that commit"
    # without materialising it, and without confusing "empty file" for "no file".
    if ! git cat-file -e "${base}:${f}" 2>/dev/null; then
      printf '  %s: INTRODUCED at this change (absent at %s) — reviewed as a whole, not compared\n' \
        "${f}" "${base:0:8}"
      continue
    fi
    git show "${base}:${f}" | entries > "${tmp}/base"
    entries < "${f}" > "${tmp}/head"
    added="$(comm -13 "${tmp}/base" "${tmp}/head")"
    removed="$(comm -23 "${tmp}/base" "${tmp}/head")"

    if [ -n "${removed}" ]; then
      printf '  %s: %d entr(ies) REMOVED — the direction this file is supposed to move:\n' \
        "${f}" "$(printf '%s\n' "${removed}" | grep -c .)"
      printf '%s\n' "${removed}" | sed 's/^/      - /'
    fi
    if [ -n "${added}" ]; then
      grew=1
      printf '::error file=%s::%s gained %d entr(ies) — a baseline may only shrink\n' \
        "${f}" "${f}" "$(printf '%s\n' "${added}" | grep -c .)"
      printf '%s\n' "${added}" | sed 's/^/      + /'
    fi
    [ -z "${removed}${added}" ] && printf '  %s: unchanged\n' "${f}"
  done
  return "${grew}"
}

# ── Self-test ────────────────────────────────────────────────────────────────
#
# The guard is the thing standing between "the waivers shrink" and "the waivers
# are wherever they drifted to", and its first version shipped with a bug that
# disabled the whole gate. So it gets the same treatment every other detector in
# this repo gets: cases with known answers, run on every CI pass.

self_test() {
  local dir pass=0 fail=0
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${dir}'" RETURN

  ( cd "${dir}"
    git init -q .
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    mkdir -p scripts
  )

  # case <name> <expected 0|1> <base-setup-fn> <head-setup-fn>
  run_case() {
    local name="$1" want="$2" basecontent="$3" headcontent="$4" got
    ( cd "${dir}"
      rm -f scripts/known-residue.txt
      git rm -q --cached -r . >/dev/null 2>&1 || true
      # base commit
      if [ "${basecontent}" != "__ABSENT__" ]; then
        printf '%s\n' "${basecontent}" > scripts/known-residue.txt
        git add -A
      else
        printf 'placeholder\n' > README.md; git add -A
      fi
      git commit -qm base --allow-empty
      # head commit
      if [ "${headcontent}" != "__ABSENT__" ]; then
        printf '%s\n' "${headcontent}" > scripts/known-residue.txt
      else
        rm -f scripts/known-residue.txt
      fi
      git add -A; git commit -qm head --allow-empty
    )
    set +e
    ( cd "${dir}" && check_baselines "HEAD^1" scripts/known-residue.txt ) >/dev/null 2>&1
    got=$?
    set -e
    if [ "${got}" -eq "${want}" ]; then
      pass=$((pass + 1)); printf '  ✅ %-58s exit %d\n' "${name}" "${got}"
    else
      fail=$((fail + 1)); printf '  ❌ %-58s exit %d, wanted %d\n' "${name}" "${got}" "${want}"
    fi
  }

  printf '\n══ SELF-TEST — the shrink-only guard\n'
  # THE REGRESSION GUARD for the bug that skipped the gate on main.
  run_case "file ABSENT at base (introduced) → clean" 0 "__ABSENT__" "./a"$'\n'"./b"
  run_case "entry removed (shrink) → clean"           0 "./a"$'\n'"./b" "./a"
  run_case "entry added (growth) → FAIL"              1 "./a" "./a"$'\n'"./b"
  run_case "unchanged → clean"                        0 "./a" "./a"
  run_case "only a comment reworded → clean"          0 "./a" "./a"$'\n'"# a new reason"
  run_case "file absent at base AND head → clean"     0 "__ABSENT__" "__ABSENT__"

  printf '\n'
  if [ "${fail}" -eq 0 ]; then
    printf '  ✅ GUARD SOUND — %d case(s) correct.\n' "${pass}"
    return 0
  fi
  printf '  ❌ GUARD BROKEN — %d case(s) wrong.\n' "${fail}"
  return 1
}

# ── Main ─────────────────────────────────────────────────────────────────────

if [ "${SELF_TEST}" -eq 1 ]; then
  self_test
  exit $?
fi

git rev-parse --git-dir >/dev/null 2>&1 || { printf 'not a git repository\n' >&2; exit 2; }

if [ -z "${BASE}" ]; then
  # First parent. On a push that is the previous commit on the branch; on a
  # pull_request checkout it is the base branch tip. A root commit has no
  # parent — there is nothing to have shrunk from, so there is nothing to check.
  if ! BASE="$(git rev-parse --verify --quiet 'HEAD^1')"; then
    printf 'HEAD has no first parent (root commit) — nothing to compare against.\n'
    exit 0
  fi
fi

if ! git cat-file -e "${BASE}^{commit}" 2>/dev/null; then
  printf 'base commit %s is not available in this checkout — skipping rather than guessing.\n' "${BASE}"
  exit 0
fi

printf 'Comparing baselines against %s\n' "${BASE:0:8}"
set +e
check_baselines "${BASE}" "${FILES[@]}"
GREW=$?
set -e

if [ "${GREW}" -eq 0 ]; then
  printf 'OK: no baseline grew.\n'
  exit 0
fi
if [ "${ALLOW_GROWTH}" -eq 1 ]; then
  printf '::warning::A baseline grew; allowed explicitly (the growth override is set).\n'
  exit 0
fi
printf '::error::A baseline gained entries. If this is intended and reviewed, apply the '\''baseline-growth'\'' label.\n'
exit 1
