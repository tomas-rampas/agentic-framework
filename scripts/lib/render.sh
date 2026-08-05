#!/usr/bin/env bash
# render.sh - One render function per generated documentation block.
#
# Every render_* function below builds the EXACT text that belongs inside a
# marker region, reading ONLY from the canonical sources:
#   - scripts/lib/facts.sh  (derived agent set / counts)
#   - claude.json           (.agent_categories, .consistency.doc_blocks, .sub_agents.*.focus)
#
# Hard rules:
#   - Output is LF-only (we route jq output through facts.sh's CR-stripping
#     wrapper, and printf emits LF on every platform).
#   - The text produced for the CURRENT (correct) tree MUST be byte-identical to
#     what already lives between the markers, so the first `--write` is a no-op
#     on visible content (idempotency / clean round-trip).
#   - No hardcoded counts or agent names: everything is derived.
#
# This file is meant to be SOURCED (it depends on facts.sh being loaded):
#     source "$(dirname "$0")/lib/facts.sh"
#     source "$(dirname "$0")/lib/render.sh"
#
# Requirements: bash, jq (via facts.sh).

# --- guard against double-sourcing -----------------------------------------
if [[ -n "${__RENDER_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__RENDER_SH_LOADED=1

# Ensure facts.sh is available (it defines _facts_jq, FACTS_CLAUDE_JSON, etc.).
if [[ -z "${__FACTS_SH_LOADED:-}" ]]; then
  # Best-effort autoload from the same lib directory.
  # shellcheck source=scripts/lib/facts.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/facts.sh"
fi

# ---------------------------------------------------------------------------
# Block: list-agents-summary
#   Renders the data-bearing lines of the JSON `summary` object inside the
#   ```json sample in commands/list-agents.md. The category map is single-
#   sourced: each doc-facing key sums the sizes of one or more REAL
#   .agent_categories groups, as declared in
#   .consistency.doc_blocks.list_agents_summary_categories (an ordered object,
#   so jq's key order == the order we emit, matching the existing doc).
#
#   Emitted text (4/6-space indentation, matching the sample's nesting):
#       "total_agents": <N>,
#       "ready": <N>,
#       "unavailable": 0,
#       "categories": {
#         "<doc_key>": <sum>,
#         ...
#         "<last_doc_key>": <sum>
#       }
#
#   total_agents/ready are derived from the agent registry; unavailable is a
#   structural literal (no source of truth for "unavailable" agents exists -
#   every registered agent is enabled). The trailing closing brace of the
#   categories object is part of the region; the OUTER summary `}` is left
#   outside the marker region.
# ---------------------------------------------------------------------------
render_list_agents_summary() {
  local total ready
  total="$(fact_count agents)"
  ready="$total"          # all registered agents are enabled => ready == total

  # Build "<doc_key>=<sum>" lines, preserving the declared order, where <sum>
  # is the total membership of all mapped .agent_categories groups. jq does the
  # arithmetic against the live .agent_categories so the counts can never drift.
  local lines
  lines="$(_facts_jq -r '
    .agent_categories as $cats
    | .consistency.doc_blocks.list_agents_summary_categories
    | to_entries[]
    | .key as $doc
    | ([.value[] | ($cats[.] // []) | length] | add // 0) as $sum
    | "\($doc)=\($sum)"
  ' "$FACTS_CLAUDE_JSON")" || return 1

  # Emit the fixed leading triple.
  printf '    "total_agents": %s,\n' "$total"
  printf '    "ready": %s,\n' "$ready"
  printf '    "unavailable": 0,\n'
  printf '    "categories": {\n'

  # Emit each category line; the LAST one omits the trailing comma (valid JSON).
  local n i key val
  n="$(printf '%s\n' "$lines" | grep -c .)"
  i=0
  while IFS='=' read -r key val; do
    [[ -z "$key" ]] && continue
    i=$((i + 1))
    if [[ "$i" -lt "$n" ]]; then
      printf '      "%s": %s,\n' "$key" "$val"
    else
      printf '      "%s": %s\n' "$key" "$val"
    fi
  done <<< "$lines"

  # Close the categories object. NOTE: printf with no trailing \n here; the
  # markers layer adds exactly one final LF for the region.
  printf '    }'
}

# ---------------------------------------------------------------------------
# Block: framework-stats
#   Renders the README footer's headline stats line. Every number is derived
#   (fact_counts) and the version comes from claude.json, so the footer can
#   never drift from reality. Emitted WITHOUT a trailing newline (the markers
#   layer adds exactly one final LF for the region).
# ---------------------------------------------------------------------------
render_framework_stats() {
  local agents hooks skills commands version
  agents="$(fact_count agents)"     || return 1
  hooks="$(fact_count hooks)"       || return 1
  skills="$(fact_count skills)"     || return 1
  commands="$(fact_count commands)" || return 1
  version="$(_facts_jq -r '.version // "0.0.0"' "$FACTS_CLAUDE_JSON")" || return 1
  printf '**Built for Claude Code CLI • %s Specialized Agents • %s Hook Scripts • %s Skills • %s Commands • v%s**' \
    "$agents" "$hooks" "$skills" "$commands" "$version"
}

# ---------------------------------------------------------------------------
# Block: team-presentation-stats
#   Renders the ENTIRE "By the numbers" table in docs/team-presentation.md,
#   header row and separator included. The whole table is one region on purpose:
#   an HTML comment placed between two markdown table rows terminates the table
#   in GFM, so per-row markers are not an option.
#
#   Every row is derived at runtime:
#     agents/skills/commands  -> fact_counts (claude.json + filesystem)
#     categories / tiers      -> claude.json .agent_categories / .sub_agents[].model
#     hook pairs              -> hooks/<name>.ps1 that have a matching <name>.sh
#     MCP servers             -> mcp-plugin/.mcp.json .mcpServers (keys_unsorted,
#                                so the listed order follows the file)
#     validator checks        -> the `_check_on <n>` call registry inside
#                                scripts/validate-consistency.sh (self-registering;
#                                nothing is hardcoded)
#     test suites             -> tests/*.test.* files
#     CI jobs                 -> top-level keys under `jobs:` in
#                                .github/workflows/consistency.yml
#
#   FRESHNESS COUPLING (know this before editing the repo): unlike the other two
#   blocks, this one reads well beyond claude.json — hooks/, tests/,
#   .github/workflows/consistency.yml and the validator SOURCE all feed rows. So
#   adding a hook pair, a test suite, a CI job, or a check makes this block STALE
#   until `generate-docs.sh --write` is re-run. In particular a test harness that
#   MUTATES tests/ or the workflow in a working copy will see a STALE report that
#   is correct, not spurious-looking noise to be suppressed.
#
#   The old "Test assertions" row was DELETED rather than generated: assertion
#   totals are runtime facts of a suite execution, so no static source can derive
#   them — which is exactly why that row drifted repeatedly. The derived
#   "Test suites" row replaces it.
#
#   Emitted WITHOUT a trailing newline (the markers layer adds exactly one).
# ---------------------------------------------------------------------------
render_team_presentation_stats() {
  local root="$FACTS_REPO_ROOT"
  local agents skills commands categories tiers hook_pairs
  local mcp_count mcp_list checks suites job_count job_list

  agents="$(fact_count agents)"     || return 1
  skills="$(fact_count skills)"     || return 1
  commands="$(fact_count commands)" || return 1

  categories="$(_facts_jq -r '.agent_categories | keys | length' "$FACTS_CLAUDE_JSON")" || return 1
  tiers="$(_facts_jq -r '[.sub_agents[].model] | unique | length' "$FACTS_CLAUDE_JSON")" || return 1

  # Hook PAIRS: a .ps1 implementation with the matching .sh beside it. dispatch.sh
  # has no .ps1 counterpart and is correctly not counted as a pair.
  local f base
  hook_pairs=0
  shopt -s nullglob
  for f in "$FACTS_HOOKS_DIR"/*.ps1; do
    base="${f%.ps1}"
    [[ -f "$base.sh" ]] && hook_pairs=$((hook_pairs + 1))
  done
  shopt -u nullglob

  local mcp_json="$root/mcp-plugin/.mcp.json"
  mcp_count="$(_facts_jq -r '.mcpServers // {} | keys | length' "$mcp_json")" || return 1
  mcp_list="$(_facts_jq -r '.mcpServers // {} | keys_unsorted | join(", ")' "$mcp_json")" || return 1

  # Validator check count: every check body is entered through a `_check_on <n>`
  # call, so that call registry IS the check list. Counting it means adding a
  # check updates this row automatically. DISTINCT numbers, not call sites: a
  # check accidentally registered twice must not inflate the row.
  checks="$(grep -oE '^_check_on [0-9]+ ' "$root/scripts/validate-consistency.sh" \
            | awk '{print $2}' | LC_ALL=C sort -u | grep -c .)" || return 1

  suites=0
  shopt -s nullglob
  for f in "$root"/tests/*.test.*; do suites=$((suites + 1)); done
  shopt -u nullglob

  # Top-level keys under `jobs:` in the CI workflow (two-space indented, bare key).
  job_list="$(awk '
    /^jobs:/            { in_jobs = 1; next }
    in_jobs && /^[^[:space:]#]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      gsub(/^  |:[[:space:]]*$/, "", $0); printf "%s%s", (n++ ? ", " : ""), $0
    }
  ' "$root/.github/workflows/consistency.yml")" || return 1
  # An empty job list yields "" from awk, never "0" — so guard explicitly rather
  # than relying on a field count of the empty string.
  if [[ -z "$job_list" ]]; then
    job_count=0
  else
    job_count="$(printf '%s' "$job_list" | awk -F', ' '{print NF}')"
  fi

  printf '| | |\n'
  printf '|---|---|\n'
  printf '| Specialized agents | %s (%s categories, %s model tiers) |\n' "$agents" "$categories" "$tiers"
  printf '| Hooks | %s .ps1/.sh implementation pairs |\n' "$hook_pairs"
  printf '| Skills | %s loadable knowledge modules |\n' "$skills"
  printf '| Commands | %s management commands |\n' "$commands"
  printf '| MCP servers | %s (%s) |\n' "$mcp_count" "$mcp_list"
  printf '| Validator checks | %s, all derived at runtime |\n' "$checks"
  printf '| Test suites | %s automated suites under tests/ |\n' "$suites"
  printf '| CI jobs | %s (%s) |' "$job_count" "$job_list"
}

# ---------------------------------------------------------------------------
# render_focus <agent>
#   Helper exposing the single-sourced focus string for one agent (from
#   claude.json .sub_agents[<agent>].focus). Returns non-zero if absent.
#   Available for any future README-table generation; the README tables are
#   intentionally NOT generated in this phase (grouping cannot round-trip from
#   .agent_categories - see scripts/generate-docs.sh notes), but the validator
#   uses this to cross-check the prose table against the canonical field.
# ---------------------------------------------------------------------------
render_focus() {
  local agent="${1:?render_focus requires an agent name}" val
  val="$(_facts_jq -r --arg a "$agent" '.sub_agents[$a].focus // empty' "$FACTS_CLAUDE_JSON")" || return 1
  [[ -n "$val" ]] || return 1
  printf '%s' "$val"
}
