#!/usr/bin/env bash
# hooks.test.sh — Bash test harness for hooks/*.sh test runner.
# Hooks under test are POSIX sh; this harness requires bash for test control.
# Tests exercise plain sh hook implementations.
#
# Builds a throwaway git repo + isolated state dir (CLAUDE_STATE_DIR), feeds each
# hook synthetic stdin JSON, and asserts on output/exit codes. Exit 0 = all pass.
#
# Usage: bash tests/hooks.test.sh

set -u

# --- locate the repo under test ────────────────────────────────────────────
# The harness lives at <repo>/tests/hooks.test.sh, so the source repo is
# one level up from this script's directory.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_REPO="$(cd "$TEST_DIR/.." && pwd)"

# --- output helpers ────────────────────────────────────────────────────────
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
HARNESS_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hooks-test.XXXXXXXX") || exit 1

cleanup_all() {
  cd / 2>/dev/null || true
  [ -n "${HARNESS_ROOT:-}" ] && rm -rf "$HARNESS_ROOT"
}
trap cleanup_all EXIT INT TERM

# Defensive precondition: ensure harness root is NOT inside a git worktree.
# This belt-and-suspenders check prevents test dirs from mutating the repo
# if mktemp accidentally creates a dir inside an existing worktree.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
if git -C "$HARNESS_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'FATAL: harness root %s is inside a git worktree\n' "$HARNESS_ROOT" >&2
  exit 2
fi

# --- temp dir and repo helpers ─────────────────────────────────────────────
make_work_dir() {
  # Create a throwaway temp directory under HARNESS_ROOT for test fixtures.
  # All test subdirectories are created here, ensuring proper isolation.
  local wd
  wd=$(mktemp -d "$HARNESS_ROOT/wd.XXXXXX") || {
    printf 'FATAL: mktemp failed\n' >&2
    exit 2
  }
  printf '%s\n' "$wd"
}

make_test_repo() {
  # Create a git repo suitable for peer-review-gate testing
  local d="$1"
  git -C "$d" init -q -b main
  # Safety guard: if init failed, later git -C calls would walk up into the
  # enclosing REAL repo and mutate it (add/commit/checkout). Never proceed.
  [ -d "$d/.git" ] || { printf 'make_test_repo: git init failed for %s\n' "$d" >&2; return 1; }
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

# --- hook runner ───────────────────────────────────────────────────────────
# run_dispatch <dispatch.sh> <hook_name> <stdin>
#   Runs dispatch.sh and captures stdout + exit code
RUN_OUT=""
RUN_RC=0
run_dispatch() {
  local dispatch="$1" hook="$2" stdin="$3"

  # Run dispatch.sh with stdin, capturing output and exit code
  RUN_OUT="$( (printf '%s' "$stdin" | sh "$dispatch" "$hook") 2>&1)"
  RUN_RC=$?
}

# --- assertions ────────────────────────────────────────────────────────────
_pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASS=$((TESTS_PASS + 1)); printf '  %sPASS%s  %s\n' "$C_GRN" "$C_NC" "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1))
  printf '  %sFAIL%s  %s\n' "$C_RED" "$C_NC" "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
}

assert_rc_zero() {
  local label="$1"
  if [ "$RUN_RC" -eq 0 ]; then _pass "$label (exit 0)"
  else _fail "$label" "expected exit 0, got $RUN_RC"; fi
}

assert_out_empty() {
  local label="$1"
  if [ -z "$RUN_OUT" ]; then _pass "$label (empty output)"
  else _fail "$label" "expected empty output, got: $RUN_OUT"; fi
}

assert_out_contains() {
  local label="$1" needle="$2"
  if printf '%s' "$RUN_OUT" | grep -qF -- "$needle"; then _pass "$label"
  else _fail "$label" "expected output to contain: $needle"; fi
}

section() { printf '\n%s%s%s\n' "$C_CYN" "$1" "$C_NC"; }

# ===========================================================================
printf '%s================================================%s\n' "$C_CYN" "$C_NC"
printf '%s  Bash Hooks Dispatch Test Harness%s\n' "$C_CYN" "$C_NC"
printf '%s  source repo: %s%s\n' "$C_CYN" "$SRC_REPO" "$C_NC"
printf '%s================================================%s\n' "$C_CYN" "$C_NC"

# --- dispatch cases ────────────────────────────────────────────────────────

section "[DISPATCH-A] Unknown hook name → exit 0, empty output"
{
  workdir="$(make_work_dir)" || exit 2
  cp "$SRC_REPO/hooks/dispatch.sh" "$workdir/" 2>/dev/null || true

  if [ -f "$workdir/dispatch.sh" ]; then
    run_dispatch "$workdir/dispatch.sh" "unknown-hook" ""
    assert_rc_zero "unknown hook routes to exit 0"
    assert_out_empty "unknown hook produces no output"
  else
    _fail "dispatch.sh exists" "hooks/dispatch.sh not found; test skipped"
  fi
  rm -rf "$workdir"
}

section "[DISPATCH-B] Empty/missing hook name → exit 0, empty output"
{
  workdir="$(make_work_dir)" || exit 2
  cp "$SRC_REPO/hooks/dispatch.sh" "$workdir/" 2>/dev/null || true

  if [ -f "$workdir/dispatch.sh" ]; then
    run_dispatch "$workdir/dispatch.sh" "" ""
    assert_rc_zero "empty hook name routes to exit 0"
    assert_out_empty "empty hook name produces no output"
  else
    _fail "dispatch.sh exists" "hooks/dispatch.sh not found; test skipped"
  fi
  rm -rf "$workdir"
}

section "[DISPATCH-C1] platform-aware routing: MSYS arm vs Linux sh arm"
{
  workdir="$(make_work_dir)" || exit 2
  mkdir -p "$workdir/hooks"
  cp "$SRC_REPO/hooks/dispatch.sh" "$workdir/hooks/" 2>/dev/null || true

  if [ -f "$workdir/hooks/dispatch.sh" ]; then
    # Detect actual platform
    platform_name=$(uname -s 2>/dev/null || echo "Unknown")
    case "$platform_name" in
      MINGW*|MSYS*|CYGWIN*)
        # Windows with MSYS family: jq present -> sh fast path; jq absent -> pwsh arm.
        # Both fakes exist so the test exercises whichever arm dispatch actually picks.
        cat > "$workdir/hooks/session-start-context.ps1" << 'PSFAKE'
$in = [Console]::In.ReadToEnd()
Write-Output "LEN=$($in.Length)"
PSFAKE
        cat > "$workdir/hooks/session-start-context.sh" << 'SHFAKE'
#!/bin/sh
in=$(cat)
printf 'SH_LEN=%s\n' "${#in}"
SHFAKE
        chmod +x "$workdir/hooks/session-start-context.sh"

        test_payload='{"session_id":"test_c1"}'
        payload_len=${#test_payload}

        run_dispatch "$workdir/hooks/dispatch.sh" "session-start-context" "$test_payload"

        if command -v jq >/dev/null 2>&1; then
          sh_len_value=$(printf '%s' "$RUN_OUT" | grep -o 'SH_LEN=[0-9]*' | head -1 | cut -d= -f2)
          assert_rc_zero "sh fast-path dispatch exits 0 (Windows, jq present)"
          if [ "$sh_len_value" = "$payload_len" ]; then
            _pass "jq present: dispatch fast-paths to .sh with stdin intact (SH_LEN=$sh_len_value) on MSYS"
          else
            _fail "sh fast path on MSYS" "expected SH_LEN=$payload_len, got: $RUN_OUT"
          fi
        else
          len_value=$(printf '%s' "$RUN_OUT" | grep -o 'LEN=[0-9]*' | head -1 | cut -d= -f2)
          assert_rc_zero "pwsh-arm dispatch exits 0 (Windows, no jq)"
          if [ "$len_value" = "$payload_len" ]; then
            _pass "stdin payload passed through to pwsh (LEN=$len_value) on MSYS"
          else
            _fail "stdin passthrough to pwsh" "expected LEN=$payload_len, got LEN=$len_value"
          fi
        fi
        ;;
      *)
        # Linux/Unix: expect sh arm
        cat > "$workdir/hooks/session-start-context.sh" << 'SHFAKE'
#!/bin/sh
printf 'SH_ARM_RAN\n'
SHFAKE
        chmod +x "$workdir/hooks/session-start-context.sh"

        test_payload='{"session_id":"test_c1"}'

        run_dispatch "$workdir/hooks/dispatch.sh" "session-start-context" "$test_payload"

        assert_rc_zero "sh-arm dispatch exits 0 (Linux)"
        if printf '%s' "$RUN_OUT" | grep -q 'SH_ARM_RAN'; then
          _pass "sh-arm routed correctly on Linux"
        else
          _fail "sh-arm routing on Linux" "expected SH_ARM_RAN, got: $RUN_OUT"
        fi
        ;;
    esac
  else
    _fail "dispatch.sh exists" "hooks/dispatch.sh not found; test skipped"
  fi
  rm -rf "$workdir"
}

section "[DISPATCH-C2] sh-arm routing via fake uname"
{
  workdir="$(make_work_dir)" || exit 2
  mkdir -p "$workdir/hooks" "$workdir/bin"
  cp "$SRC_REPO/hooks/dispatch.sh" "$workdir/hooks/" 2>/dev/null || true

  if [ -f "$workdir/hooks/dispatch.sh" ]; then
    # Create fake uname that reports Linux
    cat > "$workdir/bin/uname" << 'SHFAKE'
#!/bin/sh
echo "Linux"
SHFAKE
    chmod +x "$workdir/bin/uname"

    # Create fake sh hook that outputs SH_ARM_RAN
    cat > "$workdir/hooks/session-start-context.sh" << 'SHARM'
#!/bin/sh
printf 'SH_ARM_RAN\n'
SHARM
    chmod +x "$workdir/hooks/session-start-context.sh"

    # Invoke with PATH shimmed to use fake uname
    RUN_OUT="$(PATH="$workdir/bin:$PATH" sh "$workdir/hooks/dispatch.sh" "session-start-context" 2>&1)"
    RUN_RC=$?

    assert_rc_zero "sh-arm dispatch exits 0"
    if printf '%s' "$RUN_OUT" | grep -q 'SH_ARM_RAN'; then
      _pass "sh-arm routing via fake uname (output contains SH_ARM_RAN)"
    else
      _fail "sh-arm output" "expected SH_ARM_RAN in output, got: $RUN_OUT"
    fi

    if printf '%s' "$RUN_OUT" | grep -q 'LEN='; then
      _fail "sh-arm did not route to pwsh" "output contains LEN= (wrong arm)"
    else
      _pass "sh-arm correctly avoided pwsh arm (no LEN= prefix)"
    fi
  else
    _fail "dispatch.sh exists" "hooks/dispatch.sh not found; test skipped"
  fi
  rm -rf "$workdir"
}

section "[DISPATCH-D] dispatch always exits 0 even if child fails"
{
  workdir="$(make_work_dir)" || exit 2
  mkdir -p "$workdir/hooks"
  cp "$SRC_REPO/hooks/dispatch.sh" "$workdir/hooks/" 2>/dev/null || true

  if [ -f "$workdir/hooks/dispatch.sh" ]; then
    # Create a fake sh hook that exits with code 7
    cat > "$workdir/hooks/session-start-context.sh" << 'BADEXIT'
#!/bin/sh
exit 7
BADEXIT
    chmod +x "$workdir/hooks/session-start-context.sh"

    # Create a fake ps1 that also exits 7
    cat > "$workdir/hooks/session-start-context.ps1" << 'BADPS'
exit 7
BADPS

    run_dispatch "$workdir/hooks/dispatch.sh" "session-start-context" ""

    assert_rc_zero "dispatch returns 0 even when child exits non-zero"
  else
    _fail "dispatch.sh exists" "hooks/dispatch.sh not found; test skipped"
  fi
  rm -rf "$workdir"
}

section "[DISPATCH-E] No CR byte in all *.sh files"
{
  for sh_file in "$SRC_REPO"/hooks/*.sh; do
    if [ -f "$sh_file" ]; then
      fname=$(basename "$sh_file")
      if grep -q "$(printf '\r')" "$sh_file"; then
        _fail "$fname has no CR bytes" "CR bytes found in $fname"
      else
        _pass "$fname contains no CR bytes"
      fi
    fi
  done
  if [ ! -f "$SRC_REPO/hooks/dispatch.sh" ]; then
    _fail "dispatch.sh exists" "hooks/dispatch.sh not found; test skipped"
  fi
}

section "[SESSION-START-CONTEXT] ahead-of-base on feature branch"
{
  workdir="$(make_work_dir)" || exit 2
  mkdir -p "$workdir/test_repo"
  testgit="$workdir/test_repo"

  # Build test repo: init, config, commit, branch
  git -C "$testgit" init -q -b main
  git -C "$testgit" config user.email 'test@test.local'
  git -C "$testgit" config user.name 'hooks-test'
  printf 'one\n' > "$testgit/a.txt"
  git -C "$testgit" add -A
  git -C "$testgit" commit -q -m 'init'
  git -C "$testgit" checkout -q -b feature/x
  printf 'two\n' > "$testgit/b.txt"
  git -C "$testgit" add -A
  git -C "$testgit" commit -q -m 'feature work'

  # Test ahead-of-base
  test_payload="{\"session_id\":\"s1\",\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/session-start-context.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "ahead-of-base hook exits 0"
  if printf '%s' "$RUN_OUT" | grep -q 'ahead of'; then
    _pass "output contains 'ahead of'"
  else
    _fail "ahead-of-base output" "expected 'ahead of', got: $RUN_OUT"
  fi
  if printf '%s' "$RUN_OUT" | grep -q 'feature/x'; then
    _pass "output contains 'feature/x'"
  else
    _fail "ahead-of-base branch name" "expected 'feature/x', got: $RUN_OUT"
  fi

  rm -rf "$workdir"
}

section "[SESSION-START-CONTEXT] base-branch state on main"
{
  workdir="$(make_work_dir)" || exit 2
  mkdir -p "$workdir/test_repo"
  testgit="$workdir/test_repo"

  # Build test repo
  git -C "$testgit" init -q -b main
  git -C "$testgit" config user.email 'test@test.local'
  git -C "$testgit" config user.name 'hooks-test'
  printf 'one\n' > "$testgit/a.txt"
  git -C "$testgit" add -A
  git -C "$testgit" commit -q -m 'init'
  git -C "$testgit" checkout -q -b feature/x
  printf 'two\n' > "$testgit/b.txt"
  git -C "$testgit" add -A
  git -C "$testgit" commit -q -m 'feature work'
  git -C "$testgit" checkout -q main

  # Test on main branch
  test_payload="{\"session_id\":\"s2\",\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/session-start-context.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "main-branch hook exits 0"
  if printf '%s' "$RUN_OUT" | grep -q "On 'main'"; then
    _pass "output contains \"On 'main'\""
  else
    _fail "main-branch output" "expected \"On 'main'\", got: $RUN_OUT"
  fi
  assert_out_contains "main-branch message mentions the code-review gate" "code-review-gatekeeper"
  assert_out_contains "main-branch message keeps the peer-review statement" "The peer-review Stop gate applies only to feature branches; a push to main/master"

  rm -rf "$workdir"
}

section "[SESSION-START-CONTEXT] silent outside a git worktree"
{
  # Create temp dir OUTSIDE the repo (under HARNESS_ROOT, safe from repo mutations)
  workdir="$(make_work_dir)" || exit 2

  # Test outside git worktree
  test_payload="{\"session_id\":\"s3\",\"cwd\":\"$workdir\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/session-start-context.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "outside-git hook exits 0"
  assert_out_empty "outside-git produces no output"

  rm -rf "$workdir"
}

section "[SESSION-START-CONTEXT] fail-open on malformed stdin"
{
  RUN_OUT="$(printf 'not json' | sh "$SRC_REPO/hooks/session-start-context.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "malformed-stdin hook exits 0"
  assert_out_empty "malformed-stdin produces no output"
}

section "[SESSION-START-CONTEXT] jq not installed: preflight warning and exit 0"
{
  workdir="$(make_work_dir)" || exit 2
  mkdir -p "$workdir/bin" "$workdir/test_repo"
  testgit="$workdir/test_repo"
  make_test_repo "$testgit"

  # Create stub bin directory with symlinks/wrappers for tools the hook uses (cat, git),
  # but intentionally WITHOUT jq. This simulates an environment where jq is missing.
  # We use symlinks where possible, with wrapper-script fallback for Git Bash compatibility
  # (where symlinks may not be reliable). This mechanism is chosen because it works
  # consistently across both Linux and Git Bash without requiring knowledge of
  # system-specific binary paths.
  for tool in cat git; do
    real="$(command -v "$tool" 2>/dev/null)"
    [ -z "$real" ] && continue
    # Try symlink first; fallback to wrapper script if symlink fails (Git Bash)
    ln -s "$real" "$workdir/bin/$tool" 2>/dev/null || {
      printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$workdir/bin/$tool"
      chmod +x "$workdir/bin/$tool"
    }
  done
  # Crucially: do NOT create $workdir/bin/jq, so command -v jq will fail with our restricted PATH

  # Run hook with restricted PATH that is ONLY the stub bin directory. This ensures
  # jq cannot be found even if it exists in /usr/bin or other system paths (as on CI).
  # Capture the sh interpreter's path before restricting PATH, so we can invoke it directly.
  test_payload="{\"session_id\":\"no_jq\",\"cwd\":\"$testgit\"}"
  real_sh="$(command -v sh)"

  # Use a subshell with stub-only PATH; redirect output to a file for capture
  (
    PATH="$workdir/bin"
    export PATH
    printf '%s' "$test_payload" | "$real_sh" "$SRC_REPO/hooks/session-start-context.sh" 2>&1
  ) > "$workdir/output.txt"
  RUN_RC=$?
  RUN_OUT="$(cat "$workdir/output.txt" 2>/dev/null)"

  assert_rc_zero "jq-missing hook exits 0"
  assert_out_contains "jq-missing hook prints jq warning" "jq not installed"

  rm -rf "$workdir"
}

section "[SESSION-START-CONTEXT] jq installed: no preflight warning, normal behavior"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  # Run with normal PATH where jq is available (system default)
  test_payload="{\"session_id\":\"with_jq\",\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/session-start-context.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "normal hook exits 0"
  # Verify no jq warning when jq is present
  if printf '%s' "$RUN_OUT" | grep -qF 'jq not installed'; then
    _fail "no jq warning when jq present" "unexpected jq warning in: $RUN_OUT"
  else
    _pass "no jq warning when jq present"
  fi
  # Verify normal behavior: ahead-of-base message appears
  assert_out_contains "normal ahead-of-base message appears" "ahead of"

  rm -rf "$workdir"
}

section "[PRETOOLUSE-DELEGATION-HINT] suggests rust-expert for .rs file"
{
  workdir="$(make_work_dir)" || exit 2

  # Set CLAUDE_STATE_DIR for this test to isolate state
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR"

  # Test .rs file suggestion
  test_payload="{\"session_id\":\"d1\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$workdir/lib.rs\"}}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/pretooluse-delegation-hint.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "rust-expert hook exits 0"
  if printf '%s' "$RUN_OUT" | grep -q 'rust-expert'; then
    _pass "output contains 'rust-expert'"
  else
    _fail "rust-expert suggestion" "expected 'rust-expert', got: $RUN_OUT"
  fi
  if printf '%s' "$RUN_OUT" | grep -q '"systemMessage"'; then
    _pass "output contains '\"systemMessage\"'"
  else
    _fail "systemMessage field" "expected '\"systemMessage\"', got: $RUN_OUT"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[PRETOOLUSE-DELEGATION-HINT] hints at most once per session per agent"
{
  workdir="$(make_work_dir)" || exit 2

  # Set CLAUDE_STATE_DIR for this test
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR"

  # First .rs file in session d1
  test_payload="{\"session_id\":\"d1\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$workdir/lib.rs\"}}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/pretooluse-delegation-hint.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "first rust-expert hint exits 0"

  # Second .rs file in same session → should be silent
  test_payload="{\"session_id\":\"d1\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$workdir/main.rs\"}}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/pretooluse-delegation-hint.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "second rust-expert hint exits 0"
  if [ -z "$RUN_OUT" ]; then
    _pass "hints at most once per session per agent (silent on repeat)"
  else
    _fail "once-per-session hint" "expected no output on second hint, got: $RUN_OUT"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[PRETOOLUSE-DELEGATION-HINT] silent for unmapped extensions"
{
  workdir="$(make_work_dir)" || exit 2

  # Set CLAUDE_STATE_DIR for this test
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR"

  # Test .txt file (unmapped)
  test_payload="{\"session_id\":\"d2\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$workdir/notes.txt\"}}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/pretooluse-delegation-hint.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "unmapped-extension hook exits 0"
  assert_out_empty "unmapped-extension produces no output"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[PRETOOLUSE-DELEGATION-HINT] fail-open on malformed stdin"
{
  RUN_OUT="$(printf '[broken' | sh "$SRC_REPO/hooks/pretooluse-delegation-hint.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "malformed-stdin hook exits 0"
}

section "[STOP-PEER-REVIEW-GATE-1] loop-safety: stop_hook_active=true allows"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload="{\"session_id\":\"s1\",\"stop_hook_active\":true,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  assert_out_empty "gate produces no output"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-2] blocks: feature branch ahead, clean tree, no marker"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload="{\"session_id\":\"s2\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  if printf '%s' "$RUN_OUT" | grep -q 'decision.*block'; then
    _pass "gate blocks with decision:block JSON"
  else
    _fail "gate blocks" "expected decision:block JSON, got: $RUN_OUT"
  fi
  if printf '%s' "$RUN_OUT" | grep -q 'peer-review-critic'; then
    _pass "reason mentions peer-review-critic"
  else
    _fail "reason mentions peer-review-critic" "got: $RUN_OUT"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-3] fires at most once per session (.fired marker)"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # First call blocks
  test_payload="{\"session_id\":\"s2\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?
  if printf '%s' "$RUN_OUT" | grep -q 'decision.*block'; then
    _pass "first call blocks"
  else
    _fail "first call blocks" "got: $RUN_OUT"
  fi

  # Second call in same session should be silent (budget exhausted after 1 block in no-verdict case)
  test_payload="{\"session_id\":\"s2\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "second call exits 0"
  assert_out_empty "second call produces no output"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-4] allows when peer-review marker exists (legacy)"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Write legacy marker (just 'reviewed' text, no verdict line)
  printf 'reviewed' > "$CLAUDE_STATE_DIR/peer-review/s3"

  test_payload="{\"session_id\":\"s3\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  assert_out_empty "gate produces no output"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-5] allows when working tree is dirty"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Make tree dirty
  printf 'wip' > "$testgit/dirty.txt"

  test_payload="{\"session_id\":\"s4\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  assert_out_empty "gate produces no output"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-6] allows on base branch (main)"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Switch to main
  git -C "$testgit" checkout -q main

  test_payload="{\"session_id\":\"s5\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  assert_out_empty "gate produces no output"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-7] allows outside a git worktree"
{
  workdir="$(make_work_dir)" || exit 2
  non_git="$workdir/not_a_repo"
  mkdir -p "$non_git"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload="{\"session_id\":\"s6\",\"stop_hook_active\":false,\"cwd\":\"$non_git\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  assert_out_empty "gate produces no output"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-8] fail-open on malformed stdin"
{
  _wd="$(make_work_dir)" || exit 2
  CLAUDE_STATE_DIR="$_wd/state"
  export CLAUDE_STATE_DIR
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  RUN_OUT="$(printf 'this is not json' | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  assert_out_empty "gate produces no output"

  unset CLAUDE_STATE_DIR
}

section "[STOP-PEER-REVIEW-GATE-R7a] 3-line marker with verdict=APPROVED allows"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Get current HEAD
  head_now=$(git -C "$testgit" rev-parse HEAD)

  # Write 3-line marker with APPROVED verdict
  printf '2026-07-18T00:00:00.0000000+02:00\nverdict=APPROVED\nhead=%s' "$head_now" > "$CLAUDE_STATE_DIR/peer-review/r7-approved"

  test_payload="{\"session_id\":\"r7-approved\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  assert_out_empty "gate produces no output"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-R7b] 3-line marker with verdict=CHANGES_REQUIRED blocks"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Get current HEAD
  head_now=$(git -C "$testgit" rev-parse HEAD)

  # Write 3-line marker with CHANGES_REQUIRED verdict
  printf '2026-07-18T00:00:00.0000000+02:00\nverdict=CHANGES_REQUIRED\nhead=%s' "$head_now" > "$CLAUDE_STATE_DIR/peer-review/r7-blocked"

  test_payload="{\"session_id\":\"r7-blocked\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  if printf '%s' "$RUN_OUT" | grep -q 'decision.*block'; then
    _pass "gate blocks with decision:block JSON"
  else
    _fail "gate blocks" "got: $RUN_OUT"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-g1] allows on verdict=APPROVED marker"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Write marker with APPROVED verdict
  printf '2026-07-18T00:00:00.0000000+02:00\nverdict=APPROVED' > "$CLAUDE_STATE_DIR/peer-review/g1"

  test_payload="{\"session_id\":\"g1\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  assert_out_empty "gate produces no output"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-g2] verdict=CHANGES_REQUIRED blocks with 3-call budget"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Write marker with CHANGES_REQUIRED verdict
  printf '2026-07-18T00:00:00.0000000+02:00\nverdict=CHANGES_REQUIRED' > "$CLAUDE_STATE_DIR/peer-review/g2"

  # 1st call: blocks and mentions CHANGES_REQUIRED
  test_payload="{\"session_id\":\"g2\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?
  if printf '%s' "$RUN_OUT" | grep -q 'decision.*block'; then
    _pass "1st call blocks with decision:block JSON"
  else
    _fail "1st call blocks" "got: $RUN_OUT"
  fi
  if printf '%s' "$RUN_OUT" | grep -q 'CHANGES_REQUIRED'; then
    _pass "1st call mentions CHANGES_REQUIRED"
  else
    _fail "1st call mentions CHANGES_REQUIRED" "got: $RUN_OUT"
  fi

  # 2nd call: blocks (budget = 3)
  test_payload="{\"session_id\":\"g2\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?
  if printf '%s' "$RUN_OUT" | grep -q 'decision.*block'; then
    _pass "2nd call blocks"
  else
    _fail "2nd call blocks" "got: $RUN_OUT"
  fi

  # 3rd call: blocks (budget = 3)
  test_payload="{\"session_id\":\"g2\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?
  if printf '%s' "$RUN_OUT" | grep -q 'decision.*block'; then
    _pass "3rd call blocks"
  else
    _fail "3rd call blocks" "got: $RUN_OUT"
  fi

  # 4th call: budget exhausted, allows
  test_payload="{\"session_id\":\"g2\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "4th call exits 0"
  assert_out_empty "4th call produces no output (budget exhausted)"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-g2-approved] later APPROVED marker allows"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Write initial CHANGES_REQUIRED marker
  printf '2026-07-18T00:00:00.0000000+02:00\nverdict=CHANGES_REQUIRED' > "$CLAUDE_STATE_DIR/peer-review/g2"

  # Make some blocks
  for _i in 1 2 3; do
    test_payload="{\"session_id\":\"g2\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
    RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  done

  # Update marker to APPROVED
  printf '2026-07-18T00:00:00.0000000+02:00\nverdict=APPROVED' > "$CLAUDE_STATE_DIR/peer-review/g2"

  # Next call should allow
  test_payload="{\"session_id\":\"g2\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "gate exits 0"
  assert_out_empty "gate produces no output"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[STOP-PEER-REVIEW-GATE-g3] legacy empty .fired counts as 1 block"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Write CHANGES_REQUIRED marker
  printf '2026-07-18T00:00:00.0000000+02:00\nverdict=CHANGES_REQUIRED' > "$CLAUDE_STATE_DIR/peer-review/g3"

  # Create empty .fired file (legacy format, counts as 1)
  touch "$CLAUDE_STATE_DIR/peer-review/g3.fired"

  # 1st call: blocks (block_count=1, max_blocks=3, so 1 < 3)
  test_payload="{\"session_id\":\"g3\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?
  if printf '%s' "$RUN_OUT" | grep -q 'decision.*block'; then
    _pass "1st call blocks (2nd block granted)"
  else
    _fail "1st call blocks" "got: $RUN_OUT"
  fi

  # 2nd call: blocks (block_count=2, max_blocks=3, so 2 < 3)
  test_payload="{\"session_id\":\"g3\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?
  if printf '%s' "$RUN_OUT" | grep -q 'decision.*block'; then
    _pass "2nd call blocks (3rd block granted)"
  else
    _fail "2nd call blocks" "got: $RUN_OUT"
  fi

  # 3rd call: budget exhausted (block_count=3, max_blocks=3, so 3 >= 3)
  test_payload="{\"session_id\":\"g3\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "3rd call exits 0"
  assert_out_empty "3rd call produces no output (budget exhausted)"

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] writes marker for peer-review-critic run"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"r1","tool_name":"Task","tool_input":{"subagent_type":"peer-review-critic"}}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ -f "$CLAUDE_STATE_DIR/peer-review/r1" ]; then
    _pass "marker file created"
  else
    _fail "marker file created" "expected marker at $CLAUDE_STATE_DIR/peer-review/r1"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] marker without report text carries no verdict line"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"r1","tool_name":"Task","tool_input":{"subagent_type":"peer-review-critic"}}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  if [ -f "$CLAUDE_STATE_DIR/peer-review/r1" ]; then
    marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/r1")
    if printf '%s' "$marker_content" | grep -q 'verdict='; then
      _fail "no verdict line on empty report" "marker contains verdict= : $marker_content"
    else
      _pass "marker without verdict line (empty report)"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] ignores other subagents"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"r2","tool_name":"Task","tool_input":{"subagent_type":"rust-expert"}}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ ! -f "$CLAUDE_STATE_DIR/peer-review/r2" ]; then
    _pass "no marker for rust-expert (ignored)"
  else
    _fail "ignores other subagents" "unexpected marker created"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] fail-open on malformed stdin"
{
  _wd="$(make_work_dir)" || exit 2
  CLAUDE_STATE_DIR="$_wd/state"
  export CLAUDE_STATE_DIR
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  RUN_OUT="$(printf 'not json either' | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0 on malformed stdin"

  unset CLAUDE_STATE_DIR
}

section "[RECORD-SUBAGENT-RUN] parses verdict from string tool_response"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v1","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"peer-review-critic"},"tool_response":"Review done.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ -f "$CLAUDE_STATE_DIR/peer-review/v1" ]; then
    if grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/v1"; then
      _pass "verdict=APPROVED extracted from string tool_response"
    else
      _fail "verdict from string" "expected verdict=APPROVED in marker"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] parses verdict from content-array tool_response"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v2","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"peer-review-critic"},"tool_response":{"status":"completed","content":[{"type":"text","text":"Findings...\nVERDICT: CHANGES_REQUIRED"}]}}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ -f "$CLAUDE_STATE_DIR/peer-review/v2" ]; then
    if grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/v2"; then
      _pass "verdict=CHANGES_REQUIRED from content-array"
    else
      _fail "verdict from content-array" "expected verdict=CHANGES_REQUIRED"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] SubagentStop path records verdict"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v3","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","last_assistant_message":"Solid work overall.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ -f "$CLAUDE_STATE_DIR/peer-review/v3" ]; then
    if grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/v3"; then
      _pass "verdict from last_assistant_message"
    else
      _fail "SubagentStop verdict" "expected verdict=APPROVED"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

# --- code-review-gatekeeper recording (REQ-003) -----------------------------
cr_run() { RUN_OUT="$(printf '%s' "$1" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"; RUN_RC=$?; }

section "[RECORD-SUBAGENT-RUN-CR-1] gatekeeper APPROVED with Target writes four-line code-review marker"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$workdir/repo"; make_test_repo "$workdir/repo"
  headsha="$(git -C "$workdir/repo" rev-parse HEAD)"
  tgt='feature/x vs origin/main (abc1234..def5678); fallback: none'
  cr_run "$(jq -n --arg cwd "$workdir/repo" --arg t "Review.
Target: $tgt
VERDICT: APPROVED" '{session_id:"cr1",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Agent",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:$t}')"
  assert_rc_zero "exit 0"
  m="$CLAUDE_STATE_DIR/code-review/cr1"
  if [ -f "$m" ]; then _pass "code-review marker exists"; else _fail "code-review marker" "missing $m"; fi
  if [ "$(sed -n 2p "$m" 2>/dev/null)" = "verdict=APPROVED" ]; then _pass "line 2 verdict=APPROVED"; else _fail "line 2" "$(cat "$m" 2>&1)"; fi
  if [ "$(sed -n 3p "$m" 2>/dev/null)" = "head=$headsha" ]; then _pass "line 3 head=HEAD"; else _fail "line 3" "$(cat "$m" 2>&1)"; fi
  if [ "$(sed -n 4p "$m" 2>/dev/null)" = "target=$tgt" ]; then _pass "line 4 target"; else _fail "line 4" "$(cat "$m" 2>&1)"; fi
  if [ ! -e "$CLAUDE_STATE_DIR/peer-review/cr1" ]; then _pass "no peer-review marker"; else _fail "peer-review marker" "should not exist"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-CR-2] peer-review-critic run writes nothing under code-review/"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  cr_run "$(jq -n '{session_id:"cr2",hook_event_name:"PostToolUse",tool_name:"Agent",tool_input:{subagent_type:"peer-review-critic"},tool_response:"Target: x\nVERDICT: APPROVED"}')"
  assert_rc_zero "exit 0"
  if [ -f "$CLAUDE_STATE_DIR/peer-review/cr2" ]; then _pass "peer-review marker written"; else _fail "peer-review marker" "missing"; fi
  if [ ! -e "$CLAUDE_STATE_DIR/code-review/cr2" ]; then _pass "no code-review marker"; else _fail "code-review marker" "should not exist"; fi
  if grep -q '^target=' "$CLAUDE_STATE_DIR/peer-review/cr2"; then _fail "peer-review target" "target= must not appear"; else _pass "no target= in peer-review marker"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-CR-3] gatekeeper report without Target writes a three-line marker"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$workdir/repo"; make_test_repo "$workdir/repo"
  cr_run "$(jq -n --arg cwd "$workdir/repo" '{session_id:"cr3",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Agent",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:"No target here.\nVERDICT: CHANGES_REQUIRED"}')"
  m="$CLAUDE_STATE_DIR/code-review/cr3"
  assert_rc_zero "exit 0"
  if [ "$(wc -l < "$m" | tr -d ' ')" = "2" ] && grep -q '^verdict=CHANGES_REQUIRED$' "$m" && grep -q '^head=' "$m" && ! grep -q '^target=' "$m"; then
    _pass "three lines (timestamp, verdict, head), no target"
  else _fail "three-line marker" "$(cat "$m" 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-CR-4] instance dedupe suppresses a repeated gatekeeper instance at the same HEAD"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$workdir/repo"; make_test_repo "$workdir/repo"
  cr_run "$(jq -n --arg cwd "$workdir/repo" '{session_id:"cr4",cwd:$cwd,tool_use_id:"toolu_X",hook_event_name:"PostToolUse",tool_name:"Agent",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:"VERDICT: CHANGES_REQUIRED"}')"
  cr_run "$(jq -n --arg cwd "$workdir/repo" '{session_id:"cr4",cwd:$cwd,tool_use_id:"toolu_X",hook_event_name:"PostToolUse",tool_name:"Agent",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:"VERDICT: APPROVED"}')"
  assert_rc_zero "exit 0"
  m="$CLAUDE_STATE_DIR/code-review/cr4"; sup="$m.verdict-suppressed"
  if grep -q '^verdict=CHANGES_REQUIRED$' "$m"; then _pass "marker still CHANGES_REQUIRED"; else _fail "marker" "$(cat "$m" 2>&1)"; fi
  if [ -f "$sup" ] && [ "$(wc -l < "$sup" | tr -d ' ')" = "1" ] && grep -q 'guard=instance-dedupe' "$sup"; then _pass "one suppression line guard=instance-dedupe"; else _fail "suppressed sidecar" "$(cat "$sup" 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-CR-5] scoped agentic-framework:code-review-gatekeeper on SubagentStop records target"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  cr_run "$(jq -n '{session_id:"cr5",hook_event_name:"SubagentStop",agent_type:"AgentiC-Framework:Code-Review-Gatekeeper",last_assistant_message:"Done.\nTarget:   main..HEAD  \nVERDICT: APPROVED"}')"
  assert_rc_zero "exit 0"
  m="$CLAUDE_STATE_DIR/code-review/cr5"
  if grep -q '^verdict=APPROVED$' "$m" 2>/dev/null && grep -q '^target=main\.\.HEAD$' "$m"; then _pass "scoped SubagentStop records verdict and trimmed target"; else _fail "scoped SubagentStop" "$(cat "$m" 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-CR-6] target line is sanitized: CR removed, non-ASCII dropped, capped at 200"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  long="$(printf 'a%.0s' $(seq 1 250))"
  cr_run "$(jq -n --arg long "$long" '{session_id:"cr6",hook_event_name:"SubagentStop",agent_type:"code-review-gatekeeper",last_assistant_message:("Target: café-" + $long + "\r\nVERDICT: APPROVED")}')"
  assert_rc_zero "exit 0"
  m="$CLAUDE_STATE_DIR/code-review/cr6"
  val="$(grep '^target=' "$m" 2>/dev/null | sed 's/^target=//')"
  if [ "${#val}" = "200" ] && [ -z "$(printf '%s' "$val" | LC_ALL=C tr -d '\040-\176')" ] && [ "${val#caf-}" != "$val" ]; then _pass "target is 200 printable ASCII chars, CR and e-acute dropped"; else _fail "target sanitize" "len=${#val} val=$val"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-CR-7] Markdown-bold **Target:** label recorded; non-ASCII dropped before trimming"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  # U+00A0 (no-break space) around the value: dropped first, then the ASCII spaces are trimmed
  cr_run "$(jq -n '{session_id:"cr7",hook_event_name:"SubagentStop",agent_type:"code-review-gatekeeper",last_assistant_message:"Done.\n**Target:**   feat/x vs origin/main (abc1234..def5678); fallback: none  \nVERDICT: APPROVED"}')"
  assert_rc_zero "exit 0"
  m="$CLAUDE_STATE_DIR/code-review/cr7"
  if grep -qx 'target=feat/x vs origin/main (abc1234..def5678); fallback: none' "$m" 2>/dev/null; then _pass "bold label recorded, value trimmed after non-ASCII removal"; else _fail "bold Target label" "$(cat "$m" 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}


# --- hand-back report source (REQ-003 amendment 2026-10-23) -----------------
# hb_transcript <file> <report> [final-text-only]: fixture sub-agent transcript. Default shape: user line,
# assistant text block, assistant SubagentHandback tool_use carrying <report>, user tool_result line.
# With a third argument the report goes into a final assistant TEXT block and no hand-back exists.
hb_transcript() {
  {
    printf '%s\n' '{"type":"user","timestamp":"2026-10-22T17:30:00.100Z","agentId":"hb0000000000000001","isSidechain":true,"message":{"role":"user","content":[{"type":"text","text":"go"}]}}'
    printf '%s%s\n' '{"type":"assistant","timestamp":"2026-10-22T17:31:00.200Z","agentId":"hb0000000000000001","isSidechain":true,"message":{"role":"assistant","model":"claude-opus-5-5","id":"msg_1","usage":{"input_tokens":5,"output_tokens":7},' \
      '"content":[{"type":"text","text":"Reviewing..."}]}}'
    if [ -n "${3:-}" ]; then
      jq -nc --arg m "$2" '{type:"assistant",timestamp:"2026-10-22T17:42:25.300Z",agentId:"hb0000000000000001",isSidechain:true,message:{role:"assistant",model:"claude-opus-5-5",id:"msg_2",usage:{input_tokens:6,output_tokens:9},content:[{type:"text",text:$m}]}}'
    else
      jq -nc --arg m "$2" --arg tid "${HB_TUID:-toolu_hb1}" '{type:"assistant",timestamp:"2026-10-22T17:42:25.300Z",agentId:"hb0000000000000001",isSidechain:true,message:{role:"assistant",model:"claude-opus-5-5",id:"msg_2",usage:{input_tokens:6,output_tokens:9},content:[{type:"tool_use",id:$tid,name:"SubagentHandback",input:{message:$m}}]},wireToolInputs:{message:"ignored"}}'
      printf '%s\n' '{"type":"user","timestamp":"2026-10-22T17:42:25.400Z","agentId":"hb0000000000000001","isSidechain":true,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_hb1","content":"{\"success\":true,\"message\":\"Report delivered to your caller.\"}"}]}}'
    fi
  } > "$1"
}
HB_REPORT='Target: feat/x vs origin/main (abc1234..def5678)
Findings: none.
VERDICT: APPROVED'

section "[RECORD-SUBAGENT-RUN-HB-1] gatekeeper SubagentStop: empty last_assistant_message, verdict and Target from the hand-back"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$workdir/repo"; make_test_repo "$workdir/repo"
  headsha="$(git -C "$workdir/repo" rev-parse HEAD)"
  hb_transcript "$workdir/t.jsonl" "$HB_REPORT"
  cr_run "$(jq -n --arg cwd "$workdir/repo" --arg t "$workdir/t.jsonl" '{session_id:"hb1",cwd:$cwd,hook_event_name:"SubagentStop",agent_id:"hb0000000000000001",agent_type:"agentic-framework:code-review-gatekeeper",last_assistant_message:"",agent_transcript_path:$t}')"
  assert_rc_zero "exit 0"
  m="$CLAUDE_STATE_DIR/code-review/hb1"
  if [ "$(wc -l < "$m" 2>/dev/null | tr -d ' ')" = "3" ]; then _pass "four-line marker (three newlines)"; else _fail "marker shape" "$(cat "$m" 2>&1)"; fi
  if [ "$(sed -n 2p "$m" 2>/dev/null)" = "verdict=APPROVED" ]; then _pass "line 2 verdict=APPROVED"; else _fail "line 2" "$(cat "$m" 2>&1)"; fi
  if [ "$(sed -n 3p "$m" 2>/dev/null)" = "head=$headsha" ]; then _pass "line 3 head=HEAD"; else _fail "line 3" "$(cat "$m" 2>&1)"; fi
  if [ "$(sed -n 4p "$m" 2>/dev/null)" = "target=feat/x vs origin/main (abc1234..def5678)" ]; then _pass "line 4 target from hand-back"; else _fail "line 4" "$(cat "$m" 2>&1)"; fi
  if [ -z "$(find "$CLAUDE_STATE_DIR" -name '.hb.*' 2>/dev/null)" ]; then _pass "no .hb.* scratch file left"; else _fail "hb scratch left" "$(find "$CLAUDE_STATE_DIR" -name '.hb.*' 2>&1)"; fi
  if [ ! -e "$CLAUDE_STATE_DIR/peer-review/hb1" ]; then _pass "nothing under peer-review/"; else _fail "peer-review marker" "should not exist"; fi
  if [ "$(cat "$m.verdict-sources" 2>/dev/null)" = "hb0000000000000001-hb-toolu_hb1" ]; then _pass ".verdict-sources holds <agent_id>-hb-<SubagentHandback tool_use id>"; else _fail "verdict-sources" "$(cat "$m.verdict-sources" 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-HB-2] peer-review-critic (bare and scoped) records the hand-back verdict"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  hb_transcript "$workdir/t.jsonl" "Review done.
VERDICT: APPROVED"
  for spelling in peer-review-critic agentic-framework:peer-review-critic; do
    sid="hb2-$(printf '%s' "$spelling" | tr -cd 'a-z')"
    cr_run "$(jq -n --arg sid "$sid" --arg ty "$spelling" --arg t "$workdir/t.jsonl" '{session_id:$sid,hook_event_name:"SubagentStop",agent_id:"hb0000000000000001",agent_type:$ty,agent_transcript_path:$t}')"
    assert_rc_zero "exit 0 ($spelling)"
    m="$CLAUDE_STATE_DIR/peer-review/$sid"
    if grep -qx 'verdict=APPROVED' "$m" 2>/dev/null; then _pass "peer-review marker carries verdict=APPROVED ($spelling)"; else _fail "peer-review marker ($spelling)" "$(cat "$m" 2>&1)"; fi
    if [ ! -e "$CLAUDE_STATE_DIR/code-review/$sid" ]; then _pass "nothing under code-review/ ($spelling)"; else _fail "code-review marker" "should not exist"; fi
  done
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-HB-3] a verdict in last_assistant_message wins over the transcript"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  hb_transcript "$workdir/t.jsonl" "VERDICT: APPROVED"
  cr_run "$(jq -n --arg t "$workdir/t.jsonl" '{session_id:"hb3",hook_event_name:"SubagentStop",agent_id:"hb0000000000000001",agent_type:"peer-review-critic",last_assistant_message:"Found a blocker.\nVERDICT: CHANGES_REQUIRED",agent_transcript_path:$t}')"
  assert_rc_zero "exit 0"
  if grep -qx 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/hb3" 2>/dev/null; then _pass "marker records CHANGES_REQUIRED (last_assistant_message wins)"; else _fail "lam precedence" "$(cat "$CLAUDE_STATE_DIR/peer-review/hb3" 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-HB-4] no hand-back: the last assistant text block holds the verdict"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  hb_transcript "$workdir/t.jsonl" "Final words.
VERDICT: APPROVED" textonly
  cr_run "$(jq -n --arg t "$workdir/t.jsonl" '{session_id:"hb4",hook_event_name:"SubagentStop",agent_id:"hb0000000000000001",agent_type:"peer-review-critic",last_assistant_message:"",agent_transcript_path:$t}')"
  assert_rc_zero "exit 0"
  if grep -qx 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/hb4" 2>/dev/null; then _pass "verdict read from the last assistant text block"; else _fail "text-block fallback" "$(cat "$CLAUDE_STATE_DIR/peer-review/hb4" 2>&1)"; fi
  # a valid-JSON assistant line whose message is a string must not poison the read
  hb_transcript "$workdir/t2.jsonl" "$HB_REPORT"
  { head -n 1 "$workdir/t2.jsonl"; printf '%s\n' '{"type":"assistant","timestamp":"2026-10-22T17:45:00.000Z","message":"oops"}'; tail -n +2 "$workdir/t2.jsonl"; } > "$workdir/t3.jsonl"
  cr_run "$(jq -n --arg t "$workdir/t3.jsonl" '{session_id:"hb4m",hook_event_name:"SubagentStop",agent_id:"hb0000000000000001",agent_type:"peer-review-critic",last_assistant_message:"",agent_transcript_path:$t}')"
  if grep -qx 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/hb4m" 2>/dev/null; then _pass "verdict recorded despite a non-object message line"; else _fail "malformed message line" "$(cat "$CLAUDE_STATE_DIR/peer-review/hb4m" 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-HB-5] missing or unreadable transcript leaves the timestamp-only marker"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$workdir/adir"
  cr_run "$(jq -n --arg t "$workdir/nope.jsonl" '{session_id:"hb5a",hook_event_name:"SubagentStop",agent_id:"hb5a",agent_type:"peer-review-critic",last_assistant_message:"",agent_transcript_path:$t}')"
  assert_rc_zero "exit 0 (missing transcript)"
  m="$CLAUDE_STATE_DIR/peer-review/hb5a"
  if [ -f "$m" ] && [ "$(wc -l < "$m" | tr -d ' ')" = "0" ] && ! grep -q '^verdict=' "$m"; then _pass "missing transcript: timestamp-only marker"; else _fail "missing transcript" "$(cat "$m" 2>&1)"; fi
  cr_run "$(jq -n --arg t "$workdir/adir" '{session_id:"hb5b",hook_event_name:"SubagentStop",agent_id:"hb5b",agent_type:"code-review-gatekeeper",last_assistant_message:"",agent_transcript_path:$t}')"
  assert_rc_zero "exit 0 (directory as transcript)"
  m="$CLAUDE_STATE_DIR/code-review/hb5b"
  if [ -f "$m" ] && [ "$(wc -l < "$m" | tr -d ' ')" = "0" ] && ! grep -q '^verdict=' "$m"; then _pass "unreadable transcript: timestamp-only marker"; else _fail "unreadable transcript" "$(cat "$m" 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-HB-6] PostToolUse launch acknowledgement writes nothing and leaves a recorded verdict untouched"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  ack='Async agent launched successfully. (This tool result is internal metadata)
agentId: ab12cd34ef567890a (internal ID - do not mention to user.)
The agent is working in the background.'
  cr_run "$(jq -n --arg a "$ack" '{session_id:"hb6a",hook_event_name:"PostToolUse",tool_name:"Agent",tool_use_id:"toolu_L1",tool_input:{subagent_type:"peer-review-critic"},tool_response:[{type:"text",text:$a}]}')"
  assert_rc_zero "exit 0 (content array)"
  if [ ! -e "$CLAUDE_STATE_DIR/peer-review/hb6a" ]; then _pass "array ack: no peer-review marker"; else _fail "array ack marker" "$(cat "$CLAUDE_STATE_DIR/peer-review/hb6a" 2>&1)"; fi
  cr_run "$(jq -n --arg a "
$ack" '{session_id:"hb6b",hook_event_name:"PostToolUse",tool_name:"Agent",tool_use_id:"toolu_L2",tool_input:{subagent_type:"agentic-framework:code-review-gatekeeper"},tool_response:$a}')"
  assert_rc_zero "exit 0 (plain string, leading blank line)"
  if [ ! -e "$CLAUDE_STATE_DIR/code-review/hb6b" ] && [ ! -e "$CLAUDE_STATE_DIR/code-review/hb6b.verdict-sources" ]; then _pass "string ack: no code-review marker or sidecar"; else _fail "string ack marker" "$(ls "$CLAUDE_STATE_DIR/code-review" 2>&1)"; fi
  # phrase on line 1 but no "agentId:" second line: an ordinary report, not a launch (timestamp-only marker, no verdict)
  cr_run "$(jq -n --arg a 'Async agent launched successfully. (This tool result is internal metadata)
The agent is working in the background.' '{session_id:"hb6e",hook_event_name:"PostToolUse",tool_name:"Agent",tool_use_id:"toolu_L6",tool_input:{subagent_type:"peer-review-critic"},tool_response:$a}')"
  assert_rc_zero "exit 0 (phrase without agentId line)"
  m6e="$CLAUDE_STATE_DIR/peer-review/hb6e"
  if [ -f "$m6e" ] && [ "$(wc -l < "$m6e" | tr -d ' ')" = "0" ] && ! grep -q 'verdict=' "$m6e"; then _pass "phrase-only text is an ordinary report: timestamp-only marker"; else _fail "phrase without agentId" "$(cat "$m6e" 2>&1)"; fi
  # existing recorded verdict: unchanged, no sidecar line added
  hb_transcript "$workdir/t.jsonl" "VERDICT: CHANGES_REQUIRED"
  cr_run "$(jq -n --arg t "$workdir/t.jsonl" '{session_id:"hb6c",hook_event_name:"SubagentStop",agent_id:"hb0000000000000001",agent_type:"peer-review-critic",agent_transcript_path:$t}')"
  m="$CLAUDE_STATE_DIR/peer-review/hb6c"
  before="$(cat "$m"; cat "$m.verdict-sources"; ls "$CLAUDE_STATE_DIR/peer-review" | sort)"
  cr_run "$(jq -n --arg a "$ack" '{session_id:"hb6c",hook_event_name:"PostToolUse",tool_name:"Agent",tool_use_id:"toolu_L3",tool_input:{subagent_type:"peer-review-critic"},tool_response:[{type:"text",text:$a}]}')"
  after="$(cat "$m"; cat "$m.verdict-sources"; ls "$CLAUDE_STATE_DIR/peer-review" | sort)"
  if grep -qx 'verdict=CHANGES_REQUIRED' "$m" && [ "$before" = "$after" ]; then _pass "ack leaves the recorded verdict, sources and sidecars untouched"; else _fail "ack over recorded verdict" "$after"; fi
  # object form (the payload's real tool_response): no marker change, no sidecar line
  obj='{"agentId":"aa304bc86dde44d40","canContinueAgent":true,"canReadOutputFile":false,"description":"d","isAsync":true,"outputFile":"C:/x/tasks/aa304bc86dde44d40.output","prompt":"review it","resolvedModel":"claude-sonnet-5-5","status":"async_launched"}'
  cr_run "$(jq -n --argjson o "$obj" '{session_id:"hb6c",hook_event_name:"PostToolUse",tool_name:"Agent",tool_use_id:"toolu_L4",tool_input:{subagent_type:"peer-review-critic"},tool_response:$o}')"
  assert_rc_zero "exit 0 (object form over a recorded verdict)"
  after2="$(cat "$m"; cat "$m.verdict-sources"; ls "$CLAUDE_STATE_DIR/peer-review" | sort)"
  if grep -qx 'verdict=CHANGES_REQUIRED' "$m" && [ "$before" = "$after2" ]; then _pass "object ack leaves the recorded verdict, sources and sidecars untouched"; else _fail "object ack over recorded verdict" "$after2"; fi
  cr_run "$(jq -n --argjson o "$obj" '{session_id:"hb6d",hook_event_name:"PostToolUse",tool_name:"Agent",tool_use_id:"toolu_L5",tool_input:{subagent_type:"peer-review-critic"},tool_response:$o}')"
  if [ ! -e "$CLAUDE_STATE_DIR/peer-review/hb6d" ] && [ ! -e "$CLAUDE_STATE_DIR/peer-review/hb6d.verdict-sources" ]; then _pass "object ack: no marker, no sidecar"; else _fail "object ack marker" "$(ls "$CLAUDE_STATE_DIR/peer-review" 2>&1)"; fi
  # isAsync only (no status): still a launch acknowledgement
  cr_run "$(jq -n '{session_id:"hb6f",hook_event_name:"PostToolUse",tool_name:"Agent",tool_use_id:"toolu_L7",tool_input:{subagent_type:"peer-review-critic"},tool_response:{isAsync:true,agentId:"ab12cd34ef567890a"}}')"
  if [ ! -e "$CLAUDE_STATE_DIR/peer-review/hb6f" ] && [ ! -e "$CLAUDE_STATE_DIR/peer-review/hb6f.verdict-sources" ]; then _pass "isAsync-only object: no marker, no sidecar"; else _fail "isAsync-only marker" "$(ls "$CLAUDE_STATE_DIR/peer-review" 2>&1)"; fi
  # a non-launch object response is an ordinary report: its verdict is recorded
  cr_run "$(jq -n '{session_id:"hb6g",hook_event_name:"PostToolUse",tool_name:"Agent",tool_use_id:"toolu_L8",tool_input:{subagent_type:"peer-review-critic"},tool_response:{status:"completed",content:[{type:"text",text:"Done.\nVERDICT: APPROVED"}]}}')"
  if grep -qx 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/hb6g" 2>/dev/null; then _pass "non-launch object response still records its verdict"; else _fail "non-launch object verdict" "$(cat "$CLAUDE_STATE_DIR/peer-review/hb6g" 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-HB-8] a continued reviewer stopping without a new hand-back cannot re-record its old report; a new hand-back records"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$workdir/repo"; make_test_repo "$workdir/repo"
  h1="$(git -C "$workdir/repo" rev-parse HEAD)"
  m="$CLAUDE_STATE_DIR/code-review/hb8"
  hb8_stop() { cr_run "$(jq -n --arg cwd "$workdir/repo" --arg t "$workdir/t.jsonl" '{session_id:"hb8",cwd:$cwd,hook_event_name:"SubagentStop",agent_id:"hb0000000000000001",agent_type:"code-review-gatekeeper",last_assistant_message:"",agent_transcript_path:$t}')"; }
  hb_transcript "$workdir/t.jsonl" "$HB_REPORT"
  hb8_stop
  assert_rc_zero "exit 0 (first stop)"
  if grep -qx 'verdict=APPROVED' "$m" && grep -qx "head=$h1" "$m"; then _pass "APPROVED recorded at H1"; else _fail "first record" "$(cat "$m" 2>&1)"; fi
  # HEAD moves to H2
  git -C "$workdir/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m next
  h2="$(git -C "$workdir/repo" rev-parse HEAD)"
  [ "$h1" != "$h2" ] && _pass "HEAD moved H1 -> H2" || _fail "HEAD move" "$h1"
  mbefore="$(cat "$m")"; sbefore="$(cat "$m.verdict-sources")"
  hb8_stop
  assert_rc_zero "exit 0 (same transcript again)"
  if [ "$(cat "$m")" = "$mbefore" ] && grep -qx "head=$h1" "$m"; then _pass "marker unchanged (head=H1)"; else _fail "marker after stale stop" "$(cat "$m" 2>&1)"; fi
  if [ "$(cat "$m.verdict-sources")" = "$sbefore" ]; then _pass ".verdict-sources unchanged"; else _fail "sources after stale stop" "$(cat "$m.verdict-sources" 2>&1)"; fi
  if [ "$(wc -l < "$m.verdict-suppressed" 2>/dev/null | tr -d ' ')" = "1" ] && grep -q 'guard=instance-dedupe' "$m.verdict-suppressed"; then _pass "one .verdict-suppressed line with guard=instance-dedupe"; else _fail "suppressed" "$(cat "$m.verdict-suppressed" 2>&1)"; fi
  # a continuation hands back again (new tool_use id, new verdict): recorded normally
  HB_TUID=toolu_hb8b hb_transcript "$workdir/t.jsonl" "VERDICT: CHANGES_REQUIRED"
  hb8_stop
  assert_rc_zero "exit 0 (new hand-back)"
  if grep -qx 'verdict=CHANGES_REQUIRED' "$m" && grep -qx "head=$h2" "$m"; then _pass "new hand-back recorded: CHANGES_REQUIRED at H2"; else _fail "new hand-back record" "$(cat "$m" 2>&1)"; fi
  if [ "$(wc -l < "$m.verdict-sources" | tr -d ' ')" = "2" ] && grep -qxF 'hb0000000000000001-hb-toolu_hb8b' "$m.verdict-sources"; then _pass "second .verdict-sources line for the new hand-back"; else _fail "sources after new hand-back" "$(cat "$m.verdict-sources" 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

# big_hb_transcript <file>: hb_transcript whose hand-back lies beyond the first 16 MiB (~17 MiB of filler between).
big_hb_transcript() {
  hb_transcript "$1.small" "$HB_REPORT"
  _filler="$(printf '%4000s' '' | tr ' ' 'x')"
  _fl="{\"type\":\"assistant\",\"timestamp\":\"2026-10-22T17:32:00.000Z\",\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"$_filler\"}]}}"
  { head -n 2 "$1.small"; yes "$_fl" | head -n 4300; tail -n +3 "$1.small"; } > "$1"
  rm -f "$1.small"
}

section "[RECORD-SUBAGENT-RUN-HB-7] transcript larger than 16 MiB: the hand-back is read from the LAST 16 MiB"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  big_hb_transcript "$workdir/big.jsonl"
  sz=$(wc -c < "$workdir/big.jsonl" | tr -d ' ')
  if [ "$sz" -gt 16777216 ]; then _pass "fixture exceeds the cap ($sz bytes)"; else _fail "fixture size" "$sz"; fi
  cr_run "$(jq -n --arg t "$workdir/big.jsonl" '{session_id:"hb7",hook_event_name:"SubagentStop",agent_id:"hb0000000000000001",agent_type:"code-review-gatekeeper",last_assistant_message:"",agent_transcript_path:$t}')"
  assert_rc_zero "exit 0"
  m="$CLAUDE_STATE_DIR/code-review/hb7"
  if [ "$(wc -l < "$m" 2>/dev/null | tr -d ' ')" = "3" ] && grep -qx 'verdict=APPROVED' "$m" && grep -q '^target=' "$m"; then _pass "four-line marker (three newlines) with verdict=APPROVED and target="; else _fail "big transcript marker" "$(cat "$m" 2>&1)"; fi
  if [ -z "$(find "$CLAUDE_STATE_DIR" -name '.hb.*' 2>/dev/null)" ]; then _pass "no .hb.* scratch file left"; else _fail "hb scratch left" "$(find "$CLAUDE_STATE_DIR" -name '.hb.*' 2>&1)"; fi
  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] SubagentStop ignores other agent types"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v4","hook_event_name":"SubagentStop","agent_type":"rust-expert","last_assistant_message":"VERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ ! -f "$CLAUDE_STATE_DIR/peer-review/v4" ]; then
    _pass "SubagentStop ignores rust-expert"
  else
    _fail "SubagentStop ignores other agents" "unexpected marker created"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] SubagentStop ignores otherplugin:peer-review-critic"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v4b","hook_event_name":"SubagentStop","agent_type":"otherplugin:peer-review-critic","last_assistant_message":"Review done.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ ! -f "$CLAUDE_STATE_DIR/peer-review/v4b" ]; then
    _pass "only agentic-framework:peer-review-critic allowed (not otherplugin)"
  else
    _fail "plugin boundary" "unexpected marker for otherplugin:peer-review-critic"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] last VERDICT occurrence wins"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v5","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","agent_id":"review-v5-1","last_assistant_message":"The format is \"VERDICT: APPROVED\" normally, but here:\nVERDICT: CHANGES_REQUIRED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ -f "$CLAUDE_STATE_DIR/peer-review/v5" ]; then
    if grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/v5" && ! grep 'verdict=' "$CLAUDE_STATE_DIR/peer-review/v5" | grep -q 'APPROVED'; then
      _pass "last VERDICT (CHANGES_REQUIRED) wins over quoted one"
    else
      _fail "last VERDICT wins" "expected only CHANGES_REQUIRED verdict"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] re-review overwrites marker"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v5","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","agent_id":"review-v5-1","last_assistant_message":"Initial review.\nVERDICT: CHANGES_REQUIRED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  test_payload='{"session_id":"v5","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","agent_id":"review-v5-2","last_assistant_message":"Re-review after fixes.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  if [ -f "$CLAUDE_STATE_DIR/peer-review/v5" ]; then
    marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/v5")
    if printf '%s' "$marker_content" | grep -q 'verdict=APPROVED' && ! printf '%s' "$marker_content" | grep -q 'CHANGES_REQUIRED'; then
      _pass "re-review overwrites, APPROVED wins"
    else
      _fail "re-review overwrite" "expected only APPROVED verdict, got: $marker_content"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] no-downgrade: verdict-less event preserves CHANGES_REQUIRED"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v6","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","last_assistant_message":"Blockers remain.\nVERDICT: CHANGES_REQUIRED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  test_payload='{"session_id":"v6","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"peer-review-critic"},"tool_response":{"status":"launched_in_background","agentId":"a1b2c3"}}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  if [ -f "$CLAUDE_STATE_DIR/peer-review/v6" ]; then
    if grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/v6"; then
      _pass "no-downgrade preserves CHANGES_REQUIRED on verdict-less event"
    else
      _fail "no-downgrade guard" "verdict was downgraded"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] parses verdict from bare-array tool_response"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v7","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"peer-review-critic"},"tool_response":[{"type":"text","text":"Report body.\nVERDICT: CHANGES_REQUIRED"}]}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ -f "$CLAUDE_STATE_DIR/peer-review/v7" ]; then
    if grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/v7"; then
      _pass "verdict from bare-array tool_response"
    else
      _fail "verdict from bare-array" "expected verdict=CHANGES_REQUIRED"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] falls back to tool_output when tool_response absent"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v8","hook_event_name":"PostToolUse","tool_name":"Task","tool_input":{"subagent_type":"peer-review-critic"},"tool_output":"Documented-schema field.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ -f "$CLAUDE_STATE_DIR/peer-review/v8" ]; then
    if grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/v8"; then
      _pass "verdict from tool_output (tool_response absent)"
    else
      _fail "tool_output fallback" "expected verdict=APPROVED"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] parses verdict from CRLF report text"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Using printf to include actual CRLF
  test_payload='{"session_id":"v9","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","last_assistant_message":"CRLF payload.\r\nVERDICT: APPROVED\r\n"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ -f "$CLAUDE_STATE_DIR/peer-review/v9" ]; then
    if grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/v9"; then
      _pass "verdict from CRLF report text"
    else
      _fail "CRLF parsing" "expected verdict=APPROVED"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] mid-line quoted verdict does not count"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"v10","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","last_assistant_message":"Reviews normally end with \"VERDICT: APPROVED\" but this one timed out."}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "exit 0"
  if [ -f "$CLAUDE_STATE_DIR/peer-review/v10" ]; then
    marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/v10")
    if ! printf '%s' "$marker_content" | grep -q 'verdict='; then
      _pass "mid-line quoted verdict does not count (anchored regex)"
    else
      _fail "anchored regex" "verdict should not be recorded from quoted text"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-R1] instance dedupe: same id does not overwrite APPROVED"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"r1","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","agent_id":"instance-X","last_assistant_message":"Review done.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "R1.a: exit 0"
  if grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/r1"; then
    _pass "R1.a: initial APPROVED recorded with instance id"
  else
    _fail "R1.a: APPROVED not recorded" "marker: $(cat $CLAUDE_STATE_DIR/peer-review/r1 2>/dev/null)"
  fi

  # Same id, contradicting verdict
  test_payload='{"session_id":"r1","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","agent_id":"instance-X","last_assistant_message":"Actually, blockers found.\nVERDICT: CHANGES_REQUIRED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "R1.b: exit 0"
  marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/r1")
  if printf '%s' "$marker_content" | grep -q 'verdict=APPROVED' && ! printf '%s' "$marker_content" | grep -q 'CHANGES_REQUIRED'; then
    _pass "R1.b: same id=X stale stop does not overwrite APPROVED"
  else
    _fail "R1.b: dedupe failed" "marker: $marker_content"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-R2] instance dedupe: same id does not bypass (CHANGES_REQUIRED)"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"r2","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","agent_id":"instance-Y","last_assistant_message":"Blockers remain.\nVERDICT: CHANGES_REQUIRED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "R2.a: exit 0"
  if grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/r2"; then
    _pass "R2.a: initial CHANGES_REQUIRED recorded"
  fi

  # Same id, contradicting APPROVED
  test_payload='{"session_id":"r2","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","agent_id":"instance-Y","last_assistant_message":"Actually all clear.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/r2")
  if printf '%s' "$marker_content" | grep -q 'verdict=CHANGES_REQUIRED' && ! printf '%s' "$marker_content" | grep -q 'APPROVED'; then
    _pass "R2.b: same id=Y stale stop does not bypass (CHANGES_REQUIRED persists)"
  else
    _fail "R2.b: no-bypass failed" "marker: $marker_content"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-R3] different ids at same HEAD, latest wins"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload="{\"session_id\":\"r3\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"agent_id\":\"review-A\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Review A passed.\nVERDICT: APPROVED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/r3"; then
    _pass "R3.a: first review (A) APPROVED"
  fi

  test_payload="{\"session_id\":\"r3\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"agent_id\":\"review-B\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Review B found issues.\nVERDICT: CHANGES_REQUIRED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/r3")
  if printf '%s' "$marker_content" | grep -q 'verdict=CHANGES_REQUIRED'; then
    _pass "R3.b: different id=B replaces A, CHANGES_REQUIRED wins"
  else
    _fail "R3.b: different id not processed" "marker: $marker_content"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-R4] id-less same-HEAD contradiction guard"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # R4.a: CHANGES_REQUIRED at HEAD
  test_payload="{\"session_id\":\"r4a\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Blockers found.\nVERDICT: CHANGES_REQUIRED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/r4a" && grep -q '^head=' "$CLAUDE_STATE_DIR/peer-review/r4a"; then
    _pass "R4.a: id-absent CHANGES_REQUIRED recorded at HEAD"
  fi

  # R4.b: APPROVED at same HEAD (should suppress)
  test_payload="{\"session_id\":\"r4a\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Re-review: all clear.\nVERDICT: APPROVED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/r4a")
  if printf '%s' "$marker_content" | grep -q 'verdict=CHANGES_REQUIRED' && ! printf '%s' "$marker_content" | grep -q 'APPROVED'; then
    _pass "R4.b: id-absent APPROVED at same HEAD suppressed"
  else
    _fail "R4.b: asymmetric guard failed" "marker: $marker_content"
  fi

  if [ -f "$CLAUDE_STATE_DIR/peer-review/r4a.verdict-suppressed" ]; then
    if grep -q 'guard=same-head-approve' "$CLAUDE_STATE_DIR/peer-review/r4a.verdict-suppressed"; then
      _pass "R4.b: suppression audit created with correct guard"
    fi
  fi

  # R4.c: APPROVED first
  test_payload="{\"session_id\":\"r4b\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"No issues found.\nVERDICT: APPROVED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/r4b"; then
    _pass "R4.c: id-absent APPROVED recorded at HEAD"
  fi

  # R4.d: CHANGES_REQUIRED at same HEAD (should escalate)
  test_payload="{\"session_id\":\"r4b\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Actually blockers found.\nVERDICT: CHANGES_REQUIRED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/r4b")
  if printf '%s' "$marker_content" | grep -q 'verdict=CHANGES_REQUIRED' && ! printf '%s' "$marker_content" | grep -q 'APPROVED'; then
    _pass "R4.d: id-absent CHANGES_REQUIRED escalates over APPROVED"
  else
    _fail "R4.d: escalation failed" "marker: $marker_content"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-R5] id-absent, HEAD MOVES → verdicts can change"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # R5.a: Initial CHANGES_REQUIRED at HEAD1
  test_payload="{\"session_id\":\"r5\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Initial review: blockers.\nVERDICT: CHANGES_REQUIRED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/r5"; then
    _pass "R5.a: CHANGES_REQUIRED recorded at HEAD1"
  fi

  # Simulate a fix by advancing HEAD
  printf 'fixed\n' > "$testgit/fix.txt"
  git -C "$testgit" add -A
  git -C "$testgit" commit -qm 'fix blockers'

  # R5.b: APPROVED at HEAD2 (should proceed despite earlier CHANGES_REQUIRED)
  test_payload="{\"session_id\":\"r5\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Re-review after fix: all clear.\nVERDICT: APPROVED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/r5")
  if printf '%s' "$marker_content" | grep -q 'verdict=APPROVED'; then
    _pass "R5.b: id-absent APPROVED at HEAD2 allowed (HEAD moved)"
  else
    _fail "R5.b: HEAD-move guard failed" "marker: $marker_content"
  fi

  # Reset for remaining tests
  git -C "$testgit" reset -q --hard HEAD~1

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-R6] tool_use_id dedupe and no-downgrade"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # R6.a: Initial CHANGES_REQUIRED
  test_payload='{"session_id":"r6","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","tool_use_id":"use-123","last_assistant_message":"Status: needs work.\nVERDICT: CHANGES_REQUIRED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "R6.a: exit 0"

  # R6.b: verdict-less PostToolUse with different tool_use_id (should not downgrade)
  test_payload='{"session_id":"r6","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"peer-review-critic"},"tool_use_id":"use-456","tool_response":{"status":"background"}}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/r6"; then
    _pass "R6.b: no-downgrade on verdict-less PostToolUse"
  else
    _fail "R6.b: no-downgrade guard" "verdict was downgraded"
  fi

  # R6.c: Verdict-bearing PostToolUse with different tool_use_id
  test_payload='{"session_id":"r6","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"peer-review-critic"},"tool_use_id":"use-456","tool_response":"Re-run with same id.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/r6"; then
    _pass "R6.c: tool_use_id dedupe allows new id with verdict"
  else
    _fail "R6.c: verdict update" "expected APPROVED verdict"
  fi

  # R6.d: Same tool_use_id on repeat (should dedupe)
  test_payload='{"session_id":"r6","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"peer-review-critic"},"tool_use_id":"use-456","tool_response":"Third attempt contradicts.\nVERDICT: CHANGES_REQUIRED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/r6")
  if printf '%s' "$marker_content" | grep -q 'verdict=APPROVED'; then
    _pass "R6.d: same tool_use_id dedupe blocks repeat verdict"
  else
    _fail "R6.d: dedupe guard" "expected APPROVED to persist, got: $marker_content"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-R7] HEAD-qualified instance dedupe"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # R7.a: Record at HEAD1
  test_payload="{\"session_id\":\"r7\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"agent_id\":\"instance-Z\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Initial review: blockers.\nVERDICT: CHANGES_REQUIRED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/r7" && grep -q '^head=' "$CLAUDE_STATE_DIR/peer-review/r7"; then
    _pass "R7.a: id=Z CHANGES_REQUIRED recorded with HEAD"
  else
    _fail "R7.a: marker creation" "expected marker with CHANGES_REQUIRED and HEAD"
  fi

  # Advance HEAD
  printf 'fixed\n' > "$testgit/r7-fix.txt"
  git -C "$testgit" add -A
  git -C "$testgit" commit -qm 'fix for r7'

  # R7.b: Same id at new HEAD (should record)
  test_payload="{\"session_id\":\"r7\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"agent_id\":\"instance-Z\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Re-review after fix: all clear.\nVERDICT: APPROVED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/r7")
  if printf '%s' "$marker_content" | grep -q 'verdict=APPROVED'; then
    _pass "R7.b: same id=Z at new HEAD records (HEAD moved)"
  else
    _fail "R7.b: HEAD-qualified dedupe failed" "marker: $marker_content"
  fi

  # Reset for R8
  git -C "$testgit" reset -q --hard HEAD~1

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN-R8] same id, same HEAD suppressed"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # R8.a: Record at HEAD
  test_payload="{\"session_id\":\"r8\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"agent_id\":\"instance-W\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Review: approved.\nVERDICT: APPROVED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/r8"; then
    _pass "R8.a: id=W APPROVED recorded at HEAD"
  else
    _fail "R8.a: marker creation" "expected marker with APPROVED verdict"
  fi

  # R8.b: Same id, same HEAD, contradicting verdict (should suppress)
  test_payload="{\"session_id\":\"r8\",\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"peer-review-critic\",\"agent_id\":\"instance-W\",\"cwd\":\"$testgit\",\"last_assistant_message\":\"Re-check: blockers.\nVERDICT: CHANGES_REQUIRED\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  marker_content=$(cat "$CLAUDE_STATE_DIR/peer-review/r8")
  if printf '%s' "$marker_content" | grep -q 'verdict=APPROVED' && ! printf '%s' "$marker_content" | grep -q 'CHANGES_REQUIRED'; then
    _pass "R8.b: same id=W at same HEAD suppressed (stays APPROVED)"
  else
    _fail "R8.b: instance dedupe failed" "marker: $marker_content"
  fi

  if [ -f "$CLAUDE_STATE_DIR/peer-review/r8.verdict-suppressed" ]; then
    if grep -q 'guard=instance-dedupe' "$CLAUDE_STATE_DIR/peer-review/r8.verdict-suppressed"; then
      _pass "R8.b: suppression audit with guard=instance-dedupe"
    fi
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[RECORD-SUBAGENT-RUN] plugin-scoped agentic-framework:peer-review-critic"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"plugin-sub1","hook_event_name":"SubagentStop","agent_type":"agentic-framework:peer-review-critic","last_assistant_message":"Review done.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if [ -f "$CLAUDE_STATE_DIR/peer-review/plugin-sub1" ] && grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/plugin-sub1"; then
    _pass "SubagentStop with plugin-scoped agent_type records verdict"
  else
    _fail "plugin-scoped SubagentStop" "marker not found or verdict missing"
  fi

  test_payload='{"session_id":"plugin-post1","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"agentic-framework:peer-review-critic"},"tool_response":{"status":"completed","content":[{"type":"text","text":"Review done.\nVERDICT: CHANGES_REQUIRED"}]}}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if [ -f "$CLAUDE_STATE_DIR/peer-review/plugin-post1" ] && grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/plugin-post1"; then
    _pass "PostToolUse with plugin-scoped subagent_type records verdict"
  else
    _fail "plugin-scoped PostToolUse" "marker not found or verdict missing"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[EDGE-D1] dispatch handles paths with spaces in root"
{
  # Create temp dir WITH spaces in path (under HARNESS_ROOT, preserving space property)
  # mktemp creates the base, then we add the space-containing subdirectory
  base="$(make_work_dir)" || exit 2
  root_with_spaces="$base/space test root"
  mkdir -p "$root_with_spaces/hooks"
  cp "$SRC_REPO/hooks/dispatch.sh" "$root_with_spaces/hooks/" 2>/dev/null || true

  if [ -f "$root_with_spaces/hooks/dispatch.sh" ]; then
    # Create fake sh hook that outputs SUCCESS
    cat > "$root_with_spaces/hooks/session-start-context.sh" << 'SPACESH'
#!/bin/sh
printf 'SPACE_TEST_SUCCESS\n'
SPACESH
    chmod +x "$root_with_spaces/hooks/session-start-context.sh"

    test_payload='{"session_id":"edge_d1"}'

    # Platform-aware test: only run sh arm on Linux
    platform_name=$(uname -s 2>/dev/null || echo "Unknown")
    case "$platform_name" in
      MINGW*|MSYS*|CYGWIN*)
        # Windows: create ps1 variant
        cat > "$root_with_spaces/hooks/session-start-context.ps1" << 'SPACEPS'
Write-Output "SPACE_TEST_SUCCESS"
SPACEPS

        # Note: pwsh -File with spaces requires quoting
        RUN_OUT="$(cd "$root_with_spaces/hooks" && sh dispatch.sh session-start-context <<< "$test_payload" 2>&1)"
        RUN_RC=$?
        assert_rc_zero "dispatch with spaced root exits 0 (Windows)"
        if printf '%s' "$RUN_OUT" | grep -q 'SPACE_TEST_SUCCESS'; then
          _pass "dispatch succeeds with spaced root path (Windows ps1 arm)"
        else
          _fail "spaced root dispatch" "expected SPACE_TEST_SUCCESS, got: $RUN_OUT"
        fi
        ;;
      *)
        # Linux: use sh arm
        RUN_OUT="$(cd "$root_with_spaces/hooks" && sh dispatch.sh session-start-context <<< "$test_payload" 2>&1)"
        RUN_RC=$?
        assert_rc_zero "dispatch with spaced root exits 0 (Linux)"
        if printf '%s' "$RUN_OUT" | grep -q 'SPACE_TEST_SUCCESS'; then
          _pass "dispatch succeeds with spaced root path (Linux sh arm)"
        else
          _fail "spaced root dispatch" "expected SPACE_TEST_SUCCESS, got: $RUN_OUT"
        fi
        ;;
    esac
  else
    _fail "dispatch.sh exists" "dispatch.sh not found in spaced root; test skipped"
  fi
  rm -rf "$root_with_spaces"
}

section "[EDGE-D1-CHAIN] dispatch chain-quoting: spaces in path correctly tokenized"
{
  # Test that spaced root path is correctly handled in shell chain context
  # This validates the ${0%[\\/]*} separator-strip logic on a spaced absolute path
  base="$(make_work_dir)" || exit 2
  root_with_spaces="$base/space test chain"
  mkdir -p "$root_with_spaces/hooks"
  cp "$SRC_REPO/hooks/dispatch.sh" "$root_with_spaces/hooks/" 2>/dev/null || true

  if [ -f "$root_with_spaces/hooks/dispatch.sh" ]; then
    # Create both sh and ps1 versions so dispatch routes to the right one
    cat > "$root_with_spaces/hooks/session-start-context.sh" << 'SPACESH'
#!/bin/sh
printf 'CHAIN_DISPATCH_OK\n'
SPACESH
    chmod +x "$root_with_spaces/hooks/session-start-context.sh"

    cat > "$root_with_spaces/hooks/session-start-context.ps1" << 'SPACEPS'
Write-Output "CHAIN_DISPATCH_OK"
SPACEPS

    test_payload='{"session_id":"edge_d1_chain"}'
    platform_name=$(uname -s 2>/dev/null || echo "Unknown")

    case "$platform_name" in
      MINGW*|MSYS*|CYGWIN*)
        # Windows: test sh -c with FULL registration template chain (both arms, || fallback)
        # The sh arm exits 0, so || fallback never runs, but entire chain must tokenize correctly
        # This exercises the ${0%[\\/]*} separator-strip logic on spaced absolute paths
        chain="sh \"$root_with_spaces/hooks/dispatch.sh\" session-start-context || pwsh -NoProfile -File \"$root_with_spaces/hooks/session-start-context.ps1\""
        RUN_OUT="$(printf '%s' "$test_payload" | sh -c "$chain" 2>&1)"
        RUN_RC=$?
        assert_rc_zero "sh -c with full chain exits 0 (Windows)"
        if printf '%s' "$RUN_OUT" | grep -q 'CHAIN_DISPATCH_OK'; then
          _pass "sh -c chain tokenizes full registration template with spaced paths correctly"
        else
          _fail "sh -c full chain tokenization" "expected CHAIN_DISPATCH_OK, got: $RUN_OUT"
        fi

        # Test pwsh -Command with same chain string (if pwsh available)
        if command -v pwsh >/dev/null 2>&1; then
          RUN_OUT="$(printf '%s' "$test_payload" | pwsh -NoProfile -Command "$chain" 2>&1)"
          RUN_RC=$?
          assert_rc_zero "pwsh -Command with full chain exits 0 (Windows)"
          if printf '%s' "$RUN_OUT" | grep -q 'CHAIN_DISPATCH_OK'; then
            _pass "pwsh -Command tokenizes full registration template with spaced paths correctly"
          else
            _fail "pwsh -Command full chain" "expected CHAIN_DISPATCH_OK, got: $RUN_OUT"
          fi
        else
          _pass "pwsh not available (skipped pwsh -Command test)"
        fi
        ;;
      *)
        # Linux: test sh -c with FULL registration template chain
        chain="sh \"$root_with_spaces/hooks/dispatch.sh\" session-start-context || exit 1"
        RUN_OUT="$(printf '%s' "$test_payload" | sh -c "$chain" 2>&1)"
        RUN_RC=$?
        assert_rc_zero "sh -c with full chain exits 0 (Linux)"
        if printf '%s' "$RUN_OUT" | grep -q 'CHAIN_DISPATCH_OK'; then
          _pass "sh -c chain tokenizes full registration template correctly (Linux)"
        else
          _fail "sh -c full chain" "expected CHAIN_DISPATCH_OK, got: $RUN_OUT"
        fi
        ;;
    esac
  else
    _fail "dispatch.sh exists" "dispatch.sh not found in spaced root; chain test skipped"
  fi
  rm -rf "$root_with_spaces"
}

section "[INTEGRATION-R1] record-subagent-run APPROVED → stop-peer-review-gate allows"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Record APPROVED verdict
  test_payload='{"session_id":"integ-r1","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","last_assistant_message":"All checks pass.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if [ -f "$CLAUDE_STATE_DIR/peer-review/integ-r1" ] && grep -q 'verdict=APPROVED' "$CLAUDE_STATE_DIR/peer-review/integ-r1"; then
    _pass "INTEGRATION-R1: APPROVED marker recorded"
  else
    _fail "INTEGRATION-R1: marker creation" "marker not found or verdict missing"
  fi

  # Gate should now allow
  test_payload="{\"session_id\":\"integ-r1\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "INTEGRATION-R1: gate exits 0"
  if [ -z "$RUN_OUT" ]; then
    _pass "INTEGRATION-R1: gate allows (no block output)"
  else
    _fail "INTEGRATION-R1: gate should allow" "got output: $RUN_OUT"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[INTEGRATION-V6] record-subagent-run CHANGES_REQUIRED, verdict-less re-emission → gate still blocks"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Record CHANGES_REQUIRED
  test_payload='{"session_id":"integ-v6","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","last_assistant_message":"Blockers found.\nVERDICT: CHANGES_REQUIRED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  if grep -q 'verdict=CHANGES_REQUIRED' "$CLAUDE_STATE_DIR/peer-review/integ-v6"; then
    _pass "INTEGRATION-V6: CHANGES_REQUIRED marker recorded"
  fi

  # Verdict-less re-emission (background launch)
  test_payload='{"session_id":"integ-v6","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"peer-review-critic"},"tool_response":{"status":"launched_in_background"}}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  # Gate should still block
  test_payload="{\"session_id\":\"integ-v6\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "INTEGRATION-V6: gate exits 0"
  if printf '%s' "$RUN_OUT" | grep -q 'decision.*block'; then
    _pass "INTEGRATION-V6: gate still blocks on CHANGES_REQUIRED"
  else
    _fail "INTEGRATION-V6: gate should block" "got: $RUN_OUT"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[INTEGRATION-G4] CR verdict → gate blocks; later APPROVED → gate allows"
{
  workdir="$(make_work_dir)" || exit 2
  testgit="$workdir/test_repo"
  mkdir -p "$testgit"
  make_test_repo "$testgit"

  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Start with CHANGES_REQUIRED (with instance ID)
  test_payload='{"session_id":"integ-g4","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","agent_id":"review-g4-1","last_assistant_message":"Initial blockers.\nVERDICT: CHANGES_REQUIRED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  # Gate blocks
  test_payload="{\"session_id\":\"integ-g4\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  if printf '%s' "$RUN_OUT" | grep -q 'decision.*block'; then
    _pass "INTEGRATION-G4.a: gate blocks with CHANGES_REQUIRED"
  else
    _fail "INTEGRATION-G4.a: gate should block" "got: $RUN_OUT"
  fi

  # Later APPROVED verdict (fixes applied, with different instance ID to allow new reviewer)
  test_payload='{"session_id":"integ-g4","hook_event_name":"SubagentStop","agent_type":"peer-review-critic","agent_id":"review-g4-2","last_assistant_message":"Fixed and re-reviewed.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  # Gate should now allow
  test_payload="{\"session_id\":\"integ-g4\",\"stop_hook_active\":false,\"cwd\":\"$testgit\"}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "INTEGRATION-G4.b: gate exits 0"
  if [ -z "$RUN_OUT" ]; then
    _pass "INTEGRATION-G4.b: gate allows after recorded APPROVED re-review"
  else
    _fail "INTEGRATION-G4.b: gate should allow" "got: $RUN_OUT"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[INTEGRATION-IMPOSTOR] agent-name enforcement: agentic-framework:impostor-agent not recorded"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  # Correct plugin prefix but wrong agent name: should NOT record (agent-name not in router)
  test_payload='{"session_id":"integ-impostor","hook_event_name":"SubagentStop","agent_type":"agentic-framework:impostor-agent","last_assistant_message":"Fake review.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  assert_rc_zero "INTEGRATION-IMPOSTOR: exit 0 (fail-open)"
  if [ ! -f "$CLAUDE_STATE_DIR/peer-review/integ-impostor" ]; then
    _pass "INTEGRATION-IMPOSTOR: marker NOT created for invalid agent name (agentic-framework:impostor-agent)"
  else
    _fail "INTEGRATION-IMPOSTOR: should reject by agent name" "unexpected marker created"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

section "[INTEGRATION-ABSENT-PLUGIN] otherplugin:some-agent absent from registry → handled gracefully"
{
  workdir="$(make_work_dir)" || exit 2
  export CLAUDE_STATE_DIR="$workdir/state"
  mkdir -p "$CLAUDE_STATE_DIR/peer-review"

  test_payload='{"session_id":"integ-absent","hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"otherplugin:some-unknown-agent"},"tool_response":"Some response.\nVERDICT: APPROVED"}'
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/record-subagent-run.sh" 2>&1)"

  assert_rc_zero "INTEGRATION-ABSENT-PLUGIN: exit 0 (fail-open)"
  if [ ! -f "$CLAUDE_STATE_DIR/peer-review/integ-absent" ]; then
    _pass "INTEGRATION-ABSENT-PLUGIN: no marker created (agent not in registry)"
  else
    _fail "INTEGRATION-ABSENT-PLUGIN: should ignore" "unexpected marker created"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

# NOTE: [GATE-PRECEDENCE] tests the .sh-specific implementation detail that when a
# marker file contains both verdict tokens (unreachable via the recorder's real
# write path), the .sh version implements fail-closed (CHANGES_REQUIRED is tested
# first, regardless of which verdict line appears earlier in the file). The .ps1
# twin uses first-match-wins parsing and does resolve the same dual-token marker
# differently (measured: .sh blocks, .ps1 allows) — this property is NOT asserted
# across implementations. This test documents .sh behavior only and is not mirrored
# in hooks-equivalence.
section "[GATE-PRECEDENCE] dual verdict in marker: CHANGES_REQUIRED wins over APPROVED (fail-closed)"
{
  workdir="$(make_work_dir)" || exit 2
  mkdir -p "$workdir/test_repo" "$workdir/state/peer-review"
  testgit="$workdir/test_repo"
  export CLAUDE_STATE_DIR="$workdir/state"

  # Build test repo using the shared function (with safety guard for failed git init)
  make_test_repo "$testgit"

  # Create marker with BOTH lines (APPROVED first, to prove CHANGES_REQUIRED still wins)
  marker_file="$CLAUDE_STATE_DIR/peer-review/precedence-test"
  {
    printf 'verdict=APPROVED\n'
    printf 'verdict=CHANGES_REQUIRED\n'
  } > "$marker_file"

  # Run gate hook with ahead-of-base scenario
  test_payload="{\"session_id\":\"precedence-test\",\"cwd\":\"$testgit\",\"stop_hook_active\":false}"
  RUN_OUT="$(printf '%s' "$test_payload" | sh "$SRC_REPO/hooks/stop-peer-review-gate.sh" 2>&1)"
  RUN_RC=$?

  assert_rc_zero "GATE-PRECEDENCE: hook exits 0 (always returns decision JSON)"
  if printf '%s' "$RUN_OUT" | grep -q '"decision":"block"'; then
    _pass "GATE-PRECEDENCE: correctly blocks (CHANGES_REQUIRED precedence)"
  else
    _fail "GATE-PRECEDENCE: should block" "expected decision:block, got: $RUN_OUT"
  fi
  if printf '%s' "$RUN_OUT" | grep -q 'CHANGES_REQUIRED'; then
    _pass "GATE-PRECEDENCE: reason mentions CHANGES_REQUIRED (not APPROVED)"
  else
    _fail "GATE-PRECEDENCE: reason string" "expected CHANGES_REQUIRED mention, got: $RUN_OUT"
  fi

  unset CLAUDE_STATE_DIR
  rm -rf "$workdir"
}

run_guard() {
  # $1 = payload; runs the .sh guard with BOTH guard variables unset, whatever
  # the invoking shell exports. A case that needs one of them set does not
  # use this helper: it calls the hook directly with its own
  # `env -u OTHER VAR=value` (e.g. EDGE-003, EDGE-005, EDGE-009, EDGE-011, EDGE-021 (g)).
  printf '%s' "$1" | env -u CLAUDE_CODE_SUBAGENT_MODEL -u AF_MODEL_GUARD sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1
}

section "[PRETOOLUSE-MODEL-GUARD-A] denies model=fable"
{
  test_payload='{"tool_name":"Agent","tool_input":{"subagent_type":"Explore","model":"fable"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "fable-model hook exits 0"
  assert_out_contains "denies with permissionDecision deny" '"permissionDecision":"deny"'
  assert_out_contains "reason A text" "top model tier"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-002] mixed-case model value denied like fable"
{
  for mv in "Fable" "FABLE"; do
    test_payload="{\"tool_input\":{\"subagent_type\":\"x\",\"model\":\"$mv\"}}"
    RUN_OUT="$(run_guard "$test_payload")"
    RUN_RC=$?
    assert_rc_zero "mixed-case ($mv) hook exits 0"
    assert_out_contains "mixed-case ($mv) denied" '"permissionDecision":"deny"'
  done
}

section "[PRETOOLUSE-MODEL-GUARD-B] rewrites built-in agent with no model and no floor"
{
  test_payload='{"tool_input":{"subagent_type":"Explore"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "Explore-no-model hook exits 0"
  if printf '%s' "$RUN_OUT" | grep -q 'permissionDecision'; then
    _fail "rewrite path must not emit permissionDecision" "got: $RUN_OUT"
  else
    _pass "rewrite path has no permissionDecision key"
  fi
  assert_out_contains "rewrite names Explore" "Built-in agent Explore"
  assert_out_contains "rewrite recommends haiku" "Model set to haiku"
  assert_out_contains "updatedInput sets model to haiku" '"updatedInput":{"subagent_type":"Explore","model":"haiku"}'

  test_payload='{"tool_input":{}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "empty subagent_type hook exits 0"
  assert_out_contains "empty subagent_type treated as general-purpose" "Built-in agent general-purpose"
  assert_out_contains "rewrite recommends sonnet" "Model set to sonnet"
  assert_out_contains "updatedInput on empty tool_input is just model" '"updatedInput":{"model":"sonnet"}'
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-003] built-in agent passes when CLAUDE_CODE_SUBAGENT_MODEL floor is set"
{
  test_payload='{"tool_input":{"subagent_type":"Explore"}}'
  RUN_OUT="$(printf '%s' "$test_payload" | env -u AF_MODEL_GUARD CLAUDE_CODE_SUBAGENT_MODEL=sonnet sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "floor-set hook exits 0"
  assert_out_empty "floor-set hook silent"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-004] framework agent without model passes silently (either spelling)"
{
  for st in "python-expert" "agentic-framework:python-expert"; do
    test_payload="{\"tool_input\":{\"subagent_type\":\"$st\"}}"
    RUN_OUT="$(run_guard "$test_payload")"
    RUN_RC=$?
    assert_rc_zero "framework agent ($st) hook exits 0"
    assert_out_empty "framework agent ($st) silent"
  done
}

section "[PRETOOLUSE-MODEL-GUARD-C] passes silently for a properly-tiered call"
{
  test_payload='{"tool_input":{"subagent_type":"python-expert","model":"sonnet"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "properly-tiered call hook exits 0"
  assert_out_empty "properly-tiered call silent"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-005] AF_MODEL_GUARD=off disables the guard"
{
  test_payload='{"tool_input":{"subagent_type":"Explore","model":"fable"}}'
  RUN_OUT="$(printf '%s' "$test_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL AF_MODEL_GUARD=off sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "guard-off hook exits 0"
  assert_out_empty "guard-off hook silent"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-001] fail-open on malformed stdin"
{
  RUN_OUT="$(run_guard 'not json')"
  RUN_RC=$?
  assert_rc_zero "malformed-stdin hook exits 0"
  assert_out_empty "malformed-stdin hook silent"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-009] fork always denied regardless of model or floor"
{
  RUN_OUT="$(run_guard '{"tool_input":{"subagent_type":"fork"}}')"
  RUN_RC=$?
  assert_rc_zero "fork (no model) hook exits 0"
  assert_out_contains "fork denied reason C" "runs on its parent model"

  RUN_OUT="$(run_guard '{"tool_input":{"subagent_type":"Fork","model":"sonnet"}}')"
  RUN_RC=$?
  assert_rc_zero "Fork with explicit model hook exits 0"
  assert_out_contains "fork with model still denied reason C" "runs on its parent model"

  RUN_OUT="$(printf '%s' '{"tool_input":{"subagent_type":"fork"}}' | env -u AF_MODEL_GUARD CLAUDE_CODE_SUBAGENT_MODEL=sonnet sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "fork with floor set hook exits 0"
  assert_out_contains "fork with floor still denied reason C" "runs on its parent model"

  RUN_OUT="$(printf '%s' '{"tool_input":{"subagent_type":"fork"}}' | env -u CLAUDE_CODE_SUBAGENT_MODEL AF_MODEL_GUARD=off sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "fork with guard off hook exits 0"
  assert_out_empty "fork silent when AF_MODEL_GUARD=off"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-010] top-tier substring spellings denied"
{
  for mv in "claude-fable-5-1" " fable" "fable " "fable[1m]" "FABLE"; do
    test_payload="{\"tool_input\":{\"subagent_type\":\"agentic-framework:python-expert\",\"model\":\"$mv\"}}"
    RUN_OUT="$(run_guard "$test_payload")"
    RUN_RC=$?
    assert_rc_zero "model=[$mv] hook exits 0"
    assert_out_contains "model=[$mv] denied reason A" "top model tier"
  done
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-011] floor value itself gated on emptiness and fable"
{
  for fv in "fable" " Fable "; do
    RUN_OUT="$(printf '%s' '{"tool_input":{"subagent_type":"Explore"}}' | env -u AF_MODEL_GUARD CLAUDE_CODE_SUBAGENT_MODEL="$fv" sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)"
    RUN_RC=$?
    assert_rc_zero "floor=[$fv] hook exits 0"
    assert_out_contains "floor=[$fv] does not count as set, rewrites Explore" "Built-in agent Explore"
  done

  RUN_OUT="$(printf '%s' '{"tool_input":{"subagent_type":"Explore"}}' | env -u AF_MODEL_GUARD CLAUDE_CODE_SUBAGENT_MODEL=haiku sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "floor=haiku hook exits 0"
  assert_out_empty "floor=haiku silences the guard"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-012] non-string model/subagent_type fields normalise to empty"
{
  RUN_OUT="$(run_guard '{"tool_input":{"subagent_type":"agentic-framework:python-expert","model":false}}')"
  RUN_RC=$?
  assert_rc_zero "model=false framework agent hook exits 0"
  assert_out_empty "model=false framework agent silent"

  RUN_OUT="$(run_guard '{"tool_input":{"subagent_type":"Explore","model":[]}}')"
  RUN_RC=$?
  assert_rc_zero "model=[] Explore hook exits 0"
  assert_out_contains "model=[] Explore rewritten to haiku" '"updatedInput":{"subagent_type":"Explore","model":"haiku"}'

  RUN_OUT="$(run_guard '{"tool_input":{"subagent_type":[],"model":false}}')"
  RUN_RC=$?
  assert_rc_zero "subagent_type=[] model=false hook exits 0"
  assert_out_contains "subagent_type=[] treated as general-purpose" "Built-in agent general-purpose"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-013] non-object tool_input passes silently, empty object still rewrites"
{
  for bad in '{"tool_input":"x"}' '{"tool_input":[1]}' '{"tool_input":null}' '{}'; do
    RUN_OUT="$(run_guard "$bad")"
    RUN_RC=$?
    assert_rc_zero "non-object tool_input ($bad) hook exits 0"
    assert_out_empty "non-object tool_input ($bad) silent"
  done

  RUN_OUT="$(run_guard '{"tool_input":{}}')"
  RUN_RC=$?
  assert_rc_zero "empty-object tool_input hook exits 0"
  assert_out_contains "empty-object tool_input rewritten to sonnet, general-purpose" '"updatedInput":{"model":"sonnet"}'
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-016] unknown agent type without model is a documented, tested limitation"
{
  RUN_OUT="$(run_guard '{"tool_input":{"subagent_type":"my-custom-agent"}}')"
  RUN_RC=$?
  assert_rc_zero "unknown agent without model hook exits 0"
  assert_out_empty "unknown agent without model is NOT denied (known limit: frontmatter is invisible to the hook)"

  RUN_OUT="$(run_guard '{"tool_input":{"subagent_type":"other-plugin:some-agent"}}')"
  RUN_RC=$?
  assert_rc_zero "other-plugin-scoped unknown agent hook exits 0"
  assert_out_empty "other-plugin-scoped unknown agent is NOT denied (known limit)"

  RUN_OUT="$(run_guard '{"tool_input":{"subagent_type":"my-custom-agent","model":"fable"}}')"
  RUN_RC=$?
  assert_rc_zero "unknown agent with model=fable hook exits 0"
  assert_out_contains "top-tier rule still binds for unknown agents (reason A)" "top model tier"

  RUN_OUT="$(run_guard '{"tool_input":{"subagent_type":"my-custom-agent","model":"haiku"}}')"
  RUN_RC=$?
  assert_rc_zero "unknown agent with model=haiku hook exits 0"
  assert_out_empty "unknown agent with a legitimate tier is silent"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-019a] built-in agents rewrite with no permissionDecision key anywhere"
{
  for st in "Explore" "Plan" "general-purpose" "claude" ""; do
    test_payload="{\"tool_input\":{\"subagent_type\":\"$st\"}}"
    RUN_OUT="$(run_guard "$test_payload")"
    RUN_RC=$?
    assert_rc_zero "stype=[$st] hook exits 0"
    if printf '%s' "$RUN_OUT" | grep -q 'permissionDecision'; then
      _fail "stype=[$st] must not carry permissionDecision" "got: $RUN_OUT"
    else
      _pass "stype=[$st] has no permissionDecision key"
    fi
    assert_out_contains "stype=[$st] systemMessage present" '"systemMessage"'
  done

  RUN_OUT="$(run_guard '{"tool_input":{"subagent_type":"Explore"}}')"
  assert_out_contains "Explore rewritten to haiku" '"model":"haiku"'
  assert_out_contains "Explore systemMessage names TYPE and TIER" "Built-in agent Explore had no model"

  for st in "Plan" "general-purpose" "claude" ""; do
    test_payload="{\"tool_input\":{\"subagent_type\":\"$st\"}}"
    RUN_OUT="$(run_guard "$test_payload")"
    assert_out_contains "stype=[$st] rewritten to sonnet" '"model":"sonnet"'
  done
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-019b] every original key preserved, model appended last"
{
  test_payload='{"tool_input":{"description":"d","prompt":"p","subagent_type":"general-purpose","run_in_background":true,"name":"x"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "full-key payload hook exits 0"
  assert_out_contains "updatedInput preserves original fields and appends model last" '"updatedInput":{"description":"d","prompt":"p","subagent_type":"general-purpose","run_in_background":true,"name":"x","model":"sonnet"}'
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-019c] round-trip integrity of non-ASCII, control chars and date-shaped strings"
{
  # Built via jq (not shell string escapes) to keep backslashes/newlines/tabs
  # exactly as intended; verifies against the .sh implementation directly
  # here, cross-checked byte-for-byte in the equivalence suite.
  raw_prompt=$(printf '%s' 'zluty kun <tag> & "quoted" \back\slash' )
  test_payload=$(jq -cn --arg p "$raw_prompt" --arg d '2026-09-20T10:00:00Z' '{"tool_input":{"subagent_type":"Explore","prompt":$p,"description":$d}}')
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "integrity payload hook exits 0"

  got_prompt=$(printf '%s' "$RUN_OUT" | jq -r '.hookSpecificOutput.updatedInput.prompt' 2>/dev/null)
  got_desc=$(printf '%s' "$RUN_OUT" | jq -r '.hookSpecificOutput.updatedInput.description' 2>/dev/null)
  if [ "$got_prompt" = "$raw_prompt" ]; then
    _pass "prompt round-trips exactly (backslashes, quotes, angle brackets, ampersand)"
  else
    _fail "prompt round-trip" "expected: $raw_prompt, got: $got_prompt"
  fi
  if [ "$got_desc" = "2026-09-20T10:00:00Z" ]; then
    _pass "ISO-date-shaped description round-trips exactly as a string"
  else
    _fail "description round-trip" "expected: 2026-09-20T10:00:00Z, got: $got_desc"
  fi
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-019d] large prompt rewrites within timeout"
{
  bigprompt_file=$(mktemp "${TMPDIR:-/tmp}/guard-big-prompt.XXXXXX")
  head -c 200000 /dev/zero | tr '\0' 'a' > "$bigprompt_file"
  test_payload=$(jq -cn --rawfile p "$bigprompt_file" '{"tool_input":{"subagent_type":"Explore","prompt":$p}}')
  rm -f "$bigprompt_file"
  start_ts=$(date +%s%N 2>/dev/null || date +%s)
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  end_ts=$(date +%s%N 2>/dev/null || date +%s)
  assert_rc_zero "200KB-prompt hook exits 0"
  assert_out_contains "200KB-prompt rewritten to haiku" '"model":"haiku"'
  elapsed_ns=$((end_ts - start_ts))
  printf '  INFO  sh 200KB-prompt wall time: %s ns\n' "$elapsed_ns"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-019e] non-string/whitespace model values on Explore still rewrite to a single model key"
{
  for bad_model in 'false' '[]' '"   "'; do
    test_payload="{\"tool_input\":{\"subagent_type\":\"Explore\",\"model\":$bad_model}}"
    RUN_OUT="$(run_guard "$test_payload")"
    RUN_RC=$?
    assert_rc_zero "model=$bad_model hook exits 0"
    model_count=$(printf '%s' "$RUN_OUT" | jq -r '.hookSpecificOutput.updatedInput | keys | map(select(.=="model")) | length' 2>/dev/null)
    assert_out_contains "model=$bad_model rewrites to haiku" '"model":"haiku"'
    if [ "$model_count" = "1" ]; then
      _pass "model=$bad_model results in exactly one model key"
    else
      _fail "model=$bad_model key count" "expected 1, got $model_count"
    fi
  done
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-021] lone-surrogate bypass, duplicate fields, off-switch trimming"
{
  # (a) fork + lone surrogate in prompt -> still denied reason C
  test_payload='{"tool_input":{"subagent_type":"fork","prompt":"a\ud800b"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge021a fork+surrogate hook exits 0"
  assert_out_contains "edge021a fork+surrogate denied reason C" "runs on its parent model"

  # (b) model=fable + lone surrogate in prompt -> still denied reason A
  test_payload='{"tool_input":{"subagent_type":"agentic-framework:python-expert","model":"fable","prompt":"a\ud800b"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge021b fable+surrogate hook exits 0"
  assert_out_contains "edge021b fable+surrogate denied reason A" "top model tier"

  # (c) Explore, no model, lone surrogate in prompt -> the built-in call
  # cannot be echoed safely, so it must deny rather than inherit the
  # session tier silently (flipped by the M1 fallback-deny fix).
  test_payload='{"tool_input":{"subagent_type":"Explore","prompt":"a\ud800b"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge021c Explore+surrogate hook exits 0"
  assert_out_contains "edge021c Explore+surrogate falls back to deny" "could not be rewritten safely"

  # (d) framework agent, no model, lone surrogate in prompt -> silent
  test_payload='{"tool_input":{"subagent_type":"agentic-framework:python-expert","prompt":"a\ud800b"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge021d framework-agent+surrogate hook exits 0"
  assert_out_empty "edge021d framework-agent+surrogate silent"

  # (e) duplicate "model" -> rewrite with exactly one model field, valued haiku
  test_payload='{"tool_input":{"model":"fable","model":"","subagent_type":"Explore","prompt":"p"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge021e dup-model hook exits 0"
  model_count=$(printf '%s' "$RUN_OUT" | grep -o '"model"' | wc -l | tr -d ' ')
  if [ "$model_count" = "1" ]; then _pass "edge021e dup-model raw output has exactly one model field"; else _fail "edge021e dup-model field count" "got $model_count"; fi
  assert_out_contains "edge021e dup-model rewrites to haiku" '"model":"haiku"'

  # (f) duplicate "subagent_type": fork then Explore -> rewrite, last value wins (Explore)
  test_payload='{"tool_input":{"subagent_type":"fork","subagent_type":"Explore","prompt":"p"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge021f dup-subtype fork-then-Explore hook exits 0"
  subtype_count=$(printf '%s' "$RUN_OUT" | grep -o '"subagent_type"' | wc -l | tr -d ' ')
  if [ "$subtype_count" = "1" ]; then _pass "edge021f dup-subtype raw output has exactly one subagent_type field"; else _fail "edge021f dup-subtype field count" "got $subtype_count"; fi
  assert_out_contains "edge021f dup-subtype rewrites with subagent_type Explore" '"subagent_type":"Explore"'

  # (f, reversed) Explore then fork -> last value wins (fork) -> denied reason C
  test_payload='{"tool_input":{"subagent_type":"Explore","subagent_type":"fork","prompt":"p"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge021f dup-subtype Explore-then-fork hook exits 0"
  assert_out_contains "edge021f dup-subtype Explore-then-fork denied reason C" "runs on its parent model"

  # (g) AF_MODEL_GUARD with surrounding/trailing whitespace still disables the guard
  test_payload='{"tool_input":{"subagent_type":"Explore","model":"fable"}}'
  RUN_OUT="$(printf '%s' "$test_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL AF_MODEL_GUARD=" off " sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "edge021g padded-off hook exits 0"
  assert_out_empty "edge021g padded-off silent"

  RUN_OUT="$(printf '%s' "$test_payload" | env -u CLAUDE_CODE_SUBAGENT_MODEL 'AF_MODEL_GUARD=OFF  ' sh "$SRC_REPO/hooks/pretooluse-model-guard.sh" 2>&1)"
  RUN_RC=$?
  assert_rc_zero "edge021g padded-OFF-caps hook exits 0"
  assert_out_empty "edge021g padded-OFF-caps silent"
}

section "[PRETOOLUSE-MODEL-GUARD-EDGE-022] per-field surrogate sanitising, rewrite fallback-deny, case-sensitive fields"
{
  # (a) lone surrogate INSIDE the model field itself -> deny reason A
  test_payload='{"tool_input":{"subagent_type":"agentic-framework:python-expert","model":"fable\ud800","prompt":"p"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge022a model-field-surrogate hook exits 0"
  assert_out_contains "edge022a model-field-surrogate denied reason A" "top model tier"

  # (b) lone surrogate INSIDE the model field on a fork -> deny reason C
  # (one bad field must not suppress the OTHER field's check)
  test_payload='{"tool_input":{"subagent_type":"fork","model":"sonnet\ud800","prompt":"p"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge022b fork-model-field-surrogate hook exits 0"
  assert_out_contains "edge022b fork-model-field-surrogate denied reason C" "runs on its parent model"

  # (c) lone surrogate INSIDE subagent_type: sanitised value is not a
  # recognised built-in name -> silent (pinned agreed behaviour)
  test_payload='{"tool_input":{"subagent_type":"Explore\ud800"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge022c subagent-type-field-surrogate hook exits 0"
  assert_out_empty "edge022c subagent-type-field-surrogate silent"

  # (d) Explore/Plan/no-type, no model, lone surrogate in prompt -> falls
  # back to deny naming TYPE/TIER; no updatedInput anywhere
  for pair in "Explore:haiku" "Plan:sonnet" ":sonnet"; do
    stype="${pair%%:*}"
    tier="${pair##*:}"
    if [ -n "$stype" ]; then
      test_payload="{\"tool_input\":{\"subagent_type\":\"$stype\",\"prompt\":\"a\\ud800b\"}}"
    else
      test_payload='{"tool_input":{"prompt":"a\ud800b"}}'
    fi
    RUN_OUT="$(run_guard "$test_payload")"
    RUN_RC=$?
    assert_rc_zero "edge022d [$stype] fallback-deny hook exits 0"
    assert_out_contains "edge022d [$stype] fallback-deny names tier $tier" "model set to $tier"
    if printf '%s' "$RUN_OUT" | grep -q updatedInput; then
      _fail "edge022d [$stype] must not emit updatedInput" "$RUN_OUT"
    else
      _pass "edge022d [$stype] has no updatedInput key"
    fi
  done

  # (e) framework agent, no model, lone surrogate in prompt -> still silent
  test_payload='{"tool_input":{"subagent_type":"agentic-framework:python-expert","prompt":"a\ud800b"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge022e framework-agent-surrogate hook exits 0"
  assert_out_empty "edge022e framework-agent-surrogate silent"

  # (f) case-variant field: caller's "Model" survives, exactly one
  # lowercase "model" field
  test_payload='{"tool_input":{"description":"d","prompt":"p","Model":"zzz","subagent_type":"Explore"}}'
  RUN_OUT="$(run_guard "$test_payload")"
  RUN_RC=$?
  assert_rc_zero "edge022f case-variant-field hook exits 0"
  assert_out_contains "edge022f case-variant-field preserves caller's Model" '"Model":"zzz"'
  lower_model_count=$(printf '%s' "$RUN_OUT" | grep -o '"model"' | wc -l | tr -d ' ')
  if [ "$lower_model_count" = "1" ]; then _pass "edge022f case-variant-field has exactly one lowercase model field"; else _fail "edge022f lowercase model count" "got $lower_model_count"; fi
}
# ===========================================================================
# Telemetry hooks (sh-only, silent): session start, session stop, agent run
# ===========================================================================

# tel <hook-name> <stdin>: run hooks/<name>.sh directly under $TSTATE; sets RUN_OUT/RUN_RC.
# stdout+stderr are merged so assert_out_empty proves both streams are silent.
tel() {
  RUN_OUT="$( (printf '%s' "$2" | CLAUDE_STATE_DIR="$TSTATE" CLAUDE_PLUGIN_ROOT="${TEL_PLUGIN_ROOT:-}" \
    sh "$SRC_REPO/hooks/$1.sh") 2>&1)"
  RUN_RC=$?
}

# assert_jq <label> <json-file> <jq-filter>: filter must evaluate to true.
assert_jq() {
  if [ -f "$2" ] && [ "$(jq -r "$3" "$2" 2>/dev/null)" = "true" ]; then _pass "$1"
  else _fail "$1" "jq '$3' on $2 -> $(jq -c . "$2" 2>&1 | head -c 400)"; fi
}

# tel_line <input> <output> <cache-read> <cache-create> <model>: one assistant transcript line.
tel_line() {
  printf '{"type":"assistant","timestamp":"2026-10-20T18:24:05.035Z","message":{"model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
    "$5" "$1" "$4" "$3" "$2"
}

section "[TELEMETRY-START-001] session file created with the REQ-301 fields"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; repo="$workdir/widget-checkout"; mkdir -p "$repo"
  make_test_repo "$repo"
  git -C "$repo" remote add origin 'https://user:s3cret@github.com/acme/widget.git'
  tel telemetry-session-start "$(jq -n --arg cwd "$repo" '{session_id:"s/1;x",cwd:$cwd,source:"startup",model:"claude-opus-5-5",hook_event_name:"SessionStart"}')"
  assert_rc_zero "start hook"
  assert_out_empty "start hook silent"
  f="$TSTATE/telemetry/sessions/s1x.json"
  assert_jq "id sanitized, project from origin without userinfo/.git" "$f" '.session_id=="s1x" and .project=="widget"'
  assert_jq "branch, cwd, source, last_source, model" "$f" '.branch=="feature/x" and .source=="startup" and .last_source=="startup" and .model=="claude-opus-5-5" and (.cwd|length>0)'
  assert_jq "counters zeroed" "$f" '.turns==0 and .transcript_offset==0 and .tokens=={input:0,output:0,cache_read:0,cache_creation:0}'
  assert_jq "started_at is ISO-8601 UTC" "$f" '.started_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")'
  if grep -q 's3cret' "$f"; then _fail "origin userinfo not persisted" "token leaked into $f"; else _pass "origin userinfo not persisted"; fi
  rm -rf "$workdir"
}

section "[TELEMETRY-START-002] resume keeps started_at/tokens/turns/offset, refreshes last_source/branch/cwd"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; repo="$workdir/r"; mkdir -p "$repo"
  make_test_repo "$repo"
  tel telemetry-session-start "$(jq -n --arg cwd "$repo" '{session_id:"sess2",cwd:$cwd,source:"startup"}')"
  f="$TSTATE/telemetry/sessions/sess2.json"
  jq '.started_at="2026-01-02T03:04:05Z" | .tokens.input=77 | .turns=4 | .transcript_offset=123' "$f" > "$f.t" && mv "$f.t" "$f"
  git -C "$repo" checkout -q -b other
  tel telemetry-session-start "$(jq -n --arg cwd "$repo" '{session_id:"sess2",cwd:$cwd,source:"resume"}')"
  assert_rc_zero "resume start"
  assert_out_empty "resume start silent"
  assert_jq "started_at, tokens, turns, offset preserved" "$f" '.started_at=="2026-01-02T03:04:05Z" and .tokens.input==77 and .turns==4 and .transcript_offset==123'
  assert_jq "last_source and branch refreshed, source kept" "$f" '.last_source=="resume" and .branch=="other" and .source=="startup"'
  rm -rf "$workdir"
}

section "[TELEMETRY-START-003] non-git cwd gives branch '-' and cwd basename as project"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; plain="$workdir/plainproj"; mkdir -p "$plain"
  tel telemetry-session-start "$(jq -n --arg cwd "$plain" '{session_id:"sess3",cwd:$cwd,source:"startup"}')"
  assert_rc_zero "non-git start"
  assert_jq "branch is '-', project is cwd basename, model null" "$TSTATE/telemetry/sessions/sess3.json" '.branch=="-" and .project=="plainproj" and .model==null'
  rm -rf "$workdir"
}

section "[TELEMETRY-START-004] malformed / empty stdin exits 0 silently, writes nothing"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"
  for bad in 'not json{' '' '{"cwd":"/x"}' '[1,2]'; do
    tel telemetry-session-start "$bad"
    assert_rc_zero "start malformed ($bad)"
    assert_out_empty "start malformed silent ($bad)"
  done
  n=$(find "$TSTATE" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" = "0" ]; then _pass "no files written for malformed input"; else _fail "no files written" "found $n"; fi
  rm -rf "$workdir"
}

section "[TELEMETRY-START-005] prune removes 31-day-old entries (file and dir), keeps 1-day-old"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tdir="$TSTATE/telemetry/sessions"; mkdir -p "$tdir/oldsess/agents"
  : > "$tdir/old.json"; : > "$tdir/new.json"; : > "$tdir/oldsess/agents/a.json"
  touch -t 202001010000 "$tdir/old.json" "$tdir/oldsess/agents/a.json" "$tdir/oldsess"
  touch "$tdir/new.json"
  tel telemetry-session-start "$(jq -n --arg cwd "$workdir" '{session_id:"sess5",cwd:$cwd,source:"startup"}')"
  assert_rc_zero "prune run"
  if [ ! -e "$tdir/old.json" ] && [ ! -e "$tdir/oldsess" ]; then _pass "31-day-old file and directory removed"; else _fail "31-day-old pruned" "still present"; fi
  if [ -e "$tdir/new.json" ] && [ -e "$tdir/sess5.json" ]; then _pass "1-day-old and current session kept"; else _fail "recent kept" "missing"; fi
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-001] token sums over a 3-assistant-line transcript; other lines ignored; incremental append"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"
  { tel_line 2 100 10 20 claude-opus-5-5; printf '{"type":"user","message":{"content":"hi"}}\n'
    tel_line 3 200 30 40 claude-opus-5-5; tel_line 5 300 50 60 claude-sonnet-5-5; } > "$tr_f"
  tel telemetry-session-start "$(jq -n --arg cwd "$workdir" '{session_id:"st1",cwd:$cwd,source:"startup"}')"
  f="$TSTATE/telemetry/sessions/st1.json"
  jq '.started_at="2026-10-20T10:00:00Z"' "$f" > "$f.t" && mv "$f.t" "$f"
  stop="$(jq -n --arg t "$tr_f" '{session_id:"st1",transcript_path:$t,hook_event_name:"Stop",stop_hook_active:false}')"
  tel telemetry-session-stop "$stop"
  assert_rc_zero "stop run"
  assert_out_empty "stop silent"
  assert_jq "tokens summed (10/600/90/120), model = last, turns 1" "$f" '.tokens=={input:10,output:600,cache_read:90,cache_creation:120} and .model=="claude-sonnet-5-5" and .turns==1'
  assert_jq "offset = file size, ended_at set, duration_s positive" "$f" ".transcript_offset==$(wc -c < "$tr_f" | tr -d ' ') and (.ended_at|type)==\"string\" and .duration_s>0"

  # second run over an appended transcript adds only the new line
  tel_line 7 9 1 2 claude-opus-5-5 >> "$tr_f"
  tel telemetry-session-stop "$stop"
  assert_jq "append adds only the new line (17/609/91/122), turns 2" "$f" '.tokens=={input:17,output:609,cache_read:91,cache_creation:122} and .turns==2'
  tel telemetry-session-stop "$stop"
  assert_jq "rerun with no new bytes changes no totals" "$f" '.tokens.input==17 and .tokens.output==609'
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-002] trailing partial line is not consumed, then is once completed"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"
  tel_line 1 10 0 0 m1 > "$tr_f"
  full_size=$(wc -c < "$tr_f" | tr -d ' ')
  printf '{"type":"assistant","message":{"model":"m2","usage":{"input_tokens":5,' >> "$tr_f"
  stop="$(jq -n --arg t "$tr_f" --arg c "$workdir" '{session_id:"st2",transcript_path:$t,cwd:$c,hook_event_name:"Stop"}')"
  tel telemetry-session-stop "$stop"
  f="$TSTATE/telemetry/sessions/st2.json"
  assert_rc_zero "stop with partial tail"
  assert_jq "only the complete line counted; offset stops at the newline" "$f" ".tokens.input==1 and .tokens.output==10 and .transcript_offset==$full_size"
  printf '"output_tokens":6}}}\n' >> "$tr_f"
  tel telemetry-session-stop "$stop"
  assert_jq "completed line consumed on the next run" "$f" '.tokens.input==6 and .tokens.output==16 and .model=="m2"'
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-003] corrupt complete line is skipped (no freeze): valid line counted, offset reaches EOF, ended_at stamped"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"
  { tel_line 1 10 0 0 m1; printf 'this is not json\n'; } > "$tr_f"
  tel telemetry-session-stop "$(jq -n --arg t "$tr_f" '{session_id:"st3",transcript_path:$t,hook_event_name:"Stop"}')"
  assert_rc_zero "stop with corrupt line"
  assert_out_empty "stop corrupt silent"
  assert_jq "valid line counted, offset = file size, ended_at stamped" "$TSTATE/telemetry/sessions/st3.json" ".tokens.input==1 and .tokens.output==10 and .transcript_offset==$(wc -c < "$tr_f" | tr -d ' ') and (.ended_at|type)==\"string\""
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-004] SessionEnd writes end_reason, does not bump turns"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"; tel_line 1 10 0 0 m1 > "$tr_f"
  tel telemetry-session-stop "$(jq -n --arg t "$tr_f" '{session_id:"st4",transcript_path:$t,hook_event_name:"Stop"}')"
  tel telemetry-session-stop "$(jq -n --arg t "$tr_f" '{session_id:"st4",transcript_path:$t,hook_event_name:"SessionEnd",reason:"logout"}')"
  assert_rc_zero "SessionEnd run"
  assert_out_empty "SessionEnd silent"
  assert_jq "end_reason set, turns still 1, tokens not double-counted" "$TSTATE/telemetry/sessions/st4.json" '.end_reason=="logout" and .turns==1 and .tokens.output==10'
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-005] malformed stdin exits 0 silently; missing transcript leaves totals and stamps ended_at"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"
  for bad in 'not json{' '' '{"transcript_path":"/x"}'; do
    tel telemetry-session-stop "$bad"
    assert_rc_zero "stop malformed ($bad)"
    assert_out_empty "stop malformed silent ($bad)"
  done
  tel telemetry-session-stop '{"session_id":"st5","transcript_path":"/nonexistent/t.jsonl","hook_event_name":"Stop"}'
  assert_rc_zero "stop with missing transcript"
  assert_jq "totals zero, ended_at stamped" "$TSTATE/telemetry/sessions/st5.json" '.tokens.input==0 and .tokens.output==0 and (.ended_at|type)=="string"'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-001] PreToolUse: record shape, tier from claude.json, silent"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT="$workdir/plugin"; mkdir -p "$TEL_PLUGIN_ROOT"
  printf '{"sub_agents":{"peer-review-critic":{"model":"opus"},"rust-expert":{"model":"sonnet"}}}\n' > "$TEL_PLUGIN_ROOT/claude.json"
  pre() { jq -n --arg id "$1" --argjson ti "$2" '{session_id:"ag1",tool_use_id:$id,tool_name:"Agent",hook_event_name:"PreToolUse",tool_input:$ti}'; }
  tel telemetry-agent-run "$(pre toolu_01 '{"subagent_type":"agentic-framework:peer-review-critic","description":"final review","prompt":"p"}')"
  assert_rc_zero "pre hook"
  assert_out_empty "pre hook silent (empty output allows the call)"
  d="$TSTATE/telemetry/sessions/ag1/agents"
  assert_jq "agent / agent_name / tier from claude.json / not background" "$d/toolu_01.json" '.agent=="agentic-framework:peer-review-critic" and .agent_name=="peer-review-critic" and .model_requested==null and .model_tier=="opus" and .background==false and .description=="final review" and .tool_use_id=="toolu_01"'
  assert_jq "started_at is ISO-8601" "$d/toolu_01.json" '.started_at|test("^[0-9]{4}-")'
  tel telemetry-agent-run "$(pre toolu_02 '{"subagent_type":"rust-expert","model":"haiku","run_in_background":true}')"
  assert_jq "model_requested wins over claude.json; background true" "$d/toolu_02.json" '.model_tier=="haiku" and .model_requested=="haiku" and .background==true'
  TEL_PLUGIN_ROOT=""
  tel telemetry-agent-run "$(pre toolu_03 '{"subagent_type":"rust-expert"}')"
  assert_jq "model_tier null when CLAUDE_PLUGIN_ROOT unset" "$d/toolu_03.json" '.model_tier==null'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-RUN-CR-1] gatekeeper PostToolUse record carries verdict"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/agcr1/agents"
  tel telemetry-agent-run "$(jq -n '{session_id:"agcr1",tool_use_id:"g1",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"code-review-gatekeeper"},tool_response:"Target: x\nVERDICT: APPROVED\n"}')"
  assert_rc_zero "post hook"
  assert_jq "gatekeeper verdict parsed" "$d/g1.json" '.verdict=="APPROVED" and .agent_name=="code-review-gatekeeper"'
  tel telemetry-agent-run "$(jq -n '{session_id:"agcr1",tool_use_id:"g2",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"agentic-framework:code-review-gatekeeper"},tool_response:"VERDICT: CHANGES_REQUIRED"}')"
  assert_jq "scoped gatekeeper verdict parsed" "$d/g2.json" '.verdict=="CHANGES_REQUIRED"'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-002] PostToolUse: duration, status, verdict parsing"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/ag2/agents"
  tel telemetry-agent-run '{"session_id":"ag2","tool_use_id":"t1","tool_name":"Agent","hook_event_name":"PreToolUse","tool_input":{"subagent_type":"peer-review-critic"}}'
  # post <tool_use_id> <subagent_type> <tool_response json> [extra-json]
  post() {
    _extra="${4:-}"; [ -z "$_extra" ] && _extra='{}'
    jq -n --arg id "$1" --arg st "$2" --argjson resp "$3" --argjson extra "$_extra" \
      '{session_id:"ag2",tool_use_id:$id,tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:$st},tool_response:$resp} + $extra'
  }
  tel telemetry-agent-run "$(post t1 peer-review-critic '"All good.\nVERDICT: APPROVED\n"' '{"duration_ms":12500}')"
  assert_rc_zero "post hook"
  assert_out_empty "post hook silent"
  assert_jq "duration_s from duration_ms, completed, APPROVED, Pre fields kept" "$d/t1.json" '.duration_s==12.5 and .status=="completed" and .verdict=="APPROVED" and .agent_name=="peer-review-critic" and (.ended_at|type)=="string"'
  tel telemetry-agent-run "$(post t2 spec-compliance-reviewer '{"content":[{"type":"text","text":"x\nVERDICT: APPROVED\nrevised\n  VERDICT: CHANGES_REQUIRED  \n"}]}')"
  assert_jq "content[] shape, last match wins, record created without Pre" "$d/t2.json" '.verdict=="CHANGES_REQUIRED" and .status=="completed" and .started_at==null'
  tel telemetry-agent-run "$(post t3 peer-review-critic '[{"type":"text","text":"VERDICT: CHANGES_REQUIRED"}]')"
  assert_jq "array-of-blocks shape; CHANGES_REQUIRED" "$d/t3.json" '.verdict=="CHANGES_REQUIRED"'
  tel telemetry-agent-run "$(post t4 peer-review-critic '"The line `VERDICT: APPROVED` is quoted here, and > VERDICT: APPROVED too"')"
  assert_jq "quoted / mid-line mention ignored" "$d/t4.json" 'has("verdict")|not'
  tel telemetry-agent-run "$(post t5 rust-expert '"VERDICT: APPROVED"')"
  assert_jq "non-reviewer agent gets no verdict" "$d/t5.json" 'has("verdict")|not'
  tel telemetry-agent-run '{"session_id":"ag2","tool_use_id":"bg1","tool_name":"Agent","hook_event_name":"PreToolUse","tool_input":{"subagent_type":"rust-expert","run_in_background":true}}'
  tel telemetry-agent-run "$(post bg1 rust-expert '{"status":"async_launched"}' '{"tool_input":{"subagent_type":"rust-expert","run_in_background":true}}')"
  assert_jq "background Pre+Post pair: launch path, status launched, launched_at set, no duration_s or ended_at" "$d/bg1.json" '.background==true and .status=="launched" and (.launched_at|type)=="string" and (has("duration_s")|not) and (has("ended_at")|not)'
  tel telemetry-agent-run '{"session_id":"ag2","tool_use_id":"fg1","tool_name":"Agent","hook_event_name":"PreToolUse","tool_input":{"subagent_type":"rust-expert"}}'
  tel telemetry-agent-run "$(post fg1 rust-expert '"done"')"
  tel telemetry-agent-run '{"session_id":"ag2","tool_use_id":"bg2","tool_name":"Agent","hook_event_name":"PreToolUse","tool_input":{"subagent_type":"rust-expert","run_in_background":true}}'
  tel telemetry-agent-run "$(post bg2 rust-expert '"Launched in background"' '{"tool_input":{"subagent_type":"rust-expert","run_in_background":true}}')"
  assert_jq "older-harness background (plain string response): launched with ended_at and duration_s, no agent_id" "$d/bg2.json" '.status == "launched" and (.ended_at | type) == "string" and (.duration_s | type) == "number" and (has("agent_id") | not)'
  assert_jq "foreground Pre+Post pair ends completed" "$d/fg1.json" '.background==false and .status=="completed"'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-003] SubagentStop: tokens and model from the subagent transcript"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; tr_f="$workdir/agent-a1.jsonl"
  { tel_line 1 10 2 3 claude-haiku-4-5; printf '{"type":"user"}\n'; tel_line 4 20 5 6 claude-haiku-4-5; } > "$tr_f"
  d="$TSTATE/telemetry/sessions/ag3/agents"
  tel telemetry-agent-run "$(jq -n --arg t "$tr_f" '{session_id:"ag3",agent_id:"a1/../x",agent_type:"agentic-framework:peer-review-critic",hook_event_name:"SubagentStop",agent_transcript_path:$t,last_assistant_message:"done\nVERDICT: APPROVED"}')"
  assert_rc_zero "subagent stop"
  assert_out_empty "subagent stop silent"
  assert_jq "tokens, model_actual, names, verdict" "$d/subagent-a1..x.json" '.tokens=={input:5,output:30,cache_read:7,cache_creation:9} and .model_actual=="claude-haiku-4-5" and .agent_name=="peer-review-critic" and .agent_type=="agentic-framework:peer-review-critic" and .verdict=="APPROVED" and .agent_id=="a1..x"'
  tel telemetry-agent-run '{"session_id":"ag3","agent_id":"a2","agent_type":"rust-expert","hook_event_name":"SubagentStop","agent_transcript_path":"/nonexistent"}'
  assert_jq "missing transcript: record without tokens" "$d/subagent-a2.json" '.agent_name=="rust-expert" and (has("tokens")|not)'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-004] non-Agent tool and malformed stdin: exit 0, silent, no files"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""
  tel telemetry-agent-run '{"session_id":"ag4","tool_use_id":"t1","tool_name":"Bash","hook_event_name":"PreToolUse","tool_input":{"command":"ls"}}'
  assert_rc_zero "non-Agent tool"
  assert_out_empty "non-Agent tool silent"
  for bad in 'not json{' '' '{"hook_event_name":"PreToolUse"}'; do
    tel telemetry-agent-run "$bad"
    assert_rc_zero "agent-run malformed ($bad)"
    assert_out_empty "agent-run malformed silent ($bad)"
  done
  n=$(find "$TSTATE" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" = "0" ]; then _pass "no files written"; else _fail "no files written" "found $n"; fi
  rm -rf "$workdir"
}

section "[TELEMETRY-DISPATCH-001] dispatch routes a telemetry name to its sh implementation"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; mkdir -p "$workdir/hooks"
  cp "$SRC_REPO/hooks/dispatch.sh" "$SRC_REPO/hooks/telemetry-session-start.sh" "$workdir/hooks/"
  RUN_OUT="$( (printf '%s' "$(jq -n --arg c "$workdir" '{session_id:"dsp",cwd:$c,source:"startup"}')" \
    | CLAUDE_STATE_DIR="$TSTATE" sh "$workdir/hooks/dispatch.sh" telemetry-session-start) 2>&1)"; RUN_RC=$?
  assert_rc_zero "dispatch telemetry-session-start"
  assert_out_empty "dispatch telemetry-session-start silent"
  assert_jq "dispatch wrote the session file" "$TSTATE/telemetry/sessions/dsp.json" '.session_id=="dsp"'
  rm -rf "$workdir"
}

# tel_idline <id> <input> <output> <cache-read> <cache-create> <model> [extra-json-fields]:
# one assistant line carrying a message id (Claude Code writes one such line per content block).
tel_idline() {
  printf '{"type":"assistant"%s,"message":{"id":"%s","model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
    "${7:-}" "$1" "$6" "$2" "$5" "$4" "$3"
}

section "[TELEMETRY-START-006] project derivation never stores credentials; scp form; bare host falls back to cwd"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; repo="$workdir/cwdname"; mkdir -p "$repo"
  make_test_repo "$repo"
  n=0
  while IFS='|' read -r u want; do
    n=$((n + 1))
    git -C "$repo" remote remove origin 2>/dev/null
    git -C "$repo" remote add origin "$u"
    tel telemetry-session-start "$(jq -n --arg cwd "$repo" --arg s "pj$n" '{session_id:$s,cwd:$cwd,source:"startup"}')"
    f="$TSTATE/telemetry/sessions/pj$n.json"
    assert_out_empty "project case $n silent"
    assert_jq "project case $n is '$want'" "$f" ".project==\"$want\""
    if grep -qE 'SECRET|ghp_' "$f"; then _fail "no credential in record (case $n)" "$(cat "$f")"; else _pass "no credential in record (case $n)"; fi
  done <<'URLS'
https://user:ghp_SECRET1@github.com|cwdname
https://ghp_SECRET2@example.com/|cwdname
https://example.com/o/repo.git?private_token=SECRET3|repo
git@github.com:o/repo.git|repo
https://example.com/o/lib.git#frag|lib
https://user:ghp_aa/SECRETX1@host.example|cwdname
https://user:ghpYY?rest@host.example:o/repo.git|cwdname
https://user:ghpZZ#rest@host.example/o/r.git|cwdname
https://user:pa?x@host/|cwdname
https://user:pw@host.example/o/a@b.git|cwdname
ssh://git@host.example:22/o/svc.git|svc
URLS
  rm -rf "$workdir"
}

section "[TELEMETRY-START-007] dots-only / newline-bearing session ids write nothing outside sessions/"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"
  for bad in '..' '.' '...' ''; do
    tel telemetry-session-start "$(jq -n --arg s "$bad" --arg c "$workdir" '{session_id:$s,cwd:$c,source:"startup"}')"
    assert_rc_zero "start with id '$bad'"
    tel telemetry-session-stop "$(jq -n --arg s "$bad" '{session_id:$s,hook_event_name:"Stop"}')"
    assert_rc_zero "stop with id '$bad'"
  done
  tel telemetry-agent-run "$(jq -n '{session_id:"..",tool_use_id:"t",tool_name:"Agent",hook_event_name:"PreToolUse",tool_input:{subagent_type:"x"}}')"
  assert_out_empty "agent-run with id '..' silent"
  n=$(find "$TSTATE" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" = "0" ]; then _pass "nothing written for dots-only ids"; else _fail "nothing written" "found $n files"; fi
  tel telemetry-session-start "$(jq -n --arg c "$workdir" '{session_id:"a\nb/c",cwd:$c,source:"startup"}')"
  if [ -f "$TSTATE/telemetry/sessions/abc.json" ]; then _pass "newline and slash stripped from id"; else _fail "newline stripped" "$(find "$TSTATE" -type f | head -5)"; fi
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-006] usage counted once per message id (last line of the id wins); sidechain excluded"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"
  { tel_idline msg_A 2 5 10 20 m1; tel_idline msg_A 2 5 10 20 m1; tel_idline msg_A 2 100 10 20 m1
    printf '{"type":"user","message":{"content":"hi"}}\n'
    tel_idline msg_B 3 200 30 40 m2
    tel_idline msg_S 99 99 99 99 m3 ',"isSidechain":true'
    tel_line 1 1 1 1 m4; tel_line 1 1 1 1 m4; } > "$tr_f"
  stop="$(jq -n --arg t "$tr_f" '{session_id:"st6",transcript_path:$t,hook_event_name:"Stop"}')"
  tel telemetry-session-stop "$stop"
  f="$TSTATE/telemetry/sessions/st6.json"
  assert_rc_zero "dedupe run"
  assert_out_empty "dedupe run silent"
  assert_jq "A once (last line), B once, id-less lines individually, sidechain skipped" "$f" '.tokens=={input:7,output:302,cache_read:42,cache_creation:62} and .model=="m4" and .last_message_id==null'
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-007] a message whose lines straddle two runs is counted once"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"
  { tel_idline msg_A 2 100 10 20 m1; tel_idline msg_A 2 100 10 20 m1; } > "$tr_f"
  stop="$(jq -n --arg t "$tr_f" '{session_id:"st7",transcript_path:$t,hook_event_name:"Stop"}')"
  tel telemetry-session-stop "$stop"
  f="$TSTATE/telemetry/sessions/st7.json"
  assert_jq "first chunk: A counted, last_message_id persisted" "$f" '.tokens.output==100 and .last_message_id=="msg_A"'
  { tel_idline msg_A 2 100 10 20 m1; tel_idline msg_B 3 7 0 0 m1; } >> "$tr_f"
  tel telemetry-session-stop "$stop"
  assert_jq "continuation of A skipped, B counted once" "$f" '.tokens.output==107 and .tokens.input==5 and .last_message_id=="msg_B"'
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-008] corrupt line is skipped: valid lines around it counted, offset reaches EOF"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"
  { tel_line 1 10 0 0 m1; printf 'this is not json\n{"type":"assistant"\n'; tel_line 2 20 0 0 m2; tel_line 4 40 0 0 m3; } > "$tr_f"
  tel telemetry-session-stop "$(jq -n --arg t "$tr_f" '{session_id:"st8",transcript_path:$t,hook_event_name:"Stop"}')"
  assert_rc_zero "stop with corrupt lines"
  assert_out_empty "stop corrupt silent"
  assert_jq "all three valid lines counted; offset = file size" "$TSTATE/telemetry/sessions/st8.json" ".tokens.input==7 and .tokens.output==70 and .transcript_offset==$(wc -c < "$tr_f" | tr -d ' ') and (.ended_at|type)==\"string\""
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-009] shrunk or replaced transcript: totals equal the recount, not the sum"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"; f="$TSTATE/telemetry/sessions/st9.json"
  { tel_line 1 10 0 0 m1; tel_line 2 20 0 0 m1; tel_line 4 40 0 0 m1; } > "$tr_f"
  stop="$(jq -n --arg t "$tr_f" '{session_id:"st9",transcript_path:$t,hook_event_name:"Stop"}')"
  tel telemetry-session-stop "$stop"
  assert_jq "baseline 7/70" "$f" '.tokens.input==7 and .tokens.output==70'
  tel_line 8 80 0 0 m2 > "$tr_f"
  tel telemetry-session-stop "$stop"
  assert_jq "shrunk file: totals == recount (8/80), not the sum" "$f" ".tokens.input==8 and .tokens.output==80 and .model==\"m2\" and .transcript_offset==$(wc -c < "$tr_f" | tr -d ' ')"
  tr2="$workdir/other.jsonl"
  { tel_line 1 1 0 0 m3; tel_line 1 1 0 0 m3; tel_line 1 1 0 0 m3; tel_line 1 1 0 0 m3; } > "$tr2"
  tel telemetry-session-stop "$(jq -n --arg t "$tr2" '{session_id:"st9",transcript_path:$t,hook_event_name:"Stop"}')"
  assert_jq "different transcript_path (larger file): totals == recount (4/4)" "$f" '.tokens.input==4 and .tokens.output==4 and .model=="m3"'
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-010] CRLF transcript is parsed"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"
  { tel_line 1 10 2 3 m1; tel_line 2 20 4 5 m1; } | sed 's/$/\r/' > "$tr_f"
  tel telemetry-session-stop "$(jq -n --arg t "$tr_f" '{session_id:"st10",transcript_path:$t,hook_event_name:"Stop"}')"
  assert_jq "CRLF lines counted, offset = file size" "$TSTATE/telemetry/sessions/st10.json" ".tokens=={input:3,output:30,cache_read:6,cache_creation:8} and .transcript_offset==$(wc -c < "$tr_f" | tr -d ' ')"
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-011] stop_hook_active=true does not increment turns"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; f="$TSTATE/telemetry/sessions/st11.json"
  tel telemetry-session-stop '{"session_id":"st11","hook_event_name":"Stop","stop_hook_active":false}'
  tel telemetry-session-stop '{"session_id":"st11","hook_event_name":"Stop","stop_hook_active":true}'
  assert_rc_zero "re-fired stop"
  assert_jq "turns stays 1, ended_at stamped" "$f" '.turns==1 and (.ended_at|type)=="string"'
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-012] non-regular transcript path (directory) is skipped; ended_at still stamped"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; mkdir -p "$workdir/adir"
  tel telemetry-session-stop "$(jq -n --arg t "$workdir/adir" '{session_id:"st12",transcript_path:$t,hook_event_name:"Stop"}')"
  assert_rc_zero "directory as transcript"
  assert_out_empty "directory as transcript silent"
  assert_jq "totals zero, offset 0, ended_at stamped" "$TSTATE/telemetry/sessions/st12.json" '.tokens.input==0 and .transcript_offset==0 and (.ended_at|type)=="string"'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-005] PostToolUse without duration_ms falls back to ended_at - started_at; oversized fields capped"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/ag5/agents"
  head -c 40000 /dev/zero | tr '\0' 'x' > "$workdir/big.txt"
  jq -n --rawfile big "$workdir/big.txt" '{session_id:"ag5",tool_use_id:"t1",tool_name:"Agent",hook_event_name:"PreToolUse",tool_input:{subagent_type:"rust-expert",description:$big}}' > "$workdir/pre.json"
  tel telemetry-agent-run "$(cat "$workdir/pre.json")"
  assert_jq "description capped to 200 chars" "$d/t1.json" '(.description|length)==200'
  jq '.started_at="2020-01-01T00:00:00Z"' "$d/t1.json" > "$d/t1.tmp" && mv "$d/t1.tmp" "$d/t1.json"
  jq -n --rawfile big "$workdir/big.txt" '{session_id:"ag5",tool_use_id:"t1",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"rust-expert",description:$big},tool_response:"ok"}' > "$workdir/post.json"
  tel telemetry-agent-run "$(cat "$workdir/post.json")"
  assert_rc_zero "post with 40 KB description"
  assert_out_empty "post silent"
  assert_jq "status completed, duration_s from started_at fallback" "$d/t1.json" '.status=="completed" and (.duration_s|type)=="number" and .duration_s>1000000 and (.description|length)==200'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-006] SubagentStop: usage once per message id, sidechain lines counted, corrupt line skipped"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; tr_f="$workdir/agent-a6.jsonl"
  { tel_idline m1 1 10 0 0 h ',"isSidechain":true'; tel_idline m1 1 10 0 0 h ',"isSidechain":true'
    printf 'garbage\n'; tel_idline m2 2 20 0 0 h ',"isSidechain":true'; } | sed 's/$/\r/' > "$tr_f"
  tel telemetry-agent-run "$(jq -n --arg t "$tr_f" '{session_id:"ag6",agent_id:"a6",agent_type:"rust-expert",hook_event_name:"SubagentStop",agent_transcript_path:$t}')"
  assert_jq "tokens 3/30 over distinct ids" "$TSTATE/telemetry/sessions/ag6/agents/subagent-a6.json" '.tokens.input==3 and .tokens.output==30 and .model_actual=="h"'
  tel telemetry-agent-run "$(jq -n --arg t "$workdir" '{session_id:"ag6",agent_id:"a7",agent_type:"rust-expert",hook_event_name:"SubagentStop",agent_transcript_path:$t}')"
  assert_jq "directory transcript: record without tokens" "$TSTATE/telemetry/sessions/ag6/agents/subagent-a7.json" 'has("tokens")|not'
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-013] chunk larger than the cap is consumed across several Stops; offset advances; totals equal the whole file"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"; f="$TSTATE/telemetry/sessions/st13.json"
  # 40 messages, two lines each (partial then final output), so chunk boundaries split messages.
  i=0; : > "$tr_f"
  while [ "$i" -lt 40 ]; do
    tel_idline "msg_$i" 1 1 0 0 m1 >> "$tr_f"; tel_idline "msg_$i" 1 3 0 0 m1 >> "$tr_f"; i=$((i + 1))
  done
  size=$(wc -c < "$tr_f" | tr -d ' ')
  stop="$(jq -n --arg t "$tr_f" '{session_id:"st13",transcript_path:$t,hook_event_name:"Stop"}')"
  AF_TELEMETRY_CHUNK_CAP=4096; export AF_TELEMETRY_CHUNK_CAP
  tel telemetry-session-stop "$stop"
  o1=$(jq -r .transcript_offset "$f")
  tel telemetry-session-stop "$stop"
  o2=$(jq -r .transcript_offset "$f")
  runs=2
  while [ "$(jq -r .transcript_offset "$f")" -lt "$size" ] && [ "$runs" -lt 30 ]; do tel telemetry-session-stop "$stop"; runs=$((runs + 1)); done
  unset AF_TELEMETRY_CHUNK_CAP
  if [ "$o1" -gt 0 ] && [ "$o1" -lt "$size" ] && [ "$o2" -gt "$o1" ]; then _pass "offset advances per Stop ($o1 -> $o2 of $size)"; else _fail "offset advance" "o1=$o1 o2=$o2 size=$size"; fi
  assert_jq "offset reaches EOF over several Stops; 40 messages counted once with final usage (40/120)" "$f" ".transcript_offset==$size and .tokens.input==40 and .tokens.output==120"
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-014] 40 KB message.id: record still written, id capped at 200, deduped within and across runs"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"; f="$TSTATE/telemetry/sessions/st14.json"
  big=$(head -c 40000 /dev/zero | tr '\0' 'q')
  { tel_idline "$big" 2 100 10 20 m1; tel_idline "$big" 2 100 10 20 m1; } > "$tr_f"
  stop="$(jq -n --arg t "$tr_f" '{session_id:"st14",transcript_path:$t,hook_event_name:"Stop"}')"
  tel telemetry-session-stop "$stop"
  assert_rc_zero "40 KB id run"
  assert_out_empty "40 KB id run silent"
  assert_jq "two lines of one long id count once; id capped at 200" "$f" '.tokens=={input:2,output:100,cache_read:10,cache_creation:20} and (.last_message_id|length)==200'
  tel_idline "$big" 2 160 10 20 m1 >> "$tr_f"
  tel telemetry-session-stop "$stop"
  assert_jq "continuation across runs adds only the growth (output 160, input 2)" "$f" '.tokens.output==160 and .tokens.input==2 and .tokens.cache_read==10'
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-015] split message keeps last-line usage; <synthetic> model does not replace the model"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"; f="$TSTATE/telemetry/sessions/st15.json"
  tel_idline msg_A 3 50 0 0 m1 > "$tr_f"
  stop="$(jq -n --arg t "$tr_f" '{session_id:"st15",transcript_path:$t,hook_event_name:"Stop"}')"
  tel telemetry-session-stop "$stop"
  assert_jq "first part counted, usage stored" "$f" '.tokens.output==50 and (.last_message_usage.output)==50'
  { tel_idline msg_A 3 80 0 0 m1; tel_line 1 1 0 0 "<synthetic>"; } >> "$tr_f"
  tel telemetry-session-stop "$stop"
  assert_jq "final usage wins (80 not 130), synthetic line counted but model stays m1" "$f" '.tokens.output==81 and .tokens.input==4 and .model=="m1"'
  rm -rf "$workdir"
}

section "[TELEMETRY-STOP-016] unreadable file size skips accounting: path, offset and totals untouched"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tr_f="$workdir/t.jsonl"; f="$TSTATE/telemetry/sessions/st16.json"
  { tel_line 1 10 0 0 m1; tel_line 2 20 0 0 m1; tel_line 4 40 0 0 m1; } > "$tr_f"
  stop="$(jq -n --arg t "$tr_f" '{session_id:"st16",transcript_path:$t,hook_event_name:"Stop"}')"
  tel telemetry-session-stop "$stop"
  before=$(jq -c '[.tokens,.transcript_offset,.transcript_path]' "$f")
  mkdir -p "$workdir/shim"; printf '#!/bin/sh\nexit 1\n' > "$workdir/shim/wc"; chmod +x "$workdir/shim/wc"
  RUN_OUT="$( (printf '%s' "$(jq -n --arg t "$tr_f" '{session_id:"st16",transcript_path:$t,hook_event_name:"SessionEnd",reason:"x"}')" \
    | PATH="$workdir/shim:$PATH" CLAUDE_STATE_DIR="$TSTATE" sh "$SRC_REPO/hooks/telemetry-session-stop.sh") 2>&1)"; RUN_RC=$?
  assert_rc_zero "stop with failing wc"
  assert_out_empty "stop with failing wc silent"
  after=$(jq -c '[.tokens,.transcript_offset,.transcript_path]' "$f")
  if [ "$before" = "$after" ]; then _pass "totals, offset and path unchanged"; else _fail "state changed on size failure" "$before vs $after"; fi
  assert_jq "end_reason still stamped" "$f" '.end_reason=="x"'
  rm -rf "$workdir"
}

section "[TELEMETRY-START-008] stale .tmp.* work dirs (>60 min, empty or not, any depth) are removed; fresh ones kept"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; tdir="$TSTATE/telemetry/sessions"
  mkdir -p "$tdir/.tmp.stale1" "$tdir/.tmp.staleempty" "$tdir/.tmp.fresh1" "$tdir/sx/agents/.tmp.stale2"
  : > "$tdir/.tmp.stale1/chunk"; : > "$tdir/.tmp.fresh1/chunk"; : > "$tdir/sx/agents/.tmp.stale2/lines"
  touch -t 202001010000 "$tdir/.tmp.stale1/chunk" "$tdir/.tmp.stale1" "$tdir/.tmp.staleempty" "$tdir/sx/agents/.tmp.stale2/lines" "$tdir/sx/agents/.tmp.stale2"
  tel telemetry-session-start "$(jq -n --arg cwd "$workdir" '{session_id:"sess8",cwd:$cwd,source:"startup"}')"
  assert_rc_zero "start with stale work dirs"
  assert_out_empty "start with stale work dirs silent"
  if [ ! -e "$tdir/.tmp.stale1" ] && [ ! -e "$tdir/.tmp.staleempty" ] && [ ! -e "$tdir/sx/agents/.tmp.stale2" ]; then _pass "stale work dirs removed"; else _fail "stale work dirs remain" "$(find "$tdir" -name '.tmp.*')"; fi
  if [ -d "$tdir/.tmp.fresh1" ]; then _pass "fresh work dir kept"; else _fail "fresh work dir removed" "$(ls -a "$tdir")"; fi
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-007] no .tmp.* left behind after Pre / Post / SubagentStop"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/ag7/agents"
  tr_f="$workdir/agent-a7.jsonl"; tel_idline m1 1 10 0 0 h > "$tr_f"
  tel telemetry-agent-run '{"session_id":"ag7","tool_use_id":"t1","tool_name":"Agent","hook_event_name":"PreToolUse","tool_input":{"subagent_type":"rust-expert"}}'
  tel telemetry-agent-run '{"session_id":"ag7","tool_use_id":"t1","tool_name":"Agent","hook_event_name":"PostToolUse","tool_input":{"subagent_type":"rust-expert"},"tool_response":"ok"}'
  tel telemetry-agent-run "$(jq -n --arg t "$tr_f" '{session_id:"ag7",agent_id:"a7",agent_type:"rust-expert",hook_event_name:"SubagentStop",agent_transcript_path:$t}')"
  # launch -> hand-back completion path (REQ-303a)
  tel telemetry-agent-run '{"session_id":"ag7","tool_use_id":"t2","tool_name":"Agent","hook_event_name":"PreToolUse","tool_input":{"subagent_type":"peer-review-critic"}}'
  tel telemetry-agent-run '{"session_id":"ag7","tool_use_id":"t2","tool_name":"Agent","hook_event_name":"PostToolUse","tool_input":{"subagent_type":"peer-review-critic"},"tool_response":"Async agent launched successfully.\nagentId: a7b"}'
  tel telemetry-agent-run "$(jq -n --arg t "$tr_f" '{session_id:"ag7",agent_id:"a7b",agent_type:"peer-review-critic",hook_event_name:"SubagentStop",agent_transcript_path:$t}')"
  left=$(find "$TSTATE" -name '.tmp.*' | head -3)
  if [ -z "$left" ] && [ -f "$d/t1.json" ] && [ -f "$d/subagent-a7.json" ] && [ -f "$d/subagent-a7b.json" ] && [ "$(jq -r .status "$d/t2.json")" = "completed" ]; then _pass "records written (incl. launch -> completion), no work dir left"; else _fail "leftover or missing record" "$left"; fi
  rm -rf "$workdir"
}


# --- launch acknowledgement and hand-back (REQ-303a) ------------------------
TEL_ACK='Async agent launched successfully. (This tool result is internal metadata)
agentId: ab12cd34ef567890a (internal ID - do not mention to user.)
The agent is working in the background.
output_file: C:\Users\x\tasks\ab12cd34ef567890a.output'
TEL_OBJ='{"agentId":"ab12cd34ef567890a","canContinueAgent":true,"canReadOutputFile":false,"description":"gate review","isAsync":true,"outputFile":"C:/x/tasks/ab12cd34ef567890a.output","prompt":"review the diff","resolvedModel":"claude-opus-5-5","status":"async_launched"}'
tel_hb_tr() { # <file> <report>: hand-back transcript with fractional-second timestamps and a model
  {
    printf '%s\n' '{"type":"user","timestamp":"2026-10-22T17:44:49.753Z","isSidechain":true,"message":{"role":"user","content":[{"type":"text","text":"go"}]}}'
    printf '%s%s\n' '{"type":"assistant","timestamp":"2026-10-22T17:50:00.000Z","isSidechain":true,"message":{"role":"assistant","model":"claude-opus-5-5","id":"m1","usage":{"input_tokens":3,"output_tokens":4,"cache_read_input_tokens":1,"cache_creation_input_tokens":2},' \
      '"content":[{"type":"text","text":"Reviewing..."}]}}'
    jq -nc --arg m "$2" '{type:"assistant",timestamp:"2026-10-22T17:57:14.100Z",isSidechain:true,message:{role:"assistant",model:"claude-opus-5-5",id:"m2",usage:{input_tokens:1,output_tokens:2,cache_read_input_tokens:0,cache_creation_input_tokens:0},
      content:[{type:"tool_use",id:"toolu_z",name:"SubagentHandback",input:{message:$m}}]}}'
    printf '%s\n' '{"type":"user","timestamp":"2026-10-22T17:57:14.200Z","isSidechain":true,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_z","content":"ok"}]}}'
  } > "$1"
}

section "[TELEMETRY-AGENT-HB-1] PostToolUse launch acknowledgement: status launched, agent_id, launched_at, no duration"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/hb1/agents"
  tel telemetry-agent-run '{"session_id":"hb1","tool_use_id":"toolu_L","tool_name":"Agent","hook_event_name":"PreToolUse","tool_input":{"subagent_type":"agentic-framework:code-review-gatekeeper","model":"opus","description":"gate review"}}'
  tel telemetry-agent-run "$(jq -n --argjson o "$TEL_OBJ" '{session_id:"hb1",tool_use_id:"toolu_L",tool_name:"Agent",hook_event_name:"PostToolUse",duration_ms:23,tool_input:{subagent_type:"agentic-framework:code-review-gatekeeper",model:"opus"},tool_response:$o}')"
  assert_rc_zero "post ack"
  assert_out_empty "post ack silent"
  assert_jq "launched record: agent_id, launched_at, no ended_at/duration_s/verdict" "$d/toolu_L.json" '.status=="launched" and .agent_id=="ab12cd34ef567890a" and (.launched_at|test("^[0-9]{4}-")) and (has("duration_s")|not) and (has("ended_at")|not) and (has("verdict")|not)'
  assert_jq "Pre fields preserved" "$d/toolu_L.json" '.description=="gate review" and .model_tier=="opus" and .agent_name=="code-review-gatekeeper" and (.started_at|test("^[0-9]{4}-"))'
  # text form kept as a second launch-acknowledgement form
  tel telemetry-agent-run "$(jq -n --arg a "$TEL_ACK" '{session_id:"hb1",tool_use_id:"toolu_T",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"rust-expert"},tool_response:[{type:"text",text:$a}]}')"
  assert_jq "text-form ack: launched, agent_id from the text id line" "$d/toolu_T.json" '.status=="launched" and .agent_id=="ab12cd34ef567890a" and (has("duration_s")|not) and (.launched_at | test("^[0-9]{4}-")) and (has("ended_at") | not)'
  # phrase without the agentId: second line is not a launch: completed path as before
  tel telemetry-agent-run "$(jq -n --arg a 'Async agent launched successfully. (internal)
The agent is working in the background.' '{session_id:"hb1",tool_use_id:"toolu_N",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"rust-expert"},tool_response:[{type:"text",text:$a}]}')"
  assert_jq "text without agentId line: completed, not launched" "$d/toolu_N.json" '.status=="completed" and has("duration_s")'
  # a 100-character agentId token is capped to 64
  long="$(printf '%100s' '' | tr ' ' 'a')"
  tel telemetry-agent-run "$(jq -n --arg a "Async agent launched successfully. (internal)
agentId: $long (internal ID)" '{session_id:"hb1",tool_use_id:"toolu_C",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"rust-expert"},tool_response:[{type:"text",text:$a}]}')"
  assert_jq "text-form agent_id capped at 64 characters" "$d/toolu_C.json" '.status=="launched" and (.agent_id|length)==64'
  tel telemetry-agent-run "$(jq -n --arg l "$long" '{session_id:"hb1",tool_use_id:"toolu_C2",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"rust-expert"},tool_response:{status:"async_launched",agentId:$l}}')"
  assert_jq "object-form agent_id capped at 64 characters" "$d/toolu_C2.json" '.status=="launched" and (.agent_id|length)==64'
  # isAsync only (no status): still a launch
  tel telemetry-agent-run "$(jq -n '{session_id:"hb1",tool_use_id:"toolu_IA",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"rust-expert"},tool_response:{isAsync:true,agentId:"ia1"}}')"
  assert_jq "isAsync-only object: launched" "$d/toolu_IA.json" '.status=="launched" and .agent_id=="ia1"'
  # a non-launch object response is an ordinary completed report with its verdict
  tel telemetry-agent-run "$(jq -n '{session_id:"hb1",tool_use_id:"toolu_NL",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"peer-review-critic"},tool_response:{status:"completed",content:[{type:"text",text:"Done.\nVERDICT: APPROVED"}]}}')"
  assert_jq "non-launch object: completed with verdict" "$d/toolu_NL.json" '.status=="completed" and .verdict=="APPROVED"'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-HB-2] SubagentStop completes the launch record and links the subagent record"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/hb2/agents"
  tel_hb_tr "$workdir/t.jsonl" "Target: x vs y (a..b)
VERDICT: APPROVED"
  tel telemetry-agent-run '{"session_id":"hb2","tool_use_id":"toolu_L","tool_name":"Agent","hook_event_name":"PreToolUse","tool_input":{"subagent_type":"agentic-framework:code-review-gatekeeper","description":"gate review"}}'
  tel telemetry-agent-run "$(jq -n --argjson o "$TEL_OBJ" '{session_id:"hb2",tool_use_id:"toolu_L",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"agentic-framework:code-review-gatekeeper"},tool_response:$o}')"
  sleep 2
  tel telemetry-agent-run "$(jq -n --arg t "$workdir/t.jsonl" '{session_id:"hb2",agent_id:"ab12cd34ef567890a",agent_type:"agentic-framework:code-review-gatekeeper",hook_event_name:"SubagentStop",last_assistant_message:"",agent_transcript_path:$t}')"
  assert_rc_zero "subagent stop"
  assert_out_empty "subagent stop silent"
  assert_jq "launch record completed with verdict and model_actual" "$d/toolu_L.json" '.status=="completed" and .verdict=="APPROVED" and .model_actual=="claude-opus-5-5" and (.ended_at|test("^[0-9]{4}-")) and .agent_id=="ab12cd34ef567890a"'
  assert_jq "duration_s = stop - started_at within 2 s (and at least the 2 s slept)" "$d/toolu_L.json" '((.duration_s - ((.ended_at|fromdateiso8601) - (.started_at|fromdateiso8601))) | fabs) <= 2 and .duration_s >= 2'
  assert_jq "subagent record: tool_use_id, started_at, duration_s, tokens" "$d/subagent-ab12cd34ef567890a.json" '.tool_use_id=="toolu_L" and .started_at=="2026-10-22T17:44:49.753Z" and (.duration_s|type)=="number" and .verdict=="APPROVED" and .tokens=={input:4,output:6,cache_read:1,cache_creation:2}'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-HB-6] resumed agent: a second SubagentStop re-merges onto the same launch record and keeps the link"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/hb6/agents"
  tel_hb_tr "$workdir/t.jsonl" "VERDICT: APPROVED"
  tel telemetry-agent-run '{"session_id":"hb6","tool_use_id":"toolu_L","tool_name":"Agent","hook_event_name":"PreToolUse","tool_input":{"subagent_type":"agentic-framework:code-review-gatekeeper"}}'
  tel telemetry-agent-run "$(jq -n --argjson o "$TEL_OBJ" '{session_id:"hb6",tool_use_id:"toolu_L",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"agentic-framework:code-review-gatekeeper"},tool_response:$o}')"
  stop_ev="$(jq -n --arg t "$workdir/t.jsonl" '{session_id:"hb6",agent_id:"ab12cd34ef567890a",agent_type:"agentic-framework:code-review-gatekeeper",hook_event_name:"SubagentStop",last_assistant_message:"",agent_transcript_path:$t}')"
  tel telemetry-agent-run "$stop_ev"
  end1="$(jq -r .ended_at "$d/toolu_L.json")"
  sleep 1
  printf '%s\n' '{"type":"assistant","timestamp":"2026-10-22T18:10:00.000Z","isSidechain":true,"message":{"role":"assistant","model":"claude-opus-5-5","id":"m3","usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"resumed"}]}}' >> "$workdir/t.jsonl"
  tel telemetry-agent-run "$stop_ev"
  assert_rc_zero "second stop"
  assert_jq "same record re-merged: completed, ended_at moved on, agent_id kept" "$d/toolu_L.json" ".status==\"completed\" and .agent_id==\"ab12cd34ef567890a\" and .ended_at > \"$end1\" and .tool_use_id==\"toolu_L\""
  assert_jq "subagent record keeps tool_use_id after the second stop" "$d/subagent-ab12cd34ef567890a.json" '.tool_use_id=="toolu_L" and .tokens.output==7'
  n=$(find "$d" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  if [ "$n" = 2 ]; then _pass "no extra record created (2 files)"; else _fail "record count" "$n"; fi
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-HB-7] state directory containing a space: the launch link still completes"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state dir"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/hb7/agents"
  tel_hb_tr "$workdir/t.jsonl" "VERDICT: APPROVED"
  tel telemetry-agent-run '{"session_id":"hb7","tool_use_id":"toolu_L","tool_name":"Agent","hook_event_name":"PreToolUse","tool_input":{"subagent_type":"agentic-framework:code-review-gatekeeper"}}'
  tel telemetry-agent-run "$(jq -n --argjson o "$TEL_OBJ" '{session_id:"hb7",tool_use_id:"toolu_L",tool_name:"Agent",hook_event_name:"PostToolUse",tool_input:{subagent_type:"agentic-framework:code-review-gatekeeper"},tool_response:$o}')"
  tel telemetry-agent-run "$(jq -n --arg t "$workdir/t.jsonl" '{session_id:"hb7",agent_id:"ab12cd34ef567890a",agent_type:"agentic-framework:code-review-gatekeeper",hook_event_name:"SubagentStop",last_assistant_message:"",agent_transcript_path:$t}')"
  assert_jq "launch record completed in a state path with a space" "$d/toolu_L.json" '.status=="completed" and .verdict=="APPROVED" and .agent_id=="ab12cd34ef567890a"'
  assert_jq "subagent record linked (tool_use_id set)" "$d/subagent-ab12cd34ef567890a.json" '.tool_use_id=="toolu_L"'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-HB-3] SubagentStop without a launch record: subagent record only, transcript span, fractional seconds stripped"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/hb3/agents"
  tel_hb_tr "$workdir/t.jsonl" "VERDICT: CHANGES_REQUIRED"
  tel telemetry-agent-run "$(jq -n --arg t "$workdir/t.jsonl" '{session_id:"hb3",agent_id:"zz99",agent_type:"peer-review-critic",hook_event_name:"SubagentStop",agent_transcript_path:$t}')"
  assert_rc_zero "subagent stop"
  n=$(find "$d" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  if [ "$n" = "1" ] && [ -f "$d/subagent-zz99.json" ]; then _pass "only the subagent record written"; else _fail "files" "$(ls -A "$d" 2>&1)"; fi
  tel_hb_tr "$workdir/t2.jsonl" "VERDICT: CHANGES_REQUIRED"
  { head -n 1 "$workdir/t2.jsonl"; printf '%s\n' '{"type":"assistant","timestamp":"2026-10-22T17:45:00.000Z","message":"oops"}'; tail -n +2 "$workdir/t2.jsonl"; } > "$workdir/t3.jsonl"
  tel telemetry-agent-run "$(jq -n --arg t "$workdir/t3.jsonl" '{session_id:"hb3",agent_id:"zz98",agent_type:"peer-review-critic",hook_event_name:"SubagentStop",agent_transcript_path:$t}')"
  assert_jq "non-object message line: verdict still parsed from the hand-back" "$d/subagent-zz98.json" '.verdict=="CHANGES_REQUIRED"'
  assert_jq "tool_use_id null, started_at is the first timestamp, verdict from hand-back" "$d/subagent-zz99.json" '.tool_use_id==null and .started_at=="2026-10-22T17:44:49.753Z" and .verdict=="CHANGES_REQUIRED"'
  assert_jq "duration_s = ended_at - first timestamp (fractional part stripped)" "$d/subagent-zz99.json" '.duration_s == ((.ended_at|fromdateiso8601) - (.started_at|sub("\\.[0-9]+";"")|fromdateiso8601))'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-HB-4] untyped SubagentStop without a transcript writes nothing; a typed one still does"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/hb4/agents"
  mkdir -p "$d"; : > "$d/keep.json"
  before=$(find "$TSTATE" -type f | wc -l | tr -d ' ')
  tel telemetry-agent-run '{"session_id":"hb4","agent_id":"u1","agent_type":"","hook_event_name":"SubagentStop","agent_transcript_path":"/nonexistent/x.jsonl"}'
  tel telemetry-agent-run '{"session_id":"hb4","agent_id":"u2","hook_event_name":"SubagentStop"}'
  after=$(find "$TSTATE" -type f | wc -l | tr -d ' ')
  assert_rc_zero "untyped stop"
  if [ "$before" = "$after" ]; then _pass "no file written for untyped events ($before files)"; else _fail "untyped wrote files" "$before -> $after"; fi
  tel telemetry-agent-run '{"session_id":"hb4","agent_id":"t1","agent_type":"rust-expert","hook_event_name":"SubagentStop","agent_transcript_path":"/nonexistent/x.jsonl"}'
  assert_jq "typed stop without transcript still writes the subagent record" "$d/subagent-t1.json" '.agent_name=="rust-expert" and .tool_use_id==null and .started_at==null and .duration_s==null'
  rm -rf "$workdir"
}

section "[TELEMETRY-AGENT-HB-5] transcript larger than 16 MiB: verdict from the tail, tokens and started_at from the head"
{
  workdir="$(make_work_dir)" || exit 2
  TSTATE="$workdir/state"; TEL_PLUGIN_ROOT=""; d="$TSTATE/telemetry/sessions/hb5/agents"
  big_hb_transcript "$workdir/big.jsonl"
  tel telemetry-agent-run "$(jq -n --arg t "$workdir/big.jsonl" '{session_id:"hb5",agent_id:"big1",agent_type:"agentic-framework:code-review-gatekeeper",hook_event_name:"SubagentStop",last_assistant_message:"",agent_transcript_path:$t}')"
  assert_rc_zero "subagent stop"
  assert_out_empty "subagent stop silent"
  assert_jq "verdict APPROVED, tokens present, started_at = first line" "$d/subagent-big1.json" '.verdict=="APPROVED" and (.tokens|type)=="object" and .tokens.input>0 and .started_at=="2026-10-22T17:30:00.100Z"'
  rm -rf "$workdir"
}

section "[TELEMETRY-DISPATCH-002] MINGW arm without jq and without a .ps1 twin: exit 0, silent, nothing run"
{
  workdir="$(make_work_dir)" || exit 2
  mkdir -p "$workdir/hooks" "$workdir/bin"
  cp "$SRC_REPO/hooks/dispatch.sh" "$SRC_REPO/hooks/telemetry-session-start.sh" "$workdir/hooks/"
  printf '#!/bin/sh\necho MINGW64_NT-10.0\n' > "$workdir/bin/uname"; chmod +x "$workdir/bin/uname"
  sh_bin="$(command -v sh)"
  # PATH holds only the fake uname, so `command -v jq` fails inside dispatch.sh.
  RUN_OUT="$( (printf '%s' '{"session_id":"nojq","source":"startup"}' | PATH="$workdir/bin" CLAUDE_STATE_DIR="$workdir/state" \
    "$sh_bin" "$workdir/hooks/dispatch.sh" telemetry-session-start) 2>&1)"; RUN_RC=$?
  assert_rc_zero "dispatch no-jq MINGW"
  assert_out_empty "dispatch no-jq MINGW silent"
  if [ ! -e "$workdir/state" ]; then _pass "no-jq MINGW: hook not run, nothing written"; else _fail "hook ran without jq" "$(find "$workdir/state" | head -3)"; fi
  rm -rf "$workdir"
}


# ===========================================================================
# pretooluse-code-review-gate (REQ-004, REQ-005, EDGE-001 .. EDGE-008)
# ===========================================================================

GATE="$SRC_REPO/hooks/pretooluse-code-review-gate.sh"
GATE_STATE=""

gate_commit() {
  # gate_commit <dir> <message>: append a line to f.txt and commit it
  printf '%s\n' "$2" >> "$1/f.txt"
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

gate_mkrepo() {
  # gate_mkrepo <dir> [branch]: repo with origin/<branch> one commit behind <branch>,
  # origin/HEAD -> origin/<branch>, a feat/x branch at the tip. The remote URL points
  # at a path that does not exist; nothing in these tests ever contacts it.
  local d="$1" b="${2:-main}"
  mkdir -p "$d"
  git -C "$d" init -q -b "$b"
  [ -d "$d/.git" ] || { printf 'gate_mkrepo: git init failed for %s\n' "$d" >&2; return 1; }
  git -C "$d" config user.email 'test@test.local'
  git -C "$d" config user.name 'hooks-test'
  git -C "$d" config commit.gpgsign false
  gate_commit "$d" c1
  git -C "$d" remote add origin "$d.nowhere"
  git -C "$d" update-ref "refs/remotes/origin/$b" "$(git -C "$d" rev-parse HEAD)"
  git -C "$d" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$b"
  gate_commit "$d" c2
  git -C "$d" branch feat/x
}

gate_build_fixtures() {
  # gate_build_fixtures <root>: sets GF_* fixture paths (see EDGE-001 table)
  local r="$1"
  GF_M="$r/m";   gate_mkrepo "$GF_M" main                       # on main
  GF_XS="$r/xs"; cp -R "$GF_M" "$GF_XS"; git -C "$GF_XS" checkout -q feat/x   # feat/x at main's sha
  GF_X="$r/x";   cp -R "$GF_XS" "$GF_X"; gate_commit "$GF_X" c3                # feat/x one ahead of main
  GF_U="$r/u";   cp -R "$GF_X" "$GF_U"                          # feat/x, upstream origin/main
  git -C "$GF_U" config branch.feat/x.remote origin
  git -C "$GF_U" config branch.feat/x.merge refs/heads/main
  GF_U2="$r/u2"; cp -R "$GF_X" "$GF_U2"                         # feat/x, upstream origin/feat/x
  git -C "$GF_U2" update-ref refs/remotes/origin/feat/x "$(git -C "$GF_U2" rev-parse main)"
  git -C "$GF_U2" config branch.feat/x.remote origin
  git -C "$GF_U2" config branch.feat/x.merge refs/heads/feat/x
  GF_MATCH="$r/mt"; cp -R "$GF_X" "$GF_MATCH"; git -C "$GF_MATCH" config push.default matching
  GF_DIRTY="$r/dy"; cp -R "$GF_X" "$GF_DIRTY"; printf 'dirty\n' >> "$GF_DIRTY/f.txt"
  GF_SUB="$r/sb";   cp -R "$GF_X" "$GF_SUB"; gate_mkrepo "$GF_SUB/sub" main   # nested repo on main
  GF_DET="$r/dt";   cp -R "$GF_M" "$GF_DET"; git -C "$GF_DET" checkout -q --detach
  GF_EQ="$r/eq";    cp -R "$GF_X" "$GF_EQ"                      # main equal to origin/main
  git -C "$GF_EQ" update-ref refs/remotes/origin/main "$(git -C "$GF_EQ" rev-parse main)"
  GF_MASTER="$r/ms"; gate_mkrepo "$GF_MASTER" master            # on master
  GF_HOME="$r/home"; GF_OTH="$GF_HOME/other"; gate_mkrepo "$GF_OTH" main   # <other>: on main, ahead
  GF_BH="$r/bh";    cp -R "$GF_X" "$GF_BH"; git -C "$GF_BH" checkout -q main  # main one behind origin/main
  git -C "$GF_BH" update-ref refs/remotes/origin/main "$(git -C "$GF_BH" rev-parse feat/x)"
  GF_UP="$r/up";    cp -R "$GF_M" "$GF_UP"                      # branch.main.remote=upstream
  git -C "$GF_UP" remote add upstream "$GF_UP.nowhere-up"
  git -C "$GF_UP" update-ref refs/remotes/upstream/main "$(git -C "$GF_UP" rev-parse main~1)"
  git -C "$GF_UP" update-ref refs/remotes/origin/main "$(git -C "$GF_UP" rev-parse main)"
  git -C "$GF_UP" config branch.main.remote upstream
  GF_PL="$r/plain"; mkdir -p "$GF_PL"                            # not a git work tree
}

gate_real_marker() {
  # gate_real_marker <sid> <dir> <target prefix> <merge-base ref> [verdict] [head]: a marker whose
  # target carries the real reviewed range (<merge-base>..<HEAD>) of <dir>
  local h mb
  h="$(git -C "$2" rev-parse HEAD)"
  mb="$(git -C "$2" merge-base "$4" HEAD)"
  gate_marker "$1" "${5:-APPROVED}" "${6:-$h}" "$3 ($mb..$h); fallback: none"
}

gate_now_ms() {
  # bash 3.2 / BSD date have neither EPOCHREALTIME nor date +%N: perl, then python3, then seconds
  # (the tool is chosen once, below: callers run this in $(...), so a cache set here would be lost)
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then t="${EPOCHREALTIME/[.,]/}"; printf '%s\n' "$((t / 1000))"; return 0; fi
  case "$GATE_MS_TOOL" in
    perl) perl -MTime::HiRes -e 'printf "%d\n", Time::HiRes::time()*1000' ;;
    python3) python3 -c 'import time; print(int(time.time()*1000))' ;;
    *) printf '%s000\n' "$(date +%s)" ;;
  esac
}

if command -v perl >/dev/null 2>&1 && perl -MTime::HiRes -e 1 >/dev/null 2>&1; then GATE_MS_TOOL=perl
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import time' >/dev/null 2>&1; then GATE_MS_TOOL=python3
else GATE_MS_TOOL="date"; fi

gate_mkbin() {
  # gate_mkbin <dir> <tool>...: a PATH directory holding exec wrappers for exactly these tools
  local dir="$1" tool p
  shift
  mkdir -p "$dir"
  for tool in "$@"; do
    p="$(command -v "$tool")" || { printf 'gate_mkbin: %s not found\n' "$tool" >&2; return 1; }
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$p" > "$dir/$tool"
    chmod +x "$dir/$tool"
  done
}

gate_marker() {
  # gate_marker <sid> <verdict|-> <head|-> <target|->: write a code-review marker under GATE_STATE
  mkdir -p "$GATE_STATE/code-review"
  {
    printf '2026-10-21T00:00:00Z'
    [ "$2" != "-" ] && printf '\nverdict=%s' "$2"
    [ "$3" != "-" ] && printf '\nhead=%s' "$3"
    [ "$4" != "-" ] && printf '\ntarget=%s' "$4"
    true
  } > "$GATE_STATE/code-review/$1"
}

GATE_TOOL=Bash
GATE_HOME=""
gate_payload() { MSYS2_ARG_CONV_EXCL='*' jq -cn --arg s "$1" --arg c "$2" --arg m "$3" --arg t "$GATE_TOOL" '{session_id:$s,cwd:$c,tool_name:$t,tool_input:{command:$m}}'; }

gate_run() {
  # gate_run <sid> <cwd> <command>; GATE_TOOL sets tool_name, GATE_HOME (when set) sets HOME
  RUN_OUT="$(gate_payload "$1" "$2" "$3" | HOME="${GATE_HOME:-$HOME}" CLAUDE_STATE_DIR="$GATE_STATE" sh "$GATE" 2>&1)"
  RUN_RC=$?
}

gate_run_big() {
  # gate_run_big <sid> <cwd> <command>: the command reaches jq on stdin (no argv length limit)
  RUN_OUT="$(printf '%s' "$3" | MSYS2_ARG_CONV_EXCL='*' jq -Rsc --arg s "$1" --arg c "$2" '{session_id:$s,cwd:$c,tool_name:"Bash",tool_input:{command:.}}' \
    | CLAUDE_STATE_DIR="$GATE_STATE" sh "$GATE" 2>&1)"
  RUN_RC=$?
}

gate_run_raw() {
  # gate_run_raw <raw stdin>
  RUN_OUT="$(printf '%s' "$1" | CLAUDE_STATE_DIR="$GATE_STATE" sh "$GATE" 2>&1)"
  RUN_RC=$?
}

gate_run_env() {
  # gate_run_env <AF_CODE_REVIEW_GATE value> <sid> <cwd> <command>
  RUN_OUT="$(gate_payload "$2" "$3" "$4" | AF_CODE_REVIEW_GATE="$1" CLAUDE_STATE_DIR="$GATE_STATE" sh "$GATE" 2>&1)"
  RUN_RC=$?
}

gate_assert_allow() {
  if [ "$RUN_RC" -eq 0 ] && [ -z "$RUN_OUT" ]; then _pass "$1"
  else _fail "$1" "expected allow (exit 0, empty), got rc=$RUN_RC out=$RUN_OUT"; fi
}

gate_assert_deny() {
  # gate_assert_deny <label> <needle>...: deny JSON whose reason contains every needle
  local label="$1" reason dec n bad=""
  shift
  dec=$(printf '%s' "$RUN_OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  reason=$(printf '%s' "$RUN_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  [ "$RUN_RC" -eq 0 ] || bad="rc=$RUN_RC"
  [ "$dec" = "deny" ] || bad="$bad decision=[$dec]"
  for n in "$@"; do
    printf '%s' "$reason" | grep -qF -- "$n" || bad="$bad missing[$n]"
  done
  if [ -z "$bad" ]; then _pass "$label"; else _fail "$label" "$bad :: $RUN_OUT"; fi
}

gate_row() {
  # gate_row <nn> <fixture> <allow|none|src|unconf|plain|loc|norepo|stale> <command> [extra needle]
  local nn="$1" fix="$2" expect="$3" cmd="$4" extra="${5:-}" cwd label want
  case "$fix" in
    M) cwd="$GF_M" ;; X) cwd="$GF_X" ;; XS) cwd="$GF_XS" ;; U) cwd="$GF_U" ;; U2) cwd="$GF_U2" ;;
    MT) cwd="$GF_MATCH" ;; DY) cwd="$GF_DIRTY" ;; SB) cwd="$GF_SUB" ;; DT) cwd="$GF_DET" ;;
    EQ) cwd="$GF_EQ" ;; MS) cwd="$GF_MASTER" ;; BH) cwd="$GF_BH" ;; UP) cwd="$GF_UP" ;;
    PL) cwd="$GF_PL" ;; /*) cwd="$fix" ;; *) cwd="$GF_M" ;;
  esac
  label="${cmd//$'\n'/\\n}"; label="${label//$'\r'/<CR>}"
  label="EDGE-001 row $nn: $label"
  [ "$GATE_TOOL" = PowerShell ] && label="$label [PowerShell]"
  gate_run "r$nn" "$cwd" "$cmd"
  case "$expect" in
    allow) gate_assert_allow "$label" ;;
    none) want='review is recorded' ;;
    src) want='checked-out commit' ;;
    unconf) want='configured remote' ;;
    plain) want="$GATE_PLAIN" ;;
    loc) want='does not exist or is not a git work tree' ;;
    norepo) want='not a git work tree' ;;
    stale) want='stale' ;;
  esac
  if [ "$expect" != "allow" ]; then
    if [ -n "$extra" ]; then gate_assert_deny "$label" "$want" "$extra"; else gate_assert_deny "$label" "$want"; fi
  fi
}

gate_row_ps() { GATE_TOOL=PowerShell; gate_row "$@"; GATE_TOOL=Bash; }

# Decision S.5: a row whose command is a plain form (S.2) keeps its table decision;
# every other row is denied as not plain, whatever the table column says.
GATE_PLAIN='not a plain push or pull request command'

section "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE001] 201-row command decision table (decision S)"
{
  workdir="$(make_work_dir)" || exit 2
  GATE_STATE="$workdir/state"
  gate_build_fixtures "$workdir"
  gate_real_marker r42 "$GF_M" 'main vs origin/main' refs/remotes/origin/main
  gate_real_marker r125 "$GF_M" 'main vs origin/main' refs/remotes/origin/main
  gate_real_marker r126 "$GF_M" 'main vs origin/main' refs/remotes/origin/main

  gate_row 01 M none 'git push' 'main vs origin/main'
  gate_row 02 X allow 'git push'
  gate_row 03 U none 'git push' 'feat/x vs origin/main'
  gate_row 04 U2 allow 'git push'
  gate_row 05 MT src 'git push'
  gate_row 06 X src 'git push origin main'
  gate_row 07 XS src 'git push origin main'
  gate_row 08 M none 'git push origin HEAD'
  gate_row 09 M none 'git push origin HEAD:main'
  gate_row 10 M none 'git push origin main:main'
  gate_row 11 MS none 'git push origin HEAD:refs/heads/master' 'master vs origin/master'
  gate_row 12 M none 'git push origin +HEAD:main'
  gate_row 13 M none 'git push --force origin main'
  gate_row 14 M none 'git push --force-with-lease origin +main'
  gate_row 15 M plain 'git push --repo=origin HEAD:main'
  gate_row 16 M none 'git push -o ci.skip origin main'
  gate_row 17 X plain 'git push origin feat/x main'
  gate_row 18 M none 'git push origin main --tags'
  gate_row 19 DY none 'git push origin feat/x:main'
  gate_row 20 M unconf 'git push https://host/r.git main'
  gate_row 21 M plain 'git push origin main 2>&1 | tail'
  gate_row 22 M none 'git push 2>&1'
  gate_row 23 X allow 'git push -u origin feat/x'
  gate_row 24 M allow 'git push origin HEAD:feat/x'
  gate_row 25 M allow 'git push --tags'
  gate_row 26 M allow 'git push origin v1.2.0'
  gate_row 27 M allow 'git push --dry-run origin main'
  gate_row 28 M allow 'git push -n origin main'
  gate_row 29 X allow 'git push origin :main'
  gate_row 30 X allow 'git push --delete origin main'
  gate_row 31 X allow 'git push -d origin main'
  gate_row 32 X plain 'git push --all origin'
  gate_row 33 M plain 'git push --all origin'
  gate_row 34 EQ plain 'git push --all origin'
  gate_row 35 M plain 'git push --mirror origin'
  gate_row 36 SB none 'git -C sub push origin main' 'main vs origin/main'
  gate_row 37 SB none 'cd sub && git push' 'main vs origin/main'
  gate_row 38 SB plain '(cd sub && git push origin main); git status'
  gate_row 39 M plain 'cd "$(git rev-parse --show-toplevel)" && git push'
  gate_row 40 M plain 'git add -A && git commit -m x && git push'
  gate_row 41 X plain 'git add -A && git commit -m x && git push'
  gate_row 42 M plain 'git commit --amend --no-edit && git push --force-with-lease origin main'
  gate_row 43 X plain 'git checkout main && git push'
  gate_row 44 M plain 'git merge feat/x && git push origin main'
  gate_row 45 U2 plain 'git pull && git push'
  gate_row 46 X plain 'git switch - && git push'
  gate_row 47 M plain 'git push origin main && gh pr create --fill'
  gate_row 48 M plain 'git commit -m "docs: gate git push to main"'
  gate_row 49 M plain $'git commit -m "$(cat <<\'EOF\'\ngit push origin main\nEOF\n)"'
  gate_row 50 X src 'git push origin "main"'
  gate_row 51 M plain 'echo git push origin main'
  gate_row 52 M plain 'FOO=1 git push'
  gate_row 53 M plain 'AF_CODE_REVIEW_GATE=off git push'
  gate_row 54 M plain 'sudo git push origin main'
  gate_row 55 M plain 'sudo -u deploy git push origin main'
  gate_row 56 M plain 'timeout 30 git push origin main'
  gate_row 57 M plain 'git.exe push origin main'
  gate_row 58 M plain '/usr/bin/git push origin main'
  gate_row 59 M plain '& git push origin main'
  gate_row 60 M plain "sh -c 'git push origin main'"
  gate_row 61 M plain 'bash -c "git fetch && git push origin HEAD:main"'
  gate_row 62 M plain 'eval "git push origin main"'
  gate_row 63 M plain 'git push origin main "unbalanced'
  gate_row 64 M allow 'git commit -m "unbalanced'
  gate_row 65 DT src 'git push origin main'
  gate_row 66 X none 'gh pr create --fill' 'gh pr create denied'
  gate_row 67 X none 'gh pr create --draft --fill'
  gate_row 68 X none 'gh pr create --web'
  gate_row 69 X none 'gh pr create --base develop --fill' 'feat/x vs develop'
  # changed in the first review round (S.3-bis d): a short-option cluster is not plain
  gate_row 70 X plain 'gh pr create -Bdevelop --fill'
  gate_row 71 X none 'gh pr create -b "text" --fill' 'feat/x vs main'
  gate_row 72 X src 'gh pr create --head=other --fill'
  gate_row 73 X src 'gh pr create --head owner:feat/x --fill'
  gate_row 74 X allow 'gh pr create --dry-run'
  gate_row 75 X allow 'gh pr view 12'
  gate_row 76 X allow 'gh pr merge 12'
  gate_row 77 X allow 'gh api repos/o/r/pulls -X POST'
  gate_row 78 X none 'glab mr create --fill' 'glab mr create denied'
  gate_row 79 X none 'glab mr new --fill'
  gate_row 80 X none 'glab mr create --target-branch develop --fill' 'feat/x vs develop'
  gate_row 81 X src 'glab mr create -s other --fill'
  gate_row 82 X allow 'glab mr list'

  # rows 83-96: PowerShell dialect (tool_name PowerShell)
  oth_w="$(cygpath -w "$GF_OTH" 2>/dev/null || printf '%s' "$GF_OTH")"
  gate_row_ps 83 M plain 'if ($?) { git push origin main }'
  gate_row_ps 84 M plain 'try { git push origin main } catch { Write-Error $_ }'
  gate_row_ps 85 M plain '$out = git push origin main 2>&1'
  gate_row_ps 86 X plain '$url = gh pr create --fill'
  gate_row_ps 87 M plain '$r = @(git push origin main)'
  gate_row_ps 88 M plain 'foreach ($b in @("main")) { git push origin $b }'
  gate_row_ps 89 M plain '. { git push origin main }'
  gate_row_ps 90 M plain 'iex "git push origin main"'
  # S.3-bis (m): in the PowerShell dialect a <dir> beginning with / is not plain, so on a
  # POSIX host (no cygpath -w, oth_w is /tmp/...) rows 91-93 expect W_PLAIN; a Windows drive path is plain
  case "$oth_w" in
    /*) oth_exp=plain; oth_x="" ;;
    *) oth_exp=none; oth_x="main vs origin/main" ;;
  esac
  gate_row_ps 91 X "$oth_exp" "Set-Location '$oth_w'; git push origin main" "$oth_x"
  gate_row_ps 92 X "$oth_exp" "cd $oth_w; git push origin main" "$oth_x"
  gate_row_ps 93 X "$oth_exp" "git -C $oth_w push origin main" "$oth_x"
  # 91b: a PowerShell ~\ location prefix moves the review target on every host (HOME is GF_HOME)
  GATE_HOME="$GF_HOME"
  gate_row_ps 91b X none 'cd ~\other; git push origin main' 'main vs origin/main'
  GATE_HOME=""
  gate_row_ps 94 M loc 'git -C C:\nope\x push origin main'
  gate_row_ps 95 M plain $'echo hi\rgit push origin main'
  gate_row_ps 96 M none 'git push origin “main”'

  # rows 97-133: POSIX completeness, refspec forms, redirection, caps
  # r115 and r119 are plain double-quoted assignments: bash 3.2 (macOS /bin/bash) does not see
  # here-doc bodies inside $(...) and rewrites $'..' to its single-quoted value (the old blocks
  # used <<'EOF')
  r115="echo \$'\\'' ; git push origin main ; echo \\'"
  r118=$(cat <<'EOF'
bash -c "bash -c 'git push origin main'"
EOF
)
  r119="git \$'push' origin main"
  gate_row 97 M plain 'f() { git push origin main; }; f'
  gate_row 98 M plain 'git push -u origin "$(git branch --show-current)"'
  gate_row 99 X plain 'git push -u origin "$(git branch --show-current)"'
  gate_row 100 M plain 'B=main; git push origin "$B"'
  gate_row 101 X plain 'git push origin HEAD:"$B"'
  gate_row 102 M none 'git push origin @'
  gate_row 103 M none 'git push origin HEAD:heads/main'
  gate_row 104 X plain 'git push origin :'
  gate_row 105 M plain "git push origin 'refs/heads/*:refs/heads/*'"
  gate_row 106 M plain 'git push --dry-run --no-dry-run origin main'
  gate_row 107 M plain 'git push -d --no-delete origin main'
  gate_row 108 X none 'gh pr new --fill'
  gate_row 109 X plain 'git push --branches origin'
  gate_row 110 X plain 'git -c push.default=matching push'
  gate_row 111 X plain 'git -c remote.origin.push=HEAD:main push'
  gate_row 112 X plain "GIT_DIR=$GF_OTH/.git git push"
  gate_row 113 X plain "git --git-dir=$GF_OTH/.git push origin main"
  GATE_HOME="$GF_HOME"
  gate_row 114 X none 'cd ~/other && git push origin main' 'main vs origin/main'
  GATE_HOME=""
  gate_row 115 M plain "$r115"
  gate_row 116 M plain $'echo $((1<<2))\ngit push origin main'
  gate_row 117 M plain 'echo "$(case a in a) true ;; esac; git push origin main)"'
  gate_row 118 M plain "$r118"
  gate_row 119 M plain "$r119"
  gate_row 120 M plain 'Git push origin main'
  gate_row 121 M plain 'GIT.exe push origin main'
  gate_row 122 M plain 'time -p git push origin main'
  gate_row 123 M plain 'command -p git push origin main'
  gate_row 124 M plain 'exec -a x git push origin main'
  gate_row 125 M plain 'git update-ref refs/heads/main HEAD~1 && git push --force origin main'
  gate_row 126 M plain 'gh pr checkout 5 && git push origin HEAD:main'
  gate_row 127 BH none 'git push --force origin main'
  gate_row 128 UP none 'git push' 'main vs upstream/main'
  gate_row 129 PL norepo 'gh pr create -R owner/repo --head feat/x --base main --fill' 'gh pr create denied'
  gate_row 130 X plain 'glab mr create --fill "unbalanced'

  # 131: about 5 KB of chained decoys (under the 64 KB cap) is a chain: not plain
  r131=""
  for _i in $(seq 1 150); do r131="${r131}false && git push origin x; "; done
  r131="${r131}git push origin main"
  t0="$(gate_now_ms)"; gate_run r131 "$GF_M" "$r131"; t1="$(gate_now_ms)"; T131_MS=$((t1 - t0))
  if [ "$T131_MS" -lt 15000 ]; then
    gate_assert_deny "EDGE-001 row 131: 150 x 'false && git push origin x; ' then git push origin main: not plain, decided in ${T131_MS} ms (limit 15000)" "$GATE_PLAIN"
  else
    _fail "EDGE-001 row 131: 150 decoys then git push origin main" "took ${T131_MS} ms (limit 15000)"
  fi
  r132_word="$(head -c 102400 /dev/zero | tr '\0' a)"
  t0="$(gate_now_ms)"; gate_run_big r132 "$GF_M" "git push origin main \"$r132_word\""; t1="$(gate_now_ms)"; T132_MS=$((t1 - t0))
  if [ "$T132_MS" -lt 15000 ]; then
    gate_assert_deny "EDGE-001 row 132: git push origin main then one 100 KB quoted word: size cap, decided in ${T132_MS} ms (limit 15000)" 'unresolvable' 'longer than 64 KB'
  else
    _fail "EDGE-001 row 132: git push origin main then a 100 KB word" "took ${T132_MS} ms (limit 15000)"
  fi
  gate_row 133 M plain 'if false; then :; elif git push origin main; then :; fi'

  # rows 134-175
  pl_w="$(cygpath -w "$GF_PL" 2>/dev/null || printf '%s' "$GF_PL")"
  head_x="$(git -C "$GF_X" rev-parse HEAD)"
  head_bh="$(git -C "$GF_BH" rev-parse HEAD)"
  gate_row_ps 134 M plain 'if(1){git push origin main}'
  gate_row_ps 135 M plain 'try{git push origin main}catch{}'
  gate_row_ps 136 M plain '1|%{git push origin main }'
  gate_row_ps 137 M plain '<# x #> git push origin main'
  gate_row_ps 138 M plain $'$x = @"\na"\n"@; git push origin main # "'
  gate_row_ps 139 X plain "git push origin ('HEAD:main')"
  gate_row 140 M plain 'f(){ git push origin main;}; f'
  gate_row 141 M plain 'f()(git push origin main); f'
  gate_row 142 M plain 'case a in a) git "push" origin main;; esac'
  gate_row 143 X plain 'case a in a) git push origin HEAD:main;; esac'
  gate_row 144 M plain "false && cd $GF_PL; git push origin main"
  gate_row 145 M plain "cd $GF_PL && cd - && git push origin main"
  gate_row 146 M plain "pushd $GF_PL; popd; git push origin main"
  gate_row 147 M loc "cd $GF_PL; git push origin main"
  gate_row 148 M plain 'git push origin ma[i]n'
  gate_row 149 M plain 'git push origin mai?'
  GF_PC="$workdir/pc"; cp -R "$GF_X" "$GF_PC"; git -C "$GF_PC" config remote.origin.push HEAD:refs/heads/main
  gate_row 150 "$GF_PC" none 'git push' 'feat/x vs origin/main'
  gate_row 151 X plain "HOME=$GF_PL git push origin"

  r152=""; dots="./"
  for _i in $(seq 1 31); do r152="${r152}git -C $GF_X/$dots push; "; dots="$dots./"; done
  r152="${r152}git -C $GF_OTH push origin main"
  t0="$(gate_now_ms)"; gate_run r152 "$GF_M" "$r152"; t1="$(gate_now_ms)"; T152_MS=$((t1 - t0))
  if [ "$T152_MS" -lt 8000 ]; then
    gate_assert_deny "EDGE-001 row 152: 31 x 'git -C <repo>/./ push' (distinct spellings) then git -C <other> push origin main: not plain, decided in ${T152_MS} ms (limit 8000)" "$GATE_PLAIN"
  else
    _fail "EDGE-001 row 152: 31 chained -C pushes then git -C <other> push origin main" "took ${T152_MS} ms (limit 8000)"
  fi

  gate_row 153 M plain 'git $(printf push) origin main'
  gate_row 154 M plain 'X=git; $X push origin main'
  gate_row 155 M plain 'git pu${x}sh origin main'
  gate_marker r156 APPROVED "$head_x" "feat/x vs main ($(git -C "$GF_X" rev-parse main)..$head_x); fallback: none"
  gate_row 156 X stale 'gh pr create --base main --fill' 'not an ancestor of origin/main'
  GF_RH="$workdir/rh"; cp -R "$GF_X" "$GF_RH"                     # origin/feat/x one commit ahead of HEAD
  git -C "$GF_RH" checkout -q -b tmp157; gate_commit "$GF_RH" c4
  git -C "$GF_RH" update-ref refs/remotes/origin/feat/x tmp157
  git -C "$GF_RH" checkout -q feat/x; git -C "$GF_RH" branch -q -D tmp157
  gate_real_marker r157 "$GF_RH" 'feat/x vs main' refs/remotes/origin/main
  gate_row 157 "$GF_RH" stale 'gh pr create --fill' 'origin/feat/x'
  gate_real_marker r158 "$GF_M" 'main vs origin/main' refs/remotes/origin/main
  gate_row 158 M plain 'git fetch --update-head-ok . other:main && git push origin main'
  gate_row 159 X plain "git -C $GF_OTH push origin "'"$(git branch --show-current)"'
  gate_row 160 M plain 'git checkout . && git push'
  gate_row 161 M plain 'git checkout README.md; git push'
  gate_row 162 X plain 'git rebase feat/x main && git push'
  gate_row 163 X plain 'git symbolic-ref HEAD refs/heads/main && git push'
  # MSYS drive form /<drive>/...: cygpath -u would map a temp dir back to its /tmp mount
  u2_msys="$(cygpath -m "$GF_U2" 2>/dev/null | sed -E 's#^([A-Za-z]):#/\L\1#')"
  [ -n "$u2_msys" ] || u2_msys="$GF_U2"
  gate_row 164 M allow "cd $u2_msys && git push"
  gate_row 165 X plain 'echo main | xargs git push origin'
  gate_marker r166 APPROVED "$head_bh" "main vs origin/main ($head_bh..$head_bh); fallback: none"
  gate_row 166 BH stale 'git push --force origin main' 'is empty'
  r167_body="$(yes 'a new line of text' | head -n 3700)"
  gate_run_big r167 "$GF_M" "cat > out.txt <<'EOF'"$'\n'"$r167_body"$'\n'"EOF"
  gate_assert_allow "EDGE-001 row 167: cat > out.txt <<'EOF' with a 70 KB body naming no push: oversize, allowed"
  gate_row_ps 168 X allow 'git push -u origin feat/x *>&1'
  gate_real_marker r169 "$GF_M" 'main vs origin/main' refs/remotes/origin/main
  gate_row 169 M plain 'git branch -f main HEAD~1 && git push --force origin main'
  gate_real_marker r170 "$GF_M" 'main vs origin/main' refs/remotes/origin/main
  gate_row 170 M plain 'glab mr checkout 3 && git push origin HEAD:main'
  gate_row 171 X plain "export GIT_DIR=$GF_OTH/.git; git push origin main"
  gate_row_ps 172 X plain "\$env:GIT_DIR='$oth_w/.git'; git push origin main"
  gate_row_ps 173 M plain "Push-Location '$pl_w'; Pop-Location; git push origin main"
  gate_row_ps 174 X plain "chdir $oth_w; git push origin main"
  gate_row_ps 175 M plain "if (\$false) { Set-Location '$pl_w' }; git push origin main"

  # rows 176-201
  GF_DM="$workdir/dm"; cp -R "$GF_X" "$GF_DM"; git -C "$GF_DM" checkout -q main   # main, dirty, feat/x differs
  printf 'dirty\n' >> "$GF_DM/f.txt"
  GF_Y="$workdir/y"; cp -R "$GF_X" "$GF_Y"; git -C "$GF_Y" checkout -q -b feat/y   # feat/y tracking origin/main
  git -C "$GF_Y" config branch.feat/y.remote origin
  git -C "$GF_Y" config branch.feat/y.merge refs/heads/main
  GF_Y2="$workdir/y2"; cp -R "$GF_Y" "$GF_Y2"                                     # same, push.default unset
  git -C "$GF_Y" config push.default upstream
  GF_YR="$workdir/yr"; cp -R "$GF_X" "$GF_YR"; git -C "$GF_YR" checkout -q -b feat/y
  git -C "$GF_YR" config remote.origin.push refs/heads/feat/y:refs/heads/main
  GF_PL2="$workdir/plain2"; mkdir -p "$GF_PL2"
  pl2_w="$(cygpath -w "$GF_PL2" 2>/dev/null || printf '%s' "$GF_PL2")"
  gate_row 176 "$GF_DM" plain 'git checkout feat/x; git push'
  gate_row 177 M plain 'git checkout -b feat/x; git push -u origin HEAD'
  gate_row 178 X plain 'git checkout -Bmain && git push origin HEAD'
  gate_row 179 X plain 'git switch --force-create=main && git push origin HEAD'
  gate_row 180 "$GF_Y" none 'git push -u origin feat/y' 'feat/y vs origin/main'
  gate_row 181 "$GF_Y2" plain 'git -c push.default=upstream push origin feat/y'
  gate_row 182 "$GF_YR" none 'git push origin feat/y' 'feat/y vs origin/main'
  gate_row 183 M plain $'false &&\n cd '"$GF_PL"$'\ngit push origin main'
  gate_row 184 M plain $'echo x |\ncd '"$GF_PL"'; git push origin main'
  gate_row 185 M plain "pushd $GF_PL; cd $GF_PL2; popd; git push origin main"
  gate_row 186 M plain "cd $GF_PL; popd; git push origin main"
  gate_row 187 X plain "eval \"cd $GF_OTH\"; git push origin main"
  gate_row 188 M plain 'coproc git push origin main'
  gate_row 189 M plain $'cat <<EOF\n$(git push origin main)\nEOF'
  gate_row 190 M plain $'git p\\\nush origin main'
  gate_row 191 M plain 'cmd=push; git $cmd origin main'
  gate_real_marker r192 "$GF_M" 'main vs origin/main' refs/remotes/origin/main
  gate_row 192 M plain 'git stash list && git push origin HEAD:main'
  RUN_OUT="$(gate_payload r193 "$GF_U2" 'git push' | env SECONDS=100 CLAUDE_STATE_DIR="$GATE_STATE" sh "$GATE" 2>&1)"; RUN_RC=$?
  gate_assert_allow "EDGE-001 row 193: git push (feat/x with upstream, SECONDS=100 in the hook environment)"
  gate_row 194 X plain "GIT_DIR=$GF_OTH/.git gh pr create --fill"
  gate_row_ps 195 M plain 'git checkout -b feat/x; git push -u origin HEAD'
  gate_row_ps 196 M plain $'git rev-parse --verify --quiet nope &&\n Set-Location \''"$pl_w"$'\'\ngit push origin main'
  gate_row_ps 197 M plain "Push-Location '$pl_w'; Set-Location '$pl2_w'; Pop-Location; git push origin main"

  # 198: old git (< 2.31) rejects --end-of-options; the chain is denied before any git call.
  # 199: a git that takes 9 s per call; the plain push runs out of the 8 s budget.
  real_git="$(command -v git)"
  if gate_mkbin "$workdir/oldgit" cat && gate_mkbin "$workdir/slowgit" cat; then
    printf '#!/bin/sh\ncase " $* " in *" rev-parse "*" --end-of-options "*) echo "usage: git rev-parse [<options>] <args>..." >&2; exit 129 ;; esac\nexec "%s" "$@"\n' "$real_git" > "$workdir/oldgit/git"
    printf '#!/bin/sh\nsleep 9\nexec "%s" "$@"\n' "$real_git" > "$workdir/slowgit/git"
    chmod +x "$workdir/oldgit/git" "$workdir/slowgit/git"
    RUN_OUT="$(gate_payload r198 "$GF_X" 'git checkout main && git push' | PATH="$workdir/oldgit:$PATH" CLAUDE_STATE_DIR="$GATE_STATE" sh "$GATE" 2>&1)"; RUN_RC=$?
    gate_assert_deny "EDGE-001 row 198: git checkout main && git push (git wrapper rejecting rev-parse --end-of-options)" "$GATE_PLAIN"
    t0="$(gate_now_ms)"
    RUN_OUT="$(gate_payload r199 "$GF_M" 'git push origin main' | PATH="$workdir/slowgit:$PATH" CLAUDE_STATE_DIR="$GATE_STATE" sh "$GATE" 2>&1)"; RUN_RC=$?
    t1="$(gate_now_ms)"; T199_MS=$((t1 - t0))
    gate_assert_deny "EDGE-001 row 199: git push origin main (git wrapper sleeping 9 s per call): decided in ${T199_MS} ms" 'ran out of time'
  else
    _fail "EDGE-001 row 198: old-git wrapper fixture" "could not build the wrapper bin dir"
    _fail "EDGE-001 row 199: slow-git wrapper fixture" "could not build the wrapper bin dir"
  fi
  gate_row 200 M plain 'git switch --create feat/z && git push -u origin HEAD'
  # Row 201: a PowerShell backtick continuation before CRLF joins into "git push", so the
  # text is a candidate; the backtick and the newline make it not plain.
  gate_row_ps 201 M plain $'git pu`\r\nsh origin main'
  rm -rf "$workdir"
}

section "[PRETOOLUSE-CODE-REVIEW-GATE-REQ004] unlock rule and deny wordings"
{
  workdir="$(make_work_dir)" || exit 2
  GATE_STATE="$workdir/state"
  gate_build_fixtures "$workdir"
  head_x="$(git -C "$GF_X" rev-parse HEAD)"
  other_sha='0123456789abcdef0123456789abcdef01234567'

  gate_run rq1 "$GF_X" 'gh pr create --fill'
  gate_assert_deny "REQ-004 no marker: gh pr create denied with all five parts" \
    'gh pr create' 'feat/x vs main' 'Agent tool' 'subagent_type: code-review-gatekeeper' \
    'agentic-framework:code-review' 'VERDICT: APPROVED' 'AF_CODE_REVIEW_GATE=off' 'review is recorded'
  dec_shape=$(printf '%s' "$RUN_OUT" | jq -c '[(.hookSpecificOutput|keys_unsorted), .hookSpecificOutput.hookEventName]' 2>/dev/null)
  if [ "$dec_shape" = '[["hookEventName","permissionDecision","permissionDecisionReason"],"PreToolUse"]' ]; then _pass "REQ-004 deny JSON shape and key order"; else _fail "REQ-004 deny JSON shape" "$dec_shape"; fi
  if printf '%s' "$RUN_OUT" | grep -q '[<>&]' ; then _fail "REQ-004 reason has no angle brackets or ampersands" "$RUN_OUT"; else _pass "REQ-004 reason has no angle brackets or ampersands"; fi
  if printf '%s' "$RUN_OUT" | LC_ALL=C grep -q '[^ -~]'; then _fail "REQ-004 output is ASCII" "$RUN_OUT"; else _pass "REQ-004 output is ASCII"; fi

  gate_run rq1b "$GF_X" 'git push origin HEAD:main'
  gate_assert_deny "REQ-004 no marker: push names target with commit count" 'git push' 'feat/x vs origin/main (2 commits ahead)'

  # a PR's reviewed range starts on the destination's remote-tracking ref (I-ter.8)
  gate_real_marker rq2 "$GF_X" 'feat/x vs main' refs/remotes/origin/main
  gate_run rq2 "$GF_X" 'gh pr create --fill'
  gate_assert_allow "REQ-004 APPROVED marker at HEAD, base matches: gh pr create allowed"

  gate_real_marker rq3 "$GF_X" "PR #7 $head_x vs origin/main" refs/remotes/origin/main
  gate_run rq3 "$GF_X" 'git push origin HEAD:main'
  gate_assert_allow "REQ-004 APPROVED 'PR #7 <sha> vs origin/main' marker: git push origin HEAD:main allowed"

  gate_real_marker rq4 "$GF_X" 'feat/x vs main' refs/heads/main APPROVED "$other_sha"
  gate_run rq4 "$GF_X" 'gh pr create --fill'
  gate_assert_deny "REQ-004 marker head differs from HEAD: denied as stale" 'stale' "$other_sha" "$head_x"

  gate_real_marker rq5 "$GF_X" 'feat/x vs develop' refs/heads/main
  gate_run rq5 "$GF_X" 'gh pr create --fill'
  gate_assert_deny "REQ-004 marker base differs from destination: denied naming both" 'Base mismatch' 'develop' 'main'

  gate_marker rq6a APPROVED "$head_x" "uncommitted @ $head_x (3 files)"
  gate_run rq6a "$GF_X" 'gh pr create --fill'
  gate_assert_deny "REQ-004 non-branch target 'uncommitted @': denied" 'did not cover the branch against its destination'
  gate_marker rq6b APPROVED "$head_x" "paths a.sh b.sh @ $head_x"
  gate_run rq6b "$GF_X" 'gh pr create --fill'
  gate_assert_deny "REQ-004 non-branch target 'paths ... @': denied" 'did not cover the branch against its destination'
  gate_marker rq6c APPROVED "$head_x" "paths a.sh b.sh in PR #3 $head_x"
  gate_run rq6c "$GF_X" 'gh pr create --fill'
  gate_assert_deny "REQ-004 non-branch target 'paths ... in PR': denied" 'did not cover the branch against its destination'
  gate_marker rq6d APPROVED "$head_x" -
  gate_run rq6d "$GF_X" 'gh pr create --fill'
  gate_assert_deny "REQ-004 marker with no target line: denied" 'did not cover the branch against its destination'

  gate_real_marker rq7 "$GF_X" 'feat/x vs main' refs/heads/main CHANGES_REQUIRED
  gate_run rq7 "$GF_X" 'gh pr create --fill'
  gate_assert_deny "REQ-004 CHANGES_REQUIRED at HEAD: wording asks to resolve findings and re-run" 'CHANGES_REQUIRED' 'Resolve every open finding' 're-run the review'

  gate_run_env off rq8 "$GF_X" 'gh pr create --fill'
  gate_assert_allow "REQ-004 AF_CODE_REVIEW_GATE=off allows gh pr create"
  gate_run_env ' OFF ' rq8 "$GF_M" 'git push origin main'
  gate_assert_allow "REQ-004 AF_CODE_REVIEW_GATE=' OFF ' (trimmed, case-insensitive) allows git push origin main"
  gate_run_env on rq8 "$GF_X" 'gh pr create --fill'
  gate_assert_deny "REQ-004 AF_CODE_REVIEW_GATE=on does not disable the gate" 'review is recorded'

  gate_run rq9 "$GF_M" 'AF_CODE_REVIEW_GATE=off git push'
  gate_assert_deny "REQ-004 inline AF_CODE_REVIEW_GATE=off git push on main still denied (not a plain command, decision S)" "$GATE_PLAIN"

  gate_run_raw 'this is not json {'
  gate_assert_allow "REQ-004 malformed stdin: exit 0, empty output"
  gate_run_raw "$(jq -cn --arg c "$GF_X" '{session_id:"rq10",cwd:$c,tool_name:"Bash",tool_input:{description:"x"}}')"
  gate_assert_allow "REQ-004 payload without tool_input.command: exit 0, empty output"

  # The multi-segment dangling-token cases (rq11a 'cd sub; git -C<LF>git push', rq11b
  # 'echo ...; gh pr create --head') are withdrawn with the segment parser (decision S):
  # chains are not plain. The plain dangling option stays.
  gate_real_marker rq11b "$GF_X" 'feat/x vs main' refs/remotes/origin/main
  gate_run rq11b "$GF_X" 'gh pr create --head'
  gate_assert_allow "REQ-004 dangling 'gh pr create --head' reads an empty source"
  gate_run rq11c "$GF_M" 'git -C'
  gate_assert_allow "REQ-004 'git -C' alone names no push: not a candidate"
  gate_run rq11d "$GF_M" 'git -C push'
  gate_assert_deny "REQ-004 'git -C push' (dangling -C value, no push word after it): not plain" "$GATE_PLAIN"

  # S.2 quoted literal tokens: banned characters inside a clean quoted string are data
  gate_run rq12a "$GF_X" 'gh pr create --title "fix (x)" --fill'
  gate_assert_deny "REQ-004 quoted title with parentheses is plain: no-marker deny" 'review is recorded'
  gate_run rq12b "$GF_X" 'git push origin "main"'
  gate_assert_deny "REQ-004 quoted refspec is plain: source-not-HEAD deny" 'checked-out commit'
  gate_run rq12c "$GF_X" 'gh pr create --title "x; git push origin main" --fill'
  gate_assert_deny "REQ-004 quoted title with ; and push text is data: no-marker deny" 'review is recorded'
  gate_run rq12d "$GF_X" 'gh pr create --title "$T" --fill'
  gate_assert_deny "REQ-004 quoted title with a variable is not plain" "$GATE_PLAIN"
  gate_run rq12f "$GF_M" 'git push origin "refs/heads/*:refs/heads/*"'
  gate_assert_deny "REQ-004 quoted wildcard refspec is not plain" "$GATE_PLAIN"
  gate_run rq12g "$GF_X" 'git push origin "feat/x:main"'
  gate_assert_deny "REQ-004 quoted literal refspec stays plain: no-marker deny" 'review is recorded'
  gate_run rq12e "$GF_X" "sh -c 'git push origin main'"
  gate_assert_deny "REQ-004 sh -c wrapper with quoted push is not plain" "$GATE_PLAIN"

  # W_PLAIN wording verbatim
  gate_run rq13 "$GF_M" 'git add -A && git commit -m x && git push'
  gate_assert_deny "REQ-004 W_PLAIN sentence verbatim" \
    'The command text is not a plain push or pull request command. The gate allows a push or a PR/MR creation only as its own command with literal names: git push REMOTE REFSPEC, gh pr create ..., glab mr create ..., optionally after one cd DIR (joined by a double ampersand or a semicolon) or as git -C DIR push. Split chained commands, variables, substitutions, wrappers and scripts into separate plain commands; pass a multi-line PR body with --body-file. If this command is not a push or a PR creation, its text still mentions one: reword it or move the text to a file.'

  # --- first review round of decision S (S.1 two spellings, S.3-bis a to l) ---
  # S.1: non-candidates pass with no git call
  gate_run rqa1 "$GF_M" 'git stash push -m wip'
  gate_assert_allow "REQ-004 S.1 'git stash push -m wip' is not a candidate"
  gate_run rqa2 "$GF_M" 'git config push.default simple'
  gate_assert_allow "REQ-004 S.1 'git config push.default simple' is not a candidate"
  gate_run rqa3 "$GF_M" 'gh issue create --title x'
  gate_assert_allow "REQ-004 S.1 'gh issue create --title x' is not a candidate"
  # S.1: the second spelling (only ${ and } removed) and curly quotes / $' make candidates
  while IFS= read -r gcase; do
    [ -n "$gcase" ] || continue
    gate_run rqa4 "$GF_M" "$gcase"
    gate_assert_deny "REQ-004 S.1 candidate in a second spelling is not plain: $gcase" "$GATE_PLAIN"
  done <<'GCASES'
${GIT:-git} push origin main
git ${CMD:-push} origin main
gh pr ${C:-create} --fill
echo '${'; git push origin HEAD:main; echo '}'
echo ${x:-$(git push origin HEAD:main)}
git pu${x}sh origin main
git pu$''sh origin main
GCASES
  gate_run rqa5 "$GF_M" $'git p\xe2\x80\x9c\xe2\x80\x9dush origin main'
  gate_assert_deny "REQ-004 S.1 curly quotes inside the word push still make a candidate" "$GATE_PLAIN"

  # S.2 / S.3-bis: session id sanitised before the candidate and size tests
  big_cmd="git push origin $(head -c 70000 /dev/zero | tr '\0' a)"
  gate_run_big '' "$GF_M" "$big_cmd"
  gate_assert_allow "REQ-004 S.2 oversize candidate with an empty session id exits 0 silently"
  gate_run_big '!!!' "$GF_M" "$big_cmd"
  gate_assert_allow "REQ-004 S.2 oversize candidate with session id '!!!' exits 0 silently"

  # S.3: ~user and a quoted tilde directory are not plain (Bash does not expand a quoted tilde)
  gate_run rqa6 "$GF_M" 'cd ~root && git push origin main'
  gate_assert_deny "REQ-004 S.3 cd ~user is not plain" "$GATE_PLAIN"
  gate_run rqa7 "$GF_M" 'cd "~/x" && git push origin main'
  gate_assert_deny "REQ-004 S.3 Bash quoted cd \"~/x\" is not plain" "$GATE_PLAIN"
  gate_run rqa7b "$GF_M" "git -C '~/x' push origin main"
  gate_assert_deny "REQ-004 S.3 Bash quoted git -C '~/x' is not plain" "$GATE_PLAIN"

  # S.3-bis b: an empty quoted value is one literal token
  gate_run rqa8 "$GF_X" 'gh pr create --title "x" --body ""'
  gate_assert_deny "REQ-004 S.3-bis empty double-quoted --body is plain: no-marker deny" 'review is recorded'
  gate_run rqa8b "$GF_X" "gh pr create --title x --body ''"
  gate_assert_deny "REQ-004 S.3-bis empty single-quoted --body is plain: no-marker deny" 'review is recorded'

  # S.3-bis c: PowerShell option values and high bytes
  GATE_TOOL=PowerShell
  gate_run rqa9 "$GF_X" $'git push --force-with-lease=a\xc2\xa0b origin main'
  gate_assert_deny "REQ-004 S.3-bis PowerShell NBSP inside --force-with-lease= is not plain" "$GATE_PLAIN"
  gate_run rqa9b "$GF_X" $'git push -o "a\\ \xc2\xa0b" origin main'
  gate_assert_deny "REQ-004 S.3-bis PowerShell NBSP inside an unclean quoted -o value is not plain" "$GATE_PLAIN"
  GATE_TOOL=Bash

  # S.3-bis d, l: short-option clusters, --dry-run=<value>
  gate_run rqa10 "$GF_X" 'gh pr create -fHother'
  gate_assert_deny "REQ-004 S.3-bis gh short-option cluster -fHother is not plain" "$GATE_PLAIN"
  gate_run rqa10b "$GF_X" 'gh pr create -dB develop'
  gate_assert_deny "REQ-004 S.3-bis gh short-option cluster -dB is not plain" "$GATE_PLAIN"
  gate_run rqa11 "$GF_X" 'gh pr create --dry-run --dry-run=false'
  gate_assert_deny "REQ-004 S.3-bis gh --dry-run then --dry-run=false is not plain" "$GATE_PLAIN"
  gate_run rqa11b "$GF_X" 'gh pr create --recover -B --fill'
  gate_assert_deny "REQ-004 S.3-bis l,r --recover consumes '-B' as its value, so -B does not swallow --fill: target feat/x vs main" 'review is recorded' 'feat/x vs main'
  # round 3 (S.3-bis v): glab value-taking options that are not the branches
  gate_run rqa11c "$GF_X" 'glab mr create -H -b --target-branch develop'
  gate_assert_deny "REQ-004 S.3-bis v glab -H consumes '-b' as its value: target feat/x vs develop" 'review is recorded' 'feat/x vs develop'
  gate_run rqa11d "$GF_X" 'glab mr create -i 12 --fill'
  gate_assert_deny "REQ-004 S.3-bis v glab -i takes an issue number, not a branch: target feat/x vs main" 'review is recorded' 'feat/x vs main'

  # S.3-bis f: map_ref follows query_refspecs (a colon-less remote.<r>.push entry is skipped)
  GF_CL="$workdir/cl"; cp -R "$GF_X" "$GF_CL"
  git -C "$GF_CL" checkout -q -b feat/y
  git -C "$GF_CL" config branch.feat/y.remote origin
  git -C "$GF_CL" config branch.feat/y.merge refs/heads/main
  git -C "$GF_CL" config push.default upstream
  git -C "$GF_CL" config remote.origin.push refs/heads/feat/y
  gate_run rqa12 "$GF_CL" 'git push origin feat/y'
  gate_assert_deny "REQ-004 S.3-bis colon-less remote.origin.push entry is skipped: bare feat/y remaps through upstream to main" 'review is recorded' 'origin/main'

  # S.3-bis h: more than one colon in a refspec
  gate_run rqa13 "$GF_X" 'git push origin :/c3:main'
  gate_assert_deny "REQ-004 S.3-bis refspec with two colons is not plain" "$GATE_PLAIN"

  # S.3-bis i: a UNC directory is decided before any filesystem access
  t_unc0=$(gate_now_ms)
  gate_run rqa14 "$GF_X" 'cd //192.0.2.7/x; git push origin HEAD:main'
  t_unc=$(( $(gate_now_ms) - t_unc0 ))
  if [ "$t_unc" -lt 3000 ]; then gate_assert_deny "REQ-004 S.3-bis UNC cd //host/x is not plain, decided in ${t_unc} ms (limit 3000)" "$GATE_PLAIN"
  else _fail "REQ-004 S.3-bis UNC cd //host/x" "took ${t_unc} ms (limit 3000)"; fi
  gate_run rqa14b "$GF_X" 'git -C //192.0.2.7/x push origin HEAD:main'
  gate_assert_deny "REQ-004 S.3-bis UNC git -C //host/x is not plain" "$GATE_PLAIN"

  # S.3-bis j: repository state of the push fail-open
  GF_OR="$workdir/orph"; cp -R "$GF_X" "$GF_OR"; git -C "$GF_OR" checkout -q --orphan orph
  gate_run rqa15 "$GF_OR" 'git push origin feat/x:main'
  gate_assert_deny "REQ-004 S.3-bis unborn HEAD in a repository with refs: source-not-HEAD rule applies" 'checked-out commit'
  GF_EMPTY="$workdir/empty"; mkdir -p "$GF_EMPTY"; git -C "$GF_EMPTY" init -q -b main
  gate_run rqa16 "$GF_EMPTY" 'git push origin feat/x:main'
  gate_assert_allow "REQ-004 S.3-bis repository with no refs at all stays fail-open"
  GF_BARE="$workdir/bare.git"; git init -q --bare -b main "$GF_BARE"
  gate_run rqa17 "$GF_BARE" 'git push origin HEAD:main'
  gate_assert_deny "REQ-004 S.3-bis bare repository cwd is gated: W_LOC" 'does not exist or is not a git work tree'
  gate_run rqa18 "$GF_X/.git" 'git push origin HEAD:main'
  gate_assert_deny "REQ-004 S.3-bis cwd inside .git is gated: W_LOC" 'does not exist or is not a git work tree'

  # S.3-bis k, T.6: the at-cap -q push through FORM and the token stage; the deadline is checked after the token stage
  q_cmd="git push$(i=0; while [ "$i" -lt 21300 ]; do printf ' -q'; i=$((i + 1)); done)"
  tq0=$(gate_now_ms)
  gate_run_big rqa19 "$GF_X" "$q_cmd"
  tq=$(( $(gate_now_ms) - tq0 ))
  if [ "$tq" -ge 15000 ]; then _fail "REQ-004 S.3-bis git push + 21300 x -q" "took ${tq} ms (limit 15000)"
  elif [ -z "$RUN_OUT" ] && [ "$RUN_RC" -eq 0 ]; then _pass "REQ-004 S.3-bis git push + 21300 x -q: decided plain in ${tq} ms (under the 8 s budget on this host; limit 15000)"
  else gate_assert_deny "REQ-004 S.3-bis git push + 21300 x -q: W_TIME in ${tq} ms (limit 15000)" 'ran out of time'; fi

  # --- second review round of decision S (S.3-bis i, j, m to u) ---
  # item 1: the stash exclusion needs both previous words to be exactly 'git stash'
  mkdir -p "$workdir/sd"; cp -R "$GF_X" "$workdir/sd/stash"
  gate_run rqb1 "$workdir/sd" 'git -C stash push origin main'
  gate_assert_deny "REQ-004 S.1 'git -C stash push origin main' is a candidate (relative stash dir, judged: source-not-HEAD)" 'checked-out commit'
  gate_run rqb1b "$GF_M" "git -C $workdir/sd/stash push origin main"
  gate_assert_deny "REQ-004 S.1 'git -C <abs>/stash push origin main' is a candidate (judged: source-not-HEAD)" 'checked-out commit'
  gate_run rqb1c "$GF_M" 'git -c a.b=stash push origin main'
  gate_assert_deny "REQ-004 S.1 'git -c a.b=stash push origin main' is a candidate and not plain" "$GATE_PLAIN"
  gate_run rqb1d "$GF_M" 'git stash push -m wip'
  gate_assert_allow "REQ-004 S.1 'git stash push -m wip' stays a non-candidate"
  # round 3 (S.1): the stash exemption is anchored to the start of the text
  gate_run rqs1 "$GF_M" 'git -C git/stash push origin main'
  gate_assert_deny "REQ-004 S.1 anchored: 'git -C git/stash push origin main' is a candidate (judged: W_LOC, no such dir)" 'does not exist or is not a git work tree'
  gate_run rqs2 "$GF_M" 'git stash push; git push origin main'
  gate_assert_deny "REQ-004 S.1 anchored: 'git stash push; git push origin main' is not plain" "$GATE_PLAIN"
  gate_run rqs3 "$GF_M" 'cd x && git stash push'
  gate_assert_deny "REQ-004 S.1 anchored: 'cd x && git stash push' is a candidate and not plain" "$GATE_PLAIN"
  gate_run rqs4 "$GF_M" 'echo; git stash push'
  gate_assert_deny "REQ-004 S.1 anchored: 'echo; git stash push' is a candidate and not plain" "$GATE_PLAIN"
  gate_run rqs5 "$GF_M" 'git stash push;'
  gate_assert_allow "REQ-004 S.1 anchored: 'git stash push;' begins with git stash push and is not a candidate"
  gate_run rqs6 "$GF_M" 'git stash push|cat'
  gate_assert_allow "REQ-004 S.1 anchored: 'git stash push|cat' is not a candidate"
  gate_run rqs7 "$GF_M" 'git/stash push'
  gate_assert_allow "REQ-004 S.1 anchored: 'git/stash push' is not a candidate (words are runs bounded by non-alphanumerics)"

  # item 2: the candidate test strips U+201A, U+201B and U+201E too
  GATE_TOOL=PowerShell
  gate_run rqb2 "$GF_M" $'git pu\xe2\x80\x9e\xe2\x80\x9esh origin main'
  gate_assert_deny "REQ-004 S.1 PowerShell git pu<U+201E><U+201E>sh is a candidate and not plain (T.7a: a quoted keyword)" "$GATE_PLAIN"
  gate_run rqb2b "$GF_M" $'git pu\xe2\x80\x9a\xe2\x80\x9bsh origin main'
  gate_assert_deny "REQ-004 S.1 PowerShell git pu<U+201A><U+201B>sh is a candidate and not plain (T.7a)" "$GATE_PLAIN"
  GATE_TOOL=Bash
  gate_run rqb2c "$GF_M" $'git pu\xe2\x80\x9e\xe2\x80\x9esh origin main'
  gate_assert_deny "REQ-004 S.1 Bash git pu<U+201E><U+201E>sh is a candidate and not plain" "$GATE_PLAIN"
  gate_run rqb2d "$GF_M" $'git pu\xe2\x80\x9a\xe2\x80\x9bsh origin main'
  gate_assert_deny "REQ-004 S.1 Bash git pu<U+201A><U+201B>sh is a candidate and not plain" "$GATE_PLAIN"

  # decision T: the regex grammar's refinements (T.7), the default-value spellings (T.2)
  # and the token-stage ambiguities (T.4); the same rows and labels as tests/hooks.test.ps1
  gate_run rt7a1 "$GF_M" '"git" push origin main'
  gate_assert_deny 'REQ-004 T.7a: "git" push origin main is not plain (quoted keyword)' "$GATE_PLAIN"
  GATE_TOOL=PowerShell
  gate_run rt7a2 "$GF_M" 'git pu""sh origin main'
  gate_assert_deny 'REQ-004 T.7a: PowerShell git pu""sh origin main is not plain (quoted keyword)' "$GATE_PLAIN"
  GATE_TOOL=Bash
  gate_run rt7a3 "$GF_M" 'git "push" origin main'
  gate_assert_deny 'REQ-004 T.7a: git "push" origin main is not plain' "$GATE_PLAIN"
  GATE_TOOL=PowerShell
  gate_run rt7b "$GF_X" "gh pr create --title 'it''s'"
  gate_assert_deny "REQ-004 T.7b: PowerShell 'it''s' (a doubled quote) is not plain" "$GATE_PLAIN"
  gate_run rt7c "$GF_X" "gh pr create --title a'x'\"y\""
  gate_assert_deny "REQ-004 T.7c: PowerShell a'x'\"y\" (two adjacent quoted strings) is not plain" "$GATE_PLAIN"
  gate_run rt7c2 "$GF_X" "gh pr create --title a'x'b"
  gate_assert_deny "REQ-004 T.7c: PowerShell a'x'b (one quoted string inside a bare word) stays plain: judged" 'feat/x vs main' 'review is recorded'
  gate_run rt7d "$GF_X" "gh pr create --title @'x'"
  gate_assert_deny "REQ-004 T.7d: PowerShell @'x' is not plain" "$GATE_PLAIN"
  gate_run rt7d2 "$GF_X" 'gh pr create --title @'
  gate_assert_deny 'REQ-004 T.7d: PowerShell bare @ stays plain: judged' 'feat/x vs main' 'review is recorded'
  GATE_TOOL=Bash
  gate_run rt7e1 "$GF_X" 'gh pr create --fill > "out file"'
  gate_assert_deny 'REQ-004 T.7e: a quoted redirection target is not plain' "$GATE_PLAIN"
  gate_run rt7e2 "$GF_X" "gh pr create --fill > ''"
  gate_assert_deny "REQ-004 T.7e: an empty quoted redirection target is not plain" "$GATE_PLAIN"
  gate_run rt7e3 "$GF_X" 'gh pr create --fill > out.txt'
  gate_assert_deny 'REQ-004 T.7e: a bare redirection target stays plain: judged' 'feat/x vs main' 'review is recorded'
  # shellcheck disable=SC2016
  gate_run rt7f1 "$GF_M" 'echo git${a-push'
  gate_assert_allow 'REQ-004 T.7f: an unclosed ${ removes the rest of spelling 1: echo git${a-push is not a candidate'
  # shellcheck disable=SC2016
  gate_run rt7f2 "$GF_M" 'echo ${ git push origin main'
  gate_assert_deny 'REQ-004 T.7f: spelling 2 still sees the tail after an unclosed ${: a candidate, not plain' "$GATE_PLAIN"
  gate_run rt7g1 "$GF_M" $'git stash\r\npush -m wip'
  gate_assert_allow 'REQ-004 T.7g: CR and LF are both separators: git stash CRLF push stays exempt'
  gate_run rt7g2 "$GF_M" $'echo x\r\ngit push origin main'
  gate_assert_deny 'REQ-004 T.7g: a push after a CRLF is a candidate and not plain' "$GATE_PLAIN"
  # shellcheck disable=SC2016
  gate_run rt2a "$GF_M" 'git pu${a:-s}h origin main'
  gate_assert_deny 'REQ-004 T.2: git pu${a:-s}h origin main is a candidate (spelling 3), not plain' "$GATE_PLAIN"
  # shellcheck disable=SC2016
  gate_run rt2b "$GF_M" 'git pu${a-s}h origin main'
  gate_assert_deny 'REQ-004 T.2: git pu${a-s}h origin main is a candidate (spelling 3), not plain' "$GATE_PLAIN"
  # shellcheck disable=SC2016
  gate_run rt2c "$GF_M" 'g${a:-i}t push origin main'
  gate_assert_deny 'REQ-004 T.2: g${a:-i}t push origin main is a candidate (spelling 3), not plain' "$GATE_PLAIN"
  # shellcheck disable=SC2016
  gate_run rt2d "$GF_M" 'git pu${a:-${b}}sh origin main'
  gate_assert_deny 'REQ-004 T.2: git pu${a:-${b}}sh origin main is a candidate (spelling 3), not plain' "$GATE_PLAIN"
  gate_run rt4a "$GF_M" 'git push -o -n origin main'
  gate_assert_deny 'REQ-004 T.4: git push -o -n origin main on main is judged (-n is the -o value, not a dry run)' 'main vs origin/main' 'review is recorded'
  gate_run rt4b "$GF_X" 'gh pr create --title --base develop'
  gate_assert_deny 'REQ-004 T.4: --title --base develop: --title consumes --base, the default base is used' 'feat/x vs main' 'review is recorded'
  gate_run rt4c "$GF_X" 'gh pr create --base a --base b'
  gate_assert_deny 'REQ-004 T.4: --base a --base b: the last base wins' 'feat/x vs b' 'review is recorded'
  gate_run rt4d "$GF_X" 'gh pr create --title " --base x" --base dev --head=me --base last'
  gate_assert_deny 'REQ-004 T.4: a quoted " --base x" is the title; head me, base last' 'source me is not HEAD' 'feat/x vs last'
  gate_run rt4e "$GF_X" 'gh pr create --title "a > b" 2>&1'
  gate_assert_deny 'REQ-004 T.4: gh pr create --title "a > b" 2>&1 is plain (the quoted > is data): judged' 'feat/x vs main' 'review is recorded'
  gate_run rt4f "$GF_X" 'gh pr create --head'
  gate_assert_deny 'REQ-004 T.4: a trailing --head leaves the source empty: judged at HEAD' 'feat/x vs main' 'review is recorded'
  gate_run rt4g "$GF_M" 'git push origin main -o'
  gate_assert_deny 'REQ-004 T.4: a trailing -o is an unread option: not plain' "$GATE_PLAIN"
  gate_run rt4h "$GF_M" 'git push a b c'
  gate_assert_deny 'REQ-004 T.4: a third positional is not plain' "$GATE_PLAIN"
  gate_run rt4i "$GF_M" 'git push origin ""'
  gate_assert_deny 'REQ-004 T.4: an empty positional is not plain' "$GATE_PLAIN"
  gate_run rt4j "$GF_M" 'git push -o ci.skip --dry-run origin main'
  gate_assert_allow 'REQ-004 T.4: -o ci.skip --dry-run origin main is a dry run (allowed)'
  GATE_TOOL=PowerShell
  gate_run rt4k "$GF_M" 'git push -o "a b" origin main'
  gate_assert_deny 'REQ-004 T.4: PowerShell -o value outside the push alphabet is not plain' "$GATE_PLAIN"
  GATE_TOOL=Bash
  gate_run rt4l "$GF_M" 'git push -o "a b" origin main'
  gate_assert_deny 'REQ-004 T.4: Bash -o value is any literal: judged' 'main vs origin/main' 'review is recorded'
  gate_run rt4m "$GF_X" 'gh pr create --body "" -H feat/x'
  gate_assert_deny 'REQ-004 T.4: --body "" consumes the empty word; -H feat/x is HEAD: judged' 'feat/x vs main' 'review is recorded'
  gate_run rt4n "$GF_SUB" 'cd sub;git push origin main'
  gate_assert_deny 'REQ-004 T.4: cd sub;git push origin main (no blanks around ;) is plain: judged in sub' 'main vs origin/main' 'review is recorded'
  gate_run rt4o "$GF_M" 'cd "a;b" && git push origin main'
  gate_assert_deny 'REQ-004 T.4: cd "a;b" && ...: the quoted ; is data (no such directory: W_LOC)' 'does not exist or is not a git work tree'
  gate_run rt4p "$GF_M" $'git push origin main\r'
  gate_assert_deny 'REQ-004 T.3: a trailing CR is trailing white space: judged' 'main vs origin/main' 'review is recorded'
  # 32 KB and 64 KB texts reach jq on stdin (gate_run_big): no argv length limit
  rt_big="git push origin main$(i=0; while [ "$i" -lt 32768 ]; do printf ' '; i=$((i + 1)); done)"
  gate_run_big rt4q "$GF_M" "$rt_big"
  gate_assert_deny 'REQ-004 T.3: a 32 KB trailing blank run is plain: judged' 'main vs origin/main' 'review is recorded'
  gate_run rt4r "$GF_X" $'gh pr create --title caf\xc3\xa9'
  gate_assert_deny 'REQ-004 T.3: Bash bare high byte is plain: judged' 'feat/x vs main' 'review is recorded'
  GATE_TOOL=PowerShell
  gate_run rt4s "$GF_X" $'gh pr create --title caf\xc3\xa9'
  gate_assert_deny 'REQ-004 T.3: PowerShell bare high byte is not plain' "$GATE_PLAIN"
  GATE_TOOL=Bash
  rt_big="git push origin main $(i=0; while [ "$i" -lt 21846 ]; do printf '\342\200\230'; i=$((i + 1)); done)"
  gate_run_big rt4t "$GF_M" "$rt_big"
  gate_assert_deny 'REQ-004 T.2: 21,846 x U+2018 after a push (65,559 bytes) is over 64 KB by bytes: W_SIZE' 'longer than 64 KB'
  rt_big=""
  gate_run rt4u "$GF_M" 'cd ~"/x" && git push origin main'
  gate_assert_deny 'REQ-004 T.5: Bash cd ~"/x" (raw text not ~/...) is not plain (TILDE)' "$GATE_PLAIN"

  # item 3 (S.3-bis s, T.6): the grammar stages are linear. Shapes 1-3, 6 and 7 time the
  # S.1 tr | sed | grep pipeline (over the cap), shapes 4 and 5 and the at-cap -q row time
  # FORM plus the token stage. An earlier scanning implementation measured 6.0 s for 300 KB
  # on macOS CI. Each shape is timed at n and 2n: it must finish within 5000 ms at
  # n and t(2n) < 3 * t(n) + 200 ms (the constant absorbs timer noise on a shared runner).
  gate_lin() {
    # gate_lin <id> <label> <needle> <text at n> <text at 2n>
    local id="$1" lab="$2" needle="$3" tn t2n t0
    t0=$(gate_now_ms); gate_run_big "${id}n" "$GF_M" "$4"; tn=$(( $(gate_now_ms) - t0 ))
    gate_assert_deny "REQ-004 S.3-bis s $lab at n: decided in ${tn} ms" "$needle"
    t0=$(gate_now_ms); gate_run_big "${id}d" "$GF_M" "$5"; t2n=$(( $(gate_now_ms) - t0 ))
    gate_assert_deny "REQ-004 S.3-bis s $lab at 2n: decided in ${t2n} ms" "$needle"
    # absolute limits first: a ratio alone could pass a 15 s result (past the hook timeout)
    if [ "$tn" -ge 5000 ] || [ "$t2n" -ge 10000 ]; then
      _fail "REQ-004 S.3-bis s $lab linearity" "t(n)=${tn} ms (limit 5000), t(2n)=${t2n} ms (limit 10000)"
    elif [ "$GATE_MS_TOOL" = date ] && [ -z "${EPOCHREALTIME:-}" ]; then
      # seconds-only clock: tn 0 / t2n 1000 is quantisation, not growth
      _pass "REQ-004 S.3-bis s $lab: t(n) ${tn} ms < 5000, t(2n) ${t2n} ms < 10000 (ratio check skipped: only a 1 s clock on this host)"
    elif [ "$t2n" -lt $(( 3 * tn + 200 )) ]; then
      _pass "REQ-004 S.3-bis s $lab is linear: t(n) ${tn} ms < 5000, t(2n) ${t2n} ms < 10000 and < 3 * t(n) + 200"
    else _fail "REQ-004 S.3-bis s $lab linearity" "t(n)=${tn} ms, t(2n)=${t2n} ms (limit $(( 3 * tn + 200 )))"; fi
  }
  # 300 KB / 600 KB of short words ending in a push
  big2="$(awk 'BEGIN { for (i = 0; i < 60000; i++) printf "ab c "; printf "git push origin main" }')"
  big3="$(awk 'BEGIN { for (i = 0; i < 120000; i++) printf "ab c "; printf "git push origin main" }')"
  gate_lin rqb3 "short words ending in git push (300/600 KB)" 'longer than 64 KB' "$big2" "$big3"
  # 300 KB / 600 KB of ${x}a ending in a push: the ${...} deletion must stay linear too
  big2="$(awk 'BEGIN { for (i = 0; i < 60000; i++) printf "${x}a"; printf " git push origin main" }')"
  big3="$(awk 'BEGIN { for (i = 0; i < 120000; i++) printf "${x}a"; printf " git push origin main" }')"
  gate_lin rqb3b "\${x}a ending in git push (300/600 KB)" 'longer than 64 KB' "$big2" "$big3"
  # one 300 KB / 600 KB word, then a push: the word buffer must not grow with the word
  big2="$(awk 'BEGIN { printf "echo "; for (i = 0; i < 300000; i++) printf "a"; printf " ; git push origin main" }')"
  big3="$(awk 'BEGIN { printf "echo "; for (i = 0; i < 600000; i++) printf "a"; printf " ; git push origin main" }')"
  gate_lin rqb3c "one long word then git push (300/600 KB)" 'longer than 64 KB' "$big2" "$big3"
  # ~16 KB / ~32 KB of -q flags (under the 64 KB cap, so FORM and the token stage run): a plain push, judged
  big2="$(awk 'BEGIN { printf "git push"; for (i = 0; i < 5325; i++) printf " -q"; printf " origin main" }')"
  big3="$(awk 'BEGIN { printf "git push"; for (i = 0; i < 10650; i++) printf " -q"; printf " origin main" }')"
  gate_lin rqb3d "git push with 5325 / 10650 x -q" 'review is recorded' "$big2" "$big3"
  # three more shapes: a long blank run inside a push (one lexer blank run), \001-separated
  # records (SOH mapped to STX) and one repeated curly quote (the S1_CURLY deletion)
  big2="$(awk 'BEGIN { printf "git push"; for (i = 0; i < 32000; i++) printf " "; printf "origin main" }')"
  big3="$(awk 'BEGIN { printf "git push"; for (i = 0; i < 64000; i++) printf " "; printf "origin main" }')"
  gate_lin rqb3e "git push with a 32 / 64 KB blank run" 'review is recorded' "$big2" "$big3"
  big2="$(awk 'BEGIN { for (i = 0; i < 150000; i++) printf "\001a"; printf " git push origin main" }')"
  big3="$(awk 'BEGIN { for (i = 0; i < 300000; i++) printf "\001a"; printf " git push origin main" }')"
  gate_lin rqb3f "\001a records ending in git push (300/600 KB)" 'longer than 64 KB' "$big2" "$big3"
  big2="$(awk 'BEGIN { for (i = 0; i < 100000; i++) printf "\342\200\230"; printf " git push origin main" }')"
  big3="$(awk 'BEGIN { for (i = 0; i < 200000; i++) printf "\342\200\230"; printf " git push origin main" }')"
  gate_lin rqb3g "U+2018 ending in git push (300/600 KB)" 'longer than 64 KB' "$big2" "$big3"
  # a push with flags AT the cap (21800 x -q = 65420 bytes, 116 under 65536): the
  # FORM and the token stage run on the whole text; absolute limit only (no ratio row at this size)
  big2="$(awk 'BEGIN { printf "git push"; for (i = 0; i < 21800; i++) printf " -q"; printf " origin main" }')"
  t0=$(gate_now_ms); gate_run_big rqb3h "$GF_M" "$big2"; tcap=$(( $(gate_now_ms) - t0 ))
  gate_assert_deny "REQ-004 S.3-bis s git push with 21800 x -q (65.4 KB, at the cap): no-review deny, decided in ${tcap} ms" 'review is recorded'
  if [ "$tcap" -lt 5000 ]; then _pass "REQ-004 S.3-bis s at-cap -q push decided in ${tcap} ms (limit 5000)"
  else _fail "REQ-004 S.3-bis s at-cap -q push" "took ${tcap} ms (limit 5000)"; fi
  big2=""; big3=""
  # T.6: an S.1 tool (sed or grep) fails (exit 2) or prints garbage: over 64 KB is denied as
  # unresolvable, under the cap fails open exactly as before (a crashing tool must not allow an
  # oversize text). The shim stands in for the tool only in the S.1 pipeline: sed -n and
  # grep -c are S.1's calls (FORM is grep -q, the token stage sed without -n).
  big2="$(awk 'BEGIN { for (i = 0; i < 14000; i++) printf "ab c "; printf "git push origin main" }')"
  for s1_tool in sed grep; do
    for s1_kind in exit2 garbage; do
      s1_real="$(command -v "$s1_tool")"
      s1_flag=-n; [ "$s1_tool" = grep ] && s1_flag=-c
      if [ -n "$s1_real" ] && mkdir -p "$workdir/s1bin"; then
        case $s1_kind in
          exit2) s1_act='cat >/dev/null; exit 2' ;;
          *) s1_act='cat >/dev/null; echo bogus; exit 0' ;;
        esac
        printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = %s ] && { %s; }; done\nexec "%s" "$@"\n' "$s1_flag" "$s1_act" "$s1_real" > "$workdir/s1bin/$s1_tool"
        chmod +x "$workdir/s1bin/$s1_tool"
        RUN_OUT="$(printf '%s' "$big2" | MSYS2_ARG_CONV_EXCL='*' jq -Rsc --arg s "rqb3i$s1_tool$s1_kind" --arg c "$GF_M" '{session_id:$s,cwd:$c,tool_name:"Bash",tool_input:{command:.}}' \
          | PATH="$workdir/s1bin:$PATH" CLAUDE_STATE_DIR="$GATE_STATE" sh "$GATE" 2>&1)"; RUN_RC=$?
        gate_assert_deny "REQ-004 T.6 S.1 $s1_tool shim ($s1_kind), 70 KB command ending in git push: denied as unresolvable" 'longer than 64 KB'
        RUN_OUT="$(gate_payload "rqb3j$s1_tool$s1_kind" "$GF_M" 'git push origin main' | PATH="$workdir/s1bin:$PATH" CLAUDE_STATE_DIR="$GATE_STATE" sh "$GATE" 2>&1)"; RUN_RC=$?
        gate_assert_allow "REQ-004 T.6 S.1 $s1_tool shim ($s1_kind), under-cap git push origin main: fail-open unchanged (exit 0, no output)"
        rm -f "$workdir/s1bin/$s1_tool"
      else
        _fail "REQ-004 T.6 S.1 $s1_tool shim ($s1_kind)" "could not build the shim bin dir"
      fi
    done
  done
  # T.6: a FORM or token-stage tool failure denies W_PLAIN (fail closed): grep -q (FORM)
  # and sed -E without -n (token stage) exit 2
  for s1_tool in grep sed; do
    s1_real="$(command -v "$s1_tool")"
    s1_flag=-q; [ "$s1_tool" = sed ] && s1_flag=-E
    if [ -n "$s1_real" ] && mkdir -p "$workdir/s1bin"; then
      if [ "$s1_tool" = sed ]; then
        printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -n ] && exec "%s" "$@"; done\nfor a in "$@"; do [ "$a" = -E ] && { cat >/dev/null; exit 2; }; done\nexec "%s" "$@"\n' "$s1_real" "$s1_real" > "$workdir/s1bin/sed"
      else
        printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -q ] && { cat >/dev/null; exit 2; }; done\nexec "%s" "$@"\n' "$s1_real" > "$workdir/s1bin/grep"
      fi
      chmod +x "$workdir/s1bin/$s1_tool"
      RUN_OUT="$(gate_payload "rqb3k$s1_tool" "$GF_M" 'git push origin main' | PATH="$workdir/s1bin:$PATH" CLAUDE_STATE_DIR="$GATE_STATE" sh "$GATE" 2>&1)"; RUN_RC=$?
      gate_assert_deny "REQ-004 T.6 $s1_tool shim ($s1_flag exits 2), git push origin main: FORM / token stage failure denies W_PLAIN" "$GATE_PLAIN"
      rm -f "$workdir/s1bin/$s1_tool"
    else
      _fail "REQ-004 T.6 $s1_tool shim ($s1_flag)" "could not build the shim bin dir"
    fi
  done
  big2=""

  # item 4 (S.3-bis i): mixed-separator UNC directories are decided before any filesystem access
  t_unc0=$(gate_now_ms)
  gate_run rqb4 "$GF_X" "cd '\\/192.0.2.7/x'; git push origin HEAD:main"
  gate_assert_deny "REQ-004 S.3-bis i Bash cd '\\/host/x' is not plain" "$GATE_PLAIN"
  gate_run rqb4b "$GF_X" "cd '/\\192.0.2.7\\x'; git push origin HEAD:main"
  gate_assert_deny "REQ-004 S.3-bis i Bash cd '/\\host\\x' is not plain" "$GATE_PLAIN"
  GATE_TOOL=PowerShell
  gate_run rqb4c "$GF_X" 'git -C \/192.0.2.7/x push origin HEAD:main'
  gate_assert_deny "REQ-004 S.3-bis i PowerShell git -C \\/host/x is not plain" "$GATE_PLAIN"
  gate_run rqb4d "$GF_X" 'Set-Location /\192.0.2.7\x; git push origin HEAD:main'
  gate_assert_deny "REQ-004 S.3-bis i PowerShell Set-Location /\\host\\x is not plain" "$GATE_PLAIN"
  GATE_TOOL=Bash
  t_unc=$(( $(gate_now_ms) - t_unc0 ))
  if [ "$t_unc" -lt 8000 ]; then _pass "REQ-004 S.3-bis i four mixed-separator UNC rows decided in ${t_unc} ms (limit 8000)"
  else _fail "REQ-004 S.3-bis i mixed-separator UNC rows" "took ${t_unc} ms (limit 8000)"; fi

  # item 5 (S.3-bis m): a leading slash is Bash-dialect only; ~\ is accepted like ~/
  gate_run rqb5 "$GF_M" 'cd / && git push origin HEAD:main'
  gate_assert_deny "REQ-004 S.3-bis m Bash cd / is plain and judged: W_LOC" 'does not exist or is not a git work tree'
  GATE_TOOL=PowerShell
  gate_run rqb5b "$GF_M" 'cd /; git push origin HEAD:main'
  gate_assert_deny "REQ-004 S.3-bis m PowerShell cd / is not plain" "$GATE_PLAIN"
  GATE_HOME="$GF_HOME"
  gate_run rqb5c "$GF_M" 'cd ~\other; git push origin HEAD:main'
  gate_assert_deny "REQ-004 S.3-bis m PowerShell cd ~\\other is accepted like ~/other: judged" 'review is recorded'
  GATE_HOME=""
  GATE_TOOL=Bash

  # item 6 (S.3-bis n): a quote before the first unquoted slash stops the tilde expansion
  for tcase in 'cd ~"/x" && git push origin main' 'cd ""~/x && git push origin main' 'cd ~""/x && git push origin main'; do
    gate_run rqb6 "$GF_M" "$tcase"
    gate_assert_deny "REQ-004 S.3-bis n Bash quoted tilde is not plain: $tcase" "$GATE_PLAIN"
  done
  GATE_HOME="$GF_HOME"
  gate_run rqb6b "$GF_M" 'cd ~/"other" && git push origin HEAD:main'
  gate_assert_deny "REQ-004 S.3-bis n Bash quote after the first slash keeps the tilde: judged" 'review is recorded'
  GATE_HOME=""

  # item 7 (S.3-bis t): a PowerShell word that begins with a quoted string may not continue
  GATE_TOOL=PowerShell
  gate_run rqb7 "$GF_X" 'git push origin "feat"main'
  gate_assert_deny "REQ-004 S.3-bis t PowerShell \"feat\"main is not plain" "$GATE_PLAIN"
  gate_run rqb7b "$GF_X" "git push origin 'x'main"
  gate_assert_deny "REQ-004 S.3-bis t PowerShell 'x'main is not plain" "$GATE_PLAIN"
  gate_run rqb7c "$GF_X" 'git push origin "feat/x"'
  gate_assert_allow "REQ-004 S.3-bis t PowerShell a whole quoted word stays plain (feat/x is not gated)"
  GATE_TOOL=Bash

  # push_val (S.3-bis c, r): the push alphabet for option values in the PowerShell dialect;
  # the value holds no high byte, so only push_val catches it
  GATE_TOOL=PowerShell
  gate_run rqb8 "$GF_X" 'git push -o "a b" origin feat/x'
  gate_assert_deny "REQ-004 S.3-bis r PowerShell -o \"a b\" is not plain (push_val)" "$GATE_PLAIN"
  gate_run rqb8b "$GF_X" "git push '--force-with-lease=a b' origin feat/x"
  gate_assert_deny "REQ-004 S.3-bis r PowerShell '--force-with-lease=a b' is not plain (push_val)" "$GATE_PLAIN"
  gate_run rqb8c "$GF_X" 'git push -o ab origin feat/x'
  gate_assert_allow "REQ-004 S.3-bis r PowerShell -o ab (inside the alphabet) stays plain: not gated"
  GATE_TOOL=Bash
  gate_run rqb8d "$GF_X" 'git push -o "a b" origin feat/x'
  gate_assert_allow "REQ-004 S.3-bis r Bash -o \"a b\" is plain: not gated (push_val is PowerShell-only)"

  # item 8 (S.3-bis o, r): W_REFMAP
  GF_RM="$workdir/rm"; cp -R "$GF_X" "$GF_RM"
  git -C "$GF_RM" config remote.origin.push 'refs/heads/feat/x:refs/heads/main'
  git -C "$GF_RM" config --add remote.origin.push '^refs/heads/zzz'
  gate_run rqb9 "$GF_RM" 'git push origin feat/x'
  gate_assert_deny "REQ-004 S.3-bis o a ^ entry after a matching positive entry denies W_REFMAP" 'does not name a single destination branch'
  git -C "$GF_RM" config --unset-all remote.origin.push
  git -C "$GF_RM" config remote.origin.push '^refs/heads/zzz'
  gate_run rqb9b "$GF_RM" 'git push origin feat/x'
  gate_assert_deny "REQ-004 S.3-bis o a lone non-matching ^ entry denies W_REFMAP" 'does not name a single destination branch'
  git -C "$GF_RM" config --unset-all remote.origin.push
  git -C "$GF_RM" config remote.origin.push 'refs/heads/*:refs/heads/main'
  gate_run rqb9c "$GF_RM" 'git push origin feat/x'
  gate_assert_deny "REQ-004 S.3-bis r a pattern entry with an unresolvable destination denies W_REFMAP" 'does not name a single destination branch'
  git -C "$GF_RM" config --unset-all remote.origin.push
  git -C "$GF_RM" config remote.origin.push 'refs/heads/feat/x:refs/heads/main'
  gate_run rqb9d "$GF_RM" 'git push origin feat/x'
  gate_assert_deny "REQ-004 S.3-bis o a plain mapping entry still resolves (to main): no-marker deny" 'review is recorded' 'origin/main'

  # item 9 (S.3-bis j, u): an unborn HEAD in a repository with other refs
  gate_run rqb10 "$GF_OR" 'git push origin HEAD:main'
  gate_assert_deny "REQ-004 S.3-bis j,x unborn HEAD: HEAD:main gets the source-not-HEAD wording with the no-commit clause" 'checked-out commit' 'is not HEAD (this branch has no commit yet). Check the source out first, then review and push.'
  gate_run rqb10b "$GF_OR" 'gh pr create --head feat --fill'
  gate_assert_deny "REQ-004 S.3-bis u unborn HEAD: gh pr create --head feat denies with the source-not-HEAD wording" 'checked-out commit' 'feat'
  gate_run rqb10c "$GF_OR" 'gh pr create --fill'
  gate_assert_deny "REQ-004 S.3-bis u unborn HEAD: gh pr create --fill denies with the source-not-HEAD wording" 'checked-out commit'
  gate_run rqb10d "$GF_EMPTY" 'git push origin HEAD:main'
  gate_assert_allow "REQ-004 S.3-bis j repository with no refs at all: HEAD:main stays fail-open"
  gate_run rqb10e "$GF_EMPTY" 'gh pr create --fill'
  gate_assert_deny "REQ-004 S.3-bis u repository with no refs at all: gh pr create denies W_NOREPO" 'not a git work tree' 'HEAD vs its destination'
  # round 3 (S.3-bis w): drive-relative and root-relative directories are not plain
  GATE_TOOL=PowerShell
  gate_run rqw1 "$GF_M" 'cd C:; git push origin main'
  gate_assert_deny "REQ-004 S.3-bis w [PowerShell] 'cd C:; git push origin main' is not plain" "$GATE_PLAIN"
  gate_run rqw3 "$GF_M" 'git -C \repo push origin main'
  gate_assert_deny "REQ-004 S.3-bis w [PowerShell] 'git -C \\repo push origin main' is not plain" "$GATE_PLAIN"
  gate_run rqw4 "$GF_M" 'cd D:; git push origin main'
  gate_assert_deny "REQ-004 S.3-bis w [PowerShell] 'cd D:; git push origin main' is not plain" "$GATE_PLAIN"
  GATE_TOOL=Bash
  gate_run rqw2 "$GF_M" 'cd C:repo && git push origin main'
  gate_assert_deny "REQ-004 S.3-bis w 'cd C:repo && git push origin main' is not plain" "$GATE_PLAIN"
  gm_m="$(cygpath -m "$GF_M" 2>/dev/null || printf '%s' "$GF_M")"
  gate_run rqw5 "$GF_M" "cd $gm_m && git push origin HEAD:main"
  gate_assert_deny "REQ-004 S.3-bis w positive control: 'cd <C:/repo> && git push origin HEAD:main' reaches the no-marker deny" 'review is recorded'
  rm -rf "$workdir"
}

section "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE002] marker from an earlier HEAD"
{
  workdir="$(make_work_dir)" || exit 2
  GATE_STATE="$workdir/state"
  gate_mkrepo "$workdir/r" main
  git -C "$workdir/r" checkout -q feat/x
  old_head="$(git -C "$workdir/r" rev-parse HEAD)"
  gate_real_marker e2 "$workdir/r" 'feat/x vs main' refs/remotes/origin/main
  gate_run e2 "$workdir/r" 'gh pr create --fill'
  gate_assert_allow "EDGE-002 control: marker at HEAD allows"
  gate_commit "$workdir/r" c-after-review
  new_head="$(git -C "$workdir/r" rev-parse HEAD)"
  gate_run e2 "$workdir/r" 'gh pr create --fill'
  gate_assert_deny "EDGE-002 commit after the review: denied, reason says stale and names both shas" 'stale' "$old_head" "$new_head"
  gate_run e2 "$workdir/r" 'git push origin HEAD:main'
  gate_assert_deny "EDGE-002 same marker, push to main: denied as stale" 'stale' "$old_head" "$new_head"

  # head= equals HEAD, but the reviewed range ends at the earlier commit (a background review
  # that finished after a new commit)
  gate_marker e2r1 APPROVED "$new_head" "feat/x vs main ($old_head..$old_head); fallback: none"
  gate_run e2r1 "$workdir/r" 'gh pr create --fill'
  gate_assert_deny "EDGE-002 head= is HEAD but the range ends at an earlier sha: denied as stale" 'stale' "$old_head" "$new_head"
  # a PR #<n> target whose head sha is not HEAD
  gate_marker e2r2 APPROVED "$new_head" "PR #9 $old_head vs main ($old_head..$old_head); fallback: none"
  gate_run e2r2 "$workdir/r" 'gh pr create --fill'
  gate_assert_deny "EDGE-002 'PR #9 <sha>' target whose head sha is not HEAD: denied as stale" 'stale' "$old_head"
  # an empty range (x..x) while commits are ahead of the destination
  gate_marker e2r3 APPROVED "$new_head" "feat/x vs main ($new_head..$new_head); fallback: none"
  gate_run e2r3 "$workdir/r" 'gh pr create --fill'
  gate_assert_deny "EDGE-002 empty range x..x while commits are ahead: denied as stale" 'stale' 'is empty'
  rm -rf "$workdir"
}

section "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE003] marker from a non-branch review or another base"
{
  workdir="$(make_work_dir)" || exit 2
  GATE_STATE="$workdir/state"
  gate_mkrepo "$workdir/r" main
  git -C "$workdir/r" checkout -q feat/x
  git -C "$workdir/r" update-ref refs/remotes/origin/master "$(git -C "$workdir/r" rev-parse main~1)"
  h="$(git -C "$workdir/r" rev-parse HEAD)"
  no_cover='did not cover the branch against its destination'
  gate_marker e3a APPROVED "$h" "uncommitted @ $h (2 files)"
  gate_run e3a "$workdir/r" 'git push origin HEAD:main'
  gate_assert_deny "EDGE-003 'uncommitted @ <sha>' target: denied, branch not covered" "$no_cover"
  gate_marker e3b APPROVED "$h" "paths src/a.sh src/b.sh @ $h"
  gate_run e3b "$workdir/r" 'git push origin HEAD:main'
  gate_assert_deny "EDGE-003 'paths <list> @ <sha>' target: denied, branch not covered" "$no_cover"
  gate_marker e3c APPROVED "$h" "paths src/a.sh in PR #4 $h"
  gate_run e3c "$workdir/r" 'git push origin HEAD:main'
  gate_assert_deny "EDGE-003 'paths <list> in PR #<n> <sha>' target: denied, branch not covered" "$no_cover"
  gate_marker e3d APPROVED "$h" -
  gate_run e3d "$workdir/r" 'git push origin HEAD:main'
  gate_assert_deny "EDGE-003 no target line: denied, branch not covered" "$no_cover"

  gate_real_marker e3e "$workdir/r" 'feat/x vs origin/main' refs/remotes/origin/main
  gate_run e3e "$workdir/r" 'git push origin HEAD:master'
  gate_assert_deny "EDGE-003 'feat/x vs origin/main' marker does not unlock push to master: names both" 'Base mismatch' 'origin/main' 'master'
  gate_run e3e "$workdir/r" 'gh pr create --base develop'
  gate_assert_deny "EDGE-003 'feat/x vs origin/main' marker does not unlock gh pr create --base develop: names both" 'Base mismatch' 'origin/main' 'develop'
  gate_run e3e "$workdir/r" 'git push origin HEAD:main'
  gate_assert_allow "EDGE-003 control: 'feat/x vs origin/main' marker unlocks push to main (remote prefix removed)"

  git -C "$workdir/r" branch release/1.0 main~1
  # the PR's base must have a remote-tracking ref to start from (I-ter.8)
  git -C "$workdir/r" update-ref refs/remotes/origin/release/1.0 "$(git -C "$workdir/r" rev-parse main~1)"
  gate_real_marker e3f "$workdir/r" 'feat/x vs release/1.0' refs/remotes/origin/release/1.0
  gate_run e3f "$workdir/r" 'gh pr create --base release/1.0'
  gate_assert_allow "EDGE-003 'feat/x vs release/1.0' marker unlocks gh pr create --base release/1.0"
  rm -rf "$workdir"
}

section "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE004] source is not the checked-out commit"
{
  workdir="$(make_work_dir)" || exit 2
  GATE_STATE="$workdir/state"
  gate_build_fixtures "$workdir"
  src_msg='checked-out commit'
  gate_run e4a "$GF_X" 'git push origin feat/y:main'
  gate_assert_deny "EDGE-004 git push origin feat/y:main on feat/x: source not checked out" "$src_msg" 'Check the source out first'
  gate_run e4b "$GF_X" 'git push origin main'
  gate_assert_deny "EDGE-004 git push origin main on feat/x (different sha): source not checked out" "$src_msg"
  gate_run e4b2 "$GF_XS" 'git push origin main'
  gate_assert_deny "EDGE-004 git push origin main on feat/x at main's sha: source not checked out" "$src_msg"
  gate_run e4c "$GF_X" 'gh pr create --head other --fill'
  gate_assert_deny "EDGE-004 gh pr create --head other: source not checked out" "$src_msg"

  head_x="$(git -C "$GF_X" rev-parse HEAD)"
  gate_real_marker e4d "$GF_X" 'feat/x vs origin/main' refs/remotes/origin/main
  gate_run e4d "$GF_X" 'git push origin feat/x:main'
  gate_assert_allow "EDGE-004 clean feat/x:main with an APPROVED matching marker: allowed (source is HEAD)"
  gate_run e4e "$GF_DIRTY" 'git push origin feat/x:main'
  gate_assert_deny "EDGE-004 dirty feat/x:main, no marker: the no-marker denial (dirty tree irrelevant)" 'review is recorded'
  rm -rf "$workdir"
}

section "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE005] nothing to push"
{
  workdir="$(make_work_dir)" || exit 2
  GATE_STATE="$workdir/state"
  gate_mkrepo "$workdir/r" main
  git -C "$workdir/r" update-ref refs/remotes/origin/main "$(git -C "$workdir/r" rev-parse HEAD)"
  gate_run e5a "$workdir/r" 'git push origin main'
  gate_assert_allow "EDGE-005 origin/main equals HEAD: git push origin main passes"
  gate_run e5b "$workdir/r" 'git push'
  gate_assert_allow "EDGE-005 origin/main equals HEAD: bare git push passes"
  gate_run e5c "$workdir/r" 'git push origin HEAD:main'
  gate_assert_allow "EDGE-005 origin/main equals HEAD: git push origin HEAD:main passes"
  gate_commit "$workdir/r" c3
  gate_run e5d "$workdir/r" 'git push origin main'
  gate_assert_deny "EDGE-005 control: one commit ahead is gated again" 'review is recorded'

  # HEAD one commit behind origin/main: a force-push that rewinds the destination is gated
  gate_mkrepo "$workdir/b" main
  git -C "$workdir/b" checkout -q feat/x
  gate_commit "$workdir/b" c3
  git -C "$workdir/b" checkout -q main
  git -C "$workdir/b" update-ref refs/remotes/origin/main "$(git -C "$workdir/b" rev-parse feat/x)"
  gate_run e5f "$workdir/b" 'git push --force origin main'
  gate_assert_deny "EDGE-005 HEAD one commit behind origin/main, --force: gated like one ahead" 'review is recorded'
  # an equal-sha range (HEAD..HEAD) unlocks nothing while HEAD is behind the remote tip (I-ter.8)
  h_b="$(git -C "$workdir/b" rev-parse HEAD)"
  gate_marker e5g APPROVED "$h_b" "main vs origin/main ($h_b..$h_b); fallback: none"
  gate_run e5g "$workdir/b" 'git push --force origin main'
  gate_assert_deny "EDGE-005 HEAD behind origin/main with an APPROVED (HEAD..HEAD) marker, --force: denied, empty range" 'stale' 'is empty'
  rm -rf "$workdir"
}

section "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE006] remote-tracking ref unknown or remote unconfigured"
{
  workdir="$(make_work_dir)" || exit 2
  GATE_STATE="$workdir/state"
  mkdir -p "$workdir/r"
  git -C "$workdir/r" init -q -b main
  git -C "$workdir/r" config user.email 'test@test.local'
  git -C "$workdir/r" config user.name 'hooks-test'
  git -C "$workdir/r" config commit.gpgsign false
  gate_commit "$workdir/r" c1
  git -C "$workdir/r" remote add origin "$workdir/r.nowhere"
  gate_run e6a "$workdir/r" 'git push origin main'
  gate_assert_deny "EDGE-006 no origin/main: denied naming git fetch origin main and the env var" 'git fetch origin main' 'AF_CODE_REVIEW_GATE=off' 'does not yet exist'
  gate_run e6b "$workdir/r" 'git push https://host/r.git main'
  gate_assert_deny "EDGE-006 URL remote: denied, asks for a configured remote" 'configured remote'
  if printf '%s' "$RUN_OUT" | grep -qF 'git fetch'; then _fail "EDGE-006 unconfigured remote gives no fetch hint" "$RUN_OUT"; else _pass "EDGE-006 unconfigured remote gives no fetch hint"; fi
  gate_run e6c "$workdir/r" 'git push typo main'
  gate_assert_deny "EDGE-006 typo remote name: denied, asks for a configured remote" 'configured remote'
  rm -rf "$workdir"
}

section "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE007] fail-open on anything the gate cannot read"
{
  workdir="$(make_work_dir)" || exit 2
  GATE_STATE="$workdir/state"
  gate_mkrepo "$workdir/r" main
  mkdir -p "$workdir/plain" "$workdir/empty"
  git -C "$workdir/empty" init -q -b main
  cmd='git push origin main'

  gate_run_raw 'not json at all'
  gate_assert_allow "EDGE-007 malformed JSON: exit 0, no output"
  gate_run_raw "$(jq -cn --arg c "$workdir/r" --arg m "$cmd" '{session_id:"e7",cwd:$c,tool_input:$m}')"
  gate_assert_allow "EDGE-007 tool_input is a string, not an object"
  gate_run_raw "$(jq -cn --arg c "$workdir/r" '{session_id:"e7",cwd:$c,tool_input:[1,2]}')"
  gate_assert_allow "EDGE-007 tool_input is an array"
  gate_run_raw "$(jq -cn --arg c "$workdir/r" '{session_id:"e7",cwd:$c,tool_input:{}}')"
  gate_assert_allow "EDGE-007 missing tool_input.command"
  gate_run_raw "$(jq -cn --arg c "$workdir/r" '{session_id:"e7",cwd:$c,tool_input:{command:42}}')"
  gate_assert_allow "EDGE-007 non-string command (number)"
  gate_run_raw "$(jq -cn --arg c "$workdir/r" '{session_id:"e7",cwd:$c,tool_input:{command:["git","push"]}}')"
  gate_assert_allow "EDGE-007 non-string command (array)"
  gate_run e7 "$workdir/r" "$cmd"
  gate_assert_deny "EDGE-007 control: same repo and command with a session id is denied" 'review is recorded'
  gate_run "" "$workdir/r" "$cmd"
  gate_assert_allow "EDGE-007 empty session_id"
  gate_run '../..' "$workdir/r" "$cmd"
  gate_assert_allow "EDGE-007 session_id empty after sanitising"
  gate_run_raw "$(jq -cn --arg c "$workdir/r" --arg m "$cmd" '{cwd:$c,tool_input:{command:$m}}')"
  gate_assert_allow "EDGE-007 missing session_id"
  gate_run e7 "$workdir/plain" "$cmd"
  gate_assert_allow "EDGE-007 cwd is not a git work tree"
  gate_run e7 "$workdir/empty" "$cmd"
  gate_assert_allow "EDGE-007 repository with no commits (unborn HEAD)"

  # jq absent: PATH holds wrappers for every other tool the gate runs, so only jq is missing;
  # the control run adds jq to the same set and must deny.
  real_sh="$(command -v sh)"
  e7_payload="$(gate_payload e7 "$workdir/r" "$cmd")"
  if gate_mkbin "$workdir/nojq" cat tr sed grep git && gate_mkbin "$workdir/withjq" cat tr sed grep git jq; then
    RUN_OUT="$( (printf '%s' "$e7_payload" | PATH="$workdir/nojq" CLAUDE_STATE_DIR="$GATE_STATE" "$real_sh" "$GATE") 2>&1)"
    RUN_RC=$?
    gate_assert_allow "EDGE-007 jq absent from PATH (cat tr sed grep git present): exit 0, no output"
    RUN_OUT="$( (printf '%s' "$e7_payload" | PATH="$workdir/withjq" CLAUDE_STATE_DIR="$GATE_STATE" "$real_sh" "$GATE") 2>&1)"
    RUN_RC=$?
    gate_assert_deny "EDGE-007 control: the same PATH plus jq denies" 'review is recorded'
  else
    _fail "EDGE-007 jq-absent PATH fixture" "could not build the wrapper bin dirs"
  fi
  rm -rf "$workdir"
}

section "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE008] sub-agent runs the push (agent_id in the payload)"
{
  workdir="$(make_work_dir)" || exit 2
  GATE_STATE="$workdir/state"
  gate_mkrepo "$workdir/r" main
  git -C "$workdir/r" checkout -q feat/x
  h="$(git -C "$workdir/r" rev-parse HEAD)"
  agent_payload() { jq -cn --arg s "$1" --arg c "$workdir/r" --arg m "$2" '{session_id:$s,cwd:$c,agent_id:"a1b2c3",agent_type:"bash-expert",tool_name:"Bash",tool_input:{command:$m}}'; }
  gate_run_raw "$(agent_payload e8 'git push origin HEAD:main')"
  gate_assert_deny "EDGE-008 agent_id payload, no marker for the parent session: denied" 'review is recorded'
  gate_real_marker e8 "$workdir/r" 'feat/x vs origin/main' refs/remotes/origin/main
  gate_run_raw "$(agent_payload e8 'git push origin HEAD:main')"
  gate_assert_allow "EDGE-008 agent_id payload, matching APPROVED marker of the parent session: allowed"
  gate_run_raw "$(agent_payload e8-other 'gh pr create --fill')"
  gate_assert_deny "EDGE-008 agent_id payload, another session id has no marker: denied" 'review is recorded'
  rm -rf "$workdir"
}

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%s================================================%s\n' "$C_CYN" "$C_NC"
if [ "$TESTS_FAIL" -eq 0 ]; then
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
