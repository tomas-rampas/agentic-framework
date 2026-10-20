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
umask 077
trap 'exit 0' EXIT INT TERM
exec 2>/dev/null

payload=$(cat)
[ -z "$payload" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# One jq call for every payload field; @sh makes the assignments safe to eval.
fields=$(printf '%s' "$payload" | jq -r '
  @sh "sid=\(.session_id // "" | tostring) cwd=\(.cwd // "" | tostring) source_ev=\(.source // "" | tostring) model=\(.model // "" | tostring) version=\(.claude_version // "" | tostring)"') || exit 0
eval "$fields"
sid=$(printf '%s' "${sid:-}" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
case $sid in *[!.]*) ;; *) exit 0 ;; esac

cwd=$(printf '%s' "${cwd:-}" | tr -d '\r')
[ -z "$cwd" ] && cwd=$(pwd)
source_ev=$(printf '%s' "${source_ev:-}" | tr -d '\r')
model=$(printf '%s' "${model:-}" | tr -d '\r')
version=$(printf '%s' "${version:-}" | tr -d '\r')

# project: basename of the origin URL, with query/fragment, scheme and userinfo
# (user:token@) removed first so no credential can reach the record; falls back to the
# cwd basename when nothing usable remains (e.g. a bare host).
url=$(git -C "$cwd" remote get-url origin 2>/dev/null | head -n 1 | tr -d '\r')
project=""
if [ -n "$url" ]; then
  # Anything that could hide part of a credential (a % anywhere, a ? or # in the authority or scp form, an @ that is not
  # the single leading userinfo/scp user, a / inside the userinfo) falls back to the cwd
  # basename: when in doubt, store nothing derived from the URL.
  safe=1
  case $url in *%*) safe=0 ;; esac
  u=$url
  if [ "$safe" -eq 1 ]; then
    case $url in
      *://*)
        sch=${url%%://*}
        case $sch in ''|*[!a-z]*) safe=0 ;; esac
        u=${url#*://}; a=${u%%/*}
        case $a in *[?#]*) safe=0 ;; esac
        case $u in
          *@*@*) safe=0 ;;
          *@*) case $a in *@*) ;; *) safe=0 ;; esac ;;
        esac
        u=${a##*@}${u#"$a"} ;;
      *@*)
        case $url in *[?#]*) safe=0 ;; esac
        usr=${url%%@*}; hp=${url#*@}
        case $usr in ''|*[!A-Za-z0-9._-]*) safe=0 ;; esac
        case $hp in *@*) safe=0 ;; esac
        case $hp in
          *:*) h=${hp%%:*}; case $h in ''|*/*) safe=0 ;; esac ;;
          *) safe=0 ;;
        esac
        u=$hp ;;
    esac
  fi
  if [ "$safe" -eq 1 ]; then
    u=${u%%[?#]*}; u=${u%/}
    case $u in
      */*|*:*) project=${u##*/}; project=${project##*:}; project=${project%.git}
               project=$(printf '%s' "$project" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
               case $project in *[!.]*) ;; *) project="" ;; esac ;;
    esac
  fi
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
trap 'rm -f "$tmp" "$tmp.old"; exit 0' EXIT INT TERM

# The existing record goes to jq through a file (--slurpfile), never the command line:
# an oversized cwd or model must not push the command past the Windows limit.
# $old is then an array: the record, or empty when absent or unreadable.
oldf="$tmp.old"
: > "$oldf"
if [ -f "$dest" ] && jq -e 'type == "object"' "$dest" >/dev/null 2>&1; then
  cp "$dest" "$oldf" || exit 0
fi
if jq -n --slurpfile old "$oldf" --arg sid "$sid" --arg now "$now" --arg project "$project" \
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

# Retention (confined to $tdir). Work directories (.tmp.*, any depth, empty or not) left by
# a killed hook go first, judged on their own mtime (deleting files inside would refresh
# it): one hour is far beyond any hook's life; -prune stops find descending into what it
# removes. Then files untouched for >30 days, then empty directories (a per-session
# directory's own mtime does not refresh when files inside it change).
find "$tdir" -mindepth 1 -name '.tmp.*' -mmin +60 -prune -exec rm -rf {} + 2>/dev/null
find "$tdir" -type f -mtime +30 -exec rm -f {} + 2>/dev/null
find "$tdir" -mindepth 1 -depth -type d -empty ! -name '.tmp.*' -exec rmdir {} \; 2>/dev/null
exit 0
