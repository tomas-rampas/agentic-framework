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
# Parity checks assert filename presence/parity only; they do not inspect command strings for appended shell content (dev/CI lint, not a runtime boundary).
#
# Problem types:
#   no-hooks-block         hooks/hooks.json is missing or has no "hooks" key
#   missing-hook-script    registered in hooks.json but hooks/<name>.ps1 does not exist
#   orphan-hook-script     hooks/*.ps1 exists but is not registered in hooks.json
#   invalid-hook-event     hooks.json "hooks" uses an unknown event name
#   missing-requires-ps7   hook script lacks the '#Requires -Version 7.0' header
#   missing-sh-impl        registered hook has no .sh implementation
#   orphan-sh-script       hooks/*.sh exists (non-dispatch) but is not registered
#   missing-dispatch-sh    dispatch.sh not found or not referenced in all chains
#   missing-sh-shebang     hook .sh script lacks #!/bin/sh header
#   missing-set-u          hook .sh script lacks 'set -u' line
hookcheck_problems() {
  local registered_ps1 registered_sh sh_files ps1_files events e f first

  _facts_require_hooks_json || {
    printf 'no-hooks-block\thooks/hooks.json\n'
    return 0
  }
  if ! _facts_jq -e '.hooks | type == "object" and (keys | length > 0)' \
        "$FACTS_HOOKS_JSON" >/dev/null 2>&1; then
    printf 'no-hooks-block\thooks/hooks.json\n'
    return 0
  fi

  registered_ps1="$(fact_registered_hook_scripts)"
  registered_sh="$(fact_registered_sh_scripts)"
  ps1_files="$(fact_hook_script_files)"
  sh_files="$(fact_hook_sh_impl_files)"
  events="$(fact_hook_events)"

  # (a) .ps1: registered but not on disk
  comm -23 <(printf '%s\n' "$registered_ps1" | grep -v '^$') \
           <(printf '%s\n' "$ps1_files" | grep -v '^$') \
    | while IFS= read -r f; do
        [[ -n "$f" ]] && printf 'missing-hook-script\t%s\n' "$f"
      done

  # (b) .ps1: on disk but not registered
  comm -13 <(printf '%s\n' "$registered_ps1" | grep -v '^$') \
           <(printf '%s\n' "$ps1_files" | grep -v '^$') \
    | while IFS= read -r f; do
        [[ -n "$f" ]] && printf 'orphan-hook-script\t%s\n' "$f"
      done

  # (c) .sh: for each registered .sh (except dispatch.sh), must exist
  while IFS= read -r f; do
    [[ -z "$f" || "$f" == "dispatch.sh" ]] && continue
    if ! printf '%s\n' "$sh_files" | grep -qxF "$f"; then
      printf 'missing-sh-impl\t%s\n' "$f"
    fi
  done <<< "$registered_sh"

  # (d) .sh: on disk but not registered (orphans, exclude dispatch.sh)
  while IFS= read -r f; do
    [[ -z "$f" || "$f" == "dispatch.sh" ]] && continue
    if ! printf '%s\n' "$registered_sh" | grep -qxF "$f"; then
      printf 'orphan-sh-script\t%s\n' "$f"
    fi
  done <<< "$sh_files"

  # (e) dispatch.sh must exist on disk
  if ! printf '%s\n' "$sh_files" | grep -qxF "dispatch.sh"; then
    printf 'missing-dispatch-sh\tdispatch.sh\n'
  fi

  # (e2) dispatch.sh must be referenced in every registered hook command chain
  {
    local dispatch_refs total_chains
    dispatch_refs=$(_facts_jq '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | map(select(contains("dispatch.sh"))) | length' "$FACTS_HOOKS_JSON")
    total_chains=$(_facts_jq '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | length' "$FACTS_HOOKS_JSON")
    if [[ "$dispatch_refs" -ne "$total_chains" ]]; then
      printf 'missing-dispatch-sh\tdispatch.sh\n'
    fi
  }

  # (f) unknown event names
  while IFS= read -r e; do
    [[ -z "$e" ]] && continue
    if ! printf '%s\n' "$HOOKCHECK_VALID_EVENTS" | grep -qxF -- "$e"; then
      printf 'invalid-hook-event\t%s\n' "$e"
    fi
  done <<< "$events"

  # (g) .ps1: every script must pin PowerShell 7 (first line '#Requires -Version 7.0')
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$FACTS_HOOKS_DIR/$f" ]] || continue
    first="$(head -n 1 "$FACTS_HOOKS_DIR/$f" | tr -d '\r')"
    if [[ "$first" != '#Requires -Version 7.0' ]]; then
      printf 'missing-requires-ps7\t%s\n' "$f"
    fi
  done <<< "$ps1_files"

  # (h) .sh: every script must start with #!/bin/sh
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$FACTS_HOOKS_DIR/$f" ]] || continue
    first="$(head -n 1 "$FACTS_HOOKS_DIR/$f" | tr -d '\r')"
    if [[ "$first" != '#!/bin/sh' ]]; then
      printf 'missing-sh-shebang\t%s\n' "$f"
    fi
  done <<< "$sh_files"

  # (i) .sh: every script must contain 'set -u'
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$FACTS_HOOKS_DIR/$f" ]] || continue
    if ! grep -q '^set -u' "$FACTS_HOOKS_DIR/$f"; then
      printf 'missing-set-u\t%s\n' "$f"
    fi
  done <<< "$sh_files"

  # (j) dispatch.sh: allowlist must include all registered hook names
  if [[ -f "$FACTS_HOOKS_DIR/dispatch.sh" ]]; then
    # Extract the case statement pattern from dispatch.sh
    # Look for lines like: "  hook1|hook2|hook3) ;;" between "case "$hook" in" and "esac"
    # Extract the first pattern line (before the *) catch-all), then extract just the pattern part
    dispatch_line=$(sed -n '/^[[:space:]]*case "\$hook" in$/,/^[[:space:]]*esac$/p' "$FACTS_HOOKS_DIR/dispatch.sh" 2>/dev/null | \
                    grep -v '^\*' | grep -v '^[[:space:]]*case' | grep -v '^[[:space:]]*esac' | head -1)
    # Extract pattern: everything before the closing paren
    dispatch_pattern=$(printf '%s' "$dispatch_line" | sed 's/^[[:space:]]*//; s/[[:space:]]*)[[:space:]]*;;.*//')

    # Convert pipe-separated pattern to a sorted list of hook names (without .sh extension)
    allowlist_names=$(printf '%s' "$dispatch_pattern" | tr '|' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u)

    # Compare: every registered hook name (except dispatch.sh itself) must appear in allowlist
    # Note: $registered_sh contains names WITH .sh extension (e.g., stop-peer-review-gate.sh),
    # but allowlist_names has them WITHOUT the extension. Strip .sh for comparison.
    while IFS= read -r hook_name; do
      [[ -z "$hook_name" || "$hook_name" == "dispatch.sh" ]] && continue
      # Remove .sh extension for comparison
      hook_base="${hook_name%.sh}"
      if ! printf '%s\n' "$allowlist_names" | grep -qxF "$hook_base"; then
        printf 'missing-dispatch-allowlist\t%s\n' "$hook_name"
      fi
    done <<< "$registered_sh"
  fi
}
