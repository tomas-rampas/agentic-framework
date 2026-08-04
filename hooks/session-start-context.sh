#!/bin/sh
# session-start-context.sh — SessionStart hook (POSIX sh port).
#
# Reports the branch / unreviewed-commit state so the model knows whether the
# peer-review final gate (Stop hook) is armed, plus a one-line routing reminder.
# Fail-open: any error => exit 0 with no output.
#
# Ported from session-start-context.ps1 to POSIX sh.

set -u

# Preflight: check if jq is available on PATH
if ! command -v jq >/dev/null 2>&1; then
  printf "[session-context] jq not installed; POSIX hooks including peer-review Stop gate will exit without enforcing anything. Install jq and restart the session.\n"
  exit 0
fi

# Read JSON payload from stdin
payload=$(cat 2>/dev/null)
if [ -z "$payload" ]; then
  exit 0
fi

# Validate and extract cwd from JSON using jq
# If jq fails to parse, exit 0 (fail-open)
if ! printf '%s' "$payload" | jq empty >/dev/null 2>&1; then
  exit 0
fi
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""

# If cwd not provided or invalid, use current directory
if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  cwd=$(pwd 2>/dev/null)
fi

# Check if inside a git work tree
in_tree=$(git -C "$cwd" rev-parse --is-inside-work-tree 2>/dev/null)
if [ "$?" -ne 0 ] || [ "$in_tree" != "true" ]; then
  exit 0
fi

# Get current branch
branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$?" -ne 0 ] || [ -z "$branch" ]; then
  exit 0
fi

# If on main/master/HEAD, report that and exit
case "$branch" in
  main|master|HEAD)
    printf "[session-context] On '%s'. The peer-review Stop gate applies only to feature branches.\n" "$branch"
    exit 0
    ;;
esac

# Find base branch candidate (origin/main, origin/master, main, master)
base=""
for candidate in "origin/main" "origin/master" "main" "master"; do
  if git -C "$cwd" rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
    base="$candidate"
    break
  fi
done

# If base found, check if ahead
if [ -n "$base" ]; then
  ahead=$(git -C "$cwd" rev-list --count "$base..HEAD" 2>/dev/null)
  if [ "$?" -eq 0 ] && [ "$ahead" -gt 0 ]; then
    printf "[session-context] Branch '%s' is %d commit(s) ahead of %s. The peer-review final gate (Stop hook) blocks ending a session with committed, unreviewed work — run the peer-review-critic subagent before finishing. Route specialist work to the matching subagent (run /agentic-framework:list-agents for routing guidance).\n" "$branch" "$ahead" "$base"
    exit 0
  fi
fi

# No ahead commits or no base found
printf "[session-context] Branch '%s' — no commits ahead of base; peer-review gate idle.\n" "$branch"
exit 0
