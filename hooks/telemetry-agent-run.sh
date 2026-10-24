#!/bin/sh
# telemetry-agent-run.sh — agent invocation telemetry (launch, completion, verdict, tokens).
#
# Events: PreToolUse + PostToolUse (matcher Task|Agent) and SubagentStop.
#   Pre  -> <telemetry>/<session>/agents/<tool_use_id>.json  (agent, model tier, start)
#   Post -> same file updated (created from the payload when the Pre record is missing).
#           Launch acknowledgement (an object response with status async_launched or isAsync true, or text
#           starting "Async agent launched successfully" and followed by an "agentId:" line; the Agent tool returns at launch):
#           status "launched", launched_at, agent_id (cleaned, max 64 characters); no duration. The over-cap tail window drops its partial first line.
#           Any other response (older builds): ended_at, duration_s, status completed, reviewer verdict.
#   Stop -> <telemetry>/<session>/agents/subagent-<agent_id>.json  (actual model, tokens, tool_use_id,
#           started_at/duration_s from the transcript's first-to-last timestamp span, verdict (null when
#           no VERDICT line), output_final: tokens.output counts, per message.id, the line with a non-null
#           stop_reason; output_final is false when some message had none and its largest count was used)
#           and the launch record with the same
#           agent_id is completed (ended_at, duration_s, model_actual, verdict from the transcript's
#           SubagentHandback report, read from the LAST 16 MiB; tokens from the first 16 MiB). An untyped event without a transcript writes nothing.
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
        fin: ($m.stop_reason != null),
        u: {input: ($m.usage.input_tokens | numbers // 0),
            output: ($m.usage.output_tokens | numbers // 0),
            cache_read: ($m.usage.cache_read_input_tokens | numbers // 0),
            cache_creation: ($m.usage.cache_creation_input_tokens | numbers // 0)}}] as $ls
    # Per id keep the final line (non-null stop_reason: it carries the real output count; earlier
    # lines hold a placeholder of about 8-11); with no final line, the line with the most output.
    | (reduce $ls[] as $l ([];
        if $l.id != "" and (.[-1].id == $l.id) then
          (.[-1]) as $p
          | if $l.fin then .[-1] = $l
            elif $p.fin then .
            elif $l.u.output >= $p.u.output then .[-1] = $l
            else . end
        else . + [$l] end)) as $m
    | reduce $m[] as $l
        ({model: null, output_final: true, tokens: {input: 0, output: 0, cache_read: 0, cache_creation: 0}};
         .output_final = (.output_final and $l.fin)
         |
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
    # Response text (string, array of blocks, or {content}); a launch acknowledgement is detected on it.
    printf '%s' "$payload" | jq -r '
      ([.tool_response, .tool_output] | map(select(. != null and . != "")) | .[0] // "")
      | if type == "string" then .
        else (if type == "array" then . elif type == "object" and (.content | type) == "array" then .content
              elif type == "object" and (.content | type) == "string" then [.content]
              elif type == "object" then [.] else [] end)
             | [.[] | if type == "string" then . elif type == "object" and (.text | type) == "string" then .text else empty end]
             | join("\n") end' | tr -d '\r' > "$work/resp.txt" || : > "$work/resp.txt"
    launch=0
    laid=""
    if [ "$(printf '%s' "$payload" | jq -r '([.tool_response, .tool_output] | map(select(. != null and . != "")) | .[0] // "") | type == "object" and ((.status == "async_launched") or (.isAsync == true))' | tr -d '\r')" = "true" ]; then
      launch=1
      laid=$(clean "$(printf '%s' "$payload" | jq -r '([.tool_response, .tool_output] | map(select(. != null and . != "")) | .[0] // {}) | .agentId | strings' | tr -d '\r')" | cut -c1-64)
    elif grep -m1 -E '[^[:space:]]' "$work/resp.txt" | grep -qE '^[[:space:]]*Async agent launched successfully' \
         && grep -E '[^[:space:]]' "$work/resp.txt" | sed -n 2p | grep -qE '^agentId:[[:blank:]]*[A-Za-z0-9._-]+'; then
      launch=1
      laid=$(grep -E '[^[:space:]]' "$work/resp.txt" | sed -n 2p | sed -nE 's/^agentId:[[:blank:]]*([A-Za-z0-9._-]+).*/\1/p' | head -n 1 | cut -c1-64)
    fi
    verdict=""
    if [ "$launch" = 0 ] && is_reviewer "$name"; then
      verdict=$(parse_verdict < "$work/resp.txt")
    fi
    # Records go to jq through files (--slurpfile), never the command line: a large
    # value would exceed the Windows 32 K command-line limit and the update would fail.
    printf '%s' "$rec" > "$work/rec.json" || exit 0
    : > "$work/old.json"
    if [ -f "$dest" ] && jq -e 'type == "object"' "$dest" >/dev/null; then cp "$dest" "$work/old.json" || exit 0; fi
    printf '%s' "$payload" | jq -c --slurpfile rec "$work/rec.json" --slurpfile old "$work/old.json" --arg now "$now" \
      --arg verdict "$verdict" --arg launch "$launch" --arg laid "$laid" '
      (if ($old | length) > 0 then $old[0] else $rec[0] + {started_at: null} end) as $base
      | $base
        + (if $launch == "1"
           then {status: "launched", launched_at: $now, agent_id: (if $laid == "" then null else $laid end)}
           else {ended_at: $now, status: (if $base.background == true then "launched" else "completed" end),
                 duration_s: (if (.duration_ms | type) == "number" then (.duration_ms / 1000)
                              else (try (($now | fromdateiso8601) - ($base.started_at | fromdateiso8601)) catch null) end)}
           end)
        + (if $verdict == "" then {} else {verdict: $verdict} end)' \
      | write_record "$dest"
    ;;
  SubagentStop)
    aid=$(clean "$(printf '%s' "${aid_raw:-}" | tr -d '\r')")
    [ -z "$aid" ] && exit 0
    atype=$(printf '%s' "${atype:-}" | tr -d '\r')
    tpath=$(printf '%s' "${tpath:-}" | tr -d '\r')
    readable=0
    if [ -n "$tpath" ] && [ -f "$tpath" ] && [ -r "$tpath" ]; then readable=1; fi
    # Untyped event without a transcript (classifier sidechain): nothing a report or a cost can use.
    if [ -z "$atype" ] && [ "$readable" = 0 ]; then exit 0; fi
    mkwork
    name=${atype#agentic-framework:}
    sums='{}'
    first_ts=""
    last_ts=""
    hb=""
    if [ "$readable" = 1 ]; then
      sums=$(sum_transcript "$tpath") || sums='{}'
      if [ -f "$work/lines" ]; then
        first_ts=$(jq -r -n -R 'first(inputs | fromjson? | objects) | .timestamp | strings' "$work/lines" | tr -d '\r')
        last_ts=$(jq -r -n -R '[inputs | fromjson? | objects | .timestamp | strings] | last // empty' "$work/lines" | tr -d '\r')
        if is_reviewer "$name"; then
          hb_src="$work/lines"
          tsize=$(wc -c < "$tpath" 2>/dev/null | tr -d '[:space:]')
          case "$tsize" in ''|*[!0-9]*) tsize=0 ;; esac
          if [ "$tsize" -gt 16777216 ]; then
            # the report is the file's tail, beyond the capped head read
            if tail -c 16777216 -- "$tpath" | sed 1d | tr -d '\r' > "$work/tail"; then hb_src="$work/tail"; fi
          fi
          hb=$(jq -r -n -R '
            def blocks: (.message | if type == "object" then .content else null end) | if type == "array" then . else [] end;
            [inputs | fromjson? | objects | select(.type == "assistant")] as $a
            | ([$a[] | [blocks[] | select(type == "object" and .type == "tool_use" and .name == "SubagentHandback" and (.input | type) == "object")
                        | .input.message | strings] | last // empty] | last)
              // ([$a[] | [blocks[] | if type == "string" then . elif type == "object" and .type == "text" and (.text | type) == "string" then .text else empty end]
                        | select(length > 0) | join("\n")] | last)
              // ""' "$hb_src")
        fi
      fi
    fi
    [ -z "$sums" ] && sums='{}'
    verdict=""
    if is_reviewer "$name"; then
      verdict=$(printf '%s' "${lam:-}" | parse_verdict)
      [ -z "$verdict" ] && verdict=$(printf '%s' "$hb" | parse_verdict)
    fi
    # Link to the launch record of this agent_id (status launched or completed); first match wins.
    linked=""
    # (resumed agent: a completed record keeps its link, so a second stop re-merges onto it)
    aid_link=$(printf '%s' "$aid" | cut -c1-64)
    # names relative to $adir (no spaces by construction): an absolute path may hold one
    for f in $(cd "$adir" && grep -lF -- "\"agent_id\":\"$aid_link\"" ./*.json 2>/dev/null); do
      case ${f##*/} in subagent-*) continue ;; esac
      f="$adir/${f#./}"
      if jq -e --arg a "$aid_link" 'type == "object" and .agent_id == $a and (.status == "launched" or .status == "completed")' "$f" >/dev/null; then linked=$f; break; fi
    done
    printf '%s' "$sums" > "$work/sums.json" || exit 0
    tuid_link=""
    if [ -n "$linked" ]; then
      cp "$linked" "$work/old.json" || exit 0
      tuid_link=$(jq -r '.tool_use_id // empty' "$work/old.json" | tr -d '\r')
      jq -n -c --slurpfile old "$work/old.json" --slurpfile sums "$work/sums.json" --arg now "$now" \
        --arg first "$first_ts" --arg verdict "$verdict" '
        def ts: sub("\\.[0-9]+"; "") | fromdateiso8601;
        ($now | ts) as $n
        | (try ($old[0].started_at | ts) catch null) as $s
        | (try ($first | ts) catch null) as $f
        | $old[0]
          + {status: "completed", ended_at: $now,
             duration_s: (if $s != null then $n - $s elif $f != null then $n - $f else null end)}
          + (if $verdict == "" then {} else {verdict: $verdict} end)
          + (if $sums[0].model != null then {model_actual: $sums[0].model} else {} end)' \
        | write_record "$linked"
    fi
    jq -n -c --arg id "$aid" --arg type "$atype" --arg name "$name" --arg now "$now" \
      --arg verdict "$verdict" --arg first "$first_ts" --arg last "$last_ts" --arg tuid "$tuid_link" --slurpfile sums "$work/sums.json" '
      def ts: sub("\\.[0-9]+"; "") | fromdateiso8601;
      (try ($first | ts) catch null) as $f
      | (try ($last | ts) catch null) as $l
      | {agent_id: $id, agent_type: $type, agent_name: $name, ended_at: $now,
         tool_use_id: (if $tuid == "" then null else $tuid end),
         started_at: (if $f != null then $first else null end),
         duration_s: (if $f != null and $l != null then ($l - $f)
                      elif $f != null then (($now | ts) - $f) else null end),
         verdict: (if $verdict == "" then null else $verdict end)}
      + (if $sums[0].tokens then {model_actual: $sums[0].model, tokens: $sums[0].tokens, output_final: $sums[0].output_final} else {} end)' \
      | write_record "$adir/subagent-$aid.json"
    ;;
esac
exit 0
