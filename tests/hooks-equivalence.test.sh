#!/usr/bin/env bash
# hooks-equivalence.test.sh — Cross-implementation equivalence test for hooks.
#
# Runs the same fixtures through both PowerShell (record-subagent-run.ps1 and
# stop-peer-review-gate.ps1) and Bash (record-subagent-run.sh and
# stop-peer-review-gate.sh) implementations in isolated CLAUDE_STATE_DIRs.
#
# Path handling: MSYS paths for sh, Windows paths for pwsh (via cygpath -w).
#
# SKIP GRACEFULLY when pwsh unavailable (ubuntu CI must pass trivially).
# Usage: bash tests/hooks-equivalence.test.sh

set -u

# --- Check for pwsh availability
if ! command -v pwsh >/dev/null 2>&1; then
  printf 'SKIP: pwsh not available (equivalence needs both interpreters)\n'
  exit 0
fi

# --- Setup
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_REPO="$(cd "$TEST_DIR/.." && pwd)"

if [ -t 1 ]; then
  C_RED='\033[0;31m'; C_GRN='\033[0;32m'
  C_CYN='\033[0;36m'; C_NC='\033[0m'
else
  C_RED=""; C_GRN=""; C_CYN=""; C_NC=""
fi

TESTS_RUN=0
TESTS_PASS=0
TESTS_FAIL=0

# Create a single mktemp-based harness root for all test fixtures.
# All temp dirs are created under this single root; cleanup_all removes
# it wholesale. This eliminates PID-based naming collision issues and
# ensures predictable cleanup across concurrent runs (a prior incident:
# a shared/global glob pattern caused one test-harness instance to delete
# another CONCURRENT instance's live fixture directories mid-run).
HARNESS_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hooks-equiv-test.XXXXXXXX") || exit 1

cleanup_all() {
  cd / 2>/dev/null || true
  [ -n "${HARNESS_ROOT:-}" ] && rm -rf "$HARNESS_ROOT"
}
trap cleanup_all EXIT INT TERM

# Defensive precondition: ensure harness root is NOT inside a git worktree.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
if git -C "$HARNESS_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'FATAL: harness root %s is inside a git worktree\n' "$HARNESS_ROOT" >&2
  exit 2
fi

make_work_dir() {
  local wd
  wd=$(mktemp -d "$HARNESS_ROOT/wd.XXXXXX") || {
    printf 'FATAL: mktemp failed\n' >&2
    exit 2
  }
  printf '%s\n' "$wd"
}

make_test_repo() {
  local d="$1"
  git -C "$d" init -q -b main || return 1
  [ -d "$d/.git" ] || return 1
  git -C "$d" config user.email 'test@test.local'
  git -C "$d" config user.name 'hooks-test'
  printf 'one\n' > "$d/a.txt"
  git -C "$d" add -A
  git -C "$d" commit -q -m 'init'
  git -C "$d" checkout -q -b feature/x
  printf 'two\n' > "$d/b.txt"
  git -C "$d" add -A
  git -C "$d" commit -q -m 'feature work'
}

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASS=$((TESTS_PASS + 1)); printf '  %sPASS%s  %s\n' "$C_GRN" "$C_NC" "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1))
  printf '  %sFAIL%s  %s\n' "$C_RED" "$C_NC" "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
}

section() { printf '\n%s%s%s\n' "$C_CYN" "$1" "$C_NC"; }

# --- Marker comparison
marker_compare() {
  local m_ps="$1" m_sh="$2" label="$3"

  if [ ! -f "$m_ps" ] && [ ! -f "$m_sh" ]; then
    _fail "$label" "both markers missing"
    return 1
  fi
  if [ ! -f "$m_ps" ] || [ ! -f "$m_sh" ]; then
    _fail "$label" "one missing (ps=$([  -f "$m_ps" ] && echo yes || echo no), sh=$([  -f "$m_sh" ] && echo yes || echo no))"
    return 1
  fi

  local m_ps_norm m_sh_norm
  m_ps_norm=$(tail -n +2 "$m_ps")
  m_sh_norm=$(tail -n +2 "$m_sh")

  if [ "$m_ps_norm" = "$m_sh_norm" ]; then
    _pass "$label: markers equivalent (timestamp normalized)"
    return 0
  else
    _fail "$label" "markers differ after timestamp drop"
    return 1
  fi
}

# --- Sidecar comparison
sidecar_compare() {
  local f_ps="$1" f_sh="$2" label="$3"

  if [ ! -f "$f_ps" ] && [ ! -f "$f_sh" ]; then
    _pass "$label: both missing"
    return 0
  fi
  if [ ! -f "$f_ps" ] || [ ! -f "$f_sh" ]; then
    _fail "$label" "one missing (ps=$([  -f "$f_ps" ] && echo yes || echo no), sh=$([  -f "$f_sh" ] && echo yes || echo no))"
    return 1
  fi

  local f_ps_norm f_sh_norm
  f_ps_norm=$(cat "$f_ps" | sed 's/^[^ ]* //')
  f_sh_norm=$(cat "$f_sh" | sed 's/^[^ ]* //')

  if [ "$f_ps_norm" = "$f_sh_norm" ]; then
    _pass "$label: sidecars equivalent (timestamp normalized)"
    return 0
  else
    _fail "$label" "sidecars differ after timestamp normalization"
    printf '        PS (normalized): %s\n' "$(printf '%s' "$f_ps_norm" | head -c 100)"
    printf '        SH (normalized): %s\n' "$(printf '%s' "$f_sh_norm" | head -c 100)"
    return 1
  fi
}

# ===========================================================================
printf '%s================================================%s\n' "$C_CYN" "$C_NC"
printf '%s  Bash-PowerShell Hooks Equivalence Test%s\n' "$C_CYN" "$C_NC"
printf '%s  source repo: %s%s\n' "$C_CYN" "$SRC_REPO" "$C_NC"
printf '%s================================================%s\n' "$C_CYN" "$C_NC"

# --- RECORDER-A: SubagentStop APPROVED
section "[RECORDER-A] SubagentStop APPROVED plain-string"
{
  workdir="$(make_work_dir)"
  state_ps_msys="$workdir/state_ps"
  state_sh_msys="$workdir/state_sh"
  state_ps_win=$(cygpath -w "$state_ps_msys" 2>/dev/null || echo "$state_ps_msys")
  mkdir -p "$state_ps_msys/peer-review" "$state_sh_msys/peer-review"

  payload='{"session_id":"rec_a","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","last_assistant_message":"Good.\nVERDICT: APPROVED"}'

  printf '%s' "$payload" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$payload" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1

  marker_compare "$state_ps_msys/peer-review/rec_a" "$state_sh_msys/peer-review/rec_a" "marker"
  rm -rf "$workdir"
}

# --- RECORDER-B: PostToolUse CHANGES_REQUIRED
section "[RECORDER-B] PostToolUse CHANGES_REQUIRED content-array"
{
  workdir="$(make_work_dir)"
  state_ps_msys="$workdir/state_ps"
  state_sh_msys="$workdir/state_sh"
  state_ps_win=$(cygpath -w "$state_ps_msys" 2>/dev/null || echo "$state_ps_msys")
  mkdir -p "$state_ps_msys/peer-review" "$state_sh_msys/peer-review"

  payload='{"session_id":"rec_b","hook_event_name":"PostToolUse","tool_use_id":"tool_1","tool_name":"Agent","tool_input":{"subagent_type":"peer-review-critic"},"tool_response":{"status":"ok","content":[{"type":"text","text":"Issues.\nVERDICT: CHANGES_REQUIRED"}]}}'

  printf '%s' "$payload" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$payload" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1

  marker_compare "$state_ps_msys/peer-review/rec_b" "$state_sh_msys/peer-review/rec_b" "marker"
  rm -rf "$workdir"
}

# --- RECORDER-C: Verdict-less
section "[RECORDER-C] Verdict-less run (ran-marker)"
{
  workdir="$(make_work_dir)"
  state_ps_msys="$workdir/state_ps"
  state_sh_msys="$workdir/state_sh"
  state_ps_win=$(cygpath -w "$state_ps_msys" 2>/dev/null || echo "$state_ps_msys")
  mkdir -p "$state_ps_msys/peer-review" "$state_sh_msys/peer-review"

  payload='{"session_id":"rec_c","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","last_assistant_message":"Reviewing..."}'

  printf '%s' "$payload" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$payload" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1

  if [ -f "$state_ps_msys/peer-review/rec_c" ] && [ -f "$state_sh_msys/peer-review/rec_c" ]; then
    _pass "both markers created"
    if ! grep -q 'verdict=' "$state_ps_msys/peer-review/rec_c"; then
      _pass "ps marker has no verdict line"
    else
      _fail "ps marker" "has verdict line when none expected"
    fi
    if ! grep -q 'verdict=' "$state_sh_msys/peer-review/rec_c"; then
      _pass "sh marker has no verdict line"
    else
      _fail "sh marker" "has verdict line when none expected"
    fi
  else
    _fail "markers created" "ps=$([  -f "$state_ps_msys/peer-review/rec_c" ] && echo yes || echo no), sh=$([  -f "$state_sh_msys/peer-review/rec_c" ] && echo yes || echo no)"
  fi

  rm -rf "$workdir"
}

# --- RECORDER-D: Scoped
section "[RECORDER-D] Scoped agentic-framework:peer-review-critic"
{
  workdir="$(make_work_dir)"
  state_ps_msys="$workdir/state_ps"
  state_sh_msys="$workdir/state_sh"
  state_ps_win=$(cygpath -w "$state_ps_msys" 2>/dev/null || echo "$state_ps_msys")
  mkdir -p "$state_ps_msys/peer-review" "$state_sh_msys/peer-review"

  payload='{"session_id":"rec_d","hook_event_name":"SubagentStop","agent_type":"agentic-framework:peer-review-critic","last_assistant_message":"Good.\nVERDICT: APPROVED"}'

  printf '%s' "$payload" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$payload" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1

  marker_compare "$state_ps_msys/peer-review/rec_d" "$state_sh_msys/peer-review/rec_d" "marker with scoped name"
  rm -rf "$workdir"
}

# --- RECORDER-E: Stale-guard
section "[RECORDER-E] Stale-guard: instance-dedupe suppression"
{
  workdir="$(make_work_dir)"
  state_ps_msys="$workdir/state_ps"
  state_sh_msys="$workdir/state_sh"
  state_ps_win=$(cygpath -w "$state_ps_msys" 2>/dev/null || echo "$state_ps_msys")
  mkdir -p "$state_ps_msys/peer-review" "$state_sh_msys/peer-review"

  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  head_sha=$(git -C "$testgit" rev-parse HEAD)
  testgit_win=$(cygpath -w "$testgit" 2>/dev/null || echo "$testgit")

  # First emission (PS and SH use their respective cwd forms)
  payload_ps=$(jq -n --arg cwd "$testgit_win" '{session_id:"rec_e",hook_event_name:"PostToolUse",tool_use_id:"tool_1",tool_name:"Agent",tool_input:{subagent_type:"peer-review-critic"},tool_response:"Good.\nVERDICT: APPROVED",cwd:$cwd}')
  payload_sh=$(jq -n --arg cwd "$testgit" '{session_id:"rec_e",hook_event_name:"PostToolUse",tool_use_id:"tool_1",tool_name:"Agent",tool_input:{subagent_type:"peer-review-critic"},tool_response:"Good.\nVERDICT: APPROVED",cwd:$cwd}')

  printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1

  # Second emission (same instance, should suppress)
  payload_ps=$(jq -n --arg cwd "$testgit_win" '{session_id:"rec_e",hook_event_name:"PostToolUse",tool_use_id:"tool_1",tool_name:"Agent",tool_input:{subagent_type:"peer-review-critic"},tool_response:"Still good.\nVERDICT: APPROVED",cwd:$cwd}')
  payload_sh=$(jq -n --arg cwd "$testgit" '{session_id:"rec_e",hook_event_name:"PostToolUse",tool_use_id:"tool_1",tool_name:"Agent",tool_input:{subagent_type:"peer-review-critic"},tool_response:"Still good.\nVERDICT: APPROVED",cwd:$cwd}')

  printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1

  sidecar_compare "$state_ps_msys/peer-review/rec_e.verdict-suppressed" "$state_sh_msys/peer-review/rec_e.verdict-suppressed" "suppressed audit lines"
  rm -rf "$workdir"
}

# --- GATE-A: APPROVED allows
section "[GATE-A] APPROVED marker allows"
{
  workdir="$(make_work_dir)"
  testgit="$workdir/test_repo"
  state_ps_msys="$workdir/state_ps"
  state_sh_msys="$workdir/state_sh"
  state_ps_win=$(cygpath -w "$state_ps_msys" 2>/dev/null || echo "$state_ps_msys")
  testgit_win=$(cygpath -w "$testgit" 2>/dev/null || echo "$testgit")

  mkdir -p "$testgit"
  make_test_repo "$testgit"

  head_sha=$(git -C "$testgit" rev-parse HEAD)

  for state_dir in "$state_ps_msys" "$state_sh_msys"; do
    mkdir -p "$state_dir/peer-review"
    printf '%b' "2026-07-18T00:00:00+02:00\nverdict=APPROVED\nhead=$head_sha" > "$state_dir/peer-review/gate_a"
  done

  payload_ps=$(jq -n --arg cwd "$testgit_win" '{session_id:"gate_a",stop_hook_active:false,cwd:$cwd}')
  payload_sh=$(jq -n --arg cwd "$testgit" '{session_id:"gate_a",stop_hook_active:false,cwd:$cwd}')

  ps_out=$(printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/stop-peer-review-gate.ps1" 2>&1)
  ps_rc=$?

  sh_out=$(printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)
  sh_rc=$?

  if [ "$ps_rc" -eq 0 ] && [ "$sh_rc" -eq 0 ]; then
    _pass "both exit 0"
  else
    _fail "exit codes" "ps=$ps_rc, sh=$sh_rc"
  fi

  if [ -z "$ps_out" ] && [ -z "$sh_out" ]; then
    _pass "both silent (gate allows)"
  else
    _fail "output" "ps empty=$([  -z "$ps_out" ] && echo yes || echo no), sh empty=$([  -z "$sh_out" ] && echo yes || echo no)"
  fi

  rm -rf "$workdir"
}

# --- GATE-B: CHANGES_REQUIRED blocks
section "[GATE-B] CHANGES_REQUIRED marker blocks"
{
  workdir="$(make_work_dir)"
  testgit="$workdir/test_repo"
  state_ps_msys="$workdir/state_ps"
  state_sh_msys="$workdir/state_sh"
  state_ps_win=$(cygpath -w "$state_ps_msys" 2>/dev/null || echo "$state_ps_msys")
  testgit_win=$(cygpath -w "$testgit" 2>/dev/null || echo "$testgit")

  mkdir -p "$testgit"
  make_test_repo "$testgit"

  head_sha=$(git -C "$testgit" rev-parse HEAD)

  for state_dir in "$state_ps_msys" "$state_sh_msys"; do
    mkdir -p "$state_dir/peer-review"
    printf '%b' "2026-07-18T00:00:00+02:00\nverdict=CHANGES_REQUIRED\nhead=$head_sha" > "$state_dir/peer-review/gate_b"
  done

  payload_ps=$(jq -n --arg cwd "$testgit_win" '{session_id:"gate_b",stop_hook_active:false,cwd:$cwd}')
  payload_sh=$(jq -n --arg cwd "$testgit" '{session_id:"gate_b",stop_hook_active:false,cwd:$cwd}')

  ps_out=$(printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/stop-peer-review-gate.ps1" 2>&1)
  ps_rc=$?

  sh_out=$(printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)
  sh_rc=$?

  if [ "$ps_rc" -eq 0 ] && [ "$sh_rc" -eq 0 ]; then
    _pass "both exit 0"
  else
    _fail "exit codes" "ps=$ps_rc, sh=$sh_rc"
  fi

  if printf '%s' "$ps_out" | grep -q 'decision.*block'; then
    _pass "ps outputs block"
  else
    _fail "ps output" "no decision:block"
  fi

  if printf '%s' "$sh_out" | grep -q 'decision.*block'; then
    _pass "sh outputs block"
  else
    _fail "sh output" "no decision:block"
  fi

  ps_norm=$(printf '%s' "$ps_out" | jq -S . 2>/dev/null || echo "")
  sh_norm=$(printf '%s' "$sh_out" | jq -S . 2>/dev/null || echo "")

  if [ "$ps_norm" = "$sh_norm" ] && [ -n "$ps_norm" ]; then
    _pass "JSON output equivalent"
  else
    _fail "JSON equivalence" "outputs differ after jq -S"
  fi

  rm -rf "$workdir"
}

# --- GATE-C: No marker blocks
section "[GATE-C] No marker blocks"
{
  workdir="$(make_work_dir)"
  testgit="$workdir/test_repo"
  state_ps_msys="$workdir/state_ps"
  state_sh_msys="$workdir/state_sh"
  state_ps_win=$(cygpath -w "$state_ps_msys" 2>/dev/null || echo "$state_ps_msys")
  testgit_win=$(cygpath -w "$testgit" 2>/dev/null || echo "$testgit")

  mkdir -p "$testgit"
  make_test_repo "$testgit"

  mkdir -p "$state_ps_msys/peer-review" "$state_sh_msys/peer-review"

  payload_ps=$(jq -n --arg cwd "$testgit_win" '{session_id:"gate_c",stop_hook_active:false,cwd:$cwd}')
  payload_sh=$(jq -n --arg cwd "$testgit" '{session_id:"gate_c",stop_hook_active:false,cwd:$cwd}')

  ps_out=$(printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/stop-peer-review-gate.ps1" 2>&1)
  ps_rc=$?

  sh_out=$(printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)
  sh_rc=$?

  if [ "$ps_rc" -eq 0 ] && [ "$sh_rc" -eq 0 ]; then
    _pass "both exit 0"
  else
    _fail "exit codes" "ps=$ps_rc, sh=$sh_rc"
  fi

  ps_blocks=$(printf '%s' "$ps_out" | grep -q 'decision' && echo yes || echo no)
  sh_blocks=$(printf '%s' "$sh_out" | grep -q 'decision' && echo yes || echo no)

  if [ "$ps_blocks" = "yes" ] && [ "$sh_blocks" = "yes" ]; then
    _pass "both block (no marker = never reviewed)"
  else
    _fail "blocking behavior" "ps blocks=$ps_blocks, sh blocks=$sh_blocks"
  fi

  rm -rf "$workdir"
}

# === Summary
printf '\n%s================================================%s\n' "$C_CYN" "$C_NC"
printf 'RESULT: %d run, %d pass, %d fail\n' "$TESTS_RUN" "$TESTS_PASS" "$TESTS_FAIL"
printf '%s================================================%s\n' "$C_CYN" "$C_NC"

exit "$([  "$TESTS_FAIL" -eq 0 ] && echo 0 || echo 1)"
