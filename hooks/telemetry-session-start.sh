#!/bin/sh
# telemetry-session-start.sh — SessionStart telemetry: create/refresh the session record.
#
# Event: SessionStart (all sources: startup|resume|clear|compact|fork).
# Writes <state>/telemetry/sessions/<session_id>.json (project, branch, model, token
# counters at zero). On resume/compact the existing record keeps started_at, tokens,
# turns and transcript_offset; only last_source, branch, cwd (and model) are refreshed.
# Prunes telemetry entries older than 30 days. sh-only advisory hook: silent (no stdout,
# no stderr), no network, fail-open (exits 0 on every path, including malformed stdin).
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

cwd=$(field '.cwd // empty')
[ -z "$cwd" ] && cwd=$(pwd)
source_ev=$(field '.source // empty')
model=$(field '.model // empty')
version=$(field '.claude_version // empty')

# project: basename of the origin URL (this also drops any user:token@ userinfo,
# which precedes the last path segment); falls back to the cwd basename.
url=$(git -C "$cwd" remote get-url origin 2>/dev/null | head -n 1 | tr -d '\r')
project=""
if [ -n "$url" ]; then
  project=${url%/}; project=${project##*/}; project=${project##*:}; project=${project%.git}
fi
if [ -z "$project" ]; then
  project=$(printf '%s' "$cwd" | tr "\\\\" '/'); project=${project%/}; project=${project##*/}
fi
branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null | head -n 1 | tr -d '\r')
[ -z "$branch" ] && branch="-"

state=${CLAUDE_STATE_DIR:-$HOME/.claude/.state}
tdir="$state/telemetry/sessions"
mkdir -p "$tdir" || exit 0
dest="$tdir/$sid.json"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp "$tdir/.tmp.XXXXXX") || exit 0

# $old is the existing record (empty array when absent or unreadable).
old='[]'
if [ -f "$dest" ] && jq -e 'type == "object"' "$dest" >/dev/null 2>&1; then
  old=$(jq -c '[.]' "$dest")
fi

if jq -n --argjson old "$old" --arg sid "$sid" --arg now "$now" --arg project "$project" \
     --arg cwd "$cwd" --arg branch "$branch" --arg src "$source_ev" --arg model "$model" \
     --arg ver "$version" '
  {session_id: $sid, started_at: $now, project: $project, cwd: $cwd, branch: $branch,
   source: $src, model: (if $model == "" then null else $model end),
   last_source: $src, transcript_offset: 0, turns: 0,
   tokens: {input: 0, output: 0, cache_read: 0, cache_creation: 0}}
  | (if $ver == "" then . else . + {claude_version: $ver} end) as $new
  | if ($old | length) == 0 then $new
    else $old[0] + {last_source: $src, branch: $branch, cwd: $cwd}
         + (if $new.model then {model: $new.model} else {} end)
    end' > "$tmp"
then
  mv -f "$tmp" "$dest"
else
  rm -f "$tmp"
fi

# Retention: drop session files and per-session directories untouched for >30 days.
find "$tdir" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + 2>/dev/null
exit 0
