#!/usr/bin/env bash
# hookcheck.sh - Shared hook-architecture checks (real Claude Code hooks).
#
# Asserts registration parity between hooks/hooks.json (plugin hook registrations)
# and the hook implementations in hooks/*.ps1. Consumed by BOTH
# scripts/validate-consistency.sh (check 3) and scripts/validate-hooks.sh so the
# two can never drift apart.
#
# This file is meant to be SOURCED after facts.sh:
#     source "$(dirname "$0")/lib/facts.sh"
#     source "$(dirname "$0")/lib/hookcheck.sh"
#
# Requirements: bash, jq (via facts.sh).

# --- guard against double-sourcing -----------------------------------------
if [[ -n "${__HOOKCHECK_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__HOOKCHECK_SH_LOADED=1

# Valid Claude Code hook event names (the settings "hooks" schema).
HOOKCHECK_VALID_EVENTS='PreToolUse
PostToolUse
UserPromptSubmit
Notification
Stop
SubagentStop
SessionStart
SessionEnd
PreCompact'

# hookcheck_problems - print one "<type>TAB<subject>" line per problem found.
# Empty output (and exit 0) means the hook architecture is consistent.
#
# Problem types:
#   no-hooks-block         hooks/hooks.json is missing or has no "hooks" key
#   missing-hook-script    registered in hooks.json but hooks/<name> does not exist
#   orphan-hook-script     hooks/*.ps1 exists but is not registered in hooks.json
#   invalid-hook-event     hooks.json "hooks" uses an unknown event name
#   missing-requires-ps7   hook script lacks the '#Requires -Version 7.0' header
hookcheck_problems() {
  local registered files events e f first

  _facts_require_hooks_json || {
    printf 'no-hooks-block\thooks/hooks.json\n'
    return 0
  }
  if ! _facts_jq -e '.hooks | type == "object" and (keys | length > 0)' \
        "$FACTS_HOOKS_JSON" >/dev/null 2>&1; then
    printf 'no-hooks-block\thooks/hooks.json\n'
    return 0
  fi

  registered="$(fact_registered_hook_scripts)"
  files="$(fact_hook_script_files)"
  events="$(fact_hook_events)"

  # (a) registered but not on disk
  comm -23 <(printf '%s\n' "$registered" | grep -v '^$') \
           <(printf '%s\n' "$files" | grep -v '^$') \
    | while IFS= read -r f; do
        [[ -n "$f" ]] && printf 'missing-hook-script\t%s\n' "$f"
      done

  # (b) on disk but not registered
  comm -13 <(printf '%s\n' "$registered" | grep -v '^$') \
           <(printf '%s\n' "$files" | grep -v '^$') \
    | while IFS= read -r f; do
        [[ -n "$f" ]] && printf 'orphan-hook-script\t%s\n' "$f"
      done

  # (c) unknown event names
  while IFS= read -r e; do
    [[ -z "$e" ]] && continue
    if ! printf '%s\n' "$HOOKCHECK_VALID_EVENTS" | grep -qxF -- "$e"; then
      printf 'invalid-hook-event\t%s\n' "$e"
    fi
  done <<< "$events"

  # (d) every hook script must pin PowerShell 7 (first line '#Requires -Version 7.0')
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$FACTS_HOOKS_DIR/$f" ]] || continue
    first="$(head -n 1 "$FACTS_HOOKS_DIR/$f" | tr -d '\r')"
    if [[ "$first" != '#Requires -Version 7.0' ]]; then
      printf 'missing-requires-ps7\t%s\n' "$f"
    fi
  done <<< "$files"
}
