#!/bin/sh
# session-start-context.sh — SessionStart hook (POSIX sh port).
#
# Two outputs, both injected into the session context:
#   1. A branch / unreviewed-commit line so the model knows whether the peer-review
#      final gate (Stop hook) is armed, plus a one-line routing reminder.
#   2. The framework policy: the full, unmodified content of POLICY.md at the plugin
#      root, printed after the branch line on source startup, clear and compact
#      (resume, fork, any other or absent source prints no policy: a resumed or
#      forked session keeps the transcript, which already holds the policy), unless
#      <cwd>/CLAUDE.md holds the
#      exact marker line  <!-- agentic-framework: policy inline -->  (REQ-009).
#      The marker is honoured only in <cwd>/CLAUDE.md; parent and child directories
#      are not consulted (EDGE-005). A missing POLICY.md prints nothing extra.
#      The plugin root is CLAUDE_PLUGIN_ROOT, else this script's parent directory.
# Fail-open: always exit 0. Without jq the payload cannot be parsed: the script prints a
# jq warning, then the policy as if source were startup (cwd = $PWD for the marker
# check); the branch line is skipped in that case.
#
# Ported from session-start-context.ps1 to POSIX sh.

set -u

MARKER='<!-- agentic-framework: policy inline -->'

no_jq=0
if ! command -v jq >/dev/null 2>&1; then
  no_jq=1
fi

cwd=""
source_kind=""
if [ "$no_jq" -eq 0 ]; then
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
  source_kind=$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null) || source_kind=""

  # If cwd not provided or invalid, use current directory
  if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
    cwd=$(pwd 2>/dev/null)
  fi
fi

# Prints the branch line (if any); returns instead of exiting so the policy follows.
emit_branch_line() {
  # Check if inside a git work tree
  in_tree=$(git -C "$cwd" rev-parse --is-inside-work-tree 2>/dev/null)
  if [ "$?" -ne 0 ] || [ "$in_tree" != "true" ]; then
    return 0
  fi

  # Get current branch
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$?" -ne 0 ] || [ -z "$branch" ]; then
    return 0
  fi

  # If on main/master/HEAD, report that and stop
  case "$branch" in
    main|master|HEAD)
      printf "[session-context] On '%s'. The peer-review Stop gate applies only to feature branches; a push to main/master, and gh pr create or glab mr create, need a code-review-gatekeeper review first (pretooluse-code-review-gate denies them until one is recorded).\n" "$branch"
      return 0
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
      return 0
    fi
  fi

  # No ahead commits or no base found
  printf "[session-context] Branch '%s' — no commits ahead of base; peer-review gate idle.\n" "$branch"
  return 0
}

# Prints POLICY.md byte for byte unless the marker line is in <cwd>/CLAUDE.md.
emit_policy() {
  case "$source_kind" in
    startup|clear|compact) ;;
    *) return 0 ;;
  esac
  root="${CLAUDE_PLUGIN_ROOT:-}"
  if [ -z "$root" ]; then
    root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || return 0
  fi
  policy="$root/POLICY.md"
  [ -f "$policy" ] || return 0
  # Strip every CR and a leading UTF-8 BOM so the .ps1 twin (which reads the
  # whole text, BOM-stripped, CRs removed) and this script agree on UTF-8 input with or without one BOM.
  bom=$(printf '\357\273\277')
  if [ -f "$cwd/CLAUDE.md" ] && { tr -d '\r' < "$cwd/CLAUDE.md"; } 2>/dev/null | LC_ALL=C sed "1s/^$bom//" | grep -a -q -x -F -- "$MARKER"; then
    return 0
  fi
  cat "$policy" 2>/dev/null
  return 0
}

# Without jq the payload is unreadable: warn, then print the policy as for startup.
if [ "$no_jq" -eq 1 ]; then
  printf "[session-context] jq not installed; POSIX hooks including peer-review Stop gate will exit without enforcing anything. Install jq and restart the session.\n"
  cwd=$(pwd 2>/dev/null)
  source_kind=startup
  emit_policy
  exit 0
fi

emit_branch_line
emit_policy
exit 0
