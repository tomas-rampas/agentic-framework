#!/usr/bin/env bash
# migrate-claude-md.test.sh — scripts/migrate-global-claude-md.{sh,ps1} (REQ-013, EDGE-006).
# Fixture: a synthetic file built from the bundled v5.1.0 reference plus a
# "Claude Code System Guidelines" section. With MIGRATE_TEST_USE_REAL_FILE=1 a copy of the
# owner's ~/.claude/CLAUDE.md is used instead when it still holds the framework block.
# The real file is only ever read.
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
if [ "${MIGRATE_TEST_USE_REAL_FILE:-}" = 1 ] && [ -f "$GLOBAL_REAL" ] && grep -q -x -F -- "$TITLE" "$GLOBAL_REAL" && grep -q -x -F -- "$GUIDE" "$GLOBAL_REAL"; then
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

  # 1b. installed-plugin POLICY.md warning (fake HOME / USERPROFILE)
  for variant in missing present; do
    fh="$HARNESS_ROOT/fakehome-$impl-$variant"; rm -rf "$fh"; mkdir -p "$fh/.claude/plugins" "$fh/plug"
    [ "$variant" = present ] && printf 'x\n' > "$fh/plug/POLICY.md"
    printf '{"version":2,"plugins":{"agentic-framework@agentic-framework":[{"installPath":"%s"}]}}\n' "$(to_native "$fh/plug")" > "$fh/.claude/plugins/installed_plugins.json"
    if [ "$impl" = sh ]; then
      OUT=$(HOME="$fh" sh "$SH_SCRIPT" --dry-run "$d/CLAUDE.md" 2>&1 >/dev/null); RC=$?
    else
      OUT=$(HOME="$fh" USERPROFILE="$(to_native "$fh")" pwsh -NoProfile -File "$(to_native "$PS_SCRIPT")" -Path "$(to_native "$d/CLAUDE.md")" -DryRun 2>&1 >/dev/null); RC=$?
    fi
    assert_eq "$impl installed plugin ($variant POLICY.md) exits 0" 0 "$RC"
    printf '%s' "$OUT" | grep -q -F 'installed agentic-framework plugin at'; r=$?
    if [ "$variant" = missing ]; then assert "$impl warns when the installed plugin has no POLICY.md" "$r"
    else assert_eq "$impl no installed-plugin warning when POLICY.md present" 1 "$r"; fi
  done

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

  # 7. user content BEFORE the title survives byte-identical (the block is not at line 1)
  d5="$HARNESS_ROOT/$impl-prefix"; rm -rf "$d5"; mkdir -p "$d5"
  printf '# My own notes\n\nkeep this line exactly\n  indented line with trailing space \nlast user line\n\n' > "$d5/prefix"
  { cat "$d5/prefix"; cat "$FIXTURE"; } > "$d5/CLAUDE.md"
  mig "$impl" "$d5/CLAUDE.md"
  assert_eq "$impl prefix run exits 0" 0 "$RC"
  { cat "$d5/prefix"; tail -n "+$GUIDE_LINE" "$FIXTURE"; } | cmp -s - "$d5/CLAUDE.md"; assert "$impl user content before the block is byte-identical and the block is gone" $?

  # 8. usage errors exit 2 and change nothing: extra argument, unknown flag
  d6="$HARNESS_ROOT/$impl-usage"; rm -rf "$d6"; mkdir -p "$d6"
  cp "$FIXTURE" "$d6/CLAUDE.md"
  if [ "$impl" = sh ]; then
    OUT=$(sh "$SH_SCRIPT" "$d6/CLAUDE.md" "$d6/other.md" 2>&1); RC=$?
  else
    OUT=$(pwsh -NoProfile -File "$(to_native "$PS_SCRIPT")" -Path "$(to_native "$d6/CLAUDE.md")" "$(to_native "$d6/other.md")" 2>&1); RC=$?
  fi
  assert_eq "$impl second path argument exits 2" 2 "$RC"
  cmp -s "$FIXTURE" "$d6/CLAUDE.md"; assert "$impl second path argument leaves the file unchanged" $?
  if [ "$impl" = sh ]; then
    OUT=$(sh "$SH_SCRIPT" --dry-run-please "$d6/CLAUDE.md" 2>&1); RC=$?
  else
    OUT=$(pwsh -NoProfile -File "$(to_native "$PS_SCRIPT")" -Path "$(to_native "$d6/CLAUDE.md")" -DryRunPlease 2>&1); RC=$?
  fi
  assert_eq "$impl unknown flag exits 2" 2 "$RC"
  cmp -s "$FIXTURE" "$d6/CLAUDE.md"; assert "$impl unknown flag leaves the file unchanged" $?
  assert_eq "$impl usage errors write no backup" 0 "$(backups "$d6")"

  # 9. UTF-8 BOM at the start is outside the block: kept, ignored for the title match
  bomb=$(printf '\357\273\277')
  user='# My notes — café
- keep → this 🙂
'
  d7="$HARNESS_ROOT/$impl-bom"; rm -rf "$d7"; mkdir -p "$d7"
  { printf '%s' "$bomb"; cat "$REF"; printf '\n%s' "$user"; } > "$d7/CLAUDE.md"
  { printf '%s' "$bomb"; printf '%s' "$user"; } > "$d7/expected"
  mig "$impl" "$d7/CLAUDE.md" dry
  assert_eq "$impl BOM dry-run exits 0" 0 "$RC"
  printf '%s' "$OUT" | grep -q -F -- "$bomb"; r=$?; assert_eq "$impl BOM dry-run output carries no BOM" 1 "$r"
  mig "$impl" "$d7/CLAUDE.md"
  assert_eq "$impl BOM run exits 0" 0 "$RC"
  cmp -s "$d7/expected" "$d7/CLAUDE.md"; assert "$impl BOM run output is BOM + user section, byte-identical" $?
  assert_eq "$impl BOM run writes one backup" 1 "$(backups "$d7")"
  cp "$d7/CLAUDE.md" "$d7/after"
  mig "$impl" "$d7/CLAUDE.md"
  assert_eq "$impl BOM second run exits 0" 0 "$RC"
  printf '%s' "$OUT" | grep -q -F 'nothing to do'; assert "$impl BOM second run says nothing to do" $?
  cmp -s "$d7/after" "$d7/CLAUDE.md"; assert "$impl BOM second run changes nothing" $?
  cp "$d7/expected" "$d7/CLAUDE.md"
  mig "$impl" "$d7/CLAUDE.md"
  printf '%s' "$OUT" | grep -q -F 'nothing to do'; assert "$impl BOM file without a block says nothing to do" $?
  cmp -s "$d7/expected" "$d7/CLAUDE.md"; assert "$impl BOM file without a block is unchanged" $?
  # BOM + a user line before the block: BOM stays on line 1 of the output
  d8="$HARNESS_ROOT/$impl-bom-prefix"; rm -rf "$d8"; mkdir -p "$d8"
  { printf '%s# Mine\n' "$bomb"; cat "$REF"; printf '\n%s' "$user"; } > "$d8/CLAUDE.md"
  # (the block's own trailing blank line goes with it, as in section 7)
  { printf '%s# Mine\n' "$bomb"; printf '%s' "$user"; } > "$d8/expected"
  mig "$impl" "$d8/CLAUDE.md"
  assert_eq "$impl BOM prefix run exits 0" 0 "$RC"
  cmp -s "$d8/expected" "$d8/CLAUDE.md"; assert "$impl BOM prefix run keeps the BOM and user lines" $?
  # a BOM file whose block holds a customised line is still refused, file untouched
  d9="$HARNESS_ROOT/$impl-bom-custom"; rm -rf "$d9"; mkdir -p "$d9"
  { printf '%s' "$bomb"; head -n 10 "$REF"; printf '%s\n' "$inj"; tail -n +11 "$REF"; } > "$d9/CLAUDE.md"
  cp "$d9/CLAUDE.md" "$d9/orig"
  mig "$impl" "$d9/CLAUDE.md"
  assert_eq "$impl BOM customised block exits 3" 3 "$RC"
  cmp -s "$d9/orig" "$d9/CLAUDE.md"; assert "$impl BOM customised block leaves the file unchanged" $?

  # 10. a relative path whose text before "=" is an awk identifier is a file, not an assignment
  d10="$HARNESS_ROOT/$impl-eq/a=b"; rm -rf "$HARNESS_ROOT/$impl-eq"; mkdir -p "$d10"
  cp "$FIXTURE" "$d10/CLAUDE.md"
  if [ "$impl" = sh ]; then
    OUT=$(cd "$HARNESS_ROOT/$impl-eq" && sh "$SH_SCRIPT" --dry-run a=b/CLAUDE.md 2>&1); RC=$?
  else
    OUT=$(cd "$HARNESS_ROOT/$impl-eq" && pwsh -NoProfile -File "$(to_native "$PS_SCRIPT")" -Path a=b/CLAUDE.md -DryRun 2>&1); RC=$?
  fi
  assert_eq "$impl path a=b/CLAUDE.md dry-run exits 0" 0 "$RC"
  printf '%s' "$OUT" | grep -q -F 'dry run: would remove'; assert "$impl path a=b/CLAUDE.md finds the block" $?

  # 11. a namespace-qualified "ident::ident=value" path is a file, not a gawk assignment
  d11="$HARNESS_ROOT/$impl-ns"; rm -rf "$d11"
  # (MSYS maps ":" to a private-use character on NTFS, so native pwsh cannot see that name: sh only there.)
  if [ "$impl" = ps ] && command -v cygpath >/dev/null 2>&1; then
    echo "SKIP: ps path awk::start=3/CLAUDE.md: ':' is not a legal NTFS file name for native pwsh"
  elif mkdir -p "$d11/awk::start=3" 2>/dev/null && [ -d "$d11/awk::start=3" ]; then
    cp "$FIXTURE" "$d11/awk::start=3/CLAUDE.md"
    if [ "$impl" = sh ]; then
      OUT=$(cd "$d11" && sh "$SH_SCRIPT" --dry-run 'awk::start=3/CLAUDE.md' 2>&1); RC=$?
    else
      OUT=$(cd "$d11" && pwsh -NoProfile -File "$(to_native "$PS_SCRIPT")" -Path 'awk::start=3/CLAUDE.md' -DryRun 2>&1); RC=$?
    fi
    assert_eq "$impl path awk::start=3/CLAUDE.md dry-run exits 0" 0 "$RC"
    printf '%s' "$OUT" | grep -q -F 'dry run: would remove lines 1-'; assert "$impl path awk::start=3/CLAUDE.md scans the whole file (block starts at line 1)" $?
  else
    echo "SKIP: $impl cannot create a directory named awk::start=3 on this host"
  fi

  # 12. a control byte before "# " is not a heading: the line is a customised block line (exit 3)
  d12="$HARNESS_ROOT/$impl-ctl"; rm -rf "$d12"; mkdir -p "$d12"
  { head -n 10 "$FIXTURE"; printf '\001# x\n'; tail -n +11 "$FIXTURE"; } > "$d12/CLAUDE.md"
  cp "$d12/CLAUDE.md" "$d12/orig"
  mig "$impl" "$d12/CLAUDE.md"
  assert_eq "$impl control byte before '# ' inside the block exits 3" 3 "$RC"
  cmp -s "$d12/orig" "$d12/CLAUDE.md"; assert "$impl control-byte row leaves the file unchanged" $?
}

# 13. (sh only) a FIFO path exits 2 at once instead of blocking on the BOM read
fifo_dir="$HARNESS_ROOT/fifo"; mkdir -p "$fifo_dir"
if mkfifo "$fifo_dir/f" 2>/dev/null && [ -p "$fifo_dir/f" ]; then
  if command -v timeout >/dev/null 2>&1; then
    OUT=$(timeout 10 sh "$SH_SCRIPT" "$fifo_dir/f" 2>&1 </dev/null); RC=$?
    assert_eq "sh FIFO path exits 2 without blocking (124 = timeout)" 2 "$RC"
  else
    echo "SKIP: no timeout command; FIFO row not run"
  fi
else
  echo "SKIP: mkfifo unavailable on this host; FIFO row not run"
fi

run_suite sh
if [ "$HAVE_PWSH" -eq 1 ]; then
  run_suite ps
else
  echo "SKIP: pwsh not found; the .ps1 migration script was not exercised"
fi

echo ""
echo "Tests run: $TESTS_RUN  pass: $TESTS_PASS  fail: $TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ]
