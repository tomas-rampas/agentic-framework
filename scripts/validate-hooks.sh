#!/usr/bin/env bash
# validate-hooks.sh - Hook architecture validation (real Claude Code hooks).
#
# Thin wrapper over the shared hook checks in scripts/lib/hookcheck.sh (the same
# logic validate-consistency.sh runs as check 3, so the two cannot drift):
#   - every hook script registered in hooks/hooks.json exists in hooks/
#   - every hooks/*.ps1 is registered (no dead scripts)
#   - every registered event is a real Claude Code hook event
#   - every hook script pins PowerShell 7 ('#Requires -Version 7.0')
# Plus a local deprecated-name scan over the hook scripts.

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
  n_scripts="$(fact_hook_script_files | grep -c . || true)"
  n_events="$(fact_hook_events | grep -c . || true)"
  echo "OK: $n_scripts hook script(s) registered across $n_events event(s); no orphans; all events valid; all pin PS7"
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

echo ""
echo "================================"
if [[ "$ERRORS" -eq 0 ]]; then
  echo "Hook validation passed"
  exit 0
else
  echo "Found $ERRORS error(s)"
  exit 1
fi
