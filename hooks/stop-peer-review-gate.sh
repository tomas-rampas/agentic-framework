#!/bin/sh
# stop-peer-review-gate.sh — blocking Stop hook enforcing peer-review final gate (POSIX sh port).
#
# Blocks ending a session when the current feature branch has committed work ahead
# of its base and the latest peer-review-critic run this session did not APPROVE.
# Always exits 0 (fail-open); blocks via stdout JSON decision.
#
# Ported from stop-peer-review-gate.ps1 to POSIX sh.

set -u

# Read and validate JSON payload
payload=$(cat 2>/dev/null)
if [ -z "$payload" ]; then
  exit 0
fi

# Validate JSON (jq parsing check)
if ! printf '%s' "$payload" | jq empty >/dev/null 2>&1; then
  exit 0
fi

# Extract fields from JSON
stop_hook_active=$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null) || stop_hook_active="false"
if [ "$stop_hook_active" = "true" ]; then
  exit 0
fi

session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || session_id=""
session_id=$(printf '%s' "$session_id" | sed 's/[^A-Za-z0-9_-]//g')
if [ -z "$session_id" ]; then
  exit 0
fi

# Get state directory
state_root="${CLAUDE_STATE_DIR:-}"
if [ -z "$state_root" ]; then
  state_root="$HOME/.claude/.state"
fi

review_dir="$state_root/peer-review"
marker="$review_dir/$session_id"
fired="$review_dir/${session_id}.fired"

# Parse verdict from marker (fail-closed precedence: CHANGES_REQUIRED > APPROVED, anchored regex, CR-tolerant).
# Note: record-subagent-run.sh writes exactly one verdict line per marker (atomic rewrite via temp file),
# so the dual-token case is unreachable in practice. Precedence is ordered for defense-in-depth: check
# CHANGES_REQUIRED first (fail-closed) before APPROVED (fail-open). If somehow a marker had both tokens
# (impossible with current recorder contract), CHANGES_REQUIRED wins.
verdict=""
if [ -f "$marker" ]; then
  content=$(cat "$marker" 2>/dev/null | tr -d '\r')
  if printf '%s' "$content" | grep -q '^verdict=CHANGES_REQUIRED$'; then
    verdict="CHANGES_REQUIRED"
  elif printf '%s' "$content" | grep -q '^verdict=APPROVED$'; then
    verdict="APPROVED"
  else
    verdict=""  # legacy marker without verdict line - allow
  fi

  # If marker exists with APPROVED or legacy (empty verdict), allow
  if [ "$verdict" = "APPROVED" ] || [ -z "$verdict" ]; then
    exit 0
  fi
fi

# Parse .fired block counter
block_count=0
if [ -f "$fired" ]; then
  block_count=1
  raw=$(cat "$fired" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if printf '%s' "$raw" | grep -Eq '^[0-9]+$'; then
    block_count="$raw"
    [ -z "$block_count" ] && block_count=1
  fi
fi

# Budget logic: 1 block if no verdict (reviewer never ran); 3 blocks if CHANGES_REQUIRED
max_blocks=1
if [ "$verdict" = "CHANGES_REQUIRED" ]; then
  max_blocks=3
fi

if [ "$block_count" -ge "$max_blocks" ]; then
  exit 0
fi

# Get cwd from payload
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""
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
if [ "$?" -ne 0 ] || [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
  exit 0
fi

# Allow on main/master
case "$branch" in
  main|master) exit 0 ;;
esac

# Find base branch
base=""
for candidate in "origin/main" "origin/master" "main" "master"; do
  if git -C "$cwd" rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
    base="$candidate"
    break
  fi
done

if [ -z "$base" ]; then
  exit 0
fi

# Check commits ahead
ahead=$(git -C "$cwd" rev-list --count "$base..HEAD" 2>/dev/null)
if [ "$?" -ne 0 ] || [ "$ahead" -eq 0 ]; then
  exit 0
fi

# Check for dirty tree
dirty=$(git -C "$cwd" status --porcelain 2>/dev/null)
if [ "$?" -ne 0 ] || [ -n "$dirty" ]; then
  exit 0
fi

# Create review directory if needed
mkdir -p "$review_dir" 2>/dev/null

# Increment .fired counter (atomic write)
tmp_fired="$fired.tmp.$$"
printf '%d' $((block_count + 1)) > "$tmp_fired"
mv -f "$tmp_fired" "$fired" 2>/dev/null

# Build block reason string
if [ "$verdict" = "CHANGES_REQUIRED" ]; then
  reason="Peer-review final gate: peer-review-critic reviewed branch '$branch' this session and returned CHANGES_REQUIRED. Resolve every BLOCKER/MAJOR finding, then re-run the peer-review-critic subagent (Task tool, subagent_type: peer-review-critic) until it returns VERDICT: APPROVED, or ask the user to explicitly waive the gate."
else
  reason="Peer-review final gate: branch '$branch' has $ahead commit(s) ahead of $base that have not been peer reviewed this session. Launch the peer-review-critic subagent (Task tool, subagent_type: peer-review-critic) to review the branch diff against $base and resolve every BLOCKER/MAJOR finding, or ask the user to explicitly waive the gate."
fi

# Output JSON (compact, with jq for proper escaping)
jq -cn --arg r "$reason" '{"decision":"block","reason":$r}'
exit 0
