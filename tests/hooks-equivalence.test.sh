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
  workdir="$(make_work_dir)" || exit 2
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
  workdir="$(make_work_dir)" || exit 2
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
  workdir="$(make_work_dir)" || exit 2
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
  workdir="$(make_work_dir)" || exit 2
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
  workdir="$(make_work_dir)" || exit 2
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
  workdir="$(make_work_dir)" || exit 2
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
  workdir="$(make_work_dir)" || exit 2
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
  workdir="$(make_work_dir)" || exit 2
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

section "[SESSION-START-POLICY] byte-identical stdout across sh and pwsh"
{
  ss_workdir="$(make_work_dir)" || exit 2
  ss_repo="$ss_workdir/repo"; mkdir -p "$ss_repo"; make_test_repo "$ss_repo"
  ss_plain="$ss_workdir/plain"; mkdir -p "$ss_plain/sub"
  ss_marker='<!-- agentic-framework: policy inline -->'

  # check_ss_equiv <label> <source> <cwd>   (compares raw stdout bytes incl. the final newline)
  check_ss_equiv() {
    local label="$1" src="$2" cwd="$3" cwd_win payload_sh payload_ps
    cwd_win="$(cygpath -m "$cwd" 2>/dev/null || printf '%s' "$cwd")"
    payload_sh=$(printf '{"session_id":"e","hook_event_name":"SessionStart","source":"%s","cwd":"%s"}' "$src" "$cwd")
    payload_ps=$(printf '{"session_id":"e","hook_event_name":"SessionStart","source":"%s","cwd":"%s"}' "$src" "$cwd_win")
    printf '%s' "$payload_sh" | CLAUDE_PLUGIN_ROOT="$SRC_REPO" sh "$SRC_REPO/hooks/session-start-context.sh" > "$ss_workdir/o.sh" 2>/dev/null
    local rc_sh=$?
    printf '%s' "$payload_ps" | CLAUDE_PLUGIN_ROOT="$(cygpath -m "$SRC_REPO" 2>/dev/null || printf '%s' "$SRC_REPO")" pwsh -NoProfile -File "$SRC_REPO/hooks/session-start-context.ps1" > "$ss_workdir/o.ps" 2>/dev/null
    local rc_ps=$?
    if [ "$rc_sh" -eq 0 ] && [ "$rc_ps" -eq 0 ] && cmp -s "$ss_workdir/o.sh" "$ss_workdir/o.ps"; then
      _pass "$label: stdout byte-identical (sh $(wc -c < "$ss_workdir/o.sh" | tr -d ' ') bytes)"
    else
      _fail "$label" "rc sh=$rc_sh ps=$rc_ps, bytes sh=$(wc -c < "$ss_workdir/o.sh" | tr -d ' ') ps=$(wc -c < "$ss_workdir/o.ps" | tr -d ' ')"
    fi
  }

  check_ss_equiv "startup, scratch dir" startup "$ss_plain"
  check_ss_equiv "resume, scratch dir" resume "$ss_plain"
  check_ss_equiv "clear, git repo (branch line + policy)" clear "$ss_repo"
  check_ss_equiv "compact, git repo" compact "$ss_repo"
  check_ss_equiv "unknown source (no output)" other "$ss_plain"

  printf '%s\n' "$ss_marker" > "$ss_repo/CLAUDE.md"
  check_ss_equiv "marker in <cwd>/CLAUDE.md (branch line only)" startup "$ss_repo"
  printf '%s\n' "$ss_marker" > "$ss_plain/sub/CLAUDE.md"
  check_ss_equiv "marker only in a child directory (policy printed)" startup "$ss_plain"
  printf '# p\r\n%s\r\n' "$ss_marker" > "$ss_plain/CLAUDE.md"
  check_ss_equiv "marker with CRLF line endings" resume "$ss_plain"

  rm -rf "$ss_workdir"
}

section "[MODEL-GUARD] byte-identical (deny) / canonical-identical (rewrite) stdout across sh and pwsh"
{
  # check_guard_equiv <label> <payload> <expect: deny|silent|rewrite> [EXTRA_ENV_VAR=value ...]
  # Always runs both implementations with CLAUDE_CODE_SUBAGENT_MODEL and
  # AF_MODEL_GUARD explicitly cleared unless the caller passes an override in
  # EXTRA_ENV; this stops a machine-wide floor from silently corrupting the
  # comparison.
  #
  # DENY cases are byte-compared, as before (fixed ASCII reason text, no
  # echoed user content). A "deny" expectation additionally fails if both
  # outputs are empty (equal-but-empty must not pass as "byte-identical").
  #
  # REWRITE cases echo the original tool_input, which the two
  # implementations may legitimately escape differently in JSON (jq emits
  # raw UTF-8; .NET's Utf8JsonWriter HTML-escapes <, >, &, " as < etc.
  # and may re-encode surrogate pairs). So rewrite cases are compared as
  # CANONICAL JSON (`jq -S -c .` of each output, which normalises escaping
  # and key order) instead of raw bytes, plus an explicit "no
  # permissionDecision key" check on both sides.
  check_guard_equiv() {
    local label="$1" payload="$2" expect="$3"
    shift 3

    sh_out=$(printf '%s' "$payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD "$@" sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)
    sh_rc=$?
    ps_out=$(printf '%s' "$payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD "$@" pwsh -NoProfile -File "$SRC_REPO/hooks/pretooluse-model-guard.ps1" 2>&1)
    ps_rc=$?

    if [ "$sh_rc" -eq 0 ] && [ "$ps_rc" -eq 0 ]; then
      _pass "[$label] both exit 0"
    else
      _fail "[$label] exit codes" "sh=$sh_rc, ps=$ps_rc"
    fi

    case "$expect" in
      deny)
        if [ -z "$sh_out" ] && [ -z "$ps_out" ]; then
          _fail "[$label] both empty but deny was expected" "sh= | ps="
        elif [ "$sh_out" = "$ps_out" ]; then
          _pass "[$label] byte-identical stdout"
        else
          _fail "[$label] stdout mismatch" "sh=$sh_out | ps=$ps_out"
        fi
        ;;
      silent)
        if [ -z "$sh_out" ] && [ -z "$ps_out" ]; then
          _pass "[$label] both silent"
        else
          _fail "[$label] expected both silent" "sh=$sh_out | ps=$ps_out"
        fi
        ;;
      rewrite)
        if [ -z "$sh_out" ] || [ -z "$ps_out" ]; then
          _fail "[$label] rewrite expected but got empty output" "sh=$sh_out | ps=$ps_out"
        else
          # jq's exit status is checked on purpose: two outputs that both fail to
          # parse canonicalise to the same empty string, and an equal-but-empty
          # comparison must never count as a pass. A valid document followed by
          # trailing garbage also exits non-zero, so it is emptied too.
          sh_canon=$(printf '%s' "$sh_out" | jq -S -c . 2>/dev/null) || sh_canon=""
          ps_canon=$(printf '%s' "$ps_out" | jq -S -c . 2>/dev/null) || ps_canon=""
          if [ -z "$sh_canon" ] || [ -z "$ps_canon" ]; then
            _fail "[$label] rewrite output is not valid JSON" "sh=$sh_out | ps=$ps_out"
          elif [ "$sh_canon" = "$ps_canon" ]; then
            _pass "[$label] canonical-JSON-identical stdout"
          else
            _fail "[$label] canonical JSON mismatch" "sh=$sh_canon | ps=$ps_canon"
          fi
        fi
        if printf '%s' "$sh_out" | grep -q permissionDecision; then
          _fail "[$label] sh must not emit permissionDecision on rewrite" "sh=$sh_out"
        else
          _pass "[$label] sh has no permissionDecision key"
        fi
        if printf '%s' "$ps_out" | grep -q permissionDecision; then
          _fail "[$label] ps must not emit permissionDecision on rewrite" "ps=$ps_out"
        else
          _pass "[$label] ps has no permissionDecision key"
        fi
        ;;
    esac
  }

  check_guard_equiv "fable" '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore","model":"fable"}}' deny
  check_guard_equiv "reasonB" '{"tool_input":{"subagent_type":"Explore"}}' rewrite
  check_guard_equiv "pass" '{"tool_input":{"subagent_type":"python-expert"}}' silent

  # EDGE-009 fork
  check_guard_equiv "edge009-fork" '{"tool_input":{"subagent_type":"fork"}}' deny
  check_guard_equiv "edge009-fork-model" '{"tool_input":{"subagent_type":"Fork","model":"sonnet"}}' deny
  check_guard_equiv "edge009-fork-floor" '{"tool_input":{"subagent_type":"fork"}}' deny CLAUDE_CODE_SUBAGENT_MODEL=sonnet
  check_guard_equiv "edge009-fork-off" '{"tool_input":{"subagent_type":"fork","model":"fable"}}' silent AF_MODEL_GUARD=off

  # EDGE-010 top-tier substring spellings
  check_guard_equiv "edge010-claude-fable" '{"tool_input":{"subagent_type":"agentic-framework:python-expert","model":"claude-fable-5-1"}}' deny
  check_guard_equiv "edge010-bracketed" '{"tool_input":{"subagent_type":"agentic-framework:python-expert","model":"fable[1m]"}}' deny

  # EDGE-011 floor value gating (floor=fable is now unusable -> rewrite, not deny)
  check_guard_equiv "edge011-floor-fable" '{"tool_input":{"subagent_type":"Explore"}}' rewrite CLAUDE_CODE_SUBAGENT_MODEL=fable
  check_guard_equiv "edge011-floor-haiku" '{"tool_input":{"subagent_type":"Explore"}}' silent CLAUDE_CODE_SUBAGENT_MODEL=haiku

  # EDGE-012 non-string fields normalise to empty
  check_guard_equiv "edge012-model-false" '{"tool_input":{"subagent_type":"agentic-framework:python-expert","model":false}}' silent
  check_guard_equiv "edge012-model-array" '{"tool_input":{"subagent_type":"Explore","model":[]}}' rewrite

  # EDGE-013 non-object tool_input passes silently; empty object still rewrites
  check_guard_equiv "edge013-tool-input-string" '{"tool_input":"x"}' silent
  check_guard_equiv "edge013-tool-input-empty-object" '{"tool_input":{}}' rewrite

  # EDGE-016 unknown agent type: documented limit (silent without a model),
  # but the top-tier rule still binds even for an unrecognised agent.
  check_guard_equiv "edge016-unknown-agent-silent" '{"tool_input":{"subagent_type":"my-custom-agent"}}' silent
  check_guard_equiv "edge016-unknown-agent-fable" '{"tool_input":{"subagent_type":"my-custom-agent","model":"fable"}}' deny

  # REQ-007 / EDGE-003: executors capped at sonnet
  check_guard_equiv "req007-bash-opus" '{"tool_input":{"subagent_type":"bash-expert","model":"opus"}}' deny
  check_guard_equiv "req007-ps-scoped-claude-opus" '{"tool_input":{"subagent_type":"agentic-framework:powershell-expert","model":"claude-opus-5-5"}}' deny
  check_guard_equiv "req007-bash-Opus" '{"tool_input":{"subagent_type":"bash-expert","model":"Opus"}}' deny
  check_guard_equiv "req007-bash-OPUS" '{"tool_input":{"subagent_type":"bash-expert","model":"OPUS"}}' deny
  check_guard_equiv "req007-bash-opus-5-5" '{"tool_input":{"subagent_type":"bash-expert","model":"opus-5-5"}}' deny
  check_guard_equiv "req007-bash-sonnet" '{"tool_input":{"subagent_type":"bash-expert","model":"sonnet"}}' silent
  check_guard_equiv "req007-bash-no-model" '{"tool_input":{"subagent_type":"bash-expert"}}' silent
  check_guard_equiv "req007-rust-opus" '{"tool_input":{"subagent_type":"rust-expert","model":"opus"}}' silent
  check_guard_equiv "req007-bash-opus-off" '{"tool_input":{"subagent_type":"bash-expert","model":"opus"}}' silent AF_MODEL_GUARD=off

  # EDGE-019 rewrite integrity: every original key preserved (019b) and a
  # payload built to catch a lossy .ps1 (019c) — Czech diacritics, an emoji
  # surrogate pair, <, >, &, quotes, backslashes, an embedded newline/tab,
  # and a description that is exactly an ISO-8601 timestamp.
  check_guard_equiv "edge019b-all-fields-preserved" '{"tool_input":{"description":"d","prompt":"p","subagent_type":"general-purpose","run_in_background":true,"name":"x"}}' rewrite

  integrity_prompt_file=$(mktemp "${TMPDIR:-/tmp}/guard-integrity.XXXXXX")
  printf '%s' 'žluťoučký kůň 😀 <tag> & "quoted" \back\slash
line2	tab' > "$integrity_prompt_file"
  integrity_payload=$(jq -n --rawfile p "$integrity_prompt_file" --arg d '2026-09-20T10:00:00Z' \
    '{"tool_input":{"subagent_type":"Explore","prompt":$p,"description":$d}}' -c)
  rm -f "$integrity_prompt_file"
  check_guard_equiv "edge019c-integrity" "$integrity_payload" rewrite

  # Per-field extraction equality on top of the canonical-JSON compare above:
  # each implementation's updatedInput.prompt/description must equal the
  # ORIGINAL input value exactly (not just equal each other), which is the
  # assertion that actually proves round-trip fidelity rather than "both
  # implementations are equally wrong".
  expected_prompt=$(jq -r '.tool_input.prompt' <<EOF_PAYLOAD
$integrity_payload
EOF_PAYLOAD
)
  sh_int_out=$(printf '%s' "$integrity_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)
  ps_int_out=$(printf '%s' "$integrity_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD pwsh -NoProfile -File "$SRC_REPO/hooks/pretooluse-model-guard.ps1" 2>&1)
  sh_int_prompt=$(printf '%s' "$sh_int_out" | jq -r '.hookSpecificOutput.updatedInput.prompt' 2>/dev/null)
  ps_int_prompt=$(printf '%s' "$ps_int_out" | jq -r '.hookSpecificOutput.updatedInput.prompt' 2>/dev/null)
  sh_int_desc=$(printf '%s' "$sh_int_out" | jq -r '.hookSpecificOutput.updatedInput.description' 2>/dev/null)
  ps_int_desc=$(printf '%s' "$ps_int_out" | jq -r '.hookSpecificOutput.updatedInput.description' 2>/dev/null)
  if [ "$sh_int_prompt" = "$expected_prompt" ]; then _pass "[edge019c-integrity] sh updatedInput.prompt equals original input exactly"; else _fail "[edge019c-integrity] sh prompt fidelity" "expected: $expected_prompt, got: $sh_int_prompt"; fi
  if [ "$ps_int_prompt" = "$expected_prompt" ]; then _pass "[edge019c-integrity] ps updatedInput.prompt equals original input exactly"; else _fail "[edge019c-integrity] ps prompt fidelity" "expected: $expected_prompt, got: $ps_int_prompt"; fi
  if [ "$sh_int_desc" = "2026-09-20T10:00:00Z" ]; then _pass "[edge019c-integrity] sh updatedInput.description is the unmodified ISO string"; else _fail "[edge019c-integrity] sh description fidelity" "got: $sh_int_desc"; fi
  if [ "$ps_int_desc" = "2026-09-20T10:00:00Z" ]; then _pass "[edge019c-integrity] ps updatedInput.description is the unmodified ISO string"; else _fail "[edge019c-integrity] ps description fidelity" "got: $ps_int_desc"; fi

  # EDGE-021 lone-surrogate bypass, duplicate fields, off-switch trimming.
  # A lone \uD800 escape in an unrelated field (here: prompt) must never let
  # a fork or fable call slip past undetected in either implementation.
  check_guard_equiv "edge021a-fork-surrogate" '{"tool_input":{"subagent_type":"fork","prompt":"a\ud800b"}}' deny
  check_guard_equiv "edge021b-fable-surrogate" '{"tool_input":{"subagent_type":"agentic-framework:python-expert","model":"fable","prompt":"a\ud800b"}}' deny
  # M1 fix: cannot echo safely -> falls back to deny instead of silent passthrough.
  check_guard_equiv "edge021c-explore-surrogate-deny" '{"tool_input":{"subagent_type":"Explore","prompt":"a\ud800b"}}' deny
  check_guard_equiv "edge021d-framework-agent-surrogate-silent" '{"tool_input":{"subagent_type":"agentic-framework:python-expert","prompt":"a\ud800b"}}' silent

  # Duplicate "model": both implementations must fold to exactly one
  # "model" field in their raw output, valued at the rewritten tier.
  edge021e_payload='{"tool_input":{"model":"fable","model":"","subagent_type":"Explore","prompt":"p"}}'
  sh021e_out=$(printf '%s' "$edge021e_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)
  ps021e_out=$(printf '%s' "$edge021e_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD pwsh -NoProfile -File "$SRC_REPO/hooks/pretooluse-model-guard.ps1" 2>&1)
  sh021e_count=$(printf '%s' "$sh021e_out" | grep -o '"model"' | wc -l | tr -d ' ')
  ps021e_count=$(printf '%s' "$ps021e_out" | grep -o '"model"' | wc -l | tr -d ' ')
  if [ "$sh021e_count" = "1" ]; then _pass "[edge021e-dup-model] sh raw output has exactly one model field"; else _fail "[edge021e-dup-model] sh model field count" "got: $sh021e_count in $sh021e_out"; fi
  if [ "$ps021e_count" = "1" ]; then _pass "[edge021e-dup-model] ps raw output has exactly one model field"; else _fail "[edge021e-dup-model] ps model field count" "got: $ps021e_count in $ps021e_out"; fi
  if printf '%s' "$sh021e_out" | jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' >/dev/null 2>&1; then _pass "[edge021e-dup-model] sh model value is haiku"; else _fail "[edge021e-dup-model] sh model value" "got: $sh021e_out"; fi
  if printf '%s' "$ps021e_out" | jq -e '.hookSpecificOutput.updatedInput.model == "haiku"' >/dev/null 2>&1; then _pass "[edge021e-dup-model] ps model value is haiku"; else _fail "[edge021e-dup-model] ps model value" "got: $ps021e_out"; fi

  # Duplicate "subagent_type": fork-then-Explore rewrites (last value wins:
  # Explore), one field; Explore-then-fork denies reason C (last value: fork).
  edge021f_payload='{"tool_input":{"subagent_type":"fork","subagent_type":"Explore","prompt":"p"}}'
  sh021f_out=$(printf '%s' "$edge021f_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)
  ps021f_out=$(printf '%s' "$edge021f_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD pwsh -NoProfile -File "$SRC_REPO/hooks/pretooluse-model-guard.ps1" 2>&1)
  sh021f_count=$(printf '%s' "$sh021f_out" | grep -o '"subagent_type"' | wc -l | tr -d ' ')
  ps021f_count=$(printf '%s' "$ps021f_out" | grep -o '"subagent_type"' | wc -l | tr -d ' ')
  if [ "$sh021f_count" = "1" ]; then _pass "[edge021f-dup-subtype] sh raw output has exactly one subagent_type field"; else _fail "[edge021f-dup-subtype] sh field count" "got: $sh021f_count in $sh021f_out"; fi
  if [ "$ps021f_count" = "1" ]; then _pass "[edge021f-dup-subtype] ps raw output has exactly one subagent_type field"; else _fail "[edge021f-dup-subtype] ps field count" "got: $ps021f_count in $ps021f_out"; fi
  if printf '%s' "$sh021f_out" | jq -e '.hookSpecificOutput.updatedInput.subagent_type == "Explore"' >/dev/null 2>&1; then _pass "[edge021f-dup-subtype] sh subagent_type value is Explore"; else _fail "[edge021f-dup-subtype] sh subagent_type value" "got: $sh021f_out"; fi
  if printf '%s' "$ps021f_out" | jq -e '.hookSpecificOutput.updatedInput.subagent_type == "Explore"' >/dev/null 2>&1; then _pass "[edge021f-dup-subtype] ps subagent_type value is Explore"; else _fail "[edge021f-dup-subtype] ps subagent_type value" "got: $ps021f_out"; fi

  check_guard_equiv "edge021f-dup-subtype-reversed" '{"tool_input":{"subagent_type":"Explore","subagent_type":"fork","prompt":"p"}}' deny

  # Off-switch value trimming (a common Windows "set VAR=off " slip).
  check_guard_equiv "edge021g-off-padded" '{"tool_input":{"subagent_type":"Explore","model":"fable"}}' silent AF_MODEL_GUARD=" off "
  check_guard_equiv "edge021g-off-padded-caps" '{"tool_input":{"subagent_type":"Explore","model":"fable"}}' silent 'AF_MODEL_GUARD=OFF  '

  # EDGE-022: per-field surrogate sanitising (B1), rewrite fallback-deny
  # (M1), and case-sensitive field matching (m1).

  # (a) lone surrogate INSIDE the model field itself (not an unrelated
  # field) on a framework agent -> deny reason A, byte-identical.
  check_guard_equiv "edge022a-model-field-surrogate" '{"tool_input":{"subagent_type":"agentic-framework:python-expert","model":"fable\ud800","prompt":"p"}}' deny

  # (b) lone surrogate INSIDE the model field on a fork -> deny reason C
  # (proves one bad field cannot suppress the OTHER field's check).
  check_guard_equiv "edge022b-fork-model-field-surrogate" '{"tool_input":{"subagent_type":"fork","model":"sonnet\ud800","prompt":"p"}}' deny

  # (c) lone surrogate INSIDE subagent_type itself: the sanitised value
  # ("explore�") is not a recognised built-in name, so both
  # implementations pass silently. Pinned here as the agreed behaviour.
  check_guard_equiv "edge022c-subagent-type-field-surrogate" '{"tool_input":{"subagent_type":"Explore\ud800"}}' silent

  # (d) Explore/Plan/no-type, no model, lone surrogate in prompt -> cannot
  # echo safely, falls back to deny naming TYPE/TIER; byte-identical; no
  # updatedInput anywhere in the output.
  for edge022d_payload in \
    '{"tool_input":{"subagent_type":"Explore","prompt":"a\ud800b"}}' \
    '{"tool_input":{"subagent_type":"Plan","prompt":"a\ud800b"}}' \
    '{"tool_input":{"prompt":"a\ud800b"}}'
  do
    check_guard_equiv "edge022d-fallback-deny" "$edge022d_payload" deny
    sh022d_out=$(printf '%s' "$edge022d_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)
    ps022d_out=$(printf '%s' "$edge022d_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD pwsh -NoProfile -File "$SRC_REPO/hooks/pretooluse-model-guard.ps1" 2>&1)
    if printf '%s' "$sh022d_out" | grep -q updatedInput; then _fail "[edge022d-fallback-deny] sh must not emit updatedInput" "sh=$sh022d_out"; else _pass "[edge022d-fallback-deny] sh has no updatedInput key"; fi
    if printf '%s' "$ps022d_out" | grep -q updatedInput; then _fail "[edge022d-fallback-deny] ps must not emit updatedInput" "ps=$ps022d_out"; else _pass "[edge022d-fallback-deny] ps has no updatedInput key"; fi
  done

  # (e) framework agent, no model, lone surrogate in prompt -> still
  # silent (it has its own tier; nothing to rewrite, nothing to deny).
  check_guard_equiv "edge022e-framework-agent-surrogate-silent" '{"tool_input":{"subagent_type":"agentic-framework:python-expert","prompt":"a\ud800b"}}' silent

  # (f) case-variant field: the caller's "Model" field must survive
  # unchanged in BOTH outputs, with exactly one lowercase "model" field.
  edge022f_payload='{"description":"d","prompt":"p","Model":"zzz","subagent_type":"Explore"}'
  edge022f_payload="{\"tool_input\":$edge022f_payload}"
  check_guard_equiv "edge022f-case-variant-field" "$edge022f_payload" rewrite
  sh022f_out=$(printf '%s' "$edge022f_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)
  ps022f_out=$(printf '%s' "$edge022f_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD pwsh -NoProfile -File "$SRC_REPO/hooks/pretooluse-model-guard.ps1" 2>&1)
  if printf '%s' "$sh022f_out" | jq -e '.hookSpecificOutput.updatedInput.Model == "zzz"' >/dev/null 2>&1; then _pass "[edge022f-case-variant-field] sh preserves caller's Model field"; else _fail "[edge022f-case-variant-field] sh Model field" "got: $sh022f_out"; fi
  if printf '%s' "$ps022f_out" | jq -e '.hookSpecificOutput.updatedInput.Model == "zzz"' >/dev/null 2>&1; then _pass "[edge022f-case-variant-field] ps preserves caller's Model field"; else _fail "[edge022f-case-variant-field] ps Model field" "got: $ps022f_out"; fi
  sh022f_lower_count=$(printf '%s' "$sh022f_out" | grep -o '"model"' | wc -l | tr -d ' ')
  ps022f_lower_count=$(printf '%s' "$ps022f_out" | grep -o '"model"' | wc -l | tr -d ' ')
  if [ "$sh022f_lower_count" = "1" ]; then _pass "[edge022f-case-variant-field] sh has exactly one lowercase model field"; else _fail "[edge022f-case-variant-field] sh lowercase model count" "got: $sh022f_lower_count in $sh022f_out"; fi
  if [ "$ps022f_lower_count" = "1" ]; then _pass "[edge022f-case-variant-field] ps has exactly one lowercase model field"; else _fail "[edge022f-case-variant-field] ps lowercase model count" "got: $ps022f_lower_count in $ps022f_out"; fi
}

# --- CODE-REVIEW: gatekeeper marker + pretooluse-code-review-gate deny wordings
section "[CODE-REVIEW] code-review marker through both recorders"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  state_ps_msys="$workdir/state_ps"
  state_sh_msys="$workdir/state_sh"
  state_ps_win=$(cygpath -w "$state_ps_msys" 2>/dev/null || echo "$state_ps_msys")
  testgit_win=$(cygpath -w "$testgit" 2>/dev/null || echo "$testgit")
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  report=$'Review done.\nTarget: feature/x vs origin/main (abc1234..def5678); fallback: none\nVERDICT: APPROVED'
  payload_ps=$(jq -n --arg cwd "$testgit_win" --arg t "$report" '{session_id:"crm",hook_event_name:"PostToolUse",tool_use_id:"tool_1",tool_name:"Agent",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:$t,cwd:$cwd}')
  payload_sh=$(jq -n --arg cwd "$testgit" --arg t "$report" '{session_id:"crm",hook_event_name:"PostToolUse",tool_use_id:"tool_1",tool_name:"Agent",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:$t,cwd:$cwd}')
  printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1

  if grep -q '^target=feature/x vs origin/main' "$state_sh_msys/code-review/crm" 2>/dev/null; then
    _pass "code-review marker: sh marker carries the target line"
  else
    _fail "code-review marker: sh marker target line" "$(cat "$state_sh_msys/code-review/crm" 2>&1)"
  fi
  marker_compare "$state_ps_msys/code-review/crm" "$state_sh_msys/code-review/crm" "code-review marker"
  sidecar_compare "$state_ps_msys/code-review/crm.verdict-sources" "$state_sh_msys/code-review/crm.verdict-sources" "code-review marker .verdict-sources"
  rm -rf "$workdir"
}

# --- HAND-BACK: report delivered through the SubagentHandback tool call (transcript), launch ack skipped
section "[HAND-BACK] hand-back report through both recorders"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  state_ps_msys="$workdir/state_ps"
  state_sh_msys="$workdir/state_sh"
  state_ps_win=$(cygpath -w "$state_ps_msys" 2>/dev/null || echo "$state_ps_msys")
  testgit_win=$(cygpath -w "$testgit" 2>/dev/null || echo "$testgit")
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  transcript="$workdir/agent-transcript.jsonl"
  transcript_win=$(cygpath -w "$transcript" 2>/dev/null || echo "$transcript")
  hb_msg=$'Review done.\nTarget: feat/x vs origin/main (abc1234..def5678); fallback: none\nVERDICT: APPROVED'
  {
    jq -c -n '{type:"user",timestamp:"2026-10-22T17:44:40.100Z",message:{role:"user",content:[{type:"text",text:"Review the branch."}]}}'
    jq -c -n '{type:"assistant",timestamp:"2026-10-22T17:44:45.200Z",message:{role:"assistant",content:[{type:"text",text:"Reviewing..."}]}}'
    jq -c -n --arg m "$hb_msg" '{type:"assistant",timestamp:"2026-10-22T17:44:49.753Z",message:{role:"assistant",content:[{type:"tool_use",id:"toolu_01HB",name:"SubagentHandback",input:{message:$m},caller:{type:"direct"}}]},wireToolInputs:{message:$m}}'
    jq -c -n '{type:"user",timestamp:"2026-10-22T17:44:50.300Z",message:{role:"user",content:[{type:"tool_result",tool_use_id:"toolu_01HB",content:"{\"success\":true,\"message\":\"Report delivered to your caller.\"}"}]}}'
  } > "$transcript"

  payload_ps=$(jq -n --arg cwd "$testgit_win" --arg tp "$transcript_win" '{session_id:"hbm",hook_event_name:"SubagentStop",agent_type:"code-review-gatekeeper",agent_id:"hb1agent",last_assistant_message:"",agent_transcript_path:$tp,cwd:$cwd}')
  payload_sh=$(jq -n --arg cwd "$testgit" --arg tp "$transcript" '{session_id:"hbm",hook_event_name:"SubagentStop",agent_type:"code-review-gatekeeper",agent_id:"hb1agent",last_assistant_message:"",agent_transcript_path:$tp,cwd:$cwd}')
  printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1

  if grep -q '^verdict=APPROVED$' "$state_sh_msys/code-review/hbm" 2>/dev/null && grep -q '^target=feat/x vs origin/main' "$state_sh_msys/code-review/hbm" 2>/dev/null; then
    _pass "hand-back marker: sh marker carries verdict and target from the transcript"
  else
    _fail "hand-back marker: sh marker verdict/target" "$(cat "$state_sh_msys/code-review/hbm" 2>&1)"
  fi
  marker_compare "$state_ps_msys/code-review/hbm" "$state_sh_msys/code-review/hbm" "hand-back marker"
  sidecar_compare "$state_ps_msys/code-review/hbm.verdict-sources" "$state_sh_msys/code-review/hbm.verdict-sources" "hand-back marker .verdict-sources"

  # Continuation: the same hand-back seen again after HEAD moved is suppressed by both recorders
  hb_head1=$(git -C "$testgit" rev-parse HEAD)
  git -C "$testgit" commit -q --allow-empty -m "hand-back continuation moves HEAD"
  [ "$(git -C "$testgit" rev-parse HEAD)" != "$hb_head1" ] || _fail "hand-back continuation" "HEAD did not move"
  printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1
  if grep -q "^head=$hb_head1\$" "$state_ps_msys/code-review/hbm" 2>/dev/null && grep -q "^head=$hb_head1\$" "$state_sh_msys/code-review/hbm" 2>/dev/null; then
    _pass "hand-back continuation: both markers still carry the first HEAD"
  else
    _fail "hand-back continuation: markers moved to the new HEAD" "ps: $(cat "$state_ps_msys/code-review/hbm" 2>&1); sh: $(cat "$state_sh_msys/code-review/hbm" 2>&1)"
  fi
  if grep -q 'guard=instance-dedupe' "$state_ps_msys/code-review/hbm.verdict-suppressed" 2>/dev/null && grep -q 'guard=instance-dedupe' "$state_sh_msys/code-review/hbm.verdict-suppressed" 2>/dev/null; then
    _pass "hand-back continuation: both recorders log guard=instance-dedupe"
  else
    _fail "hand-back continuation: instance-dedupe audit line missing" "ps: $(cat "$state_ps_msys/code-review/hbm.verdict-suppressed" 2>&1); sh: $(cat "$state_sh_msys/code-review/hbm.verdict-suppressed" 2>&1)"
  fi

  # PostToolUse launch acknowledgement: neither side writes anything
  ack=$'Async agent launched successfully. (This tool result is internal metadata \xe2\x80\x94 never quote or paste any part of it, including the agentId below, into a user-facing reply.)\nagentId: 0123456789abcdef0 (internal ID - do not mention to user.)\nThe agent works in the background.'
  ack_ps=$(jq -n --arg cwd "$testgit_win" --arg t "$ack" '{session_id:"hback",hook_event_name:"PostToolUse",tool_use_id:"toolu_ack",tool_name:"Agent",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:[{type:"text",text:$t}],cwd:$cwd}')
  ack_sh=$(jq -n --arg cwd "$testgit" --arg t "$ack" '{session_id:"hback",hook_event_name:"PostToolUse",tool_use_id:"toolu_ack",tool_name:"Agent",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:[{type:"text",text:$t}],cwd:$cwd}')
  printf '%s' "$ack_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$ack_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1
  if [ ! -e "$state_ps_msys/code-review/hback" ] && [ ! -e "$state_sh_msys/code-review/hback" ]; then
    _pass "hand-back launch acknowledgement: neither recorder writes a marker"
  else
    _fail "hand-back launch acknowledgement" "ps marker: $([ -e "$state_ps_msys/code-review/hback" ] && echo yes || echo no); sh marker: $([ -e "$state_sh_msys/code-review/hback" ] && echo yes || echo no)"
  fi

  # PostToolUse launch acknowledgement, object form (the payload shape): neither side writes anything
  ackobj_ps=$(jq -n --arg cwd "$testgit_win" '{session_id:"hbobj",hook_event_name:"PostToolUse",tool_use_id:"toolu_ackobj",tool_name:"Agent",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:{agentId:"aa304bc86dde44d40",canContinueAgent:true,canReadOutputFile:false,description:"x",isAsync:true,outputFile:"C:/t/a.output",prompt:"short",resolvedModel:"claude-sonnet-5-5",status:"async_launched"},cwd:$cwd}')
  ackobj_sh=$(jq -n --arg cwd "$testgit" '{session_id:"hbobj",hook_event_name:"PostToolUse",tool_use_id:"toolu_ackobj",tool_name:"Agent",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:{agentId:"aa304bc86dde44d40",canContinueAgent:true,canReadOutputFile:false,description:"x",isAsync:true,outputFile:"C:/t/a.output",prompt:"short",resolvedModel:"claude-sonnet-5-5",status:"async_launched"},cwd:$cwd}')
  [ -n "$ackobj_sh" ] && [ -n "$ackobj_ps" ] || _fail "object-form fixture" "jq produced no payload"
  printf '%s' "$ackobj_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$ackobj_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1
  if [ ! -e "$state_ps_msys/code-review/hbobj" ] && [ ! -e "$state_sh_msys/code-review/hbobj" ]; then
    _pass "hand-back launch acknowledgement (object form): neither recorder writes a marker"
  else
    _fail "hand-back launch acknowledgement (object form)" "ps marker: $([ -e "$state_ps_msys/code-review/hbobj" ] && echo yes || echo no); sh marker: $([ -e "$state_sh_msys/code-review/hbobj" ] && echo yes || echo no)"
  fi

  # Transcript above 16 MiB with the hand-back beyond its first 16 MiB: both read the tail
  big="$workdir/big-transcript.jsonl"
  big_win=$(cygpath -w "$big" 2>/dev/null || echo "$big")
  filler=$(jq -c -n --arg t "$(head -c 4000 /dev/zero | tr '\0' x)" '{type:"assistant",timestamp:"2026-10-22T17:44:42.000Z",message:{role:"assistant",content:[{type:"text",text:$t}]}}')
  {
    head -n 2 "$transcript"
    yes "$filler" | head -n 4300
    tail -n 2 "$transcript"
  } > "$big"
  payload_ps=$(jq -n --arg cwd "$testgit_win" --arg tp "$big_win" '{session_id:"hbbig",hook_event_name:"SubagentStop",agent_type:"code-review-gatekeeper",agent_id:"hbbigagent",last_assistant_message:"",agent_transcript_path:$tp,cwd:$cwd}')
  payload_sh=$(jq -n --arg cwd "$testgit" --arg tp "$big" '{session_id:"hbbig",hook_event_name:"SubagentStop",agent_type:"code-review-gatekeeper",agent_id:"hbbigagent",last_assistant_message:"",agent_transcript_path:$tp,cwd:$cwd}')
  printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_ps_win" pwsh -NoProfile -File "$SRC_REPO/hooks/record-subagent-run.ps1" >/dev/null 2>&1
  printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state_sh_msys" sh "$SRC_REPO/hooks/record-subagent-run.sh" >/dev/null 2>&1
  if [ "$(wc -c < "$big")" -gt 16777216 ] && grep -q '^verdict=APPROVED$' "$state_sh_msys/code-review/hbbig" 2>/dev/null; then
    _pass "hand-back beyond the cap: sh marker carries the verdict from a transcript over 16 MiB"
  else
    _fail "hand-back beyond the cap: sh marker verdict" "$(cat "$state_sh_msys/code-review/hbbig" 2>&1)"
  fi
  marker_compare "$state_ps_msys/code-review/hbbig" "$state_sh_msys/code-review/hbbig" "hand-back beyond the cap"
  rm -f "$big"
  rm -rf "$workdir"
}

# gate_equiv <label> <sid> <cwd-subdir> <command> <marker-kind> [marker-target]
# Builds a fixture repo (origin remote, origin/main one commit behind main, feature/x
# one commit ahead), writes a marker per <marker-kind>, runs both gates on the same
# payload with the same CLAUDE_STATE_DIR and compares stdout byte-for-byte (CR stripped).
gate_equiv() {
  local label="$1" sid="$2" cmd="$3" mkind="$4" mtgt="${5:-feature/x vs origin/main (@MB@..@HEAD@); fallback: none}" tool="${6:-Bash}" rawc="${7:-}"
  local wd repo repo_win state state_win head mb payload_ps payload_sh
  local f_ps f_sh ps_rc sh_rc
  wd="$(make_work_dir)" || exit 2
  repo="$wd/repo"; state="$wd/state"
  repo_win=$(cygpath -w "$repo" 2>/dev/null || echo "$repo")
  state_win=$(cygpath -w "$state" 2>/dev/null || echo "$state")
  mkdir -p "$repo" "$state/code-review"
  make_test_repo "$repo"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" remote add origin "$repo.nowhere"
  git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse main)"
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  head=$(git -C "$repo" rev-parse HEAD)
  # the marker's reviewed range is real, so it binds per REQ-004: <merge-base with origin/main>..<HEAD>
  mb=$(git -C "$repo" merge-base refs/remotes/origin/main HEAD)
  mtgt="${mtgt//@MB@/$mb}"; mtgt="${mtgt//@HEAD@/$head}"
  case "$mkind" in
    none) ;;
    approved) printf '2026-10-21T00:00:00Z\nverdict=APPROVED\nhead=%s\ntarget=%s' "$head" "$mtgt" > "$state/code-review/$sid" ;;
    stale) printf '2026-10-21T00:00:00Z\nverdict=APPROVED\nhead=%s\ntarget=%s' '0123456789abcdef0123456789abcdef01234567' "$mtgt" > "$state/code-review/$sid" ;;
    changes) printf '2026-10-21T00:00:00Z\nverdict=CHANGES_REQUIRED\nhead=%s\ntarget=%s' "$head" "$mtgt" > "$state/code-review/$sid" ;;
  esac
  payload_ps=$(jq -cn --arg s "$sid" --arg c "$repo_win" --arg m "$cmd" --arg t "$tool" '{session_id:$s,cwd:$c,tool_name:$t,tool_input:{command:$m}}')
  payload_sh=$(jq -cn --arg s "$sid" --arg c "$repo" --arg m "$cmd" --arg t "$tool" '{session_id:$s,cwd:$c,tool_name:$t,tool_input:{command:$m}}')
  if [ -n "$rawc" ]; then
    # a raw JSON string for the command (no jq on the command: it may hold a lone surrogate escape)
    payload_ps="{\"session_id\":\"$sid\",\"cwd\":$(jq -cn --arg c "$repo_win" '$c' | tr -d '\r'),\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"$rawc\"}}"
    payload_sh="{\"session_id\":\"$sid\",\"cwd\":$(jq -cn --arg c "$repo" '$c' | tr -d '\r'),\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"$rawc\"}}"
  fi
  f_ps="$wd/out_ps"; f_sh="$wd/out_sh"
  printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_win" pwsh -NoProfile -File "$SRC_REPO/hooks/pretooluse-code-review-gate.ps1" 2>&1 | tr -d '\r' > "$f_ps"
  ps_rc=${PIPESTATUS[1]}
  printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state" sh "$SRC_REPO/hooks/pretooluse-code-review-gate.sh" 2>&1 | tr -d '\r' > "$f_sh"
  sh_rc=${PIPESTATUS[1]}
  if [ "$ps_rc" -eq 0 ] && [ "$sh_rc" -eq 0 ]; then
    if [ -s "$f_ps" ] && [ -s "$f_sh" ]; then
      if cmp -s "$f_ps" "$f_sh"; then
        _pass "$label: both exit 0, non-empty, byte-identical stdout"
      else
        _fail "$label" "stdout differs (ps=$(head -c 300 "$f_ps") | sh=$(head -c 300 "$f_sh"))"
      fi
    else
      _fail "$label" "empty output (ps bytes=$(wc -c < "$f_ps"), sh bytes=$(wc -c < "$f_sh"))"
    fi
  else
    _fail "$label" "exit codes ps=$ps_rc sh=$sh_rc"
  fi
  rm -rf "$wd"
}

section "[CODE-REVIEW-GATE] gate deny wordings through both implementations"
gate_equiv "gate deny: no marker" ge1 'git push origin HEAD:main' none
gate_equiv "gate deny: stale head" ge2 'git push origin HEAD:main' stale
gate_equiv "gate deny: base mismatch" ge3 'git push origin HEAD:main' approved 'feature/x vs develop (@MB@..@HEAD@); fallback: none'
gate_equiv "gate deny: non-branch review target" ge4 'git push origin HEAD:main' approved 'uncommitted @ 0123456789abcdef0123456789abcdef01234567 (3 files)'
gate_equiv "gate deny: changes required" ge5 'git push origin HEAD:main' changes
gate_equiv "gate deny: unknown remote ref" ge6 'git push origin HEAD:master' none
gate_equiv "gate deny: unconfigured remote" ge7 'git push upstream HEAD:main' none
gate_equiv "gate deny: source not checked out" ge8 'git push origin main:main' none
gate_equiv "gate deny: not a plain command" ge9 'git commit --allow-empty -m x && git push origin HEAD:main' none
gate_equiv "gate deny: unresolvable text" ge10 'git push origin "main' none
gate_equiv "gate deny: drive-relative dir (PowerShell dialect)" ge11 'cd C:; git push origin main' none '' PowerShell
# decision T (T.7, T.2, T.4) under decision H: the same deny bytes from both grammars
gate_equiv "gate deny: quoted keyword" ge12 '"git" push origin HEAD:main' none
gate_equiv "gate deny: doubled quote (PowerShell dialect)" ge13 "gh pr create --title 'it''s'" none '' PowerShell
gate_equiv "gate deny: adjacent quoted strings (PowerShell dialect)" ge14 "gh pr create --title a'x'\"y\"" none '' PowerShell
gate_equiv "gate deny: quoted redirection target" ge15 'gh pr create --fill > "out file"' none
gate_equiv "gate deny: -o value is not a dry run" ge16 'git push -o -n origin HEAD:main' none
# shellcheck disable=SC2016
gate_equiv "gate deny: default-value expansion" ge17 'git pu${a:-s}h origin HEAD:main' none
# gate-round amendments (T.11, decision H labels)
gate_equiv "gate deny: backtick glued to a word" ge18 $'x`\r\ngit push origin main' none '' PowerShell
# shellcheck disable=SC2016
gate_equiv "gate deny: empty expansion in a keyword" ge19 'git pu$()sh origin main' none
gate_equiv "gate deny: PowerShell stop-parsing token" ge20 'gh pr create --% -B dev -t x' none '' PowerShell
# the seventh argument is the raw JSON text of the command: a lone surrogate escape (backslash-u D800)
gate_equiv "gate deny: lone surrogate escape" ge21 '' none '' Bash 'git push origin main #\ud800'
# on Windows jq writes every LF as CRLF: on a jq 1.7+ host this exercises the -b re-run (T.11e);
# the fallback undo for a jq without -b is covered by the "T.11e fallback" section of hooks.test.sh;
# elsewhere plain parity
gate_equiv "gate deny: Windows CRLF payload" ge22 $'git pu`\r\nsh origin main' none '' PowerShell

# gate_equiv_allow <label> <sid> <command> [tool]: both implementations exit 0, silent
gate_equiv_allow() {
  local label="$1" sid="$2" cmd="$3" tool="${4:-Bash}" wd repo repo_win state state_win payload_ps payload_sh ps_rc sh_rc out_ps out_sh
  wd="$(make_work_dir)" || exit 2
  repo="$wd/repo"; state="$wd/state"
  repo_win=$(cygpath -w "$repo" 2>/dev/null || echo "$repo")
  state_win=$(cygpath -w "$state" 2>/dev/null || echo "$state")
  mkdir -p "$repo" "$state/code-review"
  make_test_repo "$repo"
  payload_ps=$(jq -cn --arg s "$sid" --arg c "$repo_win" --arg m "$cmd" --arg t "$tool" '{session_id:$s,cwd:$c,tool_name:$t,tool_input:{command:$m}}')
  payload_sh=$(jq -cn --arg s "$sid" --arg c "$repo" --arg m "$cmd" --arg t "$tool" '{session_id:$s,cwd:$c,tool_name:$t,tool_input:{command:$m}}')
  printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_win" pwsh -NoProfile -File "$SRC_REPO/hooks/pretooluse-code-review-gate.ps1" > "$wd/out_ps" 2>&1; ps_rc=$?
  printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state" sh "$SRC_REPO/hooks/pretooluse-code-review-gate.sh" > "$wd/out_sh" 2>&1; sh_rc=$?
  out_ps=$(tr -d '\r' < "$wd/out_ps"); out_sh=$(tr -d '\r' < "$wd/out_sh")
  if [ "$ps_rc" -eq 0 ] && [ "$sh_rc" -eq 0 ] && [ -z "$out_ps" ] && [ -z "$out_sh" ]; then
    _pass "$label: both exit 0 with empty output"
  else
    _fail "$label" "ps rc=$ps_rc out=$(printf '%s' "$out_ps" | head -c 200) | sh rc=$sh_rc out=$(printf '%s' "$out_sh" | head -c 200)"
  fi
  rm -rf "$wd"
}
# shellcheck disable=SC2016
gate_equiv_allow "gate allow: unclosed brace text" ga1 'echo git${a-push'
# CR CR LF is not a continuation pair: one CR stripped too many (two stripped, CR LF left) turns
# this allow into a deny; the other direction (too few) is caught by the in-word CR LF deny rows
gate_equiv_allow "gate allow: CR CR LF continuation is not a pair" ga2 $'git pu`\r\r\nsh origin HEAD:main' PowerShell

# decision T.1: the grammar block is byte-identical in the two hooks (the .ps1 is the
# reference: a single-quoted here-string; the .sh: a single-quoted string)
{
  wd="$(make_work_dir)" || exit 2
  sed -n "/^\$script:GDEFS = @'\$/,/^'@\$/p" "$SRC_REPO/hooks/pretooluse-code-review-gate.ps1" | sed '1d;$d' | tr -d '\r' > "$wd/g_ps"
  sed -n "/^G_DEFS='\$/,/^'\$/p" "$SRC_REPO/hooks/pretooluse-code-review-gate.sh" | sed '1d;$d' > "$wd/g_sh"
  g_n=$(grep -c '=' "$wd/g_ps")
  if [ "$g_n" -ge 50 ] && cmp -s "$wd/g_ps" "$wd/g_sh"; then
    _pass "gate grammar block: byte-identical in .ps1 and .sh ($g_n lines)"
  else
    _fail "gate grammar block" "differs or missing (ps lines=$(wc -l < "$wd/g_ps"), sh lines=$(wc -l < "$wd/g_sh")): $(diff "$wd/g_ps" "$wd/g_sh" | head -5)"
  fi
  rm -rf "$wd"
}

# gate allow: an MSYS absolute path (/c/...) in a cd resolves in both implementations
# (EDGE-001 row 164; I-ter.2): feat/x with upstream origin/feat/x, so a bare push is allowed.
{
  wd="$(make_work_dir)" || exit 2
  repo="$wd/repo"; state="$wd/state"
  repo_win=$(cygpath -w "$repo" 2>/dev/null || echo "$repo")
  state_win=$(cygpath -w "$state" 2>/dev/null || echo "$state")
  mkdir -p "$repo" "$state/code-review"
  make_test_repo "$repo"
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" remote add origin "$repo.nowhere"
  git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -q -b feat/x
  git -C "$repo" update-ref refs/remotes/origin/feat/x "$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" config branch.feat/x.remote origin
  git -C "$repo" config branch.feat/x.merge refs/heads/feat/x
  # MSYS drive form /<drive>/...: cygpath -u would map a temp dir back to its /tmp mount
  repo_msys=$(cygpath -m "$repo" 2>/dev/null | sed -E 's#^([A-Za-z]):#/\L\1#')
  [ -n "$repo_msys" ] || repo_msys="$repo"
  m_cmd="cd $repo_msys && git push"
  payload_ps=$(jq -cn --arg c "$repo_win" --arg m "$m_cmd" '{session_id:"gma",cwd:$c,tool_name:"Bash",tool_input:{command:$m}}')
  payload_sh=$(jq -cn --arg c "$repo" --arg m "$m_cmd" '{session_id:"gma",cwd:$c,tool_name:"Bash",tool_input:{command:$m}}')
  # Exit codes are captured per command (PIPESTATUS inside $(...) is not visible to the parent shell).
  printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_win" pwsh -NoProfile -File "$SRC_REPO/hooks/pretooluse-code-review-gate.ps1" > "$wd/out_ps" 2>&1; ps_rc=$?
  printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state" sh "$SRC_REPO/hooks/pretooluse-code-review-gate.sh" > "$wd/out_sh" 2>&1; sh_rc=$?
  out_ps=$(tr -d '\r' < "$wd/out_ps"); out_sh=$(tr -d '\r' < "$wd/out_sh")
  if [ "$ps_rc" -eq 0 ] && [ "$sh_rc" -eq 0 ] && [ -z "$out_ps" ] && [ -z "$out_sh" ]; then
    _pass "gate allow: msys path: both exit 0 with empty output"
  else
    _fail "gate allow: msys path" "ps rc=$ps_rc out=$(printf '%s' "$out_ps" | head -c 200) | sh rc=$sh_rc out=$(printf '%s' "$out_sh" | head -c 200)"
  fi
  rm -rf "$wd"
}

# gate allow: a text that begins "git stash push" is not a candidate in either implementation
# (decision S.1, anchored exemption): both stay silent on "git stash push;" whatever follows.
{
  wd="$(make_work_dir)" || exit 2
  repo="$wd/repo"; state="$wd/state"
  repo_win=$(cygpath -w "$repo" 2>/dev/null || echo "$repo")
  state_win=$(cygpath -w "$state" 2>/dev/null || echo "$state")
  mkdir -p "$repo" "$state/code-review"
  make_test_repo "$repo"
  s_cmd='git stash push;'
  payload_ps=$(jq -cn --arg c "$repo_win" --arg m "$s_cmd" '{session_id:"gsp",cwd:$c,tool_name:"Bash",tool_input:{command:$m}}')
  payload_sh=$(jq -cn --arg c "$repo" --arg m "$s_cmd" '{session_id:"gsp",cwd:$c,tool_name:"Bash",tool_input:{command:$m}}')
  printf '%s' "$payload_ps" | CLAUDE_STATE_DIR="$state_win" pwsh -NoProfile -File "$SRC_REPO/hooks/pretooluse-code-review-gate.ps1" > "$wd/out_ps" 2>&1; ps_rc=$?
  printf '%s' "$payload_sh" | CLAUDE_STATE_DIR="$state" sh "$SRC_REPO/hooks/pretooluse-code-review-gate.sh" > "$wd/out_sh" 2>&1; sh_rc=$?
  out_ps=$(tr -d '\r' < "$wd/out_ps"); out_sh=$(tr -d '\r' < "$wd/out_sh")
  if [ "$ps_rc" -eq 0 ] && [ "$sh_rc" -eq 0 ] && [ -z "$out_ps" ] && [ -z "$out_sh" ]; then
    _pass "gate allow: git stash push: both exit 0 with empty output"
  else
    _fail "gate allow: git stash push" "ps rc=$ps_rc out=$(printf '%s' "$out_ps" | head -c 200) | sh rc=$sh_rc out=$(printf '%s' "$out_sh" | head -c 200)"
  fi
  rm -rf "$wd"
}

# === Summary
printf '\n%s================================================%s\n' "$C_CYN" "$C_NC"
printf 'RESULT: %d run, %d pass, %d fail\n' "$TESTS_RUN" "$TESTS_PASS" "$TESTS_FAIL"
printf '%s================================================%s\n' "$C_CYN" "$C_NC"

exit "$([  "$TESTS_FAIL" -eq 0 ] && echo 0 || echo 1)"
