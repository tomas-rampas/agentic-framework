#!/usr/bin/env bash
# facts.sh - Single shared facts layer for the anti-drift consistency system.
#
# Every fact exposed here is DERIVED at runtime from claude.json + the
# filesystem. There are NO hardcoded agent names, counts, or lists. This file
# is meant to be SOURCED (not executed) by validators and, later, generators:
#
#     source "$(dirname "$0")/lib/facts.sh"
#     fact_agents
#
# Conventions:
#   - Functions print to stdout, one item per line (or TAB-separated pairs).
#   - The repo root is resolved robustly so callers work from any CWD.
#   - All lookups go through jq against $FACTS_CLAUDE_JSON.
#
# Requirements: bash, jq.

# --- guard against double-sourcing -----------------------------------------
if [[ -n "${__FACTS_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__FACTS_SH_LOADED=1

# --- repo root resolution ---------------------------------------------------
# Resolution order:
#   1. FRAMEWORK_ROOT env override (explicit, highest precedence). Used by the
#      test harness to pin resolution to an isolated temp copy of the repo even
#      when that copy happens to live inside an unrelated git working tree (where
#      `git rev-parse` would otherwise resolve to the WRONG root). Must point at
#      a directory containing claude.json.
#   2. git (`git rev-parse --show-toplevel`) for normal in-repo use.
#   3. script-relative walk-up from this file's location so the library keeps
#      working inside a tarball / detached / non-git checkout (e.g. a `cp -r`
#      temp copy with no .git).
#   4. CWD as a last resort.
_facts_resolve_root() {
  local here git_root
  # 1. explicit override (must actually look like the framework root)
  if [[ -n "${FRAMEWORK_ROOT:-}" && -f "${FRAMEWORK_ROOT}/claude.json" ]]; then
    ( cd "${FRAMEWORK_ROOT}" 2>/dev/null && pwd ) && return 0
  fi
  # 2. git
  if git_root="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$git_root" ]]; then
    printf '%s\n' "$git_root"
    return 0
  fi
  # ${BASH_SOURCE[0]} is scripts/lib/facts.sh -> repo root is two levels up.
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
  if [[ -n "$here" && -f "$here/claude.json" ]]; then
    printf '%s\n' "$here"
    return 0
  fi
  # last resort: CWD
  pwd
}

FACTS_REPO_ROOT="${FACTS_REPO_ROOT:-$(_facts_resolve_root)}"
FACTS_CLAUDE_JSON="${FACTS_CLAUDE_JSON:-$FACTS_REPO_ROOT/claude.json}"
FACTS_AGENTS_DIR="${FACTS_AGENTS_DIR:-$FACTS_REPO_ROOT/agents}"
FACTS_HOOKS_DIR="${FACTS_HOOKS_DIR:-$FACTS_REPO_ROOT/hooks}"
FACTS_HOOKS_JSON="${FACTS_HOOKS_JSON:-$FACTS_REPO_ROOT/hooks/hooks.json}"
FACTS_SKILLS_DIR="${FACTS_SKILLS_DIR:-$FACTS_REPO_ROOT/skills}"
FACTS_COMMANDS_DIR="${FACTS_COMMANDS_DIR:-$FACTS_REPO_ROOT/commands}"
FACTS_SETTINGS_TEMPLATE="${FACTS_SETTINGS_TEMPLATE:-$FACTS_REPO_ROOT/settings.template.json}"

export FACTS_REPO_ROOT FACTS_CLAUDE_JSON FACTS_AGENTS_DIR FACTS_HOOKS_DIR
export FACTS_HOOKS_JSON FACTS_SKILLS_DIR FACTS_COMMANDS_DIR FACTS_SETTINGS_TEMPLATE

# --- internal helpers -------------------------------------------------------
_facts_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'facts.sh: ERROR: jq is required but not installed.\n' >&2
    return 127
  fi
}

_facts_require_claude_json() {
  if [[ ! -f "$FACTS_CLAUDE_JSON" ]]; then
    printf 'facts.sh: ERROR: claude.json not found at %s\n' "$FACTS_CLAUDE_JSON" >&2
    return 1
  fi
}

# _facts_jq - jq wrapper that normalizes line endings to LF.
# Some Windows/native jq builds emit CRLF on stdout regardless of input; that
# stray CR breaks comm/diff/string comparisons downstream. Strip it here so
# every fact is guaranteed LF-only and byte-clean on every platform.
_facts_jq() {
  # Return jq's exit status (not tr's) via PIPESTATUS, so a jq failure is
  # detectable by callers regardless of whether they have `set -o pipefail`
  # (e.g. the `_facts_jq ... || cat` fallback in validate-consistency.sh).
  jq "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

# --- agent facts ------------------------------------------------------------

# fact_agents - sorted agent names from claude.json .sub_agents | keys
fact_agents() {
  _facts_require_jq || return $?
  _facts_require_claude_json || return $?
  _facts_jq -r '.sub_agents | keys[]' "$FACTS_CLAUDE_JSON" | LC_ALL=C sort
}

# fact_agent_files - sorted basenames (without .md) of agents/*.md
fact_agent_files() {
  local f base
  shopt -s nullglob
  for f in "$FACTS_AGENTS_DIR"/*.md; do
    base="$(basename "$f")"
    printf '%s\n' "${base%.md}"
  done | LC_ALL=C sort
  shopt -u nullglob
}

# fact_categories - "category<TAB>agent" pairs from .agent_categories
fact_categories() {
  _facts_require_jq || return $?
  _facts_require_claude_json || return $?
  _facts_jq -r '.agent_categories | to_entries[] | .key as $c | .value[] | "\($c)\t\(.)"' \
    "$FACTS_CLAUDE_JSON"
}

# fact_models - "agent<TAB>model" from .sub_agents. The model value is the tier
# shorthand (opus/sonnet/haiku) - i.e. a key of .consistency.model_shorthand_map
# - which is the single source of truth shared with each agents/<a>.md frontmatter.
fact_models() {
  _facts_require_jq || return $?
  _facts_require_claude_json || return $?
  _facts_jq -r '.sub_agents | to_entries[] | "\(.key)\t\(.value.model)"' "$FACTS_CLAUDE_JSON" \
    | LC_ALL=C sort
}

# --- consistency-block facts ------------------------------------------------

# fact_deprecated - dead/legacy agent names that must not appear as references
fact_deprecated() {
  _facts_require_jq || return $?
  _facts_require_claude_json || return $?
  _facts_jq -r '.consistency.deprecated_agent_names // [] | .[]' "$FACTS_CLAUDE_JSON"
}

# fact_model_shorthand <shorthand> - resolve a shorthand (opus/sonnet/haiku)
# to its full model id via .consistency.model_shorthand_map. Prints nothing
# and returns 1 if the shorthand is unknown.
# Library accessor: retained for shorthand->runtime-id resolution (dispatch /
# deploy tooling). Check 7 compares shorthand directly, so it has no in-repo
# caller today.
fact_model_shorthand() {
  local sh="${1:-}"
  _facts_require_jq || return $?
  _facts_require_claude_json || return $?
  if [[ -z "$sh" ]]; then
    printf 'facts.sh: fact_model_shorthand requires a shorthand argument\n' >&2
    return 2
  fi
  local id
  id="$(_facts_jq -r --arg s "$sh" '.consistency.model_shorthand_map[$s] // empty' \
        "$FACTS_CLAUDE_JSON")"
  if [[ -z "$id" ]]; then
    return 1
  fi
  printf '%s\n' "$id"
}

# --- hook facts (real hook architecture) ------------------------------------
# Hooks are PowerShell scripts in hooks/*.ps1, executed by Claude Code only when
# registered in hooks/hooks.json (plugin format). hooks.json is the
# tracked, canonical registration.

_facts_require_hooks_json() {
  if [[ ! -f "$FACTS_HOOKS_JSON" ]]; then
    printf 'facts.sh: ERROR: hooks.json not found at %s\n' "$FACTS_HOOKS_JSON" >&2
    return 1
  fi
}

# fact_hook_events - event names used in hooks.json hooks block
fact_hook_events() {
  _facts_require_jq || return $?
  _facts_require_hooks_json || return $?
  _facts_jq -r '.hooks // {} | keys[]' "$FACTS_HOOKS_JSON" | LC_ALL=C sort
}

# fact_registered_hook_scripts - sorted basenames of every *.ps1 referenced in
# hook command strings in hooks.json. Uses jq scan() to extract from shell-form chains.
# Parity check only; does not inspect command strings for appended shell content (dev/CI lint, not a runtime boundary).
fact_registered_hook_scripts() {
  _facts_require_jq || return $?
  _facts_require_hooks_json || return $?
  _facts_jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | .[] | scan("[a-zA-Z0-9._-]+[.]ps1") | sub("^.*/"; "")' \
      "$FACTS_HOOKS_JSON" | LC_ALL=C sort -u
}

# fact_registered_sh_scripts - sorted basenames of every *.sh referenced in
# hook command strings in hooks.json. Extracts hook names from dispatch.sh arguments
# and derives expected .sh basenames (name.sh), plus dispatch.sh itself.
# Parity check only; does not inspect command strings for appended shell content (dev/CI lint, not a runtime boundary).
fact_registered_sh_scripts() {
  _facts_require_jq || return $?
  _facts_require_hooks_json || return $?
  # Extract hook names from dispatch.sh arguments (the word after dispatch.sh in the chain)
  # and convert to .sh basenames, then add dispatch.sh itself.
  # NOTE: The regex REQUIRES hook names to follow dispatch.sh separated by a space or quote
  # (scan pattern: 'dispatch[.]sh[" ] +([a-zA-Z0-9._-]+)'). Unquoted names without space
  # will silently extract nothing; the orphan-sh-script check catches these loudly later.
  {
    _facts_jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty] | .[] | scan("dispatch[.]sh[\" ] +([a-zA-Z0-9._-]+)") | .[0] + ".sh"' \
        "$FACTS_HOOKS_JSON"
    printf 'dispatch.sh\n'
  } | LC_ALL=C sort -u
}

# fact_hook_sh_impl_files - sorted basenames of hooks/*.sh on disk
# (hook implementations + dispatch.sh)
fact_hook_sh_impl_files() {
  local f
  shopt -s nullglob
  for f in "$FACTS_HOOKS_DIR"/*.sh; do basename "$f"; done | LC_ALL=C sort
  shopt -u nullglob
}

# fact_hook_script_files - sorted basenames of hooks/*.ps1 on disk
fact_hook_script_files() {
  local f
  shopt -s nullglob
  for f in "$FACTS_HOOKS_DIR"/*.ps1; do basename "$f"; done | LC_ALL=C sort
  shopt -u nullglob
}

# _facts_count_hook_commands - number of registered hook command entries (one
# script registered under N events counts N times). Retained as the accessor
# for the registration-entry unit; no in-repo caller today — fact_counts uses
# distinct scripts (the "Hook Scripts" docs headline unit) instead.
_facts_count_hook_commands() {
  _facts_require_jq || return $?
  if [[ ! -f "$FACTS_HOOKS_JSON" ]]; then printf '0\n'; return 0; fi
  _facts_jq -r '[.hooks // {} | to_entries[] | .value[]? | .hooks[]?] | length' \
    "$FACTS_HOOKS_JSON"
}

# --- skill / command facts ---------------------------------------------------

# fact_skills - sorted skill names. Canonical layout is skills/<name>/SKILL.md
# (the only layout Claude Code loads); flat skills/*.md files are counted too
# while they still exist so the derived count stays truthful mid-migration.
fact_skills() {
  local f b
  {
    shopt -s nullglob
    for f in "$FACTS_SKILLS_DIR"/*/SKILL.md; do
      basename "$(dirname "$f")"
    done
    for f in "$FACTS_SKILLS_DIR"/*.md; do
      b="$(basename "$f")"
      printf '%s\n' "${b%.md}"
    done
    shopt -u nullglob
  } | LC_ALL=C sort
}

# fact_commands - sorted basenames (without .md) of commands/*.md
fact_commands() {
  local f b
  shopt -s nullglob
  for f in "$FACTS_COMMANDS_DIR"/*.md; do
    b="$(basename "$f")"
    printf '%s\n' "${b%.md}"
  done | LC_ALL=C sort
  shopt -u nullglob
}

# --- derived counts ---------------------------------------------------------

# fact_counts - emit derived counts as key=value lines.
#   agents   = number of registered sub_agents
#   hooks    = number of DISTINCT hook scripts registered in hooks/hooks.json
#              (one script may be registered under several events; the docs
#              headline says "Hook Scripts", so scripts is the truthful unit)
#   skills   = number of skills (skills/<name>/SKILL.md dirs + legacy flat skills/*.md)
#   commands = number of commands/*.md
fact_counts() {
  local agents hooks skills commands
  agents="$(fact_agents | grep -c . || true)"
  hooks="$(fact_registered_hook_scripts | grep -c . || true)"
  skills="$(fact_skills | grep -c . || true)"
  commands="$(fact_commands | grep -c . || true)"
  printf 'agents=%s\n' "$agents"
  printf 'hooks=%s\n' "$hooks"
  printf 'skills=%s\n' "$skills"
  printf 'commands=%s\n' "$commands"
}

# fact_count <key> - convenience accessor: print the value for a single count
# key emitted by fact_counts (e.g. fact_count agents).
fact_count() {
  local key="${1:?fact_count requires a key}"
  fact_counts | awk -F= -v k="$key" '$1==k {print $2; found=1} END{exit !found}'
}
