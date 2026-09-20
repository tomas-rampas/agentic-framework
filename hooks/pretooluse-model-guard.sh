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
# replacing every such escape with the U+FFFD replacement character and
# re-parsed; model/subagent_type are then read from that copy. This is safe
# because the two decision fields never legitimately contain a lone
# surrogate. The sanitised copy is used only for the deny/allow decision and
# is NEVER echoed: the rewrite branch always serialises the ORIGINAL
# payload.
#
# FALLBACK DENY: if that original-payload echo fails to serialise (the
# built-in agent's OWN prompt/description carries the lone surrogate this
# time), the call is NOT allowed to pass through silently — an unrewritten
# built-in call would inherit the session's tier, the exact outcome this
# hook exists to prevent. Instead the hook denies with a dedicated,
# ASCII-only reason naming the agent's TYPE and TIER, in the same
# hookSpecificOutput/permissionDecision:"deny" shape as the fork/fable
# denials, built with `jq -cn` (no payload re-parse needed). Only stdin that
# cannot be understood AT ALL (malformed JSON, non-object tool_input, a
# sanitised copy that still fails to parse, missing jq) keeps the true
# fail-open exit-0-silent behaviour.
#
# Ported from pretooluse-model-guard.ps1 to POSIX sh. All THREE deny shapes
# (fork, fable, and the rewrite-fallback deny above) are byte-identical
# between the two implementations, since none of them echo caller-supplied
# text verbatim. REWRITE cases may legitimately differ in JSON escaping of
# echoed strings (jq emits raw UTF-8, .NET's Utf8JsonWriter may differ on
# escape choices) — compare them as canonical JSON (jq -S -c .), not as raw
# bytes.

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
if ! tool_input_type=$(printf '%s' "$decision_payload" | jq -r '(.tool_input | type)' 2>/dev/null); then
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
    if rewrite_out=$(printf '%s' "$payload" | jq -c --arg type "$type" --arg tier "$tier" '
      {
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          updatedInput: (.tool_input + {model: $tier})
        },
        systemMessage: ("[model-guard] Built-in agent " + $type + " had no model and would inherit the session model. Model set to " + $tier + ". Set AF_MODEL_GUARD=off to disable this guard.")
      }' 2>/dev/null) && [ -n "$rewrite_out" ]; then
      printf '%s\n' "$rewrite_out"
    else
      # The original payload couldn't be echoed (e.g. a lone surrogate in
      # this agent's own prompt/description). Deny rather than let the call
      # proceed unrewritten and silently inherit the session's tier.
      jq -cn --arg type "$type" --arg tier "$tier" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":("[model-guard] Built-in agent " + $type + " has no model and would inherit the session model, and this call could not be rewritten safely. Re-issue this Agent call with model set to " + $tier + ". Set AF_MODEL_GUARD=off to disable this guard.")}}'
    fi
    exit 0
  fi
fi

exit 0
