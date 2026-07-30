#!/usr/bin/env bash
# validate-hooks.sh - Hook architecture validation (real Claude Code hooks).
#
# Thin wrapper over the shared hook checks in scripts/lib/hookcheck.sh (the same
# logic validate-consistency.sh runs as check 3, so the two cannot drift):
#   - every hook script registered in hooks/hooks.json exists (both .ps1 and .sh)
#   - every hooks/*.ps1 and hooks/*.sh is registered (no orphaned scripts)
#   - dispatch.sh exists and is referenced in all hook chains
#   - every hook chain's dispatch argument matches its .ps1 filename stem
#   - every registered event is a real Claude Code hook event
#   - every .ps1 hook script pins PowerShell 7 ('#Requires -Version 7.0')
#   - every .sh hook script has #!/bin/sh shebang and 'set -u' line
# Plus a local deprecated-name scan over the hook scripts, and a WARN-only scan
# of the user's settings.json for legacy (pre-plugin) duplicate registrations
# of the same hooks — those make every hook fire twice.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/facts.sh
source "$SCRIPT_DIR/lib/facts.sh"
# shellcheck source=scripts/lib/hookcheck.sh
source "$SCRIPT_DIR/lib/hookcheck.sh"

echo "Hook Architecture Validation"
echo "============================"
echo ""

ERRORS=0

# ---------------------------------------------------------------------------
# 1. Registration parity + event validity + PS7 pin (shared with check 3)
# ---------------------------------------------------------------------------
echo "Checking hook registration parity (hooks/hooks.json <-> hooks/*.ps1)..."
echo ""

PROBLEMS="$(hookcheck_problems)"
if [[ -n "$PROBLEMS" ]]; then
  while IFS=$'\t' read -r ptype subject; do
    [[ -z "$ptype" ]] && continue
    echo "ERROR [$ptype] $subject"
    ERRORS=$((ERRORS + 1))
  done <<< "$PROBLEMS"
else
  n_ps1_scripts="$(fact_hook_script_files | grep -c . || true)"
  n_sh_scripts="$(fact_hook_sh_impl_files | grep -c . || true)"
  n_events="$(fact_hook_events | grep -c . || true)"
  echo "OK: $n_ps1_scripts .ps1 + $n_sh_scripts .sh hook script(s) registered across $n_events event(s); dispatch chains coherent; all events valid"
fi

# ---------------------------------------------------------------------------
# 2. Deprecated agent references inside hook scripts
# ---------------------------------------------------------------------------
echo ""
echo "Checking for deprecated agent references in hooks/..."
echo ""

DEPRECATED="$(fact_deprecated)"
DEP_FOUND=0

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  shopt -s nullglob
  for f in "$FACTS_HOOKS_DIR"/*.ps1 "$FACTS_HOOKS_DIR"/*.sh; do
    # -w: word-boundary match so a deprecated token that happens to be a
    # substring of an unrelated identifier cannot false-positive.
    hits="$(grep -nwF "$name" "$f" 2>/dev/null)"
    if [[ -n "$hits" ]]; then
      echo "ERROR: deprecated name '$name' in $(basename "$f"):"
      while IFS= read -r ln; do [[ -n "$ln" ]] && echo "     $ln"; done <<< "$hits"
      DEP_FOUND=$((DEP_FOUND + 1))
      ERRORS=$((ERRORS + 1))
    fi
  done
  shopt -u nullglob
done <<< "$DEPRECATED"

if [[ "$DEP_FOUND" -eq 0 ]]; then
  ndep="$(printf '%s\n' "$DEPRECATED" | grep -c . || true)"
  echo "OK: no deprecated agent references found (checked ${ndep} names)"
fi

# ---------------------------------------------------------------------------
# 3. Legacy double-registration scan (WARN-only: environment-dependent, so it
#    never fails the run — repo validation must stay deterministic)
# ---------------------------------------------------------------------------
echo ""
echo "Checking user settings for legacy duplicate hook registrations..."
echo ""

# Since v4 the plugin registers hooks via hooks/hooks.json. A pre-v4 install
# also registered them in ~/.claude/settings.json; if that entry survived
# migration, every hook fires twice (two process spawns per event).
SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
DUP_FOUND=0
if [[ -f "$SETTINGS_FILE" ]] && _facts_jq empty "$SETTINGS_FILE" 2>/dev/null; then
  while IFS= read -r hook_sh; do
    [[ -z "$hook_sh" || "$hook_sh" == "dispatch.sh" ]] && continue
    hook_name="${hook_sh%.sh}"
    if _facts_jq -e --arg n "$hook_name" \
        '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | map(select(contains($n))) | length > 0' \
        "$SETTINGS_FILE" >/dev/null 2>&1; then
      echo "WARN: '$hook_name' is also registered in $SETTINGS_FILE — the plugin already registers it via hooks/hooks.json, so it fires TWICE per event. Remove the legacy entry (/agentic-framework:migrate-legacy automates this)."
      DUP_FOUND=$((DUP_FOUND + 1))
    fi
  done < <(fact_hook_sh_impl_files)
  if [[ "$DUP_FOUND" -eq 0 ]]; then
    echo "OK: no legacy duplicate hook registrations in user settings"
  fi
else
  echo "OK: no readable user settings file at $SETTINGS_FILE (nothing can double-fire)"
fi

echo ""
echo "================================"
if [[ "$ERRORS" -eq 0 ]]; then
  if [[ "$DUP_FOUND" -gt 0 ]]; then
    echo "Hook validation passed with $DUP_FOUND warning(s)"
  else
    echo "Hook validation passed"
  fi
  exit 0
else
  echo "Found $ERRORS error(s)"
  exit 1
fi
