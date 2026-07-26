#!/usr/bin/env bash
# validate-consistency.sh - Dynamic anti-drift consistency validator.
#
# Derives all "truth" at runtime from claude.json + the filesystem via the
# shared facts layer (scripts/lib/facts.sh). NOTHING is hardcoded: no agent
# names, no counts, no rosters. If the framework grows or shrinks, this script
# adapts automatically.
#
# It runs a battery of checks, prints a clear PASS/FAIL per check with the
# offending items, COLLECTS all failures (does not bail on the first), and
# exits non-zero if ANY blocking check fails. WARNING checks print but never
# affect the exit code.
#
# Usage:
#   bash scripts/validate-consistency.sh
#   echo "exit=$?"
#
# Requirements: bash, jq. (YAML validity is best-effort via python3/ruby.)

set -uo pipefail
# NOTE: -e is deliberately NOT set. We want to run every check and aggregate
# results; a non-zero from a single grep/diff must not abort the whole run.

# Force C collation so `comm`/`sort` agree on ordering on every locale. The
# facts layer sorts with `LC_ALL=C sort`; `comm` must use the same collation or
# it reports bogus missing/orphan diffs under a non-C user locale.
export LC_ALL=C

# --- locate + source the shared facts layer --------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/facts.sh
source "$SCRIPT_DIR/lib/facts.sh"
# render.sh provides render_focus() for prose-table focus-text parity (check 10).
# shellcheck source=scripts/lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"
# hookcheck.sh provides hookcheck_problems() for hook registration parity (check 3).
# shellcheck source=scripts/lib/hookcheck.sh
source "$SCRIPT_DIR/lib/hookcheck.sh"

ROOT="$FACTS_REPO_ROOT"

# --- output helpers ---------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[1;33m'
  C_CYN=$'\033[0;36m'; C_NC=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_NC=""
fi

BLOCKING_FAILURES=0
WARNINGS=0

pass()  { printf '  %sPASS%s  %s\n' "$C_GRN" "$C_NC" "$1"; }
fail()  { printf '  %sFAIL%s  %s\n' "$C_RED" "$C_NC" "$1"; BLOCKING_FAILURES=$((BLOCKING_FAILURES + 1)); }
warn()  { printf '  %sWARN%s  %s\n' "$C_YEL" "$C_NC" "$1"; WARNINGS=$((WARNINGS + 1)); }
info()  { printf '  %sINFO%s  %s\n' "$C_CYN" "$C_NC" "$1"; }
detail(){ printf '          %s\n' "$1"; }
section(){ printf '\n%s%s%s\n' "$C_CYN" "$1" "$C_NC"; }

# _esc_ere <string> - backslash-escape every ERE metacharacter in <string> so
# it can be embedded as a LITERAL inside a larger regex. Implemented in pure
# bash (substring membership, no sed/glob pattern parsing) so it is immune to
# platform sed quirks (POSIX collating symbols, backslash-in-bracket-class) and
# to metacharacters in the input itself. Replaces the previous
# `sed 's/[..]/\\&/g'`, which emitted a literal '&' on this platform's sed and
# silently failed to escape (false negatives).
_esc_ere() {
  local s="${1-}" out="" ch i
  local meta='.[]{}()*+?^$|\'
  local bs='\'
  for (( i=0; i<${#s}; i++ )); do
    ch="${s:i:1}"
    if [[ "$meta" == *"$ch"* ]]; then
      out="${out}${bs}${ch}"
    else
      out="${out}${ch}"
    fi
  done
  printf '%s' "$out"
}

# --- preflight --------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  printf '%sERROR%s jq is required but not installed.\n' "$C_RED" "$C_NC" >&2
  exit 2
fi

printf '%s================================================%s\n' "$C_CYN" "$C_NC"
printf '%s  Anti-Drift Consistency Validator%s\n' "$C_CYN" "$C_NC"
printf '%s  repo: %s%s\n' "$C_CYN" "$ROOT" "$C_NC"
printf '%s================================================%s\n' "$C_CYN" "$C_NC"

# Cache the canonical agent set once (sorted, newline-delimited).
AGENTS_SORTED="$(fact_agents)"
AGENT_FILES_SORTED="$(fact_agent_files)"

# ===========================================================================
# CHECK 1 - Registry <-> filesystem parity
# ===========================================================================
section "[1] Registry <-> filesystem parity (claude.json .sub_agents == agents/*.md)"
{
  missing_in_registry="$(comm -13 <(printf '%s\n' "$AGENTS_SORTED") <(printf '%s\n' "$AGENT_FILES_SORTED"))"
  orphan_md="$missing_in_registry"           # .md present, not registered
  missing_md="$(comm -23 <(printf '%s\n' "$AGENTS_SORTED") <(printf '%s\n' "$AGENT_FILES_SORTED"))"
  # missing_md: registered but no .md file

  ok=1
  if [[ -n "$missing_md" ]]; then
    ok=0
    fail "Agents registered in claude.json with NO agents/<name>.md file:"
    while IFS= read -r a; do [[ -n "$a" ]] && detail "missing-md: $a"; done <<< "$missing_md"
  fi
  if [[ -n "$orphan_md" ]]; then
    ok=0
    fail "Orphan agents/<name>.md files NOT registered in claude.json:"
    while IFS= read -r a; do [[ -n "$a" ]] && detail "orphan-md: $a"; done <<< "$orphan_md"
  fi
  if [[ "$ok" -eq 1 ]]; then
    pass "$(printf '%s\n' "$AGENTS_SORTED" | grep -c .) agents: registry and filesystem match exactly"
  fi
}

# ===========================================================================
# CHECK 2 - Category partition
# ===========================================================================
section "[2] Category partition (.agent_categories partitions all agents)"
{
  # Flatten category -> agent pairs.
  cat_pairs="$(fact_categories)"            # category<TAB>agent
  cat_agents_all="$(printf '%s\n' "$cat_pairs" | awk -F'\t' 'NF{print $2}')"
  cat_agents_sorted="$(printf '%s\n' "$cat_agents_all" | LC_ALL=C sort)"
  cat_agents_uniq="$(printf '%s\n' "$cat_agents_all" | LC_ALL=C sort -u)"

  ok=1

  # 2a: duplicates (agent in two groups)
  dups="$(printf '%s\n' "$cat_agents_sorted" | uniq -d)"
  if [[ -n "$dups" ]]; then
    ok=0
    fail "Agent(s) appear in more than one category:"
    while IFS= read -r a; do
      [[ -z "$a" ]] && continue
      groups="$(printf '%s\n' "$cat_pairs" | awk -F'\t' -v x="$a" '$2==x{print $1}' | paste -sd, -)"
      detail "duplicate: $a -> [$groups]"
    done <<< "$dups"
  fi

  # 2b: unknown agent (in a category but not a real agent)
  unknown="$(comm -23 <(printf '%s\n' "$cat_agents_uniq") <(printf '%s\n' "$AGENTS_SORTED"))"
  if [[ -n "$unknown" ]]; then
    ok=0
    fail "Category references unknown agent(s) (not in .sub_agents):"
    while IFS= read -r a; do [[ -n "$a" ]] && detail "unknown-in-category: $a"; done <<< "$unknown"
  fi

  # 2c: uncategorized agent (real agent missing from every category)
  uncategorized="$(comm -13 <(printf '%s\n' "$cat_agents_uniq") <(printf '%s\n' "$AGENTS_SORTED"))"
  if [[ -n "$uncategorized" ]]; then
    ok=0
    fail "Agent(s) not assigned to any category:"
    while IFS= read -r a; do [[ -n "$a" ]] && detail "uncategorized: $a"; done <<< "$uncategorized"
  fi

  if [[ "$ok" -eq 1 ]]; then
    ncat="$(printf '%s\n' "$cat_pairs" | awk -F'\t' 'NF{print $1}' | LC_ALL=C sort -u | grep -c .)"
    pass "$ncat categories cleanly partition all $(printf '%s\n' "$AGENTS_SORTED" | grep -c .) agents (no dup, no unknown, no gap)"
  fi
}

# ===========================================================================
# CHECK 3 - Hook registration parity (real hook architecture)
# ===========================================================================
# Hooks only execute when registered in hooks/hooks.json, so the
# tracked hooks.json and hooks/*.ps1 must agree exactly: every
# registered script exists, every script is registered (no dead code), every
# event name is a real Claude Code event, and every script pins PowerShell 7.
# Shared logic lives in scripts/lib/hookcheck.sh (also used by validate-hooks.sh).
section "[3] Hook registration parity (hooks/hooks.json <-> hooks/*.ps1)"
{
  problems="$(hookcheck_problems)"
  if [[ -n "$problems" ]]; then
    while IFS=$'\t' read -r ptype subject; do
      [[ -z "$ptype" ]] && continue
      case "$ptype" in
        no-hooks-block)       fail "hooks/hooks.json has no usable hooks block: $subject" ;;
        missing-hook-script)  fail "registered .ps1 hook script missing on disk: hooks/$subject"
                              detail "missing-hook-script: $subject" ;;
        orphan-hook-script)   fail ".ps1 hook script not registered in hooks/hooks.json: hooks/$subject"
                              detail "orphan-hook-script: $subject" ;;
        missing-sh-impl)      fail "registered hook missing .sh implementation: hooks/$subject"
                              detail "missing-sh-impl: $subject" ;;
        orphan-sh-script)     fail ".sh hook script not registered in hooks/hooks.json: hooks/$subject"
                              detail "orphan-sh-script: $subject" ;;
        missing-dispatch-sh)  fail "dispatch.sh missing from hooks/: $subject"
                              detail "missing-dispatch-sh: $subject" ;;
        missing-sh-shebang)   fail ".sh hook script lacks '#!/bin/sh' header: hooks/$subject"
                              detail "missing-sh-shebang: $subject" ;;
        missing-set-u)        fail ".sh hook script lacks 'set -u' line: hooks/$subject"
                              detail "missing-set-u: $subject" ;;
        missing-dispatch-allowlist) fail "dispatch.sh allowlist missing hook name: hooks/$subject"
                              detail "missing-dispatch-allowlist: $subject" ;;
        chain-name-mismatch)  fail "hook chain command mismatch: dispatch arg differs from .ps1 filename: $subject"
                              detail "chain-name-mismatch: $subject" ;;
        invalid-hook-event)   fail "unknown Claude Code hook event in hooks/hooks.json: $subject"
                              detail "invalid-hook-event: $subject" ;;
        missing-requires-ps7) fail ".ps1 hook script lacks '#Requires -Version 7.0' header: hooks/$subject"
                              detail "missing-requires-ps7: $subject" ;;
        *)                    fail "hookcheck: $ptype $subject" ;;
      esac
    done <<< "$problems"
  else
    n_scripts="$(fact_hook_script_files | grep -c . || true)"
    n_events="$(fact_hook_events | grep -c . || true)"
    pass "$n_scripts hook script(s) registered across $n_events event(s); parity OK (both .ps1 and .sh), all events valid, all pin PS7"
  fi
}

# ===========================================================================
# CHECK 4 - JSON validity (+ best-effort YAML validity)
# ===========================================================================
section "[4] JSON validity (claude.json, settings.template.json, plugin manifests, hooks/hooks.json) + YAML best-effort"
{
  json_bad=0 json_total=0
  # Collect target json files.
  json_files=()
  [[ -f "$ROOT/claude.json" ]] && json_files+=("$ROOT/claude.json")
  [[ -f "$ROOT/settings.template.json" ]] && json_files+=("$ROOT/settings.template.json")
  [[ -f "$ROOT/.claude-plugin/plugin.json" ]] && json_files+=("$ROOT/.claude-plugin/plugin.json")
  [[ -f "$ROOT/.claude-plugin/marketplace.json" ]] && json_files+=("$ROOT/.claude-plugin/marketplace.json")
  [[ -f "$ROOT/mcp-plugin/.claude-plugin/plugin.json" ]] && json_files+=("$ROOT/mcp-plugin/.claude-plugin/plugin.json")
  [[ -f "$ROOT/mcp-plugin/.mcp.json" ]] && json_files+=("$ROOT/mcp-plugin/.mcp.json")
  [[ -f "$ROOT/hooks/hooks.json" ]] && json_files+=("$ROOT/hooks/hooks.json")
  shopt -s nullglob
  for f in "$FACTS_HOOKS_DIR"/*.json; do
    # Skip hooks.json if already added above
    [[ "$(basename "$f")" != "hooks.json" ]] && json_files+=("$f")
  done
  shopt -u nullglob

  for f in "${json_files[@]}"; do
    json_total=$((json_total + 1))
    if ! jq empty "$f" >/dev/null 2>&1; then
      json_bad=$((json_bad + 1))
      fail "invalid JSON: ${f#"$ROOT"/}"
    fi
  done
  if [[ "$json_bad" -eq 0 ]]; then
    pass "all $json_total JSON files parse cleanly (jq empty)"
  fi

  # YAML best-effort.
  shopt -s nullglob
  yaml_files=("$FACTS_HOOKS_DIR"/*.yaml "$FACTS_HOOKS_DIR"/*.yml)
  shopt -u nullglob
  if [[ "${#yaml_files[@]}" -eq 0 ]]; then
    info "no YAML hook files present"
  else
    # Pick a YAML checker that ACTUALLY WORKS. `command -v python3` is not
    # enough on Windows, where the Microsoft Store "app execution alias" stub
    # is on PATH: it exits 0 while printing an install notice and cannot import
    # yaml. We therefore functionally probe each candidate (must print a known
    # token AND have the yaml module) before trusting it. If none qualifies we
    # SKIP with a notice rather than emit false "invalid YAML" failures.
    yaml_checker=""
    if python3 -c 'import yaml; print("__pyyaml_ok__")' 2>/dev/null | grep -q '__pyyaml_ok__'; then
      yaml_checker="python3"
    elif python -c 'import yaml; print("__pyyaml_ok__")' 2>/dev/null | grep -q '__pyyaml_ok__'; then
      yaml_checker="python"
    elif ruby -ryaml -e 'puts "__ruby_ok__"' 2>/dev/null | grep -q '__ruby_ok__'; then
      yaml_checker="ruby"
    fi

    if [[ -z "$yaml_checker" ]]; then
      info "YAML validity skipped (no working python+pyyaml or ruby): ${#yaml_files[@]} file(s)"
    else
      yaml_bad=0
      for f in "${yaml_files[@]}"; do
        if [[ "$yaml_checker" == "ruby" ]]; then
          if ! ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]))' "$f" >/dev/null 2>&1; then
            yaml_bad=$((yaml_bad + 1)); fail "invalid YAML: ${f#"$ROOT"/}"
          fi
        else
          if ! "$yaml_checker" -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$f" >/dev/null 2>&1; then
            yaml_bad=$((yaml_bad + 1)); fail "invalid YAML: ${f#"$ROOT"/}"
          fi
        fi
      done
      if [[ "$yaml_bad" -eq 0 ]]; then
        pass "all ${#yaml_files[@]} YAML file(s) valid (via $yaml_checker)"
      fi
    fi
  fi
}

# ===========================================================================
# CHECK 5 - Deprecated agent names
# ===========================================================================
section "[5] Deprecated agent names (no live references in config or active doc refs)"
{
  # Scope (per spec): hooks/*.json, claude.json, commands/*.md, skills/*.md.
  #
  # IMPORTANT - false-positive avoidance:
  #   The commands/*.md and skills/*.md files legitimately *document* the
  #   deprecated names (migration guides, validator examples that literally
  #   list old names). Flagging every prose mention would be wrong. We
  #   therefore distinguish a real, LIVE reference from documentation:
  #
  #     * Structured config (hooks/*.json, claude.json):
  #         flag a deprecated name used as a JSON string token  "<name>"
  #         (this is how a hook/agent reference is actually encoded).
  #     * Docs (commands/*.md, skills/*.md):
  #         flag ONLY an ACTIVE reference, i.e.
  #             agents/<name>.md            (a real prompt-file path)
  #             subagent_type: <name>       (a real routing directive)
  #             agent: <name> / "agent":"<name>"
  #         Prose mentions ("replace maker-agent with ...") are NOT flagged.
  #
  # This yields zero false positives on the corrected tree while still
  # catching any genuine resurrection of a dead agent name.

  deprecated="$(fact_deprecated)"
  ok=1

  json_scope=("$ROOT/claude.json" "$ROOT/settings.template.json")
  shopt -s nullglob
  for f in "$FACTS_HOOKS_DIR"/*.json; do json_scope+=("$f"); done
  # Both skill layouts are scanned: skills/<name>/SKILL.md is the canonical
  # (loadable) layout; flat skills/*.md is the legacy layout kept in scope so a
  # dead name cannot hide mid-migration.
  doc_scope=("$ROOT"/commands/*.md "$ROOT"/skills/*.md "$ROOT"/skills/*/SKILL.md)
  shopt -u nullglob

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue

    # Structured config: deprecated name as a JSON string token "<name>".
    # The canonical lists that legitimately enumerate these names all live under
    # the .consistency block (deprecated_agent_names /
    # model_shorthand_map). We exclude them STRUCTURALLY by deleting that block
    # with jq before scanning, rather than text-filtering by key name (which is
    # coupled to single-line JSON layout and breaks under `jq '.'` reformatting).
    # The literal token is matched with fixed-string grep (-F) so a name
    # containing a regex metacharacter still matches exactly and cannot break
    # the pattern.
    for f in "${json_scope[@]}"; do
      [[ -f "$f" ]] || continue
      # Strip .consistency so the canonical lists are never scanned. If jq fails
      # for any reason, fall back to scanning the raw file (fail-safe: catch more,
      # never silently skip).
      scan="$(_facts_jq 'del(.consistency)' "$f" 2>/dev/null || cat "$f")"
      hits="$(printf '%s\n' "$scan" | grep -nF "\"$name\"")"
      if [[ -n "$hits" ]]; then
        ok=0
        fail "deprecated name '$name' used as config token in ${f#"$ROOT"/}:"
        while IFS= read -r ln; do [[ -n "$ln" ]] && detail "$ln"; done <<< "$hits"
      fi
    done

    # Docs: only ACTIVE references (path / routing directive), not prose.
    # Only the variable part (<name>) is interpolated into this otherwise-fixed
    # structural regex, so we metachar-escape it with _esc_ere (a name with a
    # regex metachar can therefore neither break the pattern nor over-match).
    esc="$(_esc_ere "$name")"
    active_re="agents/${esc}\.md|subagent_type[\"']?[[:space:]]*[:=][[:space:]]*[\"']?${esc}([\"', )]|\$)|\"agent\"[[:space:]]*:[[:space:]]*\"${esc}\"|(^|[[:space:](=])agent[[:space:]]*:[[:space:]]*${esc}([[:space:],)]|\$)"
    for f in "${doc_scope[@]}"; do
      [[ -f "$f" ]] || continue
      hits="$(grep -nIE "$active_re" "$f" 2>/dev/null)"
      if [[ -n "$hits" ]]; then
        ok=0
        fail "deprecated name '$name' used as an ACTIVE reference in ${f#"$ROOT"/}:"
        while IFS= read -r ln; do [[ -n "$ln" ]] && detail "$ln"; done <<< "$hits"
      fi
    done
  done <<< "$deprecated"

  if [[ "$ok" -eq 1 ]]; then
    ndep="$(printf '%s\n' "$deprecated" | grep -c .)"
    pass "no live references to any of the $ndep deprecated names (prose docs ignored by design)"
  fi
}

# ===========================================================================
# CHECK 6 - Architecture / description strings
# ===========================================================================
section "[6] Architecture description strings match derived agent count + rosters"
{
  n_agents="$(printf '%s\n' "$AGENTS_SORTED" | grep -c .)"
  ok=1

  # 6a: claude.json .description contains "<n>-agent"
  desc="$(_facts_jq -r '.description // ""' "$FACTS_CLAUDE_JSON")"
  if printf '%s' "$desc" | grep -qE "(^|[^0-9])${n_agents}-agent([^0-9]|\$)"; then
    pass "claude.json .description references '${n_agents}-agent'"
  else
    # Surface any OTHER N-agent value present so the failure is actionable.
    found="$(printf '%s' "$desc" | grep -oE '[0-9]+-agent' | paste -sd, -)"
    ok=0
    fail "claude.json .description missing '${n_agents}-agent' (found: ${found:-none})"
    detail "description: $desc"
  fi

  [[ "$ok" -eq 1 ]] || true
}

# ===========================================================================
# CHECK 8 - Stated-count scan (curated, high-signal, blocking)
#   (Numbered 8 to match the spec; model parity is check 7 below.)
# ===========================================================================
section "[8] Stated-count scan (README/docs headline counts == derived values)"
{
  n_agents="$(fact_count agents)"
  n_hooks="$(fact_count hooks)"      # DISTINCT registered hook scripts (the docs headline unit)
  n_skills="$(fact_count skills)"
  n_commands="$(fact_count commands)"

  # Files to scan for headline counts. Skills are scanned in the canonical
  # skills/<name>/SKILL.md layout only: legacy flat skills/*.md are excluded
  # (pending migration/removal, their internal narratives carry historical
  # numbers that are not current declarations).
  scan_files=()
  [[ -f "$ROOT/README.md" ]] && scan_files+=("$ROOT/README.md")
  shopt -s nullglob
  for f in "$ROOT"/commands/*.md "$ROOT"/skills/*/SKILL.md; do scan_files+=("$f"); done
  shopt -u nullglob

  ok=1

  # _scan_counts <regex> <which-number:first|last> <expected> <label>
  #
  # For each scan file, grep the regex with `-noE` (per-file => output is
  # "<lineno>:<matched-text>", no path prefix, so the line number can never be
  # mistaken for the stated count). The stated count is extracted from the
  # MATCHED TEXT only (everything after the first ':'), taking the first or
  # last number in the match. Any value != <expected> is a blocking failure.
  #
  # STRUCTURAL false-positive exclusions (the matched value is NOT a current
  # declaration and is therefore ignored, not suppressed):
  #   * grep-pattern lines: a count phrase that is the ARGUMENT of a grep call
  #     (e.g. validator/migration scripts do `grep -q "11 specialized agents"`
  #     to DETECT a stale old value). These search for a number; they don't
  #     state one. Matches the spec's allowlisted historical "11 -> 19/20".
  _scan_counts() {
    local regex="$1" which="$2" expected="$3" label="$4"
    local f rel out lineno match num srcline
    for f in "${scan_files[@]}"; do
      [[ -f "$f" ]] || continue
      rel="${f#"$ROOT"/}"
      # -o => only matched text; -n => line number; -I => skip binary.
      out="$(grep -noIE "$regex" "$f" 2>/dev/null)" || true
      [[ -z "$out" ]] && continue
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lineno="${line%%:*}"          # leading line number
        match="${line#*:}"            # matched text only (after first colon)
        # Pull the full source line for context-based exclusions.
        srcline="$(sed -n "${lineno}p" "$f")"
        # Exclude grep-pattern contexts (detecting an old value, not stating one).
        if printf '%s' "$srcline" | grep -qE '\bgrep\b'; then
          continue
        fi
        if [[ "$which" == "last" ]]; then
          num="$(printf '%s' "$match" | grep -oE '[0-9]+' | tail -1)"
        else
          num="$(printf '%s' "$match" | grep -oE '[0-9]+' | head -1)"
        fi
        if [[ "$num" != "$expected" ]]; then
          ok=0
          fail "$label: stated '$num' != derived $expected ($rel:$lineno)"
          detail "$match"
        fi
      done <<< "$out"
    done
  }

  # ---- 8a: "<N> specialized agents" headline (case-insensitive) ------------
  # High-signal ONLY: a number immediately followed by "specialized agents".
  # This deliberately does NOT match the legitimate non-derived numbers, which
  # are therefore never even examined (structural exclusion, not suppression):
  #   - "19 of 20" / "19/20" / "X/20" coverage ratios
  #   - historical "11 -> 19" / "11 agents" migration narrative
  #   - "3 MCP servers", "v3.0.0", dates, %, head -20
  _scan_counts '[0-9]+ [Ss]pecialized [Aa]gents' first "$n_agents" "agent count"

  # ---- 8b: "<N> hook scripts" / "<N> hooks" (real hook architecture) -------
  _scan_counts '[0-9]+ [Hh]ook [Ss]cripts?' first "$n_hooks" "hook-script count"
  _scan_counts '[0-9]+ [Hh]ooks\b' first "$n_hooks" "hooks count"

  # ---- 8c: "Total Hooks: <N>" / "<N> Quality Gates" (legacy phrasings) -----
  # Kept so a resurrected legacy headline is measured against the real count.
  _scan_counts 'Total Hooks:\*{0,2} ?[0-9]+' last "$n_hooks" "Total Hooks count"
  _scan_counts '[0-9]+ [Qq]uality [Gg]ates' first "$n_hooks" "quality-gate count"

  # ---- 8d: 'wc -l  # Should show <N>' agent-file assertion ------------------
  # README documents `ls -1 agents/*.md | wc -l  # Should show <N>`.
  _scan_counts 'Should show [0-9]+' last "$n_agents" "documented agent-file count"

  # ---- 8e: "<N> skills" / "<N> operational skills" --------------------------
  _scan_counts '[0-9]+ ([Oo]perational )?[Ss]kills\b' first "$n_skills" "skill count"

  # ---- 8f: "<N> commands" ----------------------------------------------------
  _scan_counts '[0-9]+ [Cc]ommands\b' first "$n_commands" "command count"

  if [[ "$ok" -eq 1 ]]; then
    pass "all high-signal stated counts match derived values (agents=$n_agents, hooks=$n_hooks, skills=$n_skills, commands=$n_commands)"
  fi
}

# ===========================================================================
# CHECK 7 - Model parity (BLOCKING)
# ===========================================================================
# Single source of truth: BOTH the agents/<a>.md frontmatter `model:` and
# claude.json `.sub_agents[<a>].model` are tier SHORTHANDS (opus/sonnet/haiku).
# We assert DIRECT string equality between them (no shorthand->full-id round
# trip), and additionally guard that every model value seen - on either side -
# is a declared key in .consistency.model_shorthand_map. An unknown/typo value
# (e.g. "sonnett") or any md<->claude.json divergence is a BLOCKING failure.
section "[7] Model parity (agents/<a>.md frontmatter model: == claude.json model, both shorthand)"
{
  ok=1 checked=0

  # Known shorthand keys from the map (the only legal model values).
  valid_models="$(_facts_jq -r '.consistency.model_shorthand_map // {} | keys[]' \
                  "$FACTS_CLAUDE_JSON" 2>/dev/null | LC_ALL=C sort)"
  if [[ -z "$valid_models" ]]; then
    ok=0
    fail "model parity: .consistency.model_shorthand_map is empty or missing (no legal model values defined)"
  fi

  # _is_valid_model <value> - 0 if <value> is a declared shorthand key, else 1.
  _is_valid_model() {
    printf '%s\n' "$valid_models" | grep -qxF -- "$1"
  }

  while IFS=$'\t' read -r agent reg_model; do
    [[ -z "$agent" ]] && continue
    md="$FACTS_AGENTS_DIR/$agent.md"
    if [[ ! -f "$md" ]]; then
      # Missing .md is reported by check 1; skip here to avoid double-counting.
      continue
    fi
    # frontmatter model: value (first occurrence), stripped of quotes/space.
    fm="$(grep -m1 -E '^model:[[:space:]]*' "$md" | sed -E 's/^model:[[:space:]]*//; s/[[:space:]]+$//; s/^["'\'']//; s/["'\'']$//')"
    checked=$((checked + 1))

    # Guard: both sides must be a declared shorthand key in the map.
    if [[ -z "$fm" ]]; then
      ok=0
      fail "$agent: agents/$agent.md has no frontmatter 'model:' value"
    elif ! _is_valid_model "$fm"; then
      ok=0
      fail "$agent: agents/$agent.md model '$fm' is not a key in consistency.model_shorthand_map"
    fi
    if [[ -z "$reg_model" ]]; then
      ok=0
      fail "$agent: claude.json .sub_agents[\"$agent\"].model is empty"
    elif ! _is_valid_model "$reg_model"; then
      ok=0
      fail "$agent: claude.json model '$reg_model' is not a key in consistency.model_shorthand_map"
    fi

    # Direct shorthand equality (only meaningful once both are present).
    if [[ -n "$fm" && -n "$reg_model" && "$fm" != "$reg_model" ]]; then
      ok=0
      fail "$agent: model mismatch (agents/$agent.md '$fm' != claude.json '$reg_model')"
    fi
  done <<< "$(fact_models)"

  if [[ "$ok" -eq 1 ]]; then
    pass "all $checked agent models agree (md frontmatter == claude.json, both valid shorthand)"
  fi
}

# ===========================================================================
# CHECK 9 - Roster-presence for NON-generated prose tables (BLOCKING)
# ===========================================================================
# These tables are NOT machine-generated (their grouping/order cannot round-trip
# from claude.json - see generate-docs.sh). We therefore guard them here:
#   (a) every registered agent appears EXACTLY ONCE in the roster,
#   (b) no unknown/extra agent rows,
#   (c) for the textual "### Category (N agents)" sections, the stated N equals
#       the actual number of agents listed beneath that header.
# This catches the missing-row / wrong-header-count drift without generating
# the prose.
section "[9] Roster-presence for prose tables (CLAUDE.md table + list-agents roster/categories)"
{
  ok=1

  # _roster_compare <label> <newline-list-of-agents-extracted>
  #   Compares an extracted roster against the canonical agent set:
  #     - duplicate rows (agent listed more than once)
  #     - unknown rows  (name not a registered agent)
  #     - missing rows  (registered agent not present)
  _roster_compare() {
    local label="$1" extracted="$2"
    local sorted dups unknown missing local_ok=1

    sorted="$(printf '%s\n' "$extracted" | grep -v '^$' | LC_ALL=C sort)"

    # (a) duplicates
    dups="$(printf '%s\n' "$sorted" | uniq -d)"
    if [[ -n "$dups" ]]; then
      local_ok=0; ok=0
      fail "$label: agent row(s) appear more than once:"
      while IFS= read -r a; do [[ -n "$a" ]] && detail "duplicate-row: $a"; done <<< "$dups"
    fi

    # (b) unknown (in roster, not a real agent)
    unknown="$(comm -23 <(printf '%s\n' "$sorted" | LC_ALL=C sort -u) <(printf '%s\n' "$AGENTS_SORTED"))"
    if [[ -n "$unknown" ]]; then
      local_ok=0; ok=0
      fail "$label: unknown/extra agent row(s) (not in claude.json .sub_agents):"
      while IFS= read -r a; do [[ -n "$a" ]] && detail "unknown-row: $a"; done <<< "$unknown"
    fi

    # (c) missing (real agent, absent from roster)
    missing="$(comm -13 <(printf '%s\n' "$sorted" | LC_ALL=C sort -u) <(printf '%s\n' "$AGENTS_SORTED"))"
    if [[ -n "$missing" ]]; then
      local_ok=0; ok=0
      fail "$label: registered agent(s) MISSING from roster:"
      while IFS= read -r a; do [[ -n "$a" ]] && detail "missing-row: $a"; done <<< "$missing"
    fi

    if [[ "$local_ok" -eq 1 ]]; then
      pass "$label: all $(printf '%s\n' "$AGENTS_SORTED" | grep -c .) agents present exactly once; no unknown rows"
    fi
  }

  # --- 9a: CLAUDE.md "AVAILABLE IMPLEMENTATION AGENTS" table ----------------
  # Rows look like:  | **agent-name** | Implementation domain |
  # Scope the extraction to the table by only matching that exact row shape; the
  # routing guidelines below use "- **Rust development**" (no leading pipe) so
  # they cannot leak in.
  claude_md="$ROOT/CLAUDE.md"
  if [[ -f "$claude_md" ]]; then
    cmd_roster="$(grep -oE '^\| \*\*[a-z0-9-]+\*\* \|' "$claude_md" \
                  | sed -E 's/^\| \*\*//; s/\*\* \|$//')"
    if [[ -z "$cmd_roster" ]]; then
      ok=0; fail "CLAUDE.md: could not locate any agent table rows"
    else
      _roster_compare "CLAUDE.md agent table" "$cmd_roster"
    fi
  else
    ok=0; fail "CLAUDE.md not found at $claude_md"
  fi

  # --- 9b: list-agents.md ASCII roster table --------------------------------
  # Rows look like:  | rust-expert              | Language | ...   (box-drawing
  # vertical bar U+2502). The file contains MORE THAN ONE box table (the main
  # roster, plus a "--language" category-view EXAMPLE that re-lists the 9
  # language/automation agents). We therefore scope extraction to the FIRST box
  # table only: capture rows after the first top border (U+250C "\xe2\x94\x8c")
  # and stop at its matching bottom border (U+2514 "\xe2\x94\x94"). Within that
  # block we pull the first content cell and keep only agent-name-shaped tokens
  # (header "Agent" and separator rows are naturally excluded).
  la="$ROOT/commands/list-agents.md"
  if [[ -f "$la" ]]; then
    la_roster="$(awk '
      # First top border opens the roster table.
      !started && /^\xe2\x94\x8c/ { started=1; next }
      started && /^\xe2\x94\x94/  { exit }            # bottom border closes it
      started && /\xe2\x94\x82/ {
        line=$0
        n=split(line, cells, "\xe2\x94\x82")
        cell=cells[2]                                  # first content cell
        gsub(/^[ \t]+/, "", cell); gsub(/[ \t]+$/, "", cell)
        if (cell ~ /^[a-z0-9]+(-[a-z0-9]+)+$/) print cell
      }
    ' "$la")"
    if [[ -z "$la_roster" ]]; then
      ok=0; fail "list-agents.md: could not locate any ASCII roster rows"
    else
      _roster_compare "list-agents.md ASCII roster" "$la_roster"

      # Also validate the declared "Total: <N> agents" line against the roster.
      declared_total="$(grep -oE 'Total: [0-9]+ agents' "$la" | head -1 | grep -oE '[0-9]+')"
      actual_total="$(printf '%s\n' "$la_roster" | grep -c .)"
      if [[ -n "$declared_total" && "$declared_total" != "$actual_total" ]]; then
        ok=0
        fail "list-agents.md roster: 'Total: $declared_total agents' != $actual_total rows in the table"
      fi
    fi

    # --- 9c: list-agents.md textual "### Category (N agents)" sections ------
    # Each header is followed by a fenced block of "agent-name -> ..." lines.
    # We (1) verify the union of all listed agents is the full roster exactly,
    # and (2) verify each header's stated N equals the agents listed beneath it.
    cat_total_ok=1
    all_cat_agents=""
    # Iterate headers with their line numbers.
    while IFS= read -r hline; do
      [[ -z "$hline" ]] && continue
      hnum="${hline%%:*}"
      htext="${hline#*:}"
      # stated N (the number inside "(N agent[s])")
      stated="$(printf '%s' "$htext" | grep -oE '\([0-9]+ agents?\)' | grep -oE '[0-9]+')"
      # Collect agent tokens from the lines AFTER this header up to the next
      # "### " header (or EOF). An agent line looks like:
      #   rust-expert          -> Rust systems programming
      sect_agents="$(awk -v start="$hnum" '
        NR > start {
          if ($0 ~ /^### /) exit
          # first token if it is an agent-name shape
          tok=$1
          if (tok ~ /^[a-z0-9]+(-[a-z0-9]+)+$/) print tok
        }
      ' "$la")"
      actual="$(printf '%s\n' "$sect_agents" | grep -c .)"
      all_cat_agents+="$sect_agents"$'\n'
      if [[ "$stated" != "$actual" ]]; then
        cat_total_ok=0; ok=0
        fail "list-agents.md category header count mismatch: '$(printf '%s' "$htext" | sed -E 's/^[[:space:]]+//')' states $stated but lists $actual"
        while IFS= read -r a; do [[ -n "$a" ]] && detail "listed: $a"; done <<< "$sect_agents"
      fi
    done <<< "$(grep -nE '^### .* \([0-9]+ agents?\)' "$la")"

    # Union of textual-category agents must equal the full roster exactly.
    if [[ -n "$all_cat_agents" ]]; then
      _roster_compare "list-agents.md textual categories (union)" "$all_cat_agents"
    else
      ok=0; fail "list-agents.md: could not locate any '### Category (N agents)' sections"
    fi
    if [[ "$cat_total_ok" -eq 1 ]]; then
      pass "list-agents.md: every '### Category (N agents)' header count matches its listed agents"
    fi
  else
    ok=0; fail "list-agents.md not found at $la"
  fi

  [[ "$ok" -eq 1 ]] || true
}

# ===========================================================================
# CHECK 10 - README focus-text parity (BLOCKING)
# ===========================================================================
# The README "## Agents" tables are NOT generated (grouping cannot round-trip),
# but each agent's Focus column is now single-sourced as .sub_agents[a].focus.
# Guard the prose against drift: every agent's README Focus cell must match the
# canonical focus field byte-for-byte, the README must list every agent exactly
# once, and contain no unknown agent rows.
section "[10] README focus-text parity (.sub_agents[a].focus == README Focus cell)"
{
  readme="$ROOT/README.md"
  ok=1
  if [[ ! -f "$readme" ]]; then
    ok=0; fail "README.md not found at $readme"
  else
    # Extract "agent<TAB>focus" pairs from the ## Agents section only.
    readme_pairs="$(awk '
      /^## Agents$/ {inagents=1; next}
      inagents && /^## / {inagents=0}
      inagents && /^\| \*\*[a-z0-9-]+\*\* \| / {
        line=$0
        sub(/^\| \*\*/, "", line)
        idx=index(line, "** | ")
        name=substr(line, 1, idx-1)
        rest=substr(line, idx+5)
        sub(/ \|$/, "", rest)
        printf "%s\t%s\n", name, rest
      }
    ' "$readme")"

    # Roster presence: agents listed in the README ## Agents tables.
    readme_roster="$(printf '%s\n' "$readme_pairs" | awk -F'\t' 'NF{print $1}')"
    readme_sorted="$(printf '%s\n' "$readme_roster" | grep -v '^$' | LC_ALL=C sort)"
    r_dups="$(printf '%s\n' "$readme_sorted" | uniq -d)"
    r_unknown="$(comm -23 <(printf '%s\n' "$readme_sorted" | LC_ALL=C sort -u) <(printf '%s\n' "$AGENTS_SORTED"))"
    r_missing="$(comm -13 <(printf '%s\n' "$readme_sorted" | LC_ALL=C sort -u) <(printf '%s\n' "$AGENTS_SORTED"))"
    if [[ -n "$r_dups" ]]; then
      ok=0; fail "README ## Agents: duplicate agent row(s):"
      while IFS= read -r a; do [[ -n "$a" ]] && detail "duplicate-row: $a"; done <<< "$r_dups"
    fi
    if [[ -n "$r_unknown" ]]; then
      ok=0; fail "README ## Agents: unknown/extra agent row(s):"
      while IFS= read -r a; do [[ -n "$a" ]] && detail "unknown-row: $a"; done <<< "$r_unknown"
    fi
    if [[ -n "$r_missing" ]]; then
      ok=0; fail "README ## Agents: registered agent(s) MISSING from tables:"
      while IFS= read -r a; do [[ -n "$a" ]] && detail "missing-row: $a"; done <<< "$r_missing"
    fi

    # Focus-text parity: README cell == claude.json focus field.
    mismatch=0
    while IFS=$'\t' read -r name foc; do
      [[ -z "$name" ]] && continue
      canon="$(render_focus "$name" 2>/dev/null || true)"
      if [[ -z "$canon" ]]; then
        ok=0; mismatch=$((mismatch + 1))
        fail "README focus parity: '$name' has no .focus field in claude.json"
      elif [[ "$foc" != "$canon" ]]; then
        ok=0; mismatch=$((mismatch + 1))
        fail "README focus parity: '$name' README cell != claude.json .focus"
        detail "README:     $foc"
        detail "claude.json: $canon"
      fi
    done <<< "$readme_pairs"

    if [[ "$ok" -eq 1 ]]; then
      pass "all $(printf '%s\n' "$readme_sorted" | grep -c .) README agent rows present once; focus text matches claude.json exactly"
    fi
  fi
}

# ===========================================================================
# CHECK 11 - Generated blocks are fresh (BLOCKING) - wires in generate-docs
# ===========================================================================
# Runs the generator in --check mode so a stale machine-generated block (e.g.
# the list-agents JSON summary) fails the same gate as everything else. Kept as
# a separate script per the phase design; this is the single call site that lets
# one `validate-consistency.sh` run cover both validation AND generation drift.
section "[11] Generated documentation blocks are up to date (generate-docs.sh --check)"
{
  gen="$SCRIPT_DIR/generate-docs.sh"
  if [[ ! -f "$gen" ]]; then
    fail "generate-docs.sh not found at $gen"
  else
    gen_out="$(bash "$gen" --check 2>&1)"
    gen_rc=$?
    if [[ "$gen_rc" -eq 0 ]]; then
      pass "all generated blocks are fresh"
    else
      fail "generate-docs.sh --check reported stale/invalid blocks (exit $gen_rc):"
      while IFS= read -r ln; do [[ -n "$ln" ]] && detail "$ln"; done <<< "$gen_out"
    fi
  fi
}

# ===========================================================================
# CHECK 12 - Skills layout (BLOCKING)
# ===========================================================================
# Claude Code only loads skills from skills/<name>/SKILL.md. Flat skills/*.md
# files are silently ignored by the runtime, so their presence is always a
# defect. Each SKILL.md must carry frontmatter with name == its directory and
# a non-empty single-line description.
section "[12] Skills layout (skills/<name>/SKILL.md only; frontmatter name == dirname)"
{
  ok=1
  skills_dir="$FACTS_SKILLS_DIR"
  if [[ -d "$skills_dir" ]]; then
    shopt -s nullglob

    # 12a: no loose files directly under skills/ (flat *.md is unloadable)
    for f in "$skills_dir"/*; do
      if [[ -f "$f" ]]; then
        ok=0
        fail "loose file in skills/ (not loadable by Claude Code): ${f#"$ROOT"/}"
        detail "flat-skill-file: $(basename "$f")"
      fi
    done

    # 12b: every skills/<name>/ dir has SKILL.md with sane frontmatter
    for d in "$skills_dir"/*/; do
      d="${d%/}"
      sname="$(basename "$d")"
      sm="$d/SKILL.md"
      if [[ ! -f "$sm" ]]; then
        ok=0
        fail "skills/$sname/ has no SKILL.md"
        detail "missing-skill-md: $sname"
        continue
      fi
      fm_name="$(grep -m1 -E '^name:[[:space:]]*' "$sm" | sed -E 's/^name:[[:space:]]*//; s/[[:space:]]+$//')"
      fm_desc="$(grep -m1 -E '^description:[[:space:]]*' "$sm" | sed -E 's/^description:[[:space:]]*//; s/[[:space:]]+$//')"
      if [[ "$fm_name" != "$sname" ]]; then
        ok=0
        fail "skills/$sname/SKILL.md frontmatter name '$fm_name' != directory name '$sname'"
        detail "skill-name-mismatch: $sname"
      fi
      if [[ -z "$fm_desc" ]]; then
        ok=0
        fail "skills/$sname/SKILL.md has no (or empty) frontmatter description"
        detail "skill-missing-description: $sname"
      fi
    done
    shopt -u nullglob

    if [[ "$ok" -eq 1 ]]; then
      n_sk="$(fact_skills | grep -c . || true)"
      pass "$n_sk skill(s) in canonical skills/<name>/SKILL.md layout; frontmatter consistent"
    fi
  else
    info "no skills/ directory present"
  fi
}

# ===========================================================================
# CHECK 13 - Version sync (BLOCKING)
# ===========================================================================
# The version must be identical across three authoritative locations:
#   - claude.json .version
#   - .claude-plugin/plugin.json .version
#   - mcp-plugin/.claude-plugin/plugin.json .version
# All three must be identical non-empty strings; any drift is a defect.
section "[13] Version sync (claude.json, .claude-plugin/plugin.json, mcp-plugin/.claude-plugin/plugin.json)"
{
  ok=1
  versions=()
  files=("$ROOT/claude.json" "$ROOT/.claude-plugin/plugin.json" "$ROOT/mcp-plugin/.claude-plugin/plugin.json")

  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      ok=0
      fail "version check: required file missing: ${f#"$ROOT"/}"
      versions+=("")
      continue
    fi
    v="$(_facts_jq -r '.version // empty' "$f" 2>/dev/null || echo "")"
    if [[ -z "$v" ]]; then
      ok=0
      fail "version check: ${f#"$ROOT"/} has no (or empty) .version field"
      versions+=("")
    else
      versions+=("$v")
    fi
  done

  # All versions must be identical and non-empty
  if [[ "$ok" -eq 1 ]]; then
    first="${versions[0]}"
    mismatch=0
    for i in "${!versions[@]}"; do
      if [[ "${versions[$i]}" != "$first" ]]; then
        mismatch=1
        fail "version mismatch: ${files[$i]#"$ROOT"/} has version '${versions[$i]}' != '$first'"
        ok=0
      fi
    done
    if [[ "$ok" -eq 1 ]]; then
      pass "all three version fields are identical: $first"
    fi
  fi
}

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%s================================================%s\n' "$C_CYN" "$C_NC"
if [[ "$BLOCKING_FAILURES" -eq 0 ]]; then
  printf '%s  RESULT: PASS%s  (blocking failures: 0, warnings: %s)\n' "$C_GRN" "$C_NC" "$WARNINGS"
  printf '%s================================================%s\n' "$C_CYN" "$C_NC"
  exit 0
else
  printf '%s  RESULT: FAIL%s  (blocking failures: %s, warnings: %s)\n' "$C_RED" "$C_NC" "$BLOCKING_FAILURES" "$WARNINGS"
  printf '%s================================================%s\n' "$C_CYN" "$C_NC"
  exit 1
fi
