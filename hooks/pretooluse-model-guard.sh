#!/bin/sh
set -u
# pretooluse-model-guard.sh — blocking PreToolUse hook (matcher: Task|Agent).
#
# Denies two things it can recognise from the call alone: every fork
# (subagent_type "fork"), since a fork always inherits its parent's model and
# ignores any override; and a normalised model value containing the substring
# "fable" (e.g. fable, claude-fable-5-1, fable[1m]), the top model tier. A
# BUILT-IN agent (Explore, Plan, general-purpose, claude, or no type given)
# issued with no model and no usable floor is REWRITTEN rather than denied:
# the hook returns updatedInput with model set to its tier, so the call
# proceeds automatically with no user step. The floor is the env var
# CLAUDE_CODE_SUBAGENT_MODEL, and it counts as usable only when it is
# non-empty and itself free of "fable"; an unusable floor (empty, or itself
# "fable") is what routes a built-in call into the rewrite.
#
# MEASURED (Claude Code 2.1.278, Agent tool): updatedInput for the Agent tool
# must echo the COMPLETE original tool_input, not just the changed key — a
# partial updatedInput (e.g. {"model":"haiku"} alone) replaces the whole
# input, so prompt/description/subagent_type vanish and schema validation
# rejects the call. The rewrite path emits no permissionDecision at all
# (tested to work and to leave the user's own permission rules alone); only
# hookSpecificOutput.updatedInput plus a top-level systemMessage. Every other
# original key comes back unchanged and in its original position; model is
# replaced in place if present, else appended last (jq's `.tool_input +
# {model: $tier}` does exactly this — see key-order proof in the equivalence
# suite).
#
# KNOWN LIMIT: any OTHER agent type — a framework agent, a user-scope agent,
# another plugin's agent — spawned with no model is never touched here,
# because this hook cannot read that agent's frontmatter. If its definition
# carries no `model:` line it silently inherits the caller's tier, and the
# only cover for that case is the user-side floor above.
#
# Non-string tool_input.model/subagent_type JSON values (bool, number, array,
# object, null, absent) normalise to empty via a jq
# `if type=="string" then . else "" end` guard so a wrong-typed field never
# resolves to text a substring/case match could accidentally hit. tool_input
# itself must be a JSON object (an empty object still qualifies and rewrites
# to {"model":"sonnet"}); any other shape (absent, null, string, array, ...)
# is an unrecognised payload and passes silently rather than being misread as
# a built-in agent. Fail-open: any error, unparseable stdin, or missing jq =>
# exit 0, no output. Disable via env AF_MODEL_GUARD=off (case-insensitive,
# surrounding whitespace trimmed).
#
# MEASURED: a lone UTF-16 surrogate escape (\uD800-\uDFFF not part of a valid
# pair) anywhere in the raw payload makes jq reject the WHOLE document, so
# without the fallback below a fork or fable call carrying one in an
# unrelated field (e.g. prompt) would silently bypass this guard. When the
# original payload fails to parse, a DECISION-ONLY copy is built by
# replacing every such escape with � and re-parsed; model/subagent_type
# are then read from that copy. This is safe because the two decision fields
# never legitimately contain a lone surrogate. The sanitised copy is used
# only for the deny/allow decision and is NEVER echoed: the rewrite branch
# always serialises the ORIGINAL payload, and if that still fails to parse,
# nothing is printed and the call proceeds unrewritten (exit 0) rather than
# emitting a prompt the hook cannot reproduce exactly.
#
# Ported from pretooluse-model-guard.ps1 to POSIX sh. DENY cases (fork,
# fable) are byte-identical between the two implementations; REWRITE cases
# may legitimately differ in JSON escaping of echoed strings (jq emits raw
# UTF-8, .NET's Utf8JsonWriter may differ on escape choices) — compare them
# as canonical JSON (jq -S -c .), not as raw bytes.

trim_lower() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]'
}

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

af_guard_lower=$(trim_lower "${AF_MODEL_GUARD:-}")
if [ "$af_guard_lower" = "off" ]; then
  exit 0
fi

payload=$(cat 2>/dev/null)
[ -z "$payload" ] && exit 0

decision_payload="$payload"
tool_input_type=$(printf '%s' "$decision_payload" | jq -r '(.tool_input | type)' 2>/dev/null)
if [ $? -ne 0 ]; then
  # Original payload doesn't parse — likely a lone surrogate escape. Build a
  # decision-only copy with such escapes replaced, for reading model/
  # subagent_type ONLY; the rewrite branch below still uses $payload as-is.
  sanitized=$(printf '%s' "$payload" | sed -E 's/\\u[dD][89a-fA-F][0-9a-fA-F]{2}/\\ufffd/g')
  tool_input_type=$(printf '%s' "$sanitized" | jq -r '(.tool_input | type)' 2>/dev/null) || exit 0
  decision_payload="$sanitized"
fi
[ "$tool_input_type" = "object" ] || exit 0

model_raw=$(printf '%s' "$decision_payload" | jq -r '(.tool_input.model | if type=="string" then . else "" end)' 2>/dev/null) || exit 0
stype_raw=$(printf '%s' "$decision_payload" | jq -r '(.tool_input.subagent_type | if type=="string" then . else "" end)' 2>/dev/null) || exit 0

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
    printf '%s' "$payload" | jq -c --arg type "$type" --arg tier "$tier" '
      {
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          updatedInput: (.tool_input + {model: $tier})
        },
        systemMessage: ("[model-guard] Built-in agent " + $type + " had no model and would inherit the session model. Model set to " + $tier + ". Set AF_MODEL_GUARD=off to disable this guard.")
      }' 2>/dev/null || exit 0
    exit 0
  fi
fi

exit 0
