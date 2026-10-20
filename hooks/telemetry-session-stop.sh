#!/bin/sh
# telemetry-session-stop.sh — Stop / SessionEnd telemetry: token accounting + end stamp.
#
# Events: Stop (turns += 1 unless stop_hook_active) and SessionEnd (sets end_reason).
# SessionEnd gives plugin hooks ~1.5 s, so the Stop run already did the accounting;
# SessionEnd re-runs it incrementally (cheap) and stamps end_reason.
# Reads the transcript from the stored transcript_offset (capped at 64 MiB per run),
# consuming COMPLETE lines only, parsing line by line (a malformed line is skipped).
# Claude Code writes one assistant line per content block, each repeating the same
# .message.id and .message.usage, so usage is counted once per message id (the last
# line of the id wins); sidechain lines are ignored. last_message_id carries across
# runs so a message straddling two chunks is not counted twice. A different
# transcript_path, or a file smaller than the stored offset, resets the accounting and
# REPLACES the totals with a recount. Any I/O failure leaves offset and totals untouched.
# sh-only advisory hook: silent, no network, fail-open (exits 0 on every path).
set -u
umask 077
trap 'exit 0' EXIT INT TERM
exec 2>/dev/null

payload=$(cat)
[ -z "$payload" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

field() { printf '%s' "$payload" | jq -r "$1" | tr -d '\r'; }

sid=$(field '.session_id // empty') || exit 0
sid=$(printf '%s' "$sid" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
case $sid in *[!.]*) ;; *) exit 0 ;; esac
event=$(field '.hook_event_name // empty')
reason=$(field '.reason // empty')
tpath=$(field '.transcript_path // empty')
cwd=$(field '.cwd // empty')
active=$(field '.stop_hook_active // false')
case $active in true) ;; *) active=false ;; esac

state=${CLAUDE_STATE_DIR:-$HOME/.claude/.state}
tdir="$state/telemetry/sessions"
mkdir -p "$tdir" || exit 0
dest="$tdir/$sid.json"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
work=$(mktemp -d "$tdir/.tmp.XXXXXX") || exit 0
trap 'rm -rf "$work"; exit 0' EXIT INT TERM

# Base record: the existing file, or a minimal one (hook installed mid-session).
if [ -f "$dest" ] && jq -e 'type == "object"' "$dest" >/dev/null 2>&1; then
  cp "$dest" "$work/base.json" || exit 0
else
  jq -n --arg sid "$sid" --arg now "$now" --arg cwd "$cwd" \
    '{session_id: $sid, started_at: $now, cwd: $cwd, last_source: null, transcript_offset: 0,
      turns: 0, tokens: {input: 0, output: 0, cache_read: 0, cache_creation: 0}}' \
    > "$work/base.json" || exit 0
fi
offset=$(jq -r '.transcript_offset // 0 | floor' "$work/base.json" | tr -d '\r')
case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
stored_path=$(jq -r '.transcript_path | strings' "$work/base.json" | tr -d '\r')
last_id=$(jq -r '.last_message_id | strings' "$work/base.json" | tr -d '\r')

delta='{"input":0,"output":0,"cache_read":0,"cache_creation":0,"model":null,"count":0,"last_id":null}'
new_offset=$offset
replace=false
path_out=$stored_path
cap=67108864
if [ -n "$tpath" ] && [ -f "$tpath" ] && [ -r "$tpath" ]; then
  path_out=$tpath
  size=$(wc -c < "$tpath" | tr -d ' ')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  # Replaced or shrunk transcript: recount from byte 0 and replace the totals.
  if { [ -n "$stored_path" ] && [ "$stored_path" != "$tpath" ]; } || [ "$size" -lt "$offset" ]; then
    offset=0; new_offset=0; last_id=""; replace=true
  fi
  # Chunk = bytes after the offset, capped; keep only up to the last newline so a
  # line still being written is left for the next run.
  if tail -c "+$((offset + 1))" "$tpath" 2>/dev/null | head -c "$cap" > "$work/chunk"; then
    total=$(wc -c < "$work/chunk" | tr -d ' ')
    keep=$total
    if [ "$total" -gt 0 ] && [ "$(tail -c 1 "$work/chunk" | wc -l | tr -d ' ')" -eq 0 ]; then
      keep=$((total - $(tail -n 1 "$work/chunk" | wc -c | tr -d ' ')))
    fi
    if [ "$keep" -eq 0 ] && [ "$total" -ge "$cap" ]; then keep=$total; fi  # one oversized line: skip it
    if [ "$keep" -gt 0 ]; then
      if d=$(head -c "$keep" "$work/chunk" | tr -d '\r' | jq -c -n -R --arg lastid "$last_id" '
          [inputs | fromjson? | objects
           | select(.type == "assistant" and .isSidechain != true
                    and (.message | type) == "object" and (.message.usage | type) == "object")] as $ls
          # one entry per message id: lines of an id are contiguous, the last one wins
          | (reduce $ls[] as $l ([];
              if ($l.message.id | type) == "string" and $l.message.id != ""
                 and length > 0 and (.[-1].message.id == $l.message.id)
              then .[-1] = $l else . + [$l] end)) as $m
          | (if ($m | length) > 0 and $lastid != "" and ($m[0].message.id == $lastid)
             then $m[1:] else $m end) as $c
          | reduce $c[] as $l
              ({input: 0, output: 0, cache_read: 0, cache_creation: 0, model: null, count: 0, last_id: null};
               .input += ($l.message.usage.input_tokens | numbers // 0)
               | .output += ($l.message.usage.output_tokens | numbers // 0)
               | .cache_read += ($l.message.usage.cache_read_input_tokens | numbers // 0)
               | .cache_creation += ($l.message.usage.cache_creation_input_tokens | numbers // 0)
               | .model = (($l.message.model | strings | .[0:100]) // .model)
               | .count += 1
               | .last_id = (($l.message.id | strings) // null))') && [ -n "$d" ]
      then
        delta=$d
        new_offset=$((offset + keep))
      fi
    else
      new_offset=$offset
    fi
  fi
fi

if jq --argjson d "$delta" --argjson off "$new_offset" --arg now "$now" --arg ev "$event" \
     --arg reason "$reason" --argjson replace "$replace" --arg tpath "$path_out" \
     --argjson active "$active" '
  (if $replace then .tokens = {input: 0, output: 0, cache_read: 0, cache_creation: 0} else . end)
  | .tokens.input = ((.tokens.input // 0) + $d.input)
  | .tokens.output = ((.tokens.output // 0) + $d.output)
  | .tokens.cache_read = ((.tokens.cache_read // 0) + $d.cache_read)
  | .tokens.cache_creation = ((.tokens.cache_creation // 0) + $d.cache_creation)
  | (if $d.model then .model = $d.model else . end)
  | (if $replace then .last_message_id = null else . end)
  | (if $d.count > 0 then .last_message_id = $d.last_id else . end)
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
