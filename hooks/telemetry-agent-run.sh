#!/bin/sh
# telemetry-agent-run.sh — agent invocation telemetry (launch, completion, verdict, tokens).
#
# Events: PreToolUse + PostToolUse (matcher Task|Agent) and SubagentStop.
#   Pre  -> <telemetry>/<session>/agents/<tool_use_id>.json  (agent, model tier, start)
#   Post -> same file updated with ended_at, duration_s, status, and the reviewer verdict
#           (created from the payload when the Pre record is missing)
#   Stop -> <telemetry>/<session>/agents/subagent-<agent_id>.json  (actual model, tokens)
# Silent by design: an empty PreToolUse output allows the tool call, so nothing is ever
# printed. sh-only advisory hook; no network; fail-open (exits 0 on every path).
set -u
umask 077
trap 'exit 0' EXIT INT TERM
exec 2>/dev/null

payload=$(cat)
[ -z "$payload" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

field() { printf '%s' "$payload" | jq -r "$1" | tr -d '\r'; }
# clean <id>: keep [A-Za-z0-9._-] only; prints nothing for an empty or dots-only result.
clean() {
  _c=$(printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
  case $_c in *[!.]*) printf '%s' "$_c" ;; esac
}

sid=$(clean "$(field '.session_id // empty')")
[ -z "$sid" ] && exit 0
event=$(field '.hook_event_name // empty')

state=${CLAUDE_STATE_DIR:-$HOME/.claude/.state}
adir="$state/telemetry/sessions/$sid/agents"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Whole-line verdict, last match wins; a quoted/mid-line mention does not count.
# Reads text on stdin, prints APPROVED|CHANGES_REQUIRED or nothing.
parse_verdict() {
  tr -d '\r' | grep -E '^[[:space:]]*VERDICT:[[:blank:]]*(APPROVED|CHANGES_REQUIRED)[[:blank:]]*$' \
    | tail -n 1 | sed -E 's/.*VERDICT:[[:blank:]]*([A-Z_]+).*/\1/'
}
is_reviewer() { case "$1" in peer-review-critic|spec-compliance-reviewer) return 0 ;; esac; return 1; }

# Token totals + last model over a transcript file (read through a 64 MiB cap), as one
# compact JSON object. Parsed line by line (a malformed line is skipped); usage is counted
# once per .message.id (Claude Code repeats it on every content-block line; lines of one
# id are contiguous, the last wins). Subagent transcripts are entirely isSidechain:true,
# so sidechain lines are NOT excluded here (unlike the main-transcript accounting).
sum_transcript() {
  head -c 67108864 "$1" | tr -d '\r' | jq -c -n -R '
    [inputs | fromjson? | objects
     | select(.type == "assistant" and (.message | type) == "object"
              and (.message.usage | type) == "object")] as $ls
    | (reduce $ls[] as $l ([];
        if ($l.message.id | type) == "string" and $l.message.id != ""
           and length > 0 and (.[-1].message.id == $l.message.id)
        then .[-1] = $l else . + [$l] end)) as $m
    | reduce $m[] as $l
        ({model: null, tokens: {input: 0, output: 0, cache_read: 0, cache_creation: 0}};
         .tokens.input += ($l.message.usage.input_tokens | numbers // 0)
         | .tokens.output += ($l.message.usage.output_tokens | numbers // 0)
         | .tokens.cache_read += ($l.message.usage.cache_read_input_tokens | numbers // 0)
         | .tokens.cache_creation += ($l.message.usage.cache_creation_input_tokens | numbers // 0)
         | .model = (($l.message.model | strings | .[0:100]) // .model))'
}

# write_record <dest>: atomically replace dest with JSON read from stdin.
write_record() {
  mkdir -p "$adir" || return 1
  _tmp=$(mktemp "$adir/.tmp.XXXXXX") || return 1
  if cat > "$_tmp" && jq -e . "$_tmp" >/dev/null; then mv -f "$_tmp" "$1"; else rm -f "$_tmp"; fi
}

case "$event" in
  PreToolUse|PostToolUse)
    tool=$(field '.tool_name // empty')
    case "$tool" in Task|Agent) ;; *) exit 0 ;; esac
    tuid=$(clean "$(field '.tool_use_id // empty')")
    [ -z "$tuid" ] && exit 0
    dest="$adir/$tuid.json"
    agent=$(field '.tool_input.subagent_type | strings | .[0:100]')
    name=${agent#agentic-framework:}
    requested=$(field '.tool_input.model | strings | .[0:100]')
    tier=$requested
    plugin_json="${CLAUDE_PLUGIN_ROOT:-}/claude.json"
    if [ -z "$tier" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$plugin_json" ]; then
      tier=$(jq -r --arg a "$name" '.sub_agents[$a].model // empty' "$plugin_json" | tr -d '\r')
    fi
    # Fresh record built from this payload; Post merges onto an existing Pre record.
    rec=$(printf '%s' "$payload" | jq -c --arg id "$tuid" --arg agent "$agent" --arg name "$name" \
      --arg req "$requested" --arg tier "$tier" --arg now "$now" '
      {tool_use_id: $id, agent: (if $agent == "" then null else $agent end),
       agent_name: (if $name == "" then null else $name end),
       model_requested: (if $req == "" then null else $req end),
       model_tier: (if $tier == "" then null else $tier end),
       background: ((.tool_input.run_in_background // false) == true),
       started_at: $now, description: ((.tool_input.description | strings | .[0:200]) // null)}') || exit 0
    if [ "$event" = "PreToolUse" ]; then
      printf '%s' "$rec" | write_record "$dest"
      exit 0
    fi
    verdict=""
    if is_reviewer "$name"; then
      verdict=$(printf '%s' "$payload" | jq -r '
        ([.tool_response, .tool_output] | map(select(. != null and . != "")) | .[0] // "")
        | if type == "string" then .
          else (if type == "array" then . elif type == "object" and (.content | type) == "array" then .content
                elif type == "object" and (.content | type) == "string" then [.content]
                elif type == "object" then [.] else [] end)
               | [.[] | if type == "string" then . elif type == "object" and (.text | type) == "string" then .text else empty end]
               | join("\n") end' | parse_verdict)
    fi
    # Records go to jq through files (--slurpfile), never the command line: a large
    # value would exceed the Windows 32 K command-line limit and the update would fail.
    mkdir -p "$adir" || exit 0
    pw=$(mktemp -d "$adir/.tmp.XXXXXX") || exit 0
    trap 'rm -rf "$pw"; exit 0' EXIT INT TERM
    printf '%s' "$rec" > "$pw/rec.json" || exit 0
    : > "$pw/old.json"
    if [ -f "$dest" ] && jq -e 'type == "object"' "$dest" >/dev/null; then cp "$dest" "$pw/old.json" || exit 0; fi
    printf '%s' "$payload" | jq -c --slurpfile rec "$pw/rec.json" --slurpfile old "$pw/old.json" --arg now "$now" \
      --arg verdict "$verdict" '
      (if ($old | length) > 0 then $old[0] else $rec[0] + {started_at: null} end) as $base
      | $base + {ended_at: $now, status: "completed",
          duration_s: (if (.duration_ms | type) == "number" then (.duration_ms / 1000)
                       else (try (($now | fromdateiso8601) - ($base.started_at | fromdateiso8601)) catch null) end)}
        + (if $verdict == "" then {} else {verdict: $verdict} end)' \
      | write_record "$dest"
    ;;
  SubagentStop)
    aid=$(clean "$(field '.agent_id // empty')")
    [ -z "$aid" ] && exit 0
    atype=$(field '.agent_type // empty')
    name=${atype#agentic-framework:}
    verdict=""
    if is_reviewer "$name"; then
      verdict=$(field '.last_assistant_message // empty' | parse_verdict)
    fi
    tpath=$(field '.agent_transcript_path // empty')
    sums='{}'
    if [ -n "$tpath" ] && [ -f "$tpath" ] && [ -r "$tpath" ]; then sums=$(sum_transcript "$tpath") || sums='{}'; fi
    [ -z "$sums" ] && sums='{}'
    jq -n -c --arg id "$aid" --arg type "$atype" --arg name "$name" --arg now "$now" \
      --arg verdict "$verdict" --argjson sums "$sums" '
      {agent_id: $id, agent_type: $type, agent_name: $name, ended_at: $now}
      + (if $verdict == "" then {} else {verdict: $verdict} end)
      + (if $sums.tokens then {model_actual: $sums.model, tokens: $sums.tokens} else {} end)' \
      | write_record "$adir/subagent-$aid.json"
    ;;
esac
exit 0
