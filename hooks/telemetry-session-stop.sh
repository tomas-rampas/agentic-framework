#!/bin/sh
# telemetry-session-stop.sh — Stop / SessionEnd telemetry: token accounting + end stamp.
#
# Events: Stop (turns += 1) and SessionEnd (sets end_reason). SessionEnd gives plugin
# hooks ~1.5 s, so the Stop run already did the accounting; SessionEnd re-runs it
# incrementally (cheap) and stamps end_reason.
# Reads the transcript from the stored transcript_offset, consuming COMPLETE lines only,
# and sums .message.usage of assistant lines into the session record. The offset and
# totals advance only after the whole chunk parsed; any jq failure leaves them untouched.
# sh-only advisory hook: silent, no network, fail-open (exits 0 on every path).
set -u
trap 'exit 0' EXIT INT TERM
exec 2>/dev/null

payload=$(cat)
[ -z "$payload" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

field() { printf '%s' "$payload" | jq -r "$1" | tr -d '\r'; }

sid=$(field '.session_id // empty') || exit 0
sid=$(printf '%s' "$sid" | sed 's/[^-._[:alnum:]]//g')
[ -z "$sid" ] && exit 0
event=$(field '.hook_event_name // empty')
reason=$(field '.reason // empty')
tpath=$(field '.transcript_path // empty')
cwd=$(field '.cwd // empty')

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

delta='{"input":0,"output":0,"cache_read":0,"cache_creation":0,"model":null}'
new_offset=$offset
if [ -n "$tpath" ] && [ -r "$tpath" ]; then
  # Chunk = bytes after the stored offset; keep only up to the last newline so a
  # line still being written is left for the next run.
  tail -c "+$((offset + 1))" "$tpath" > "$work/chunk" 2>/dev/null || : > "$work/chunk"
  total=$(wc -c < "$work/chunk" | tr -d ' ')
  keep=$total
  if [ "$total" -gt 0 ] && [ "$(tail -c 1 "$work/chunk" | wc -l | tr -d ' ')" -eq 0 ]; then
    keep=$((total - $(tail -n 1 "$work/chunk" | wc -c | tr -d ' ')))
  fi
  head -c "$keep" "$work/chunk" > "$work/complete"
  if d=$(jq -c -n 'reduce (inputs | select(type == "object" and .type == "assistant"
          and (.message | type) == "object" and (.message.usage | type) == "object")) as $l
        ({input: 0, output: 0, cache_read: 0, cache_creation: 0, model: null};
         .input += ($l.message.usage.input_tokens // 0)
         | .output += ($l.message.usage.output_tokens // 0)
         | .cache_read += ($l.message.usage.cache_read_input_tokens // 0)
         | .cache_creation += ($l.message.usage.cache_creation_input_tokens // 0)
         | .model = ($l.message.model // .model))' "$work/complete") && [ -n "$d" ]
  then
    delta=$d
    new_offset=$((offset + keep))
  fi
fi

if jq --argjson d "$delta" --argjson off "$new_offset" --arg now "$now" --arg ev "$event" \
     --arg reason "$reason" '
  .tokens.input = ((.tokens.input // 0) + $d.input)
  | .tokens.output = ((.tokens.output // 0) + $d.output)
  | .tokens.cache_read = ((.tokens.cache_read // 0) + $d.cache_read)
  | .tokens.cache_creation = ((.tokens.cache_creation // 0) + $d.cache_creation)
  | (if $d.model then .model = $d.model else . end)
  | .transcript_offset = $off
  | .ended_at = $now
  | .duration_s = (try (($now | fromdateiso8601) - (.started_at | fromdateiso8601)) catch null)
  | (if $ev == "SessionEnd" then .end_reason = $reason else .turns = ((.turns // 0) + 1) end)' \
     "$work/base.json" > "$work/out.json"
then
  # Same directory as dest, so mv is an atomic rename.
  cp "$work/out.json" "$tdir/.tmp.$sid.$$" && mv -f "$tdir/.tmp.$sid.$$" "$dest"
fi
exit 0
