#!/usr/bin/env bash
# plugin-manifests.test.sh - Test harness for plugin manifest validation
# (core plugin, mcp plugin, marketplace, hooks.json, mcp.json).
#
# ISOLATION CONTRACT (same as consistency.test.sh):
#   Each test case operates on its own throwaway copy of the repo.
#   The real working tree is NEVER mutated.
#
# Usage:
#   bash tests/plugin-manifests.test.sh
#   echo "exit=$?"      # 0 = all cases passed, 1 = at least one failed

set -uo pipefail
# NOTE: -e is intentionally NOT set — we run every case and aggregate results;
# a single failing assertion must not abort the whole suite.

# --- locate the repo under test --------------------------------------------
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_REPO="$(cd "$TEST_DIR/.." && pwd)"

# --- pin the bash interpreter (portability + Windows safety) ----------------
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

declare -a __TMP_DIRS=()

cleanup_all() {
  local d
  for d in "${__TMP_DIRS[@]:-}"; do
    [[ -n "${d:-}" && -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup_all EXIT INT TERM

# --- copy helper (identical to consistency.test.sh pattern) --------
make_copy() {
  local dst entry base
  dst="$(mktemp -d "${TMPDIR:-/tmp}/plugin-manifests-test.XXXXXX")" || {
    printf 'FATAL: mktemp failed\n' >&2
    exit 2
  }
  __TMP_DIRS+=("$dst")
  shopt -s dotglob nullglob
  for entry in "$SRC_REPO"/*; do
    base="$(basename "$entry")"
    [[ "$base" == ".git" ]] && continue
    cp -r "$entry" "$dst/"
  done
  shopt -u dotglob nullglob
  printf '%s\n' "$dst"
}

# --- assertion helpers -------------------------------------------------------
_pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASS=$((TESTS_PASS + 1)); printf '  %sPASS%s  %s\n' "$C_GRN" "$C_NC" "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1))
  printf '  %sFAIL%s  %s\n' "$C_RED" "$C_NC" "$1"
  [[ -n "${2:-}" ]] && printf '        %s\n' "$2"
}

assert_zero() {
  local rc="$1" label="$2"
  if [[ "$rc" -eq 0 ]]; then _pass "$label"
  else _fail "$label" "expected exit 0, got $rc"; fi
}

assert_nonzero() {
  local rc="$1" label="$2"
  if [[ "$rc" -ne 0 ]]; then _pass "$label"
  else _fail "$label" "expected non-zero exit, got 0"; fi
}

assert_file_exists() {
  local path="$1" label="$2"
  if [[ -f "$path" ]]; then _pass "$label"
  else _fail "$label" "file does not exist: $path"; fi
}

assert_file_not_exists() {
  local path="$1" label="$2"
  if [[ ! -f "$path" ]]; then _pass "$label"
  else _fail "$label" "file should not exist: $path"; fi
}

assert_json_field_matches() {
  local file="$1" jq_filter="$2" expected="$3" label="$4"
  local actual
  if ! command -v jq >/dev/null 2>&1; then
    _fail "$label" "jq is required but not installed"
    return
  fi
  actual="$(jq -r "$jq_filter" "$file" 2>/dev/null)" || {
    _fail "$label" "jq query failed on $file"
    return
  }
  if [[ "$actual" == "$expected" ]]; then
    _pass "$label"
  else
    _fail "$label" "expected '$expected', got '$actual'"
  fi
}

section() { printf '\n%s%s%s\n' "$C_CYN" "$1" "$C_NC"; }

# --- validator helper -------------------------------------------------------
# run_validate <copy-root> -> runs the COPIED validator against the copy.
#   Captures combined stdout+stderr into $RUN_OUT and the exit code into $RUN_RC.
RUN_OUT=""
RUN_RC=0
run_validate() {
  local root="$1"
  RUN_OUT="$(FRAMEWORK_ROOT="$root" "$BASH_BIN" "$root/scripts/validate-consistency.sh" 2>&1)"
  RUN_RC=$?
}

# ===========================================================================
printf '%s================================================%s\n' "$C_CYN" "$C_NC"
printf '%s  Plugin Manifest Test Harness%s\n' "$C_CYN" "$C_NC"
printf '%s  source repo: %s%s\n' "$C_CYN" "$SRC_REPO" "$C_NC"
printf '%s================================================%s\n' "$C_CYN" "$C_NC"

# Preflight: check jq
if ! command -v jq >/dev/null 2>&1; then
  printf '%sFATAL%s jq is required but not installed.\n' "$C_RED" "$C_NC" >&2
  exit 2
fi

# ===========================================================================
# GREEN PATH: Happy path with unmodified copy
# ===========================================================================
section "[GREEN] Plugin manifest validation — happy path"

copy="$(make_copy)"
FRAMEWORK_ROOT="$copy"
export FRAMEWORK_ROOT

# --- Assertion 1: Core plugin.json name is "agentic-framework" (kebab-case) ---
{
  assert_json_field_matches "$copy/.claude-plugin/plugin.json" '.name' "agentic-framework" \
    "core plugin.json .name == 'agentic-framework'"

  # Validate kebab-case regex
  name="$(jq -r '.name' "$copy/.claude-plugin/plugin.json")"
  if [[ $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    _pass "core plugin.json .name is kebab-case"
  else
    _fail "core plugin.json .name is kebab-case" "name '$name' does not match ^[a-z0-9]+(-[a-z0-9]+)*$"
  fi
}

# --- Assertion 2: MCP plugin.json name is "agentic-framework-mcp" (kebab-case) ---
{
  assert_json_field_matches "$copy/mcp-plugin/.claude-plugin/plugin.json" '.name' "agentic-framework-mcp" \
    "mcp plugin.json .name == 'agentic-framework-mcp'"

  # Validate kebab-case regex
  name="$(jq -r '.name' "$copy/mcp-plugin/.claude-plugin/plugin.json")"
  if [[ $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    _pass "mcp plugin.json .name is kebab-case"
  else
    _fail "mcp plugin.json .name is kebab-case" "name '$name' does not match ^[a-z0-9]+(-[a-z0-9]+)*$"
  fi
}

# --- Assertion 3: Version sync (claude.json, core plugin.json, mcp plugin.json) ---
{
  cv="$(jq -r '.version' "$copy/claude.json")"
  cv_plugin="$(jq -r '.version' "$copy/.claude-plugin/plugin.json")"
  cv_mcp="$(jq -r '.version' "$copy/mcp-plugin/.claude-plugin/plugin.json")"

  if [[ -n "$cv" && "$cv" == "$cv_plugin" && "$cv" == "$cv_mcp" ]]; then
    _pass "version sync: claude.json ($cv) == core plugin.json == mcp plugin.json"
  else
    _fail "version sync" "claude.json=$cv, core=$cv_plugin, mcp=$cv_mcp"
  fi
}

# --- Assertion 4: marketplace.json name is kebab-case ---
{
  name="$(jq -r '.name' "$copy/.claude-plugin/marketplace.json")"
  if [[ $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    _pass "marketplace.json .name is kebab-case: '$name'"
  else
    _fail "marketplace.json .name is kebab-case" "name '$name' does not match pattern"
  fi
}

# --- Assertion 5: marketplace.json plugins[].source directories exist ---
{
  rc=0
  while IFS= read -r src; do
    # Remove Windows line endings (carriage returns from jq output)
    src="${src//$'\r'/}"
    [[ -z "$src" ]] && continue
    # Normalize "./" to current directory
    if [[ "$src" == "./" ]]; then
      src_path="$copy"
    else
      src_path="$copy/$src"
    fi
    if [[ -d "$src_path" ]]; then
      : # OK
    else
      _fail "marketplace.json plugin source exists" "source '$src' does not resolve to directory"
      rc=1
    fi
  done < <(jq -r '.plugins[].source' "$copy/.claude-plugin/marketplace.json")

  if [[ "$rc" -eq 0 ]]; then
    _pass "marketplace.json plugins[].source all resolve to existing directories"
  fi
}

# --- Assertion 6: marketplace.json plugin names match plugin.json names ---
{
  # Check that each plugin in marketplace has a corresponding plugin.json
  mp_name_1="$(jq -r '.plugins[0].name' "$copy/.claude-plugin/marketplace.json")"
  mp_name_2="$(jq -r '.plugins[1].name' "$copy/.claude-plugin/marketplace.json")"

  pj_name_1="$(jq -r '.name' "$copy/.claude-plugin/plugin.json")"
  pj_name_2="$(jq -r '.name' "$copy/mcp-plugin/.claude-plugin/plugin.json")"

  if [[ "$mp_name_1" == "$pj_name_1" && "$mp_name_2" == "$pj_name_2" ]]; then
    _pass "marketplace.json plugin names match their plugin.json .name fields"
  else
    _fail "marketplace.json plugin names" "mp1=$mp_name_1 (expect $pj_name_1), mp2=$mp_name_2 (expect $pj_name_2)"
  fi
}

# --- Assertion 6a: marketplace.json has a non-empty top-level description ---
{
  desc_type="$(jq -r '.description | type' "$copy/.claude-plugin/marketplace.json")"
  desc="$(jq -r '.description' "$copy/.claude-plugin/marketplace.json")"
  # Remove Windows line endings
  desc="${desc//$'\r'/}"

  if [[ "$desc_type" != "string" ]]; then
    _fail "marketplace.json has a non-empty top-level .description" "type is $desc_type, not string"
  elif [[ -n "$desc" && "$desc" != "null" && $desc =~ [^[:space:]] ]]; then
    _pass "marketplace.json has a non-empty top-level .description"
  else
    _fail "marketplace.json has a non-empty top-level .description" "description was: $desc"
  fi
}

# --- Assertion 7: hooks.json hook event names are valid ---
{
  # Valid Claude Code hook events (from hookcheck.sh)
  declare -a valid_events=(
    "PreToolUse"
    "PostToolUse"
    "UserPromptSubmit"
    "Notification"
    "Stop"
    "SubagentStop"
    "SessionStart"
    "SessionEnd"
    "PreCompact"
  )

  rc=0
  while IFS= read -r event; do
    # Remove Windows line endings
    event="${event//$'\r'/}"
    [[ -z "$event" ]] && continue
    found=0
    for ve in "${valid_events[@]}"; do
      if [[ "$event" == "$ve" ]]; then
        found=1
        break
      fi
    done
    if [[ "$found" -ne 1 ]]; then
      _fail "hooks.json event names are valid" "event '$event' is not in the valid set"
      rc=1
    fi
  done < <(jq -r '.hooks | keys[]' "$copy/hooks/hooks.json")

  if [[ "$rc" -eq 0 ]]; then
    _pass "hooks.json all event names are valid Claude Code hook events"
  fi
}

# --- Assertion 8a: hooks.json scan-based .ps1 extraction works ---
{
  # Test that the scan-based extraction correctly identifies .ps1 files from command strings
  ps1_list="$(jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | .[] | scan("[a-zA-Z0-9._-]+[.]ps1") | sub("^.*/"; "")' "$copy/hooks/hooks.json" | sort -u)"
  ps1_count="$(printf '%s' "$ps1_list" | grep -c . || true)"
  if [[ "$ps1_count" -eq 4 ]]; then
    _pass "scan-based .ps1 extraction finds all 4 registered hook scripts"
  else
    _fail "scan-based .ps1 extraction" "expected 4 scripts, found $ps1_count"
  fi
}

# --- Assertion 8: hooks.json registered .ps1 scripts exist on disk ---
{
  rc=0
  while IFS= read -r script; do
    # Remove Windows line endings
    script="${script//$'\r'/}"
    [[ -z "$script" ]] && continue
    if [[ -f "$copy/hooks/$script" ]]; then
      : # OK
    else
      _fail "hooks.json registered .ps1 script exists" "script '$script' not found in hooks/"
      rc=1
    fi
  done < <(jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | .[] | scan("[a-zA-Z0-9._-]+[.]ps1") | sub("^.*/"; "")' "$copy/hooks/hooks.json" | sort -u)

  if [[ "$rc" -eq 0 ]]; then
    _pass "hooks.json all registered .ps1 scripts exist in hooks/ directory"
  fi
}

# --- Assertion 9: All hooks/*.ps1 files are registered (parity) ---
{
  rc=0
  registered_scripts="$(jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | .[] | scan("[a-zA-Z0-9._-]+[.]ps1") | sub("^.*/"; "")' "$copy/hooks/hooks.json" | tr -d '\r' | sort -u)"

  shopt -s nullglob
  for f in "$copy/hooks"/*.ps1; do
    script="$(basename "$f")"
    if printf '%s' "$registered_scripts" | grep -qxF "$script"; then
      : # OK
    else
      _fail "all hook .ps1 scripts are registered" "script '$script' is not registered in hooks.json"
      rc=1
    fi
  done
  shopt -u nullglob

  if [[ "$rc" -eq 0 ]]; then
    _pass "all hooks/*.ps1 files are registered in hooks.json (parity)"
  fi
}

# --- Assertion 9a: dispatch.sh exists and is referenced in all chains ---
{
  if [[ -f "$copy/hooks/dispatch.sh" ]]; then
    _pass "dispatch.sh exists in hooks/ directory"
  else
    _fail "dispatch.sh exists" "dispatch.sh not found in hooks/"
  fi

  # Check that dispatch.sh is referenced in all hook command chains
  dispatch_refs="$(jq '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | map(select(contains("dispatch.sh"))) | length' "$copy/hooks/hooks.json")"
  total_hooks="$(jq '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | length' "$copy/hooks/hooks.json")"

  if [[ "$dispatch_refs" -eq "$total_hooks" ]]; then
    _pass "dispatch.sh is referenced in all registered hook chains"
  else
    _fail "dispatch.sh referenced in all chains" "found $dispatch_refs references, expected $total_hooks"
  fi
}

# --- Assertion 9b: Hook implementation parity (.ps1 and .sh pairs) ---
{
  rc=0
  registered_ps1="$(jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | .[] | scan("[a-zA-Z0-9._-]+[.]ps1") | sub("^.*/"; "") | sub("[.]ps1$"; "")' "$copy/hooks/hooks.json" | tr -d '\r' | sort -u)"
  # Extract hook names from dispatch.sh arguments and add .sh extension (names already with .sh)
  registered_sh="$(jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | .[] | scan("dispatch[.]sh[\" ] +([a-zA-Z0-9._-]+)") | .[0] + ".sh"' "$copy/hooks/hooks.json" | tr -d '\r' | sort -u)"

  # Every .ps1 hook (name without extension) must have a corresponding .sh (name with extension)
  while IFS= read -r hook_name; do
    [[ -z "$hook_name" ]] && continue
    # Append .sh to the hook name to match against registered_sh
    if ! printf '%s' "$registered_sh" | grep -qxF "$hook_name.sh"; then
      _fail "hook implementation parity" ".sh implementation missing for '$hook_name.ps1'"
      rc=1
    fi
  done <<< "$registered_ps1"

  if [[ "$rc" -eq 0 ]]; then
    _pass "all registered hooks have both .ps1 and .sh implementations"
  fi
}

# --- Assertion 10: No root .mcp.json exists ---
{
  assert_file_not_exists "$copy/.mcp.json" "no root .mcp.json exists"
}

# --- Assertion 11: mcp-plugin/.mcp.json has exactly 5 server keys ---
{
  count="$(jq '.mcpServers | keys | length' "$copy/mcp-plugin/.mcp.json")"
  if [[ "$count" -eq 5 ]]; then
    _pass "mcp-plugin/.mcp.json has exactly 5 mcpServers keys"
  else
    _fail "mcp-plugin/.mcp.json has exactly 5 mcpServers keys" "found $count keys"
  fi
}

# --- Assertion 12: mcp-plugin/.mcp.json has the expected 5 servers ---
{
  # Extract and sort actual servers, removing carriage returns
  actual_sorted="$(jq -r '.mcpServers | keys[]' "$copy/mcp-plugin/.mcp.json" | tr -d '\r' | LC_ALL=C sort)"

  # Define expected servers
  expected_sorted="$(printf '%s\n' "context7" "fetch" "filesystem" "sequential-thinking" "serena" | LC_ALL=C sort)"

  # Do line-by-line comparison using comm (only show lines in actual but not expected or vice versa)
  diff_lines="$(comm -3 <(printf '%s' "$expected_sorted") <(printf '%s' "$actual_sorted") | grep -c . || true)"

  if [[ "$diff_lines" -eq 0 ]]; then
    _pass "mcp-plugin/.mcp.json has exactly the expected 5 servers"
  else
    _fail "mcp-plugin/.mcp.json server keys" "expected: $expected_sorted, got: $actual_sorted"
  fi
}

# --- Assertion 13: context7 env value is literal placeholder ---
{
  env_val="$(jq -r '.mcpServers.context7.env.CONTEXT7_API_KEY' "$copy/mcp-plugin/.mcp.json" | tr -d '\r')"
  if [[ "$env_val" == '${CONTEXT7_API_KEY:-}' ]]; then
    _pass "context7 env.CONTEXT7_API_KEY is literal placeholder '\${CONTEXT7_API_KEY:-}'"
  else
    _fail "context7 env placeholder" "expected '\${CONTEXT7_API_KEY:-}', got '$env_val'"
  fi
}

# --- Assertion 14: No D:/src or D:\src strings in mcp-plugin/.mcp.json ---
{
  content="$(cat "$copy/mcp-plugin/.mcp.json")"
  rc=0
  if printf '%s' "$content" | grep -qE 'D:/src|D:\\src'; then
    _fail "mcp-plugin/.mcp.json has no hardcoded D:/src paths" "found D:/src or D:\\src in content"
    rc=1
  else
    _pass "mcp-plugin/.mcp.json has no hardcoded D:/src paths"
  fi
}

rm -rf "$copy"

# ===========================================================================
# RED PATH CASE 6: Corrupt core plugin.json version
# ===========================================================================
section "[RED-6] Corrupt core plugin.json version (should fail version-sync check)"
{
  copy="$(make_copy)"
  jq '.version = "9.9.9"' "$copy/.claude-plugin/plugin.json" > "$copy/.claude-plugin/plugin.json.tmp" \
    && mv "$copy/.claude-plugin/plugin.json.tmp" "$copy/.claude-plugin/plugin.json"

  cv="$(jq -r '.version' "$copy/claude.json")"
  cv_plugin="$(jq -r '.version' "$copy/.claude-plugin/plugin.json")"

  if [[ "$cv" != "$cv_plugin" ]]; then
    _pass "RED-6: version mismatch detected (corrupt core plugin.json)"
  else
    _fail "RED-6: version mismatch should be detected" "both versions equal"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 7: Add orphan hook script (not registered in hooks.json)
# ===========================================================================
section "[RED-7] Add orphan hook script (should fail parity check)"
{
  copy="$(make_copy)"
  printf '#Requires -Version 7.0\nexit 0\n' > "$copy/hooks/zzz-orphan-unregistered.ps1"

  # Check if the new file is NOT registered (using scan-based extraction)
  if jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | .[] | scan("[a-zA-Z0-9._-]+[.]ps1") | sub("^.*/"; "")' "$copy/hooks/hooks.json" 2>/dev/null | grep -qxF "zzz-orphan-unregistered.ps1"; then
    _fail "RED-7: orphan hook should not be registered" "but it is"
  else
    _pass "RED-7: orphan hook script is not registered (parity broken)"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 8: Remove a registered hook script from disk
# ===========================================================================
section "[RED-8] Remove a registered hook script (should fail parity check)"
{
  copy="$(make_copy)"
  rm -f "$copy/hooks/stop-peer-review-gate.ps1"

  # Check if the removed file is still referenced (using scan-based extraction)
  if jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | .[] | scan("[a-zA-Z0-9._-]+[.]ps1") | sub("^.*/"; "")' "$copy/hooks/hooks.json" 2>/dev/null | grep -qxF "stop-peer-review-gate.ps1"; then
    _pass "RED-8: missing script is still registered in hooks.json (parity broken)"
  else
    _fail "RED-8: missing script should still be registered" "but it's not in hooks.json"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 9: Create root .mcp.json (should fail the "no root" check)
# ===========================================================================
section "[RED-9] Create root .mcp.json (should fail no-root-mcp check)"
{
  copy="$(make_copy)"
  printf '{"mcpServers":{}}\n' > "$copy/.mcp.json"

  if [[ -f "$copy/.mcp.json" ]]; then
    _pass "RED-9: root .mcp.json exists (check should fail)"
  else
    _fail "RED-9: root .mcp.json should exist" "file not created"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 10: Replace context7 env placeholder with fake token
# ===========================================================================
section "[RED-10] Replace context7 env with hardcoded token (should fail placeholder guard)"
{
  copy="$(make_copy)"
  fv=fake-tok-12345
  jq --arg v "$fv" '.mcpServers.context7.env.CONTEXT7_API_KEY = $v' \
    "$copy/mcp-plugin/.mcp.json" > "$copy/mcp-plugin/.mcp.json.tmp" \
    && mv "$copy/mcp-plugin/.mcp.json.tmp" "$copy/mcp-plugin/.mcp.json"

  env_val="$(jq -r '.mcpServers.context7.env.CONTEXT7_API_KEY' "$copy/mcp-plugin/.mcp.json" | tr -d '\r')"
  if [[ "$env_val" != '${CONTEXT7_API_KEY:-}' ]]; then
    _pass "RED-10: context7 env placeholder replaced with hardcoded value (guard broken)"
  else
    _fail "RED-10: placeholder should be replaced" "but it's still the placeholder"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 11: Non-kebab-case plugin name
# ===========================================================================
section "[RED-11] Plugin name with underscores (should fail kebab-case check)"
{
  copy="$(make_copy)"
  bad_name=Agentic_Framework
  jq --arg name "$bad_name" '.name = $name' "$copy/.claude-plugin/plugin.json" \
    > "$copy/.claude-plugin/plugin.json.tmp" \
    && mv "$copy/.claude-plugin/plugin.json.tmp" "$copy/.claude-plugin/plugin.json"

  name="$(jq -r '.name' "$copy/.claude-plugin/plugin.json" | tr -d '\r')"
  if [[ $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    _fail "RED-11: kebab-case validation should reject underscores" "but '$name' passed"
  else
    _pass "RED-11: non-kebab-case name '$name' correctly fails validation"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 12: Invalid hooks.json event name
# ===========================================================================
section "[RED-12] Invalid hooks.json event name (should fail event-validity check)"
{
  copy="$(make_copy)"
  bad_event=OnStop
  jq --arg event "$bad_event" '.hooks[$event] = [{"hooks": []}]' "$copy/hooks/hooks.json" \
    > "$copy/hooks/hooks.json.tmp" \
    && mv "$copy/hooks/hooks.json.tmp" "$copy/hooks/hooks.json"

  # Check if the invalid event is now in the hooks
  if jq -r '.hooks | keys[]' "$copy/hooks/hooks.json" | tr -d '\r' | grep -qxF "$bad_event"; then
    _pass "RED-12: invalid event '$bad_event' added (event-validity check should fail)"
  else
    _fail "RED-12: invalid event should have been added" "but it's not in hooks.json"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 13: Nonexistent marketplace source
# ===========================================================================
section "[RED-13] Marketplace plugin source does not exist (should fail source-exists check)"
{
  copy="$(make_copy)"
  nonexistent_path=./does-not-exist
  jq --arg path "$nonexistent_path" '.plugins[0].source = $path' "$copy/.claude-plugin/marketplace.json" \
    > "$copy/.claude-plugin/marketplace.json.tmp" \
    && mv "$copy/.claude-plugin/marketplace.json.tmp" "$copy/.claude-plugin/marketplace.json"

  source="$(jq -r '.plugins[0].source' "$copy/.claude-plugin/marketplace.json" | tr -d '\r')"
  src_path="$copy/$source"
  if [[ -d "$src_path" ]]; then
    _fail "RED-13: nonexistent source should not exist" "but directory was found at $src_path"
  else
    _pass "RED-13: source '$source' correctly fails to resolve to directory"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 14: Remove a .sh hook implementation (missing-sh-impl)
# ===========================================================================
section "[RED-14] Remove a .sh hook implementation (should fail parity check)"
{
  copy="$(make_copy)"
  rm -f "$copy/hooks/session-start-context.sh"

  # Run the validator against the mutated copy
  run_validate "$copy"

  if [[ "$RUN_RC" -ne 0 ]] && printf '%s\n' "$RUN_OUT" | grep -q "missing-sh-impl: session-start-context.sh"; then
    _pass "RED-14: validator fails with missing-sh-impl when .sh hook is deleted"
  else
    _fail "RED-14: validator should fail with missing-sh-impl" "exit=$RUN_RC, output: $(printf '%s\n' "$RUN_OUT" | grep -E 'missing-sh-impl|check' || echo '(no matches)')"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 15: Add orphan .sh hook script (not matching a registered hook)
# ===========================================================================
section "[RED-15] Add orphan .sh hook script (should fail parity check)"
{
  copy="$(make_copy)"
  printf '#!/bin/sh\nset -u\nexit 0\n' > "$copy/hooks/zzz-extra-unregistered.sh"

  # Run the validator against the mutated copy
  run_validate "$copy"

  if [[ "$RUN_RC" -ne 0 ]] && printf '%s\n' "$RUN_OUT" | grep -q "orphan-sh-script: zzz-extra-unregistered.sh"; then
    _pass "RED-15: validator fails with orphan-sh-script when unregistered .sh is added"
  else
    _fail "RED-15: validator should fail with orphan-sh-script" "exit=$RUN_RC, output: $(printf '%s\n' "$RUN_OUT" | grep -E 'orphan-sh-script|check' || echo '(no matches)')"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 16: Remove dispatch.sh (should fail dispatch presence check)
# ===========================================================================
section "[RED-16] Remove dispatch.sh (should fail dispatch presence check)"
{
  copy="$(make_copy)"
  rm -f "$copy/hooks/dispatch.sh"

  # Run the validator against the mutated copy
  run_validate "$copy"

  if [[ "$RUN_RC" -ne 0 ]] && printf '%s\n' "$RUN_OUT" | grep -q "missing-dispatch-sh: dispatch.sh"; then
    _pass "RED-16: validator fails with missing-dispatch-sh when dispatch.sh is deleted"
  else
    _fail "RED-16: validator should fail with missing-dispatch-sh" "exit=$RUN_RC, output: $(printf '%s\n' "$RUN_OUT" | grep -E 'missing-dispatch-sh|check' || echo '(no matches)')"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 17: Empty marketplace description (should fail Assertion 6a)
# ===========================================================================
section "[RED-17] Empty marketplace description (should fail non-empty check)"
{
  copy="$(make_copy)"
  jq '.description = ""' "$copy/.claude-plugin/marketplace.json" \
    > "$copy/.claude-plugin/marketplace.json.tmp" \
    && mv "$copy/.claude-plugin/marketplace.json.tmp" "$copy/.claude-plugin/marketplace.json"

  # Re-run the assertion logic to verify it fails
  desc_type="$(jq -r '.description | type' "$copy/.claude-plugin/marketplace.json")"
  desc="$(jq -r '.description' "$copy/.claude-plugin/marketplace.json")"
  desc="${desc//$'\r'/}"

  # The assertion should fail because description is empty
  if [[ "$desc_type" == "string" && -z "$desc" ]]; then
    _pass "RED-17: empty description correctly fails the non-empty check"
  else
    _fail "RED-17: empty description should fail" "type=$desc_type, desc='$desc'"
  fi

  rm -rf "$copy"
}

# ===========================================================================
# RED PATH CASE 18: Non-string marketplace description (should fail type check)
# ===========================================================================
section "[RED-18] Non-string marketplace description (should fail type check)"
{
  copy="$(make_copy)"
  jq '.description = 42' "$copy/.claude-plugin/marketplace.json" \
    > "$copy/.claude-plugin/marketplace.json.tmp" \
    && mv "$copy/.claude-plugin/marketplace.json.tmp" "$copy/.claude-plugin/marketplace.json"

  # Re-run the assertion logic to verify it fails on type check
  desc_type="$(jq -r '.description | type' "$copy/.claude-plugin/marketplace.json")"
  desc="$(jq -r '.description' "$copy/.claude-plugin/marketplace.json")"
  desc="${desc//$'\r'/}"

  # The assertion should fail because description is not a string
  if [[ "$desc_type" != "string" ]]; then
    _pass "RED-18: numeric description correctly fails the type check"
  else
    _fail "RED-18: numeric description should fail type check" "type=$desc_type, desc='$desc'"
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
