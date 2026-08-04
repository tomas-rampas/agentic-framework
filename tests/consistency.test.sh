#!/usr/bin/env bash
# consistency.test.sh - Portable, self-contained test harness for the anti-drift
# consistency system (Phase A+B: scripts/lib/*.sh, scripts/validate-consistency.sh,
# scripts/generate-docs.sh).
#
# WHY plain bash (not bats): this must run unmodified on the developer's Windows
# machine (Cygwin/Git-bash) AND on ubuntu-latest CI with a git checkout + bash + jq.
#
# ISOLATION CONTRACT (the real working tree is NEVER mutated):
#   Each test case operates on its own throwaway copy of the repo:
#     1. ONCE per run, stream tracked files from git via `git ls-files -z`
#        (NUL-delimited file list) through `tar -c` into a cached archive; each
#        case then extracts that archive into a fresh `mktemp -d` directory —
#        paying the git+tar-create cost once instead of per case (a real saving
#        on Windows, where process creation dominates). The copy is a detached,
#        NON-git tree (avoids copying .git, both for correctness and speed).
#        Preserves file permissions and handles paths with spaces safely.
#     2. Mutate ONLY the copy (inject a defect, or leave it clean).
#     3. Run the COPIED scripts/validate-consistency.sh / generate-docs.sh against
#        the copy, with FRAMEWORK_ROOT pinned to the copy root.
#     4. Assert the exit code / message.
#     5. Remove the temp dir (a per-run trap also sweeps any leftovers).
#
#   FRAMEWORK_ROOT is required, not optional: `git rev-parse` would otherwise
#   resolve the copy's root to whatever git tree the temp dir happens to live in
#   (e.g. when TMPDIR is inside a checkout), silently testing the WRONG tree.
#   facts.sh honours FRAMEWORK_ROOT above git, so pinning it guarantees every
#   assertion is made against the isolated copy.
#
# Usage:
#   bash tests/consistency.test.sh
#   echo "exit=$?"      # 0 = all cases passed, 1 = at least one failed
#
# Requirements: bash, jq, git, tar, mktemp, awk, grep, sed, cp, find, head, basename, cmp.

set -uo pipefail
# NOTE: -e is intentionally NOT set. We run every case and aggregate results; a
# single failing assertion must not abort the whole suite.

# --- locate the repo under test --------------------------------------------
# The harness lives at <repo>/tests/consistency.test.sh, so the source repo is
# one level up from this script's directory. Resolved script-relative so the
# suite can be invoked from any CWD.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_REPO="$(cd "$TEST_DIR/.." && pwd)"

# --- pin the bash interpreter (portability + Windows safety) ----------------
# Invoke every copied script with the SAME bash that is running this harness,
# and put that bash's directory first on PATH so any nested `bash ...` call
# inside the scripts (e.g. validate-consistency.sh check 11 -> generate-docs.sh)
# resolves to the identical interpreter. On a Windows box with several bash
# flavors on PATH (Cygwin, Git-for-Windows, the WindowsApps stub) a mixed
# Cygwin+Git-bash pipeline can deadlock on process substitution; pinning one
# flavor avoids that. On Linux/CI this is simply /usr/bin/bash either way.
BASH_BIN="${BASH:-bash}"
if [[ -x "$BASH_BIN" ]]; then
  PATH="$(dirname "$BASH_BIN"):$PATH"
  export PATH
fi

# --- output helpers ---------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'
  C_CYN=$'\033[0;36m'; C_NC=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_CYN=""; C_NC=""
fi

TESTS_RUN=0
TESTS_PASS=0
TESTS_FAIL=0

# Track every temp dir we create so the global trap can sweep them even if a
# case dies unexpectedly. The real tree never appears in here.
# Use a tracking file since array mutations inside subshells don't propagate to parent.
__TMP_DIRS_FILE="$(mktemp "${TMPDIR:-/tmp}/consistency-test-dirs.XXXXXX")" || {
  printf 'FATAL: mktemp for tracking file failed\n' >&2
  exit 2
}

cleanup_all() {
  local d
  [[ -f "$__TMP_DIRS_FILE" ]] || return 0
  while IFS= read -r d; do
    # -e, not -d: the tracking file holds copy DIRECTORIES and the cached
    # source ARCHIVE (a regular file) — both must be swept.
    [[ -n "${d:-}" && -e "$d" ]] && rm -rf "$d"
  done < "$__TMP_DIRS_FILE"
  rm -f "$__TMP_DIRS_FILE"
}
# Handle EXIT normally; INT/TERM must terminate immediately, not resume.
trap cleanup_all EXIT
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

# --- source archive cache ---------------------------------------------------
# Created ONCE per run; every make_copy extracts from it. Input is identical
# to the previous per-case pipeline (git ls-files -z | tar -c --null -T -),
# so the copies are byte-identical to before — the git+tar-create side of the
# pipe just runs once instead of per case. The archive captures CURRENT
# WORKING TREE content at suite start; nothing mutates the source tree during
# a run (isolation contract), so the cache cannot go stale mid-run.
__SRC_TAR="$(mktemp "${TMPDIR:-/tmp}/consistency-test-src.XXXXXX")" || {
  printf 'FATAL: mktemp for source archive failed\n' >&2
  exit 2
}
printf '%s\n' "$__SRC_TAR" >> "$__TMP_DIRS_FILE"
( cd "$SRC_REPO" && git ls-files -z | tar -c --null -T - -f - ) > "$__SRC_TAR" || {
  printf 'FATAL: source archive creation failed (git ls-files or tar error)\n' >&2
  exit 2
}

# --- copy helper ------------------------------------------------------------
# make_copy -> prints the path to a fresh, isolated, non-git copy of the repo.
# The caller mutates and runs scripts against the returned path.
#
# Source: the cached archive built once at suite start from git ls-files | tar
# (critical for performance on Windows where process creation is slow — the
# git+tar-create side runs once per run, extraction once per case).
#   * Lists only tracked files from the working tree's index, not committed content.
#   * Immune to untracked junk (stray directories, backup files, etc).
#   * Avoids copying .git — the copy is a detached, NON-git tree (exercises
#     facts.sh's non-git root-resolution fallback).
#   * Preserves file permissions including executable bit on *.sh scripts.
#   * Handles paths with spaces safely (NUL-delimited input to tar).
#
# The copy will contain CURRENT WORKING TREE content (uncommitted changes) as
# captured at suite start, not committed content—this is correct, as the test
# must exercise the actual files a developer is about to validate, not a
# snapshot from HEAD.
#
# NOTE: Requires `set -uo pipefail` so that archive-creation failures cause exit 2.
make_copy() {
  local dst
  dst="$(mktemp -d "${TMPDIR:-/tmp}/consistency-test.XXXXXX")" || {
    printf 'FATAL: mktemp failed\n' >&2
    exit 2
  }
  # Record dir in tracking file so cleanup_all (outside subshell) can sweep it.
  printf '%s\n' "$dst" >> "$__TMP_DIRS_FILE"

  # Extract the cached source archive (created once at suite start, above).
  # tar preserves parent directories, file permissions, and executable bits.
  ( cd "$dst" && tar -xf "$__SRC_TAR" ) || {
    printf 'FATAL: extraction from cached source archive failed\n' >&2
    exit 2
  }

  printf '%s\n' "$dst"
}

# --- script runners (pin FRAMEWORK_ROOT to the copy) ------------------------
# run_validate <copy-root> -> runs the COPIED validator against the copy.
#   Captures combined stdout+stderr into $RUN_OUT and the exit code into $RUN_RC.
RUN_OUT=""
RUN_RC=0
run_validate() {
  # $2 (optional): VALIDATE_CHECKS filter — run only the named check(s).
  # Red-path cases pass the single check they target: the full battery costs
  # ~10x more per run (all 14 checks incl. the generate-docs pass), and a
  # filtered failure assertion is sharper — it proves the TARGET check fires,
  # not merely that the mutation broke something somewhere. Case 1 (happy
  # path) and case 25 (filter sanity) pin the full-battery and filter
  # semantics respectively.
  local root="$1" checks="${2:-}"
  RUN_OUT="$(FRAMEWORK_ROOT="$root" VALIDATE_CHECKS="$checks" "$BASH_BIN" "$root/scripts/validate-consistency.sh" 2>&1)"
  RUN_RC=$?
}
# run_generate <copy-root> <mode...> -> runs the COPIED generator against the copy.
run_generate() {
  local root="$1"; shift
  RUN_OUT="$(FRAMEWORK_ROOT="$root" "$BASH_BIN" "$root/scripts/generate-docs.sh" "$@" 2>&1)"
  RUN_RC=$?
}

# --- assertions -------------------------------------------------------------
# Every assertion records pass/fail and prints a one-line verdict. They never
# exit; the suite always runs to completion.
_pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASS=$((TESTS_PASS + 1)); printf '  %sPASS%s  %s\n' "$C_GRN" "$C_NC" "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1))
  printf '  %sFAIL%s  %s\n' "$C_RED" "$C_NC" "$1"
  [[ -n "${2:-}" ]] && printf '        %s\n' "$2"
}

_verify_copy() {
  local copy="$1"
  if [[ -z "$copy" || ! -d "$copy" || ! -f "$copy/scripts/validate-consistency.sh" ]]; then
    printf '%sFATAL%s copy directory invalid or empty\n' "$C_RED" "$C_NC" >&2
    exit 2
  fi
}

assert_rc_zero() {
  local label="$1"
  if [[ "$RUN_RC" -eq 0 ]]; then _pass "$label (exit 0)"
  else _fail "$label" "expected exit 0, got $RUN_RC"; fi
}
assert_rc_nonzero() {
  local label="$1"
  if [[ "$RUN_RC" -ne 0 ]]; then _pass "$label (exit $RUN_RC)"
  else _fail "$label" "expected non-zero exit, got 0"; fi
}
# assert_out_contains <label> <needle>
assert_out_contains() {
  local label="$1" needle="$2"
  if printf '%s' "$RUN_OUT" | grep -qF -- "$needle"; then _pass "$label"
  else _fail "$label" "expected output to contain: $needle"; fi
}

section() { printf '\n%s%s%s\n' "$C_CYN" "$1" "$C_NC"; }

# ===========================================================================
printf '%s================================================%s\n' "$C_CYN" "$C_NC"
printf '%s  Anti-Drift Consistency Test Harness%s\n' "$C_CYN" "$C_NC"
printf '%s  source repo: %s%s\n' "$C_CYN" "$SRC_REPO" "$C_NC"
printf '%s================================================%s\n' "$C_CYN" "$C_NC"

# --- preflight --------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  printf '%sFATAL%s jq is required but not installed.\n' "$C_RED" "$C_NC" >&2
  exit 2
fi

if ! command -v git >/dev/null 2>&1; then
  printf '%sFATAL%s git is required but not installed.\n' "$C_RED" "$C_NC" >&2
  exit 2
fi

if ! command -v tar >/dev/null 2>&1; then
  printf '%sFATAL%s tar is required but not installed.\n' "$C_RED" "$C_NC" >&2
  exit 2
fi

if ! git -C "$SRC_REPO" rev-parse --git-dir >/dev/null 2>&1; then
  printf '%sFATAL%s %s is not a git checkout (required for harness operation).\n' "$C_RED" "$C_NC" "$SRC_REPO" >&2
  exit 2
fi

# Verify no tracked files are deleted but not staged
deleted_unstaged="$(git -C "$SRC_REPO" ls-files --deleted 2>/dev/null || true)"
if [[ -n "$deleted_unstaged" ]]; then
  printf '%sFATAL%s tracked files are deleted but not staged. Stage or restore them:\n' "$C_RED" "$C_NC" >&2
  printf '%s\n' "$deleted_unstaged" | while IFS= read -r f; do printf '  %s\n' "$f" >&2; done
  exit 2
fi

# ===========================================================================
# CASE 1 - Happy path: unmodified copy validates clean.
# ===========================================================================
section "[1] Happy path: unmodified copy -> validate-consistency.sh exits 0"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  run_validate "$copy"
  assert_rc_zero "unmodified copy passes validation"
  assert_out_contains "validator reports RESULT: PASS" "RESULT: PASS"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 2 - Missing agent .md: registry parity must fail.
# ===========================================================================
section "[2] Missing agent: delete agents/go-expert.md -> non-zero (registry parity)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  rm -f "$copy/agents/go-expert.md"
  run_validate "$copy" 1
  assert_rc_nonzero "validator fails when a registered agent has no .md"
  assert_out_contains "reports missing-md for go-expert" "missing-md: go-expert"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 3 - Orphan agent file not in claude.json.
# ===========================================================================
section "[3] Orphan agent file: add agents/zzz-expert.md (unregistered) -> non-zero"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  printf -- '---\nname: zzz-expert\nmodel: opus\n---\nOrphan.\n' > "$copy/agents/zzz-expert.md"
  run_validate "$copy" 1
  assert_rc_nonzero "validator fails on an orphan agents/*.md"
  assert_out_contains "reports orphan-md for zzz-expert" "orphan-md: zzz-expert"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 4 - Category partition break: remove an agent from agent_categories.
# ===========================================================================
section "[4] Category partition break: drop an agent from agent_categories -> non-zero"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  # Pick the first agent that is currently assigned to some category, then
  # remove it from every category list. The agent stays registered + has its
  # .md, so the ONLY break is the category partition (uncategorized agent).
  victim="$(jq -r '.agent_categories | to_entries[0].value[0]' "$copy/claude.json")"
  jq --arg v "$victim" '
    .agent_categories |= with_entries(.value |= map(select(. != $v)))
  ' "$copy/claude.json" > "$copy/claude.json.tmp" && mv "$copy/claude.json.tmp" "$copy/claude.json"
  run_validate "$copy" 2
  assert_rc_nonzero "validator fails when an agent is in no category"
  assert_out_contains "reports uncategorized agent ($victim)" "uncategorized: $victim"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 5 - Missing hook script: registered in hooks/hooks.json but
#          deleted from hooks/ -> check 3 must fail.
# ===========================================================================
section "[5] Missing hook script: rm hooks/stop-peer-review-gate.ps1 -> non-zero (check 3)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  rm -f "$copy/hooks/stop-peer-review-gate.ps1"
  run_validate "$copy" 3
  assert_rc_nonzero "validator fails when a registered hook script is missing"
  assert_out_contains "reports missing-hook-script" "missing-hook-script: stop-peer-review-gate.ps1"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 6 - Orphan hook script: a hooks/*.ps1 that is NOT registered in
#          hooks/hooks.json is dead code -> check 3 must fail.
# ===========================================================================
section "[6] Orphan hook script: add unregistered hooks/zzz-orphan.ps1 -> non-zero (check 3)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  printf '#Requires -Version 7.0\nexit 0\n' > "$copy/hooks/zzz-orphan.ps1"
  run_validate "$copy" 3
  assert_rc_nonzero "validator fails on an unregistered hook script"
  assert_out_contains "reports orphan-hook-script" "orphan-hook-script: zzz-orphan.ps1"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 6b - dispatch.sh allowlist missing: drop a registered hook name from
#           dispatch.sh case statement -> check 3 must fail.
# ===========================================================================
section "[6b] dispatch.sh allowlist incomplete: drop 'record-subagent-run' from case -> non-zero (check 3)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  # Remove 'record-subagent-run|' from the dispatch.sh case statement, leaving
  # stop-peer-review-gate|session-start-context|pretooluse-delegation-hint
  sed -i 's/stop-peer-review-gate|record-subagent-run|/stop-peer-review-gate|/' "$copy/hooks/dispatch.sh"
  run_validate "$copy" 3
  assert_rc_nonzero "validator fails when dispatch.sh allowlist is incomplete"
  assert_out_contains "reports missing-dispatch-allowlist for record-subagent-run" "missing-dispatch-allowlist: record-subagent-run"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 6c - chain command mismatch: dispatch arg differs from .ps1 filename
#           -> check 3 must fail.
# ===========================================================================
section "[6c] chain command mismatch: dispatch arg != .ps1 filename -> non-zero (check 3)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  # Mutate one chain: change the dispatch arg but leave the .ps1 filename unchanged
  # Original: sh "...dispatch.sh" record-subagent-run || pwsh -File ".../record-subagent-run.ps1"
  # Mutated:  sh "...dispatch.sh" record-subagent-runs || pwsh -File ".../record-subagent-run.ps1" (typo in dispatch arg)
  jq '.hooks.PostToolUse[0].hooks[0].command = "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/dispatch.sh\" record-subagent-runs || pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/hooks/record-subagent-run.ps1\""' \
    "$copy/hooks/hooks.json" > "$copy/hooks/hooks.json.tmp" \
    && mv "$copy/hooks/hooks.json.tmp" "$copy/hooks/hooks.json"
  run_validate "$copy" 3
  assert_rc_nonzero "validator fails on chain command mismatch"
  assert_out_contains "reports chain-name-mismatch" "chain-name-mismatch"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 7 - Stale claude.json description ("18-agent") -> check 6a must fail.
# ===========================================================================
section "[7] Stale architecture description: claude.json set to '18-agent' -> non-zero"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  jq '.description = "Claude Code CLI with 18-agent specialized architecture"' \
    "$copy/claude.json" > "$copy/claude.json.tmp" \
    && mv "$copy/claude.json.tmp" "$copy/claude.json"
  run_validate "$copy" 6
  assert_rc_nonzero "validator fails on a stale claude.json description"
  assert_out_contains "reports claude.json missing N-agent" "claude.json .description missing"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 8 - Roster drift in prose table: delete an agent row from CLAUDE.md.
# ===========================================================================
section "[8] Roster drift: delete an agent row from the CLAUDE.md table -> non-zero"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  # Remove the go-expert table row (shape: | **go-expert** | ... |). awk drops
  # exactly that line, leaving everything else byte-identical.
  awk '!/^\| \*\*go-expert\*\* \|/' "$copy/CLAUDE.md" > "$copy/CLAUDE.md.tmp" \
    && mv "$copy/CLAUDE.md.tmp" "$copy/CLAUDE.md"
  run_validate "$copy" 9
  assert_rc_nonzero "validator fails when an agent row is missing from CLAUDE.md table"
  assert_out_contains "reports missing-row for go-expert" "missing-row: go-expert"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 9 - Generator staleness: edit inside the GENERATED region.
# ===========================================================================
section "[9] Generator staleness: mutate inside list-agents GENERATED region -> --check non-zero"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  la="$copy/commands/list-agents.md"
  # Corrupt a data line strictly between the BEGIN/END markers so the rendered
  # block no longer matches what's on disk. Change "total_agents": N -> 999.
  awk '
    /<!-- BEGIN GENERATED: list-agents-summary -->/ { inside=1; print; next }
    /<!-- END GENERATED: list-agents-summary -->/   { inside=0; print; next }
    inside && /"total_agents":/ { sub(/[0-9]+/, "999"); print; next }
    { print }
  ' "$la" > "$la.tmp" && mv "$la.tmp" "$la"
  run_generate "$copy" --check
  assert_rc_nonzero "generate-docs.sh --check fails on a stale generated block"
  assert_out_contains "reports STALE for list-agents-summary" "STALE"
  # And the validator (check 11 wires in --check) must also fail.
  run_validate "$copy" 11
  assert_rc_nonzero "validator (check 11) also fails on the stale block"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 10 - Generator idempotency: --write on a clean copy leaves no diff.
# ===========================================================================
section "[10] Idempotency: generate-docs.sh --write on a clean copy is a no-op"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  la="$copy/commands/list-agents.md"
  cp "$la" "$copy/.la.before"
  run_generate "$copy" --write
  assert_rc_zero "generate-docs.sh --write succeeds on a clean copy"
  if cmp -s "$copy/.la.before" "$la"; then
    _pass "list-agents.md byte-identical before/after --write (idempotent)"
  else
    _fail "list-agents.md changed after --write" "expected no diff on a clean copy"
  fi
  # Belt-and-suspenders: --check must report FRESH after the no-op write.
  run_generate "$copy" --check
  assert_rc_zero "--check confirms blocks fresh after idempotent --write"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 11 - Model parity (check 7, blocking): a tier divergence and an invalid
#           shorthand must each fail validation.
# ===========================================================================
section "[11] Model parity: divergent tier + invalid shorthand -> non-zero (check 7)"
{
  # --- 11a: flip ONE agent's claude.json .model to a DIFFERENT valid tier so
  # it no longer matches that agent's agents/<a>.md frontmatter shorthand. The
  # .md is left untouched, so the ONLY break is the md<->claude.json model
  # mismatch (check 7 now blocking).
  copy="$(make_copy)"
  _verify_copy "$copy"
  # Pick a real agent and a different (but still valid) shorthand than its
  # current md value, derived from the copy so the test stays roster-agnostic.
  victim="$(jq -r '.sub_agents | keys[0]' "$copy/claude.json")"
  cur="$(jq -r --arg a "$victim" '.sub_agents[$a].model' "$copy/claude.json")"
  # Choose a different declared shorthand key.
  other="$(jq -r --arg cur "$cur" '
    .consistency.model_shorthand_map | keys[] | select(. != $cur)' \
    "$copy/claude.json" | head -1)"
  # Guard: 11a needs a second valid tier to flip to. Fail loudly rather than
  # silently no-op if the map ever shrinks below 2 tiers.
  [[ -n "$other" ]] || _fail "CASE 11a setup needs >=2 model tiers in model_shorthand_map"
  jq --arg a "$victim" --arg m "$other" '.sub_agents[$a].model = $m' \
    "$copy/claude.json" > "$copy/claude.json.tmp" \
    && mv "$copy/claude.json.tmp" "$copy/claude.json"
  run_validate "$copy" 7
  assert_rc_nonzero "validator fails when an agent's md/claude.json models diverge"
  assert_out_contains "reports a model mismatch for $victim" "$victim: model mismatch"
  rm -rf "$copy"

  # --- 11b: set an INVALID shorthand (typo) in claude.json .model. It is not a
  # key in model_shorthand_map, so the map guard must fail it (blocking).
  copy="$(make_copy)"
  _verify_copy "$copy"
  victim="$(jq -r '.sub_agents | keys[0]' "$copy/claude.json")"
  jq --arg a "$victim" '.sub_agents[$a].model = "sonnett"' \
    "$copy/claude.json" > "$copy/claude.json.tmp" \
    && mv "$copy/claude.json.tmp" "$copy/claude.json"
  run_validate "$copy" 7
  assert_rc_nonzero "validator fails on an invalid model shorthand in claude.json"
  assert_out_contains "reports invalid shorthand 'sonnett' for $victim" "is not a key in consistency.model_shorthand_map"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 12 - framework-stats staleness: mutate the README footer inside the
#           GENERATED region -> --check (and the validator via check 11) fail.
# ===========================================================================
section "[12] Generator staleness: mutate README framework-stats region -> --check non-zero"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  rm_md="$copy/README.md"
  awk '
    /<!-- BEGIN GENERATED: framework-stats -->/ { inside=1; print; next }
    /<!-- END GENERATED: framework-stats -->/   { inside=0; print; next }
    inside && /Specialized Agents/ { sub(/[0-9]+ Specialized Agents/, "99 Specialized Agents"); print; next }
    { print }
  ' "$rm_md" > "$rm_md.tmp" && mv "$rm_md.tmp" "$rm_md"
  run_generate "$copy" --check
  assert_rc_nonzero "generate-docs.sh --check fails on a stale framework-stats block"
  assert_out_contains "reports STALE for framework-stats" "STALE"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 13 - Flat skill file: a loose skills/*.md is unloadable -> check 12 fails.
# ===========================================================================
section "[13] Flat skill file: add skills/rogue.md -> non-zero (check 12)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  printf -- '---\nname: rogue\ndescription: not loadable\n---\nBody.\n' > "$copy/skills/rogue.md"
  run_validate "$copy" 12
  assert_rc_nonzero "validator fails on a flat skills/*.md file"
  assert_out_contains "reports flat-skill-file" "flat-skill-file: rogue.md"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 14 - Skill dir without SKILL.md / frontmatter-name mismatch -> check 12.
# ===========================================================================
section "[14] Broken skill dir: no SKILL.md, and name != dirname -> non-zero (check 12)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  mkdir -p "$copy/skills/broken"
  run_validate "$copy" 12
  assert_rc_nonzero "validator fails on a skill dir without SKILL.md"
  assert_out_contains "reports missing-skill-md" "missing-skill-md: broken"
  rm -rf "$copy"

  copy="$(make_copy)"
  _verify_copy "$copy"
  first_skill="$(basename "$(find "$copy/skills" -mindepth 1 -maxdepth 1 -type d | head -1)")"
  if [[ -n "$first_skill" ]]; then
    sed -i.bak "s/^name: ${first_skill}\$/name: wrong-name/" "$copy/skills/$first_skill/SKILL.md" \
      && rm -f "$copy/skills/$first_skill/SKILL.md.bak"
    run_validate "$copy" 12
    assert_rc_nonzero "validator fails on frontmatter name != dirname"
    assert_out_contains "reports skill-name-mismatch" "skill-name-mismatch: $first_skill"
  else
    _fail "found a skill directory to mutate" "skills/ has no subdirectories"
  fi
  rm -rf "$copy"
}

# ===========================================================================
# CASE 15 - Plugin version mismatch (core): .claude-plugin/plugin.json has
#           different version than what validate-consistency.sh expects.
# ===========================================================================
section "[15] Plugin version mismatch (core): set .claude-plugin/plugin.json .version to 9.9.9 -> non-zero"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  jq '.version = "9.9.9"' "$copy/.claude-plugin/plugin.json" > "$copy/.claude-plugin/plugin.json.tmp" \
    && mv "$copy/.claude-plugin/plugin.json.tmp" "$copy/.claude-plugin/plugin.json"
  run_validate "$copy" 13
  assert_rc_nonzero "validator fails on core plugin version mismatch"
  assert_out_contains "reports version mismatch for core plugin" "version mismatch"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 16 - Plugin version mismatch (mcp): mcp-plugin/.claude-plugin/plugin.json
#           has different version than expected.
# ===========================================================================
section "[16] Plugin version mismatch (mcp): set mcp-plugin/.claude-plugin/plugin.json .version to 9.9.9 -> non-zero"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  jq '.version = "9.9.9"' "$copy/mcp-plugin/.claude-plugin/plugin.json" > "$copy/mcp-plugin/.claude-plugin/plugin.json.tmp" \
    && mv "$copy/mcp-plugin/.claude-plugin/plugin.json.tmp" "$copy/mcp-plugin/.claude-plugin/plugin.json"
  run_validate "$copy" 13
  assert_rc_nonzero "validator fails on mcp plugin version mismatch"
  assert_out_contains "reports version mismatch for mcp plugin" "version mismatch"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 17 - Orphan hook script: add unregistered hooks/zzz-unregistered.ps1 ->
#           check 3 must fail with orphan-hook-script.
# ===========================================================================
section "[17] Orphan hook (unregistered in hooks.json): add hooks/zzz-unregistered.ps1 -> non-zero (check 3)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  printf '#Requires -Version 7.0\nexit 0\n' > "$copy/hooks/zzz-unregistered.ps1"
  run_validate "$copy" 3
  assert_rc_nonzero "validator fails on an unregistered hook script"
  assert_out_contains "reports orphan-hook-script for zzz-unregistered.ps1" "orphan-hook-script: zzz-unregistered.ps1"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 18 - Missing .sh hook implementation: registered but deleted from hooks/
#           -> check 3 must fail with missing-sh-impl.
# ===========================================================================
section "[18] Missing .sh hook implementation: rm hooks/session-start-context.sh -> non-zero (check 3)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  rm -f "$copy/hooks/session-start-context.sh"
  run_validate "$copy" 3
  assert_rc_nonzero "validator fails when a registered .sh hook is missing"
  assert_out_contains "reports missing-sh-impl" "missing-sh-impl: session-start-context.sh"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 19 - Orphan .sh hook script: a hooks/*.sh (non-dispatch) NOT registered
#           -> check 3 must fail with orphan-sh-script.
# ===========================================================================
section "[19] Orphan .sh hook script: add unregistered hooks/zzz-extra.sh -> non-zero (check 3)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  printf '#!/bin/sh\nset -u\nexit 0\n' > "$copy/hooks/zzz-extra.sh"
  run_validate "$copy" 3
  assert_rc_nonzero "validator fails on an unregistered .sh hook script"
  assert_out_contains "reports orphan-sh-script for zzz-extra.sh" "orphan-sh-script: zzz-extra.sh"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 20 - Missing dispatch.sh: the dispatcher not found -> check 3 must fail
#           with missing-dispatch-sh.
# ===========================================================================
section "[20] Missing dispatch.sh: rm hooks/dispatch.sh -> non-zero (check 3)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  rm -f "$copy/hooks/dispatch.sh"
  run_validate "$copy" 3
  assert_rc_nonzero "validator fails when dispatch.sh is missing"
  assert_out_contains "reports missing-dispatch-sh" "missing-dispatch-sh: dispatch.sh"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 21 - Drifted marketplace agent count: mutate marketplace.json
#           plugins[0].description agent count -> check 8 must fail (rule 8g).
# ===========================================================================
section "[21] Drifted marketplace agent count: set to '99-agent' -> non-zero (check 8)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  jq '.plugins[0].description = (.plugins[0].description | sub("[0-9]+-agent"; "99-agent"))' \
    "$copy/.claude-plugin/marketplace.json" > "$copy/.claude-plugin/marketplace.json.tmp" \
    && mv "$copy/.claude-plugin/marketplace.json.tmp" "$copy/.claude-plugin/marketplace.json"
  run_validate "$copy" 8
  assert_rc_nonzero "validator fails when marketplace.json agent count drifts"
  assert_out_contains "reports N-agent count mismatch in marketplace.json" "N-agent count: stated '99' != derived"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 22 - Drifted marketplace top-level description: mutate marketplace.json
#           .description agent count -> check 8 must fail (rule 8a).
# ===========================================================================
section "[22] Drifted marketplace top-level description: set to '99 specialized agents' -> non-zero (check 8)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  jq '.description = (.description | sub("[0-9]+ specialized"; "99 specialized"))' \
    "$copy/.claude-plugin/marketplace.json" > "$copy/.claude-plugin/marketplace.json.tmp" \
    && mv "$copy/.claude-plugin/marketplace.json.tmp" "$copy/.claude-plugin/marketplace.json"
  run_validate "$copy" 8
  assert_rc_nonzero "validator fails when marketplace.json top-level description agent count drifts"
  assert_out_contains "reports agent count mismatch in marketplace.json" "agent count: stated '99' != derived"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 23 - Policy re-broadening phrase on an operative surface -> check 14
#           must fail. Injects the exact phrasing the Jul 2026 perf
#           regression shipped ("delegate all shell execution").
# ===========================================================================
section "[23] Policy re-broadening: inject 'delegate all shell execution' into CLAUDE.md -> non-zero (check 14)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  printf '\nAgents should delegate all shell execution to the executor agents.\n' >> "$copy/CLAUDE.md"
  run_validate "$copy" 14
  assert_rc_nonzero "validator fails when a re-broadening phrase appears in CLAUDE.md"
  assert_out_contains "reports the re-broadening phrase with its location" "policy re-broadening phrase in CLAUDE.md"
  rm -rf "$copy"

  # Hook scripts are in scope too (they carry prose comments that could
  # re-teach the policy) — a phrase hidden in a .sh comment must be caught.
  copy="$(make_copy)"
  _verify_copy "$copy"
  printf '\n# Callers route all shell work here under the blanket policy.\n' >> "$copy/hooks/dispatch.sh"
  run_validate "$copy" 14
  assert_rc_nonzero "validator fails when a re-broadening phrase appears in a hook script"
  assert_out_contains "reports the phrase in hooks/dispatch.sh" "policy re-broadening phrase in hooks/dispatch.sh"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 24 - Required policy statement removed -> check 14 must fail. Strips
#           the selective section header from CLAUDE.md, simulating a doc
#           pass that quietly rewrites the policy heading.
# ===========================================================================
section "[24] Policy statement removed: strip '(selective)' header from CLAUDE.md -> non-zero (check 14)"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  sed -i.bak 's/Command-line Execution Policy (selective)/Command-line Execution Policy/' "$copy/CLAUDE.md" \
    && rm -f "$copy/CLAUDE.md.bak"
  run_validate "$copy" 14
  assert_rc_nonzero "validator fails when the selective policy header is gone"
  assert_out_contains "reports the missing required statement" "missing from CLAUDE.md"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 25 - VALIDATE_CHECKS filter sanity: the filter this suite relies on
#           must actually filter. On a copy broken ONLY in check 13 (version
#           mismatch), a run filtered to check 1 must pass and be labeled
#           FILTERED, and a run filtered to check 13 must fail. Guards
#           against the filter silently running everything (suite slow again)
#           or silently skipping the targeted check (vacuous red paths).
# ===========================================================================
section "[25] Filter sanity: check-13 break invisible to VALIDATE_CHECKS=1, caught by VALIDATE_CHECKS=13"
{
  copy="$(make_copy)"
  _verify_copy "$copy"
  jq '.version = "9.9.9"' "$copy/.claude-plugin/plugin.json" > "$copy/.claude-plugin/plugin.json.tmp" \
    && mv "$copy/.claude-plugin/plugin.json.tmp" "$copy/.claude-plugin/plugin.json"
  run_validate "$copy" 1
  assert_rc_zero "filtered run (check 1) passes despite the check-13 break"
  assert_out_contains "filtered run is labeled as partial" "RESULT: PASS (FILTERED)"
  run_validate "$copy" 13
  assert_rc_nonzero "filtered run (check 13) catches the break"
  assert_out_contains "reports the version mismatch" "version mismatch"
  rm -rf "$copy"
}

# ===========================================================================
# CASE 26 - Agent frontmatter keys (check 15, blocking). Four defects, each
#           injected into a copy and each targeting one rule of check 15.
#           Victims are DERIVED from the copy (first agent carrying the key),
#           so the cases stay roster- and value-agnostic.
# ===========================================================================
section "[26] Agent frontmatter: bad effort / unknown mcpServer / undeclared tool server / missing serena bootstrap -> non-zero (check 15)"
{
  # --- 26a: invalid effort tier -------------------------------------------
  copy="$(make_copy)"
  _verify_copy "$copy"
  victim_md="$(grep -lE '^effort:' "$copy"/agents/*.md | head -1)"
  if [[ -n "$victim_md" ]]; then
    victim="$(basename "$victim_md" .md)"
    sed -i.bak -E 's/^effort:.*$/effort: turbo/' "$victim_md" && rm -f "$victim_md.bak"
    run_validate "$copy" 15
    assert_rc_nonzero "validator fails on an invalid effort tier"
    assert_out_contains "reports invalid-effort for $victim" "invalid-effort: $victim"
  else
    _fail "found an agent with an effort: key" "no agents/*.md declares effort:"
  fi
  rm -rf "$copy"

  # --- 26b: mcpServers entry naming a server absent from .mcp.json ---------
  copy="$(make_copy)"
  _verify_copy "$copy"
  victim_md="$(grep -lE '^mcpServers:' "$copy"/agents/*.md | head -1)"
  if [[ -n "$victim_md" ]]; then
    victim="$(basename "$victim_md" .md)"
    sed -i.bak -E 's/^mcpServers: \[/mcpServers: [zzz-nonexistent, /' "$victim_md" && rm -f "$victim_md.bak"
    run_validate "$copy" 15
    assert_rc_nonzero "validator fails on an mcpServers entry with no server in .mcp.json"
    assert_out_contains "reports unknown-mcp-server for $victim" "unknown-mcp-server: $victim -> zzz-nonexistent"
  else
    _fail "found an agent with an mcpServers: key" "no agents/*.md declares mcpServers:"
  fi
  rm -rf "$copy"

  # --- 26c: tools use an mcp server the agent never declared --------------
  # The server IS real (a key of .mcp.json), so ONLY rule (c) can fire: the
  # agent's own mcpServers list does not declare it.
  copy="$(make_copy)"
  _verify_copy "$copy"
  victim_md="$(grep -lE '^mcpServers:' "$copy"/agents/*.md \
               | while IFS= read -r f; do
                   grep -qE '^tools:' "$f" && ! grep -qE '^mcpServers:.*\bfetch\b' "$f" && printf '%s\n' "$f"
                 done | head -1)"
  if [[ -n "$victim_md" ]]; then
    victim="$(basename "$victim_md" .md)"
    sed -i.bak -E 's/^(tools: .*)$/\1, mcp__fetch__fetch/' "$victim_md" && rm -f "$victim_md.bak"
    run_validate "$copy" 15
    assert_rc_nonzero "validator fails when tools reference an undeclared mcp server"
    assert_out_contains "reports undeclared-tool-server for $victim" "undeclared-tool-server: $victim -> fetch"
  else
    _fail "found an agent with tools: + mcpServers: lacking fetch" "no suitable agents/*.md victim"
  fi
  rm -rf "$copy"

  # --- 26d: serena tools without the bootstrap pair ------------------------
  copy="$(make_copy)"
  _verify_copy "$copy"
  victim_md="$(grep -lE '^tools:.*mcp__serena__activate_project' "$copy"/agents/*.md | head -1)"
  if [[ -n "$victim_md" ]]; then
    victim="$(basename "$victim_md" .md)"
    # Drop ONLY the activate_project token (other serena tools remain, so the
    # bootstrap rule is the sole break).
    sed -i.bak -E 's/, ?mcp__serena__activate_project//' "$victim_md" && rm -f "$victim_md.bak"
    run_validate "$copy" 15
    assert_rc_nonzero "validator fails when serena tools omit a bootstrap tool"
    assert_out_contains "reports missing-serena-bootstrap for $victim" "missing-serena-bootstrap: $victim -> mcp__serena__activate_project"
  else
    _fail "found an agent allowlisting mcp__serena__activate_project" "no suitable agents/*.md victim"
  fi
  rm -rf "$copy"

  # --- 26e: GREEN regression guard — flow-list `tools:` spelling ----------
  # Both YAML spellings of tools: must normalise identically. A flow list used
  # to leave its LAST token wearing a ']', which made the serena bootstrap rule
  # emit a false failure for a tool that is actually present.
  copy="$(make_copy)"
  _verify_copy "$copy"
  victim_md="$(grep -lE '^tools:.*mcp__serena__' "$copy"/agents/*.md | head -1)"
  if [[ -n "$victim_md" ]]; then
    victim="$(basename "$victim_md" .md)"
    # Same tokens, flow-list spelling: tools: a, b, c -> tools: [a, b, c]
    sed -i.bak -E 's/^tools: (.*)$/tools: [\1]/' "$victim_md" && rm -f "$victim_md.bak"
    run_validate "$copy" 15
    assert_rc_zero "flow-list tools: spelling still passes check 15 ($victim)"
    assert_out_contains "check 15 reports PASS on the flow-list spelling" "RESULT: PASS (FILTERED)"
  else
    _fail "found an agent with serena tools to reformat" "no suitable agents/*.md victim"
  fi
  rm -rf "$copy"

  # --- 26f: RED — block-style mcpServers (key present, same line empty) ---
  # The value lives on following lines, so the single-line parser sees nothing.
  # That must FAIL loudly, not silently no-op rules (b)/(c).
  copy="$(make_copy)"
  _verify_copy "$copy"
  victim_md="$(grep -lE '^mcpServers:' "$copy"/agents/*.md | head -1)"
  if [[ -n "$victim_md" ]]; then
    victim="$(basename "$victim_md" .md)"
    awk '
      /^mcpServers:/ && !done { print "mcpServers:"; print "  - serena"; done=1; next }
      { print }
    ' "$victim_md" > "$victim_md.tmp" && mv "$victim_md.tmp" "$victim_md"
    run_validate "$copy" 15
    assert_rc_nonzero "validator fails on a block-style mcpServers list"
    assert_out_contains "reports unparseable-mcpservers for $victim" "unparseable-mcpservers: $victim"
  else
    _fail "found an agent with an mcpServers: key" "no agents/*.md declares mcpServers:"
  fi
  rm -rf "$copy"

  # --- 26g: RED — block-style tools: (key present, same line empty) -------
  # Mirrors 26f. A block list would otherwise skip rules (c)/(d) entirely,
  # which is how the origin defect (serena tools without the bootstrap pair)
  # escaped detection in the first place.
  copy="$(make_copy)"
  _verify_copy "$copy"
  victim_md="$(grep -lE '^tools:' "$copy"/agents/*.md | head -1)"
  if [[ -n "$victim_md" ]]; then
    victim="$(basename "$victim_md" .md)"
    awk '
      /^tools:/ && !done {
        line=$0; sub(/^tools:[ \t]*/, "", line)
        print "tools:"
        n=split(line, t, /,[ \t]*/)
        for (i=1; i<=n; i++) if (t[i] != "") print "  - " t[i]
        done=1; next
      }
      { print }
    ' "$victim_md" > "$victim_md.tmp" && mv "$victim_md.tmp" "$victim_md"
    run_validate "$copy" 15
    assert_rc_nonzero "validator fails on a block-style tools list"
    assert_out_contains "reports unparseable-tools for $victim" "unparseable-tools: $victim"
  else
    _fail "found an agent with a tools: key" "no agents/*.md declares tools:"
  fi
  rm -rf "$copy"

  # --- 26h: RED — 26d's defect in a SPACE-separated tools: line -----------
  # This is the only spelling that distinguishes the whitespace-aware token
  # splitter from a comma-only one: under a comma-only _fm_list the whole line
  # collapses into a single token, rule (d) silently matches nothing, and the
  # missing bootstrap tool ships. 26e/26f/26g all stay green under that revert,
  # so this case is the regression guard for it.
  copy="$(make_copy)"
  _verify_copy "$copy"
  victim_md="$(grep -lE '^tools:.*mcp__serena__activate_project' "$copy"/agents/*.md | head -1)"
  if [[ -n "$victim_md" ]]; then
    victim="$(basename "$victim_md" .md)"
    sed -i.bak -E 's/, ?mcp__serena__activate_project//' "$victim_md" \
      && sed -i.bak -E '/^tools: /s/, / /g' "$victim_md" \
      && rm -f "$victim_md.bak"
    run_validate "$copy" 15
    assert_rc_nonzero "validator fails on a space-separated tools list missing a serena bootstrap tool"
    assert_out_contains "reports missing-serena-bootstrap for $victim (space-separated)" "missing-serena-bootstrap: $victim -> mcp__serena__activate_project"
  else
    _fail "found an agent allowlisting mcp__serena__activate_project" "no suitable agents/*.md victim"
  fi
  rm -rf "$copy"
}

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%s================================================%s\n' "$C_CYN" "$C_NC"
if [[ "$TESTS_FAIL" -eq 0 ]]; then
  printf '%s  RESULT: PASS%s  (%s/%s assertions passed, 0 failed)\n' \
    "$C_GRN" "$C_NC" "$TESTS_PASS" "$TESTS_RUN"
  printf '%s================================================%s\n' "$C_CYN" "$C_NC"
  exit 0
else
  printf '%s  RESULT: FAIL%s  (%s passed, %s failed, %s total)\n' \
    "$C_RED" "$C_NC" "$TESTS_PASS" "$TESTS_FAIL" "$TESTS_RUN"
  printf '%s================================================%s\n' "$C_CYN" "$C_NC"
  exit 1
fi
