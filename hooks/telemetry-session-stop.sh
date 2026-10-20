#!/bin/sh
# telemetry-session-stop.sh — Stop / SessionEnd telemetry: token accounting + end stamp.
#
# Events: Stop (turns += 1 unless stop_hook_active) and SessionEnd (sets end_reason).
# SessionEnd gives plugin hooks ~1.5 s, so the Stop run already did the accounting;
# SessionEnd re-runs it incrementally (cheap) and stamps end_reason.
# Reads the transcript from the stored transcript_offset (capped at 16 MiB per run; the
# stored offset catches up over later runs), consuming COMPLETE lines only, parsing line by
# line (a malformed line is skipped). The cap can be lowered for tests with
# AF_TELEMETRY_CHUNK_CAP=<bytes> (ignored unless all digits and >= 1024).
# Claude Code writes one assistant line per content block, each repeating the same
# .message.id and .message.usage, so usage is counted once per message id (the last
# line of the id wins); sidechain lines are ignored. last_message_id (capped at 200
# chars) and last_message_usage carry across runs so a message straddling two chunks is
# counted once, with the usage of its LAST line (the continuation adds only the growth).
# A different transcript_path, or a file smaller than the stored offset, resets the
# accounting and REPLACES the totals with a recount, but only once the new chunk was read
# successfully. Any I/O failure leaves path, offset and totals untouched.
# jq always reads FILES (piping into the native jq.exe on Windows is ~7x slower).
# sh-only advisory hook: silent, no network, fail-open (exits 0 on every path).
set -u
umask 077
trap 'exit 0' EXIT INT TERM
exec 2>/dev/null

payload=$(cat)
[ -z "$payload" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# One jq call for every payload field; @sh makes the assignments safe to eval.
fields=$(printf '%s' "$payload" | jq -r '
  @sh "sid=\(.session_id // "" | tostring) event=\(.hook_event_name // "" | tostring) reason=\(.reason // "" | tostring) tpath=\(.transcript_path // "" | tostring) cwd=\(.cwd // "" | tostring) active=\(.stop_hook_active // false | tostring)"') || exit 0
eval "$fields"
sid=$(printf '%s' "${sid:-}" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
case $sid in *[!.]*) ;; *) exit 0 ;; esac
case ${active:-} in true) ;; *) active=false ;; esac
tpath=$(printf '%s' "${tpath:-}" | tr -d '\r')
event=${event:-}; reason=${reason:-}; cwd=${cwd:-}

cap=16777216
case ${AF_TELEMETRY_CHUNK_CAP:-} in
  ''|*[!0-9]*) ;;
  *) if [ "${#AF_TELEMETRY_CHUNK_CAP}" -le 12 ] && [ "$AF_TELEMETRY_CHUNK_CAP" -ge 1024 ]; then cap=$AF_TELEMETRY_CHUNK_CAP; fi ;;
esac

state=${CLAUDE_STATE_DIR:-$HOME/.claude/.state}
tdir="$state/telemetry/sessions"
mkdir -p "$tdir" || exit 0
dest="$tdir/$sid.json"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
work=$(mktemp -d "$tdir/.tmp.XXXXXX") || exit 0
trap 'rm -rf "$work"; exit 0' EXIT INT TERM

# Base record: the existing file, or a minimal one (hook installed mid-session).
# shellcheck disable=SC2016  # the filter is a jq program, not shell
base_filter='if type == "object" and length > 0 then . else
  {session_id: $sid, started_at: $now, cwd: $cwd, last_source: null, transcript_offset: 0,
   turns: 0, tokens: {input: 0, output: 0, cache_read: 0, cache_creation: 0}} end'
printf '{}' > "$work/empty.json" || exit 0
src=$dest
[ -f "$dest" ] || src="$work/empty.json"
{ jq -c --arg sid "$sid" --arg now "$now" --arg cwd "$cwd" "$base_filter" "$src" > "$work/base.json" \
  && [ -s "$work/base.json" ]; } \
  || jq -c --arg sid "$sid" --arg now "$now" --arg cwd "$cwd" "$base_filter" "$work/empty.json" > "$work/base.json" \
  || exit 0

# One jq call for the base-record fields (the path comparison happens inside jq as well).
# shellcheck disable=SC2016  # jq program
bfields=$(jq -r --arg tpath "$tpath" '
  ((.transcript_path | strings) // "") as $sp
  | @sh "offset=\(((.transcript_offset | numbers | floor) // 0) | tostring) stored_path=\($sp) last_id=\(((.last_message_id | strings | .[0:200]) // "")) lastu=\((.last_message_usage | objects // {}) | tojson) path_changed=\(if $tpath != "" and $sp != "" and $sp != $tpath then 1 else 0 end)"' \
  "$work/base.json") || exit 0
eval "$bfields"
case "${offset:-}" in ''|*[!0-9]*) offset=0 ;; esac
case ${path_changed:-} in 1) ;; *) path_changed=0 ;; esac
[ -z "${lastu:-}" ] && lastu='{}'
stored_path=${stored_path:-}; last_id=${last_id:-}

printf '%s' '{"input":0,"output":0,"cache_read":0,"cache_creation":0,"model":null,"count":0,"last_id":null,"last_u":null}' \
  > "$work/delta.json" || exit 0
new_offset=$offset
replace=false
path_out=$stored_path
if [ -n "$tpath" ] && [ -f "$tpath" ] && [ -r "$tpath" ]; then
  size=$(wc -c < "$tpath" | tr -d ' ')
  case "$size" in ''|*[!0-9]*) size="" ;; esac
  # An unreadable size skips accounting entirely (no reset, nothing changes).
  if [ -n "$size" ]; then
    want_replace=false; eoff=$offset; elast_id=$last_id; elastu=$lastu
    # Replaced or shrunk transcript: recount from byte 0 and replace the totals.
    if [ "$path_changed" -eq 1 ] || [ "$size" -lt "$offset" ]; then
      want_replace=true; eoff=0; elast_id=""; elastu='{}'
    fi
    # Chunk = bytes after the offset, capped; keep only up to the last newline so a
    # line still being written is left for the next run.
    if tail -c "+$((eoff + 1))" "$tpath" 2>/dev/null | head -c "$cap" > "$work/chunk"; then
      total=$(wc -c < "$work/chunk" | tr -d ' ')
      keep=$total
      if [ "$total" -gt 0 ] && [ "$(tail -c 1 "$work/chunk" | wc -l | tr -d ' ')" -eq 0 ]; then
        keep=$((total - $(tail -n 1 "$work/chunk" | wc -c | tr -d ' ')))
      fi
      if [ "$keep" -eq 0 ] && [ "$total" -ge "$cap" ]; then keep=$total; fi  # one oversized line: skip it
      if [ "$keep" -gt 0 ]; then
        head -c "$keep" "$work/chunk" | tr -d '\r' > "$work/lines" && rm -f "$work/chunk"
        # shellcheck disable=SC2016  # jq program
        if [ -s "$work/lines" ] && jq -c -n -R --arg lastid "$elast_id" --argjson lastu "$elastu" '
            # each line is reduced to {id, model, usage} at once; the full line is not kept
            [inputs | fromjson? | objects
             | select(.type == "assistant" and .isSidechain != true
                      and (.message | type) == "object" and (.message.usage | type) == "object")
             | .message as $m
             | {id: (($m.id | strings | .[0:200]) // ""),
                model: (($m.model | strings | .[0:100]) // null),
                u: {input: ($m.usage.input_tokens | numbers // 0),
                    output: ($m.usage.output_tokens | numbers // 0),
                    cache_read: ($m.usage.cache_read_input_tokens | numbers // 0),
                    cache_creation: ($m.usage.cache_creation_input_tokens | numbers // 0)}}] as $ls
            # one entry per message id: lines of an id are contiguous, the last one wins
            | (reduce $ls[] as $l ([];
                if $l.id != "" and (.[-1].id == $l.id) then .[-1] = $l else . + [$l] end)) as $m
            # continuation of the message that ended the previous chunk: add only the growth
            | (($m | length) > 0 and $lastid != "" and $m[0].id == $lastid) as $cont
            | def grow($k): ([($m[0].u[$k] - ($lastu[$k] // 0)), 0] | max);
              reduce range(0; $m | length) as $i
              ({input: 0, output: 0, cache_read: 0, cache_creation: 0, model: null, count: 0, last_id: null, last_u: null};
               $m[$i] as $l
               | (if $i == 0 and $cont
                  then {input: grow("input"), output: grow("output"), cache_read: grow("cache_read"),
                        cache_creation: grow("cache_creation")}
                  else $l.u end) as $du
               | .input += $du.input | .output += $du.output
               | .cache_read += $du.cache_read | .cache_creation += $du.cache_creation
               | .model = (if $l.model != null and $l.model != "<synthetic>" then $l.model else .model end)
               | .count += 1
               | .last_id = (if $l.id == "" then null else $l.id end)
               | .last_u = $l.u)' \
            "$work/lines" > "$work/delta.new" && [ -s "$work/delta.new" ]
        then
          mv -f "$work/delta.new" "$work/delta.json" || exit 0
          new_offset=$((eoff + keep)); replace=$want_replace; path_out=$tpath
        fi
      else
        new_offset=$eoff; replace=$want_replace; path_out=$tpath
      fi
    fi
  fi
fi

if jq --slurpfile d "$work/delta.json" --argjson off "$new_offset" --arg now "$now" --arg ev "$event" \
     --arg reason "$reason" --argjson replace "$replace" --arg tpath "$path_out" \
     --argjson active "$active" '
  (if $replace then .tokens = {input: 0, output: 0, cache_read: 0, cache_creation: 0} else . end)
  | .tokens.input = ((.tokens.input // 0) + $d[0].input)
  | .tokens.output = ((.tokens.output // 0) + $d[0].output)
  | .tokens.cache_read = ((.tokens.cache_read // 0) + $d[0].cache_read)
  | .tokens.cache_creation = ((.tokens.cache_creation // 0) + $d[0].cache_creation)
  | (if $d[0].model then .model = $d[0].model else . end)
  | (if $replace then .last_message_id = null | .last_message_usage = null else . end)
  | (if $d[0].count > 0 then .last_message_id = $d[0].last_id | .last_message_usage = $d[0].last_u else . end)
  | (if $tpath == "" then . else .transcript_path = $tpath end)
  | .transcript_offset = $off
  | .ended_at = $now
  | .duration_s = (try (($now | fromdateiso8601) - (.started_at | fromdateiso8601)) catch null)
  | (if $ev == "SessionEnd" then .end_reason = $reason
     elif $active then . else .turns = ((.turns // 0) + 1) end)' \
     "$work/base.json" > "$work/out.json"
then
  # $work lives inside $tdir, so this mv is an atomic same-directory rename.
  mv -f "$work/out.json" "$dest"
fi
exit 0
