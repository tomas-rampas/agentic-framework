#!/bin/sh
set -u
# pretooluse-model-guard.sh — blocking PreToolUse hook (matcher: Task|Agent).
#
# Prevents any subagent from running on the top model tier (a normalised model
# value containing the substring "fable", e.g. fable, claude-fable-5-1,
# fable[1m]), prevents a fork (subagent_type "fork") from being issued with any
# model override since a fork always inherits its parent's model regardless of
# an override, and prevents built-in agents (Explore, Plan, general-purpose,
# claude) from silently inheriting the parent model when no tier is set
# anywhere in the resolution chain — including a user-side floor
# (CLAUDE_CODE_SUBAGENT_MODEL) whose own value is empty or itself contains
# "fable". Non-string tool_input.model/subagent_type JSON values (bool,
# number, array, object, null, absent) normalise to empty via a jq
# `if type=="string" then . else "" end` guard so a wrong-typed field never
# resolves to text a substring/case match could accidentally hit. tool_input
# itself must be a JSON object (an empty object still qualifies and denies as
# general-purpose); any other shape (absent, null, string, array, ...) is an
# unrecognised payload and passes silently rather than being misread as a
# built-in agent. Never blocks a framework agent that has its own frontmatter
# default. Fail-open:
# any error, unparseable stdin, or missing jq => exit 0, no output. Disable
# via env AF_MODEL_GUARD=off (case-insensitive).
#
# Ported from pretooluse-model-guard.ps1 to POSIX sh; byte-identical stdout.

trim_lower() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]'
}

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

af_guard_lower=$(printf '%s' "${AF_MODEL_GUARD:-}" | tr '[:upper:]' '[:lower:]')
if [ "$af_guard_lower" = "off" ]; then
  exit 0
fi

payload=$(cat 2>/dev/null)
[ -z "$payload" ] && exit 0

tool_input_type=$(printf '%s' "$payload" | jq -r '(.tool_input | type)' 2>/dev/null) || exit 0
[ "$tool_input_type" = "object" ] || exit 0

model_raw=$(printf '%s' "$payload" | jq -r '(.tool_input.model | if type=="string" then . else "" end)' 2>/dev/null) || exit 0
stype_raw=$(printf '%s' "$payload" | jq -r '(.tool_input.subagent_type | if type=="string" then . else "" end)' 2>/dev/null) || exit 0

model=$(trim_lower "$model_raw")
stype=$(trim_lower "$stype_raw")

if [ "$stype" = "fork" ]; then
  jq -cn --arg reason "[model-guard] A fork always runs on its parent model and ignores the model override. Start a fresh agent with an explicit model instead, and pass it the context it needs. Set AF_MODEL_GUARD=off to disable this guard." \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

case "$model" in
  *fable*)
    jq -cn --arg reason "[model-guard] Sub-agents must not run on the top model tier. Re-issue this Agent call with model set to opus, sonnet or haiku. Set AF_MODEL_GUARD=off to disable this guard." \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
    exit 0
    ;;
esac

floor=$(trim_lower "${CLAUDE_CODE_SUBAGENT_MODEL:-}")
floor_set=false
case "$floor" in
  "") floor_set=false ;;
  *fable*) floor_set=false ;;
  *) floor_set=true ;;
esac

if [ "$model" = "" ] && [ "$floor_set" = "false" ]; then
  type=""
  case "$stype" in
    "")                type="general-purpose" ;;
    explore)           type="Explore" ;;
    plan)              type="Plan" ;;
    general-purpose)   type="general-purpose" ;;
    claude)            type="claude" ;;
    *)                 type="" ;;
  esac

  if [ -n "$type" ]; then
    if [ "$type" = "Explore" ]; then
      tier="haiku"
    else
      tier="sonnet"
    fi
    jq -cn --arg type "$type" --arg tier "$tier" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("[model-guard] Built-in agent " + $type + " has no default tier and would inherit the parent model. Re-issue this Agent call with model set to " + $tier + ". Set AF_MODEL_GUARD=off to disable this guard.")}}'
    exit 0
  fi
fi

exit 0
