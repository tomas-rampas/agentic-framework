#!/bin/sh
# migrate-global-claude-md.sh — remove the legacy framework policy block from the
# user-level CLAUDE.md (REQ-013). Since 5.2.0 the plugin delivers the policy at
# session start (hooks/session-start-context), so the copy in ~/.claude/CLAUDE.md is
# redundant and doubles every session's context.
#
# Usage: sh scripts/migrate-global-claude-md.sh [--dry-run] [PATH]
#   PATH       file to migrate (default: $HOME/.claude/CLAUDE.md)
#   --dry-run  print the lines that would be removed; change nothing; exit 0
#
# The block starts at the first line "# Claude Code CLI - Agent Execution Framework"
# and ends before the next line starting with "# " that is not part of a shipped
# policy text. Every byte outside the block, line endings included, is preserved.
# Before changing anything a copy is written beside the file as
# CLAUDE.md.bak-<yyyyMMdd-HHmmss>.
#
# Exit codes: 0 migrated, dry run, or nothing to do (idempotent)
#             2 usage / file error
#             3 refused: the block holds non-blank lines that appear in none of the
#               bundled reference policies (scripts/legacy-policy/*.md), i.e. the
#               block was customised; the differing lines are printed, nothing is
#               changed and no backup is written.
set -u

TITLE='# Claude Code CLI - Agent Execution Framework'
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 2
REF_DIR="$SCRIPT_DIR/legacy-policy"

dry=0
path=""
have_path=0
endopts=0
for a in "$@"; do
  if [ "$endopts" -eq 0 ]; then
    case "$a" in
      --) endopts=1; continue ;;
      --dry-run|-n) dry=1; continue ;;
      -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
      -?*) echo "migrate-global-claude-md: unknown option: $a" >&2; exit 2 ;;
    esac
  fi
  if [ "$have_path" -eq 1 ]; then
    echo "migrate-global-claude-md: unexpected extra argument: $a" >&2
    exit 2
  fi
  path="$a"; have_path=1
done
[ -n "$path" ] || path="${HOME:-}/.claude/CLAUDE.md"
case "$path" in -*) path="./$path" ;; esac   # a bare "-", or any path given after "--"; keeps awk from reading it as an option
# Defence in depth: the target is fed to awk on stdin, never as an operand. Still, prefix a
# relative path whose text before its first "=" is an awk identifier (drive-qualified paths are not).
case "${path%%=*}" in "$path"|*[!A-Za-z0-9_]*|[0-9]*) ;; *) path="./$path" ;; esac

if [ ! -f "$path" ]; then
  echo "migrate-global-claude-md: file not found: $path" >&2
  exit 2
fi

# Warnings only (stderr, the exit status is unchanged).
# The installed plugin (what sessions run) must carry POLICY.md (5.2.0 or later).
plugin_key="agentic-framework@agentic-framework"
installed_json="${HOME:-}/.claude/plugins/installed_plugins.json"
install_path=""
if [ -r "$installed_json" ]; then
  if command -v jq >/dev/null 2>&1; then
    install_path=$(jq -r --arg k "$plugin_key" '.plugins[$k][0].installPath // empty' "$installed_json" 2>/dev/null)
  else
    install_path=$(tr '{},' '\n\n\n' < "$installed_json" | awk -v k="\"$plugin_key\"" '
      index($0, k) { f = 1 } f && /"installPath"/ { sub(/^[^:]*:[ \t]*"/, ""); sub(/"[ \t]*$/, ""); gsub(/\\\\/, "\\"); print; exit }')
  fi
fi
if [ -z "$install_path" ] || [ ! -f "$install_path/POLICY.md" ]; then
  echo "migrate-global-claude-md: warning: the installed agentic-framework plugin at ${install_path:-<not found in $installed_json>} has no POLICY.md; sessions get no policy until the plugin is updated to 5.2.0 or later" >&2
fi
if [ ! -f "$SCRIPT_DIR/../POLICY.md" ]; then
  echo "migrate-global-claude-md: warning: this script's folder has no POLICY.md ($SCRIPT_DIR/../POLICY.md)" >&2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "migrate-global-claude-md: warning: jq is not in PATH; the SessionStart hook still prints the policy without it, but skips the branch line." >&2
fi

# A UTF-8 BOM at the start of the file is outside the block: ignored when matching the
# title, kept in the output. The three bytes are read as hex so no NUL reaches the shell.
bom=$(printf '\357\273\277')
has_bom=0
[ "$(LC_ALL=C head -c 3 "$path" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ] && has_bom=1

set -- "$REF_DIR"/claude-md-v*.md
if [ ! -f "$1" ]; then
  echo "migrate-global-claude-md: no reference policies in $REF_DIR" >&2
  exit 2
fi

# One pass: the references (absolute operands, CR stripped) build the known-line set,
# then the target (stdin, never an operand: awk would read name=value or ns::name=value
# as an assignment) is scanned. Prints START, END (first line after the block) and one
# BAD line per non-blank block line found in no reference.
scan=$(LC_ALL=C awk -v title="$TITLE" -v nref="$#" '
  FILENAME != "-" { gsub(/\r/, ""); if ($0 ~ /[^ \t]/) ref[$0] = 1; next }
  { l = $0; sub(/\r$/, "", l)
    if (FNR == 1) sub(/^\357\273\277/, "", l)
    if (!start) { if (l == title) start = FNR; next }
    if (!done) {
      if (l ~ /^# / && !(l in ref)) { end = FNR; done = 1; next }
      if (l ~ /[^ \t]/ && !(l in ref)) bad[++nb] = FNR ": " l
    } }
  END { print "START " start + 0; print "END " (end ? end : FNR + 1)
        for (i = 1; i <= nb; i++) print "BAD " bad[i] }' "$@" - < "$path") || { echo "migrate-global-claude-md: scan failed" >&2; exit 2; }

start=$(printf '%s\n' "$scan" | sed -n 's/^START //p')
end=$(printf '%s\n' "$scan" | sed -n 's/^END //p')
bad=$(printf '%s\n' "$scan" | sed -n 's/^BAD //p')

if [ "${start:-0}" -eq 0 ]; then
  echo "nothing to do: no framework policy block in $path"
  exit 0
fi

if [ -n "$bad" ]; then
  echo "REFUSED: the framework block in $path (lines $start-$((end - 1))) holds lines found in none of the shipped policies; nothing changed, no backup written."
  echo "Differing lines (line number: text):"
  printf '%s\n' "$bad"
  exit 3
fi

if [ "$dry" -eq 1 ]; then
  echo "dry run: would remove lines $start-$((end - 1)) ($((end - start)) lines) from $path:"
  sed -n "${start},$((end - 1))p" "$path" | LC_ALL=C sed "1s/^$bom//"
  exit 0
fi

ts=$(date +%Y%m%d-%H%M%S)
backup="$path.bak-$ts"
if [ -e "$backup" ] || [ -L "$backup" ]; then
  echo "migrate-global-claude-md: backup already exists, refusing to overwrite: $backup" >&2
  exit 2
fi
cp -p "$path" "$backup" || { echo "migrate-global-claude-md: backup failed" >&2; exit 2; }

tmp=$(mktemp "$path.migrate-tmp.XXXXXX") || { echo "migrate-global-claude-md: cannot create temp file" >&2; exit 2; }
{
  [ "$has_bom" -eq 1 ] && [ "$start" -eq 1 ] && printf '%s' "$bom"
  [ "$start" -gt 1 ] && head -n "$((start - 1))" "$path"
  tail -n "+$end" "$path"
} > "$tmp" || { rm -f "$tmp"; echo "migrate-global-claude-md: write failed" >&2; exit 2; }
cat "$tmp" > "$path" || { rm -f "$tmp"; echo "migrate-global-claude-md: write failed; restore from $backup" >&2; exit 2; }
rm -f "$tmp"

echo "migrated: removed lines $start-$((end - 1)) ($((end - start)) lines) from $path"
echo "backup: $backup"
exit 0
