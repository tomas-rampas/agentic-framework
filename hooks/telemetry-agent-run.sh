#!/bin/sh
# telemetry-agent-run.sh — agent invocation telemetry (launch, completion, verdict, tokens).
#
# Events: PreToolUse + PostToolUse (matcher Task|Agent) and SubagentStop.
#   Pre  -> <telemetry>/<session>/agents/<tool_use_id>.json  (agent, model tier, start)
#   Post -> same file updated with ended_at, duration_s, status ("launched" for a background agent: Post fires at launch, so duration_s is launch latency), and the reviewer verdict
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

# clean <id>: keep [A-Za-z0-9._-] only; prints nothing for an empty or dots-only result.
clean() {
  _c=$(printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
  case $_c in *[!.]*) printf '%s' "$_c" ;; esac
}

# One jq call for every payload field (@sh makes the assignments safe to eval); the last
# assistant message is only extracted for the two reviewer agents (verdict parsing).
fields=$(printf '%s' "$payload" | jq -r '
  (.agent_type // "" | tostring | sub("^agentic-framework:"; "")) as $an
  | (.tool_input | if type == "object" then . else {} end) as $ti
  | @sh "sid_raw=\(.session_id // "" | tostring) event=\(.hook_event_name // "" | tostring) tool=\(.tool_name // "" | tostring) tuid_raw=\(.tool_use_id // "" | tostring) agent=\((($ti.subagent_type | strings | .[0:100]) // "")) requested=\((($ti.model | strings | .[0:100]) // "")) aid_raw=\(.agent_id // "" | tostring) atype=\(.agent_type // "" | tostring) tpath=\(.agent_transcript_path // "" | tostring) lam=\(if $an == "peer-review-critic" or $an == "spec-compliance-reviewer" or $an == "code-review-gatekeeper" then (.last_assistant_message // "" | tostring) else "" end)"') || exit 0
eval "$fields"
sid=$(clean "$(printf '%s' "${sid_raw:-}" | tr -d '\r')")
[ -z "$sid" ] && exit 0
event=$(printf '%s' "${event:-}" | tr -d '\r')

state=${CLAUDE_STATE_DIR:-$HOME/.claude/.state}
adir="$state/telemetry/sessions/$sid/agents"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Whole-line verdict, last match wins; a quoted/mid-line mention does not count.
# Reads text on stdin, prints APPROVED|CHANGES_REQUIRED or nothing.
parse_verdict() {
  tr -d '\r' | grep -E '^[[:space:]]*VERDICT:[[:blank:]]*(APPROVED|CHANGES_REQUIRED)[[:blank:]]*$' \
    | tail -n 1 | sed -E 's/.*VERDICT:[[:blank:]]*([A-Z_]+).*/\1/'
}
is_reviewer() { case "$1" in peer-review-critic|spec-compliance-reviewer|code-review-gatekeeper) return 0 ;; esac; return 1; }

# Token totals + last model over a transcript file (read through a 16 MiB cap into $work/lines), as one
# compact JSON object. Parsed line by line (a malformed line is skipped); usage is counted
# once per .message.id (Claude Code repeats it on every content-block line; lines of one
# id are contiguous, the last wins). Subagent transcripts are entirely isSidechain:true,
# so sidechain lines are NOT excluded here (unlike the main-transcript accounting).
sum_transcript() {
  # jq reads a FILE (piping into the native jq.exe is ~7x slower); $work is trap-covered.
  head -c 16777216 "$1" | tr -d '\r' > "$work/lines" || return 1
  jq -c -n -R '
    [inputs | fromjson? | objects
     | select(.type == "assistant" and (.message | type) == "object"
              and (.message.usage | type) == "object")
     | .message as $m
     | {id: (($m.id | strings | .[0:200]) // ""),
        model: (($m.model | strings | .[0:100]) // null),
        u: {input: ($m.usage.input_tokens | numbers // 0),
            output: ($m.usage.output_tokens | numbers // 0),
            cache_read: ($m.usage.cache_read_input_tokens | numbers // 0),
            cache_creation: ($m.usage.cache_creation_input_tokens | numbers // 0)}}] as $ls
    | (reduce $ls[] as $l ([];
        if $l.id != "" and (.[-1].id == $l.id) then .[-1] = $l else . + [$l] end)) as $m
    | reduce $m[] as $l
        ({model: null, tokens: {input: 0, output: 0, cache_read: 0, cache_creation: 0}};
         .tokens.input += $l.u.input
         | .tokens.output += $l.u.output
         | .tokens.cache_read += $l.u.cache_read
         | .tokens.cache_creation += $l.u.cache_creation
         | .model = (if $l.model != null and $l.model != "<synthetic>" then $l.model else .model end))' "$work/lines"
}

# mkwork: one trap-covered work directory per run, inside $adir so every rename into
# $adir stays an atomic same-directory move. Removed on EXIT/INT/TERM.
mkwork() {
  mkdir -p "$adir" || exit 0
  work=$(mktemp -d "$adir/.tmp.XXXXXX") || exit 0
  trap 'rm -rf "$work"; exit 0' EXIT INT TERM
}

# write_record <dest>: atomically replace dest with JSON read from stdin (needs mkwork).
write_record() {
  _tmp="$work/record.out"
  if cat > "$_tmp" && jq -e . "$_tmp" >/dev/null; then mv -f "$_tmp" "$1"; else rm -f "$_tmp"; fi
}

case "$event" in
  PreToolUse|PostToolUse)
    case "${tool:-}" in Task|Agent) ;; *) exit 0 ;; esac
    tuid=$(clean "$(printf '%s' "${tuid_raw:-}" | tr -d '\r')")
    [ -z "$tuid" ] && exit 0
    dest="$adir/$tuid.json"
    agent=$(printf '%s' "${agent:-}" | tr -d '\r')
    name=${agent#agentic-framework:}
    requested=$(printf '%s' "${requested:-}" | tr -d '\r')
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
    mkwork
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
    printf '%s' "$rec" > "$work/rec.json" || exit 0
    : > "$work/old.json"
    if [ -f "$dest" ] && jq -e 'type == "object"' "$dest" >/dev/null; then cp "$dest" "$work/old.json" || exit 0; fi
    printf '%s' "$payload" | jq -c --slurpfile rec "$work/rec.json" --slurpfile old "$work/old.json" --arg now "$now" \
      --arg verdict "$verdict" '
      (if ($old | length) > 0 then $old[0] else $rec[0] + {started_at: null} end) as $base
      | $base + {ended_at: $now, status: (if $base.background == true then "launched" else "completed" end),
          duration_s: (if (.duration_ms | type) == "number" then (.duration_ms / 1000)
                       else (try (($now | fromdateiso8601) - ($base.started_at | fromdateiso8601)) catch null) end)}
        + (if $verdict == "" then {} else {verdict: $verdict} end)' \
      | write_record "$dest"
    ;;
  SubagentStop)
    aid=$(clean "$(printf '%s' "${aid_raw:-}" | tr -d '\r')")
    [ -z "$aid" ] && exit 0
    mkwork
    atype=$(printf '%s' "${atype:-}" | tr -d '\r')
    name=${atype#agentic-framework:}
    verdict=""
    if is_reviewer "$name"; then
      verdict=$(printf '%s' "${lam:-}" | parse_verdict)
    fi
    tpath=$(printf '%s' "${tpath:-}" | tr -d '\r')
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
