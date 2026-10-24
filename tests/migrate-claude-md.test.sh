#!/usr/bin/env bash
# migrate-claude-md.test.sh — scripts/migrate-global-claude-md.{sh,ps1} (REQ-013, EDGE-006).
# Fixture: a copy of the owner's ~/.claude/CLAUDE.md when it still holds the framework
# block, else a synthetic file built from the bundled v5.1.0 reference plus a
# "Claude Code System Guidelines" section. The real file is only ever read.
# The .sh script always runs; the .ps1 runs through pwsh -NoProfile -File when pwsh exists.
# Usage: bash tests/migrate-claude-md.test.sh   (exit 0 = all pass)

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_REPO="$(cd "$TEST_DIR/.." && pwd)"
SH_SCRIPT="$SRC_REPO/scripts/migrate-global-claude-md.sh"
PS_SCRIPT="$SRC_REPO/scripts/migrate-global-claude-md.ps1"
REF="$SRC_REPO/scripts/legacy-policy/claude-md-v5.1.0.md"
TITLE='# Claude Code CLI - Agent Execution Framework'
GUIDE='# Claude Code System Guidelines'

TESTS_RUN=0
TESTS_PASS=0
TESTS_FAIL=0

HARNESS_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/migrate-test.XXXXXXXX") || exit 1
trap 'cd / 2>/dev/null || true; rm -rf "$HARNESS_ROOT"' EXIT INT TERM

assert() { # name condition-exit-status
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" -eq 0 ]; then
    TESTS_PASS=$((TESTS_PASS + 1)); printf 'PASS %s\n' "$1"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1)); printf 'FAIL %s\n' "$1"
  fi
}
assert_eq() { # name expected actual
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" = "$3" ]; then
    TESTS_PASS=$((TESTS_PASS + 1)); printf 'PASS %s\n' "$1"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1)); printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3"
  fi
}

# --- fixture -------------------------------------------------------------------
GLOBAL_REAL="${HOME:-}/.claude/CLAUDE.md"
FIXTURE="$HARNESS_ROOT/fixture-CLAUDE.md"
if [ -f "$GLOBAL_REAL" ] && grep -q -x -F -- "$TITLE" "$GLOBAL_REAL" && grep -q -x -F -- "$GUIDE" "$GLOBAL_REAL"; then
  cp "$GLOBAL_REAL" "$FIXTURE"
  echo "fixture: copy of $GLOBAL_REAL"
else
  {
    cat "$REF"
    printf '\n---\n\n%s\n\n## Behavior & Tone\n- Blunt.\n\n## Epistemics (overrides everything above)\n- Label claims.\n\n## Response Formatting\n- Lead with the answer.\n' "$GUIDE"
  } > "$FIXTURE"
  echo "fixture: synthetic (v5.1.0 reference + guidelines section)"
fi
GUIDE_LINE=$(grep -n -x -F -- "$GUIDE" "$FIXTURE" | head -n 1 | cut -d: -f1)

# Per-implementation runner. $1 = impl (sh|ps), rest = flags; PATH_ARG is set by the caller.
HAVE_PWSH=0
command -v pwsh >/dev/null 2>&1 && HAVE_PWSH=1
to_native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

OUT=""
RC=0
mig() { # impl path [dry]
  _impl=$1; _path=$2; _dry=${3:-}
  if [ "$_impl" = sh ]; then
    if [ -n "$_dry" ]; then OUT=$(sh "$SH_SCRIPT" --dry-run "$_path" 2>&1); else OUT=$(sh "$SH_SCRIPT" "$_path" 2>&1); fi
  else
    _np=$(to_native "$_path")
    if [ -n "$_dry" ]; then OUT=$(pwsh -NoProfile -File "$(to_native "$PS_SCRIPT")" -Path "$_np" -DryRun 2>&1); else OUT=$(pwsh -NoProfile -File "$(to_native "$PS_SCRIPT")" -Path "$_np" 2>&1); fi
  fi
  RC=$?
  OUT=$(printf '%s' "$OUT" | tr -d '\r')
}
backups() { ls "$1"/CLAUDE.md.bak-* 2>/dev/null | wc -l | tr -d ' '; }

run_suite() { # impl
  impl=$1
  d="$HARNESS_ROOT/$impl"; rm -rf "$d"; mkdir -p "$d"
  cp "$FIXTURE" "$d/CLAUDE.md"
  echo "--- $impl ---"

  # 1. dry run: prints the block lines, changes nothing
  mig "$impl" "$d/CLAUDE.md" dry
  assert_eq "$impl dry-run exits 0" 0 "$RC"
  printf '%s' "$OUT" | grep -q -F -- 'AGENT EXECUTION CONTEXT'; assert "$impl dry-run prints block lines" $?
  printf '%s' "$OUT" | grep -q -F -- 'Behavior & Tone'; r=$?; assert_eq "$impl dry-run does not print the guidelines section" 1 "$r"
  cmp -s "$FIXTURE" "$d/CLAUDE.md"; assert "$impl dry-run leaves the file byte-identical" $?
  assert_eq "$impl dry-run writes no backup" 0 "$(backups "$d")"

  # 2. real run
  mig "$impl" "$d/CLAUDE.md"
  assert_eq "$impl real run exits 0" 0 "$RC"
  grep -c 'AGENT EXECUTION CONTEXT' "$d/CLAUDE.md" | grep -q '^0$'; assert "$impl block gone (AGENT EXECUTION CONTEXT count 0)" $?
  grep -q -x -F -- "$GUIDE" "$d/CLAUDE.md"; assert "$impl keeps the System Guidelines heading" $?
  for sec in 'Behavior & Tone' 'Epistemics' 'Response Formatting'; do
    grep -q -- "^## $sec" "$d/CLAUDE.md"; assert "$impl keeps subsection $sec" $?
  done
  tail -n "+$GUIDE_LINE" "$FIXTURE" | cmp -s - "$d/CLAUDE.md"; assert "$impl everything after the block is byte-identical" $?
  assert_eq "$impl backup created" 1 "$(backups "$d")"
  bak=$(ls "$d"/CLAUDE.md.bak-* 2>/dev/null | head -n 1)
  [ -n "$bak" ] && cmp -s "$FIXTURE" "$bak"; assert "$impl backup equals the original" $?

  # 3. second run: exit 0, nothing changes
  cp "$d/CLAUDE.md" "$d/after-first"
  mig "$impl" "$d/CLAUDE.md"
  assert_eq "$impl second run exits 0" 0 "$RC"
  printf '%s' "$OUT" | grep -q -F 'nothing to do'; assert "$impl second run says nothing to do" $?
  cmp -s "$d/after-first" "$d/CLAUDE.md"; assert "$impl second run changes nothing" $?
  assert_eq "$impl second run adds no backup" 1 "$(backups "$d")"

  # 4. already-migrated fixture (EDGE-006)
  d2="$HARNESS_ROOT/$impl-migrated"; rm -rf "$d2"; mkdir -p "$d2"
  tail -n "+$GUIDE_LINE" "$FIXTURE" > "$d2/CLAUDE.md"
  cp "$d2/CLAUDE.md" "$d2/orig"
  mig "$impl" "$d2/CLAUDE.md"
  assert_eq "$impl already-migrated exits 0" 0 "$RC"
  printf '%s' "$OUT" | grep -q -F 'nothing to do'; assert "$impl already-migrated says nothing to do" $?
  cmp -s "$d2/orig" "$d2/CLAUDE.md"; assert "$impl already-migrated file unchanged" $?
  assert_eq "$impl already-migrated writes no backup" 0 "$(backups "$d2")"

  # 5. customised block (EDGE-006): one injected line inside the block
  d3="$HARNESS_ROOT/$impl-custom"; rm -rf "$d3"; mkdir -p "$d3"
  inj='ZZZ-CUSTOM-LINE the owner added this rule to the policy'
  { head -n 10 "$FIXTURE"; printf '%s\n' "$inj"; tail -n +11 "$FIXTURE"; } > "$d3/CLAUDE.md"
  cp "$d3/CLAUDE.md" "$d3/orig"
  mig "$impl" "$d3/CLAUDE.md"
  assert_eq "$impl customised block exits 3" 3 "$RC"
  printf '%s' "$OUT" | grep -q -F -- "$inj"; assert "$impl customised block prints the differing line" $?
  cmp -s "$d3/orig" "$d3/CLAUDE.md"; assert "$impl customised block leaves the file unchanged" $?
  assert_eq "$impl customised block writes no backup" 0 "$(backups "$d3")"

  # 6. CRLF file: line endings outside the block survive
  d4="$HARNESS_ROOT/$impl-crlf"; rm -rf "$d4"; mkdir -p "$d4"
  sed 's/$/\r/' "$FIXTURE" > "$d4/CLAUDE.md"
  cp "$d4/CLAUDE.md" "$d4/orig"
  mig "$impl" "$d4/CLAUDE.md"
  assert_eq "$impl CRLF run exits 0" 0 "$RC"
  tail -n "+$GUIDE_LINE" "$d4/orig" | cmp -s - "$d4/CLAUDE.md"; assert "$impl CRLF tail is byte-identical" $?
}

run_suite sh
if [ "$HAVE_PWSH" -eq 1 ]; then
  run_suite ps
else
  echo "SKIP: pwsh not found; the .ps1 migration script was not exercised"
fi

echo ""
echo "Tests run: $TESTS_RUN  pass: $TESTS_PASS  fail: $TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ]
