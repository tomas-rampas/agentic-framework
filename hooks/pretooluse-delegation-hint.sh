#!/bin/sh
# pretooluse-delegation-hint.sh — PreToolUse hook (POSIX sh port).
#
# Detects the technology of the file being written from its extension and suggests
# the matching specialist subagent, at most once per session per suggested agent.
# Never blocks; fail-open: any error => exit 0 with no output.
#
# Ported from pretooluse-delegation-hint.ps1 to POSIX sh.

set -u

# Read JSON payload from stdin
payload=$(cat 2>/dev/null)
if [ -z "$payload" ]; then
  exit 0
fi

# Extract file_path from JSON (try tool_input.file_path or tool_input.path)
file_path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
if [ -z "$file_path" ]; then
  exit 0
fi

# Get extension (lowercase)
ext=$(printf '%s' "$file_path" | sed 's/.*\(\.[a-zA-Z0-9]*\)$/\1/' | tr '[:upper:]' '[:lower:]')
if [ "$ext" = "$file_path" ]; then
  # No extension found
  exit 0
fi

# Map extension to tech and agent (case statement for all extensions)
case "$ext" in
  .rs)   tech="Rust"; agent="rust-expert" ;;
  .py)   tech="Python"; agent="python-expert" ;;
  .ts)   tech="TypeScript"; agent="typescript-expert" ;;
  .tsx)  tech="TypeScript/React"; agent="typescript-expert" ;;
  .js)   tech="JavaScript"; agent="typescript-expert" ;;
  .jsx)  tech="JavaScript/React"; agent="typescript-expert" ;;
  .cs)   tech="C#/.NET"; agent="csharp-expert" ;;
  .go)   tech="Go"; agent="go-expert" ;;
  .java) tech="Java"; agent="java-expert" ;;
  .sh)   tech="Bash/Shell"; agent="bash-expert" ;;
  .ps1)  tech="PowerShell"; agent="powershell-expert" ;;
  .sql)  tech="SQL/Database"; agent="database-specialist" ;;
  .mq5)  tech="MQL5"; agent="mql-trading-dev" ;;
  .mq4)  tech="MQL4"; agent="mql-trading-dev" ;;
  .mqh)  tech="MQL include"; agent="mql-trading-dev" ;;
  *)     exit 0 ;;
esac

# Extract session_id from JSON and sanitize (remove non-alphanumeric, -, _)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
if [ -z "$session_id" ]; then
  exit 0
fi

# Sanitize session_id: remove anything that's not alphanumeric, dash, or underscore
session_id=$(printf '%s' "$session_id" | sed 's/[^A-Za-z0-9_-]//g')
if [ -z "$session_id" ]; then
  exit 0
fi

# Get state directory
state_root="${CLAUDE_STATE_DIR:-}"
if [ -z "$state_root" ]; then
  state_root="$HOME/.claude/.state"
fi

hint_dir="$state_root/delegation-hints"
seen_marker="$hint_dir/${session_id}-${agent}"

# If marker exists, don't hint again
if [ -f "$seen_marker" ]; then
  exit 0
fi

# Create hint directory and marker file
mkdir -p "$hint_dir" 2>/dev/null
touch "$seen_marker" 2>/dev/null

# Prune markers older than 7 days
find "$hint_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null

# Output JSON with suppressOutput=true and systemMessage
# Format: compact JSON with exact key order matching .ps1's ConvertTo-Json -Compress
jq -cn --arg t "$tech" --arg a "$agent" '{"suppressOutput":true,"systemMessage":"[delegation-hint] \($t) file detected - consider delegating implementation work to the \($a) subagent."}'
exit 0
