#!/usr/bin/env bash
# generate-docs.sh - Single-source documentation generator.
#
# Makes claude.json (+ the filesystem, via facts.sh) the single source of truth
# for high-drift documentation blocks. Each generated block lives inside a
# marker region:
#
#     <!-- BEGIN GENERATED: <id> -->
#     ...rendered content...
#     <!-- END GENERATED: <id> -->
#
# Modes:
#   --write   Rewrite every registered marker region in place from the current
#             canonical sources. Idempotent: on the correct tree this changes
#             nothing visible (only ever the rendered bytes, which already match).
#   --check   Render each block to memory and compare against what is currently
#             between the markers. Exits non-zero and lists every STALE file
#             (drifted block) without modifying anything. Intended for CI.
#
# Exit codes:
#   0  success (--write done, or --check found everything fresh)
#   1  --check found stale block(s), or a write failed
#   2  usage error / missing prerequisite / malformed markers
#
# Requirements: bash, jq, awk.

set -uo pipefail

# --- locate repo + libraries (robust to any CWD) ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/facts.sh
source "$SCRIPT_DIR/lib/facts.sh"
# shellcheck source=scripts/lib/markers.sh
source "$SCRIPT_DIR/lib/markers.sh"
# shellcheck source=scripts/lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"

ROOT="$FACTS_REPO_ROOT"

# --- output helpers ---------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
  C_CYN=$'\033[0;36m'; C_NC=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_NC=""
fi

# --- the block registry -----------------------------------------------------
# Each entry: "<relative-file>|<marker-id>|<render-function>"
# The render function must print the EXACT region content (LF, no trailing
# newline required - the markers layer normalizes that).
#
# NOTE ON COVERAGE: only blocks whose rendered text can be reproduced
# byte-for-byte from the canonical sources are listed here. The README "## Agents"
# tables are deliberately NOT generated: their section grouping and ordering
# (e.g. "Architecture & Analysis" merges system-architect with the
# quality_analysis agents while EXCLUDING product-owner, which README files
# under "Planning & Requirements") does not match claude.json .agent_categories
# and therefore cannot round-trip from it. Per the phase spec, correctness and
# idempotency beat coverage: those tables are left ungenerated and instead
# guarded by validate-consistency.sh (roster-presence + focus-text parity).
BLOCKS=(
  "commands/list-agents.md|list-agents-summary|render_list_agents_summary"
  "README.md|framework-stats|render_framework_stats"
  "docs/team-presentation.md|team-presentation-stats|render_team_presentation_stats"
)

usage() {
  cat <<'EOF'
Usage: generate-docs.sh (--write | --check)

  --write   Regenerate all marker regions in place from claude.json + facts.
  --check   Verify all marker regions are up to date; exit non-zero if stale.
  -h|--help Show this help.
EOF
}

# render_block <render-fn> -> stdout (LF, no enforced trailing newline)
render_block() {
  local fn="$1"
  "$fn"
}

do_write() {
  local rc=0 entry rel id fn file rendered
  for entry in "${BLOCKS[@]}"; do
    IFS='|' read -r rel id fn <<< "$entry"
    file="$ROOT/$rel"
    if [[ ! -f "$file" ]]; then
      printf '%sERROR%s target file missing: %s\n' "$C_RED" "$C_NC" "$rel" >&2
      rc=2; continue
    fi
    if ! markers_validate "$file" "$id"; then
      rc=2; continue
    fi
    rendered="$(render_block "$fn")" || { printf '%sERROR%s render failed: %s\n' "$C_RED" "$C_NC" "$id" >&2; rc=1; continue; }
    if markers_replace "$file" "$id" "$rendered"; then
      printf '%sWROTE%s %s [%s]\n' "$C_GRN" "$C_NC" "$rel" "$id"
    else
      printf '%sERROR%s write failed: %s [%s]\n' "$C_RED" "$C_NC" "$rel" "$id" >&2
      rc=1
    fi
  done
  return "$rc"
}

do_check() {
  local rc=0 entry rel id fn file rendered current stale_files=()
  for entry in "${BLOCKS[@]}"; do
    IFS='|' read -r rel id fn <<< "$entry"
    file="$ROOT/$rel"
    if [[ ! -f "$file" ]]; then
      printf '%sERROR%s target file missing: %s\n' "$C_RED" "$C_NC" "$rel" >&2
      rc=2; continue
    fi
    if ! markers_validate "$file" "$id"; then
      rc=2; continue
    fi
    rendered="$(render_block "$fn")" || { printf '%sERROR%s render failed: %s\n' "$C_RED" "$C_NC" "$id" >&2; rc=1; continue; }
    current="$(markers_extract "$file" "$id")" || { rc=2; continue; }
    # Normalize both sides to "exactly one trailing newline" before comparing,
    # mirroring what markers_replace writes, so trailing-newline noise never
    # produces a false "stale".
    if [[ "$(printf '%s\n' "$rendered")" == "$(printf '%s\n' "$current")" ]]; then
      printf '%sFRESH%s %s [%s]\n' "$C_GRN" "$C_NC" "$rel" "$id"
    else
      printf '%sSTALE%s %s [%s]\n' "$C_RED" "$C_NC" "$rel" "$id"
      stale_files+=("$rel [$id]")
      rc=1
    fi
  done
  if [[ "${#stale_files[@]}" -gt 0 ]]; then
    printf '\n%sStale generated block(s) detected - run: bash scripts/generate-docs.sh --write%s\n' "$C_YEL" "$C_NC" >&2
    local s
    for s in "${stale_files[@]}"; do printf '  - %s\n' "$s" >&2; done
  fi
  return "$rc"
}

# --- preflight --------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  printf '%sERROR%s jq is required but not installed.\n' "$C_RED" "$C_NC" >&2
  exit 2
fi

MODE=""
case "${1:-}" in
  --write) MODE="write" ;;
  --check) MODE="check" ;;
  -h|--help) usage; exit 0 ;;
  "" ) printf '%sERROR%s no mode given.\n\n' "$C_RED" "$C_NC" >&2; usage >&2; exit 2 ;;
  * )  printf '%sERROR%s unknown argument: %s\n\n' "$C_RED" "$C_NC" "$1" >&2; usage >&2; exit 2 ;;
esac

printf '%s== generate-docs (%s) :: repo %s ==%s\n' "$C_CYN" "$MODE" "$ROOT" "$C_NC"

if [[ "$MODE" == "write" ]]; then
  do_write; exit $?
else
  do_check; exit $?
fi
