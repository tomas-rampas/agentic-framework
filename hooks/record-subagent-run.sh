#!/bin/sh
# record-subagent-run.sh — recorder for the peer-review final gate, hardened against stale overwrites.
#
# Fires on two events (both registered in hooks/hooks.json via the agentic-framework plugin):
#   - PostToolUse (matcher Task|Agent): a peer-review-critic subagent call completed
#   - SubagentStop: a peer-review-critic subagent finished; last_assistant_message carries its final report.
#
# Writes a per-session marker that hooks/stop-peer-review-gate.sh checks:
#   line 1: ISO timestamp (legacy format ends here)
#   line 2: verdict=APPROVED|CHANGES_REQUIRED — present only when the report text
#           contains the standardized "VERDICT:" line (agents/peer-review-critic.md).
#   line 3: head=<sha> (git HEAD at time of verdict record; enables HEAD-qualified guards).
#
# Stale-verdict hardening: instance dedupe, HEAD-qualified; id-less same-HEAD contradiction guard.
# Silent and fail-open; also prunes markers older than 7 days.

set -u

# Read stdin
payload=$(cat)
[ -z "$payload" ] && exit 0

    # Parse JSON with jq; fail-open on malformed JSON
    session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
    [ -z "$session_id" ] && exit 0

    # Sanitize session_id: remove non-word and non-dash characters
    session_id=$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9_-')
    [ -z "$session_id" ] && exit 0

    # Determine event type and extract report text
    hook_event_name=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0
    report_text=""

    if [ "$hook_event_name" = "SubagentStop" ]; then
        # SubagentStop path
        agent_type=$(printf '%s' "$payload" | jq -r '.agent_type // ""' 2>/dev/null) || exit 0
        # Case-insensitive match: ^(agentic-framework:)?peer-review-critic$
        agent_type_lower=$(printf '%s' "$agent_type" | tr '[:upper:]' '[:lower:]')
        case "$agent_type_lower" in
            peer-review-critic|agentic-framework:peer-review-critic)
                report_text=$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""' 2>/dev/null) || exit 0
                ;;
            *)
                exit 0
                ;;
        esac
    else
        # PostToolUse (Task|Agent) path
        subagent_type=$(printf '%s' "$payload" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null) || exit 0
        # Case-insensitive match
        subagent_type_lower=$(printf '%s' "$subagent_type" | tr '[:upper:]' '[:lower:]')
        case "$subagent_type_lower" in
            peer-review-critic|agentic-framework:peer-review-critic)
                # Try tool_response first, fall back to tool_output, extracting text recursively
                report_text=$(printf '%s' "$payload" | jq -r '
                  ([.tool_response, .tool_output] | map(select(.!=null and .!="")) | .[0]//"") |
                  if type == "string" then
                    .
                  elif type == "array" then
                    [.[] | if type == "string" then . elif type == "object" and .text then .text else empty end] | join("\n")
                  elif type == "object" and .content then
                    [.content[] | if type == "string" then . elif type == "object" and .text then .text else empty end] | join("\n")
                  else
                    empty
                  end
                ' 2>/dev/null) || exit 0
                ;;
            *)
                exit 0
                ;;
        esac
    fi

    # Parse verdict from report text: anchored regex (whole-line only, not mid-line/quoted)
    verdict=""
    if [ -n "$report_text" ]; then
        # Canonical extraction pipeline: remove CR, grep anchored verdicts, take last, extract value
        # This ensures last-line-wins behavior (if report has both verdicts, latest one counts)
        verdict=$(printf '%s' "$report_text" | tr -d '\r' | grep -E '^[[:space:]]*VERDICT:[[:blank:]]*(APPROVED|CHANGES_REQUIRED)[[:blank:]]*$' | tail -n 1 | sed -E 's/.*VERDICT:[[:blank:]]*([A-Z_]+).*/\1/')
    fi

    # Determine state directory
    stateRoot="${CLAUDE_STATE_DIR:-}"
    if [ -z "$stateRoot" ]; then
        stateRoot="$HOME/.claude/.state"
    fi
    review_dir="$stateRoot/peer-review"
    mkdir -p "$review_dir" 2>/dev/null || true
    marker="$review_dir/$session_id"

    # No-downgrade guard: a verdict-less event must not erase a recorded verdict
    if [ -z "$verdict" ] && [ -f "$marker" ]; then
        existing=$(cat "$marker" 2>/dev/null) || true
        if printf '%s' "$existing" | grep -qE '^[[:space:]]*verdict=[[:blank:]]*(APPROVED|CHANGES_REQUIRED)[[:blank:]]*$' 2>/dev/null; then
            exit 0
        fi
    fi

    # Only apply stale-verdict guards when a verdict was parsed
    if [ -n "$verdict" ]; then
        # Initialize variables
        current_head=""
        instance_id=""
        existing_verdict=""
        existing_head=""
        sources_file="$review_dir/$session_id.verdict-sources"
        suppressed_file="$review_dir/$session_id.verdict-suppressed"
        should_suppress=false

        # Compute git HEAD once, early, reused in all guards
        cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null) || exit 0
        if [ -z "$cwd" ]; then
            cwd="$(pwd)"
        fi

        if [ -d "$cwd" ]; then
            head_output=$(git -C "$cwd" rev-parse HEAD 2>/dev/null) || true
            if [ -n "$head_output" ]; then
                current_head="$head_output"
            fi
        fi

        # GUARD 1: Instance dedupe, HEAD-qualified (primary prevention)
        if [ "$hook_event_name" = "SubagentStop" ]; then
            # Try fields in priority order (filter out empty strings)
            instance_id=$(printf '%s' "$payload" | jq -r '([.agent_id, .agent_session_id, .subagent_id, .task_id, .agent_transcript_path] | map(select(.!=null and .!="")) | .[0]) // ""' 2>/dev/null) || exit 0
        else
            # PostToolUse: use tool_use_id
            instance_id=$(printf '%s' "$payload" | jq -r '.tool_use_id // ""' 2>/dev/null) || exit 0
        fi

        # Sanitize instance_id
        instance_id=$(printf '%s' "$instance_id" | tr -cd 'A-Za-z0-9_-' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$instance_id" ] && instance_id=""

        # Extract existing marker data
        if [ -f "$marker" ]; then
            existing=$(cat "$marker" 2>/dev/null) || true
            # Extract last verdict line
            existing_verdict_line=$(printf '%s' "$existing" | grep -E '^[[:space:]]*verdict=[[:blank:]]*(APPROVED|CHANGES_REQUIRED)[[:blank:]]*$' | tail -1) || true
            if [ -n "$existing_verdict_line" ]; then
                existing_verdict=$(printf '%s' "$existing_verdict_line" | sed -E 's/^[[:space:]]*verdict=[[:blank:]]*([^ ]+)[[:blank:]]*$/\1/')
            fi
            # Extract head line
            existing_head_line=$(printf '%s' "$existing" | grep -E '^[[:space:]]*head=' | tail -1) || true
            if [ -n "$existing_head_line" ]; then
                existing_head=$(printf '%s' "$existing_head_line" | sed -E 's/^ *head=(.+)$/\1/')
            fi
        fi

        if [ -n "$instance_id" ]; then
            # Check if instance was already consumed
            already_consumed=false
            if [ -f "$sources_file" ]; then
                if grep -qxF -- "$instance_id" "$sources_file" 2>/dev/null; then
                    already_consumed=true
                fi
            fi

            if $already_consumed; then
                # Instance already recorded: require HEAD to have moved (dedupe always needs new work)
                if [ -n "$existing_head" ]; then
                    if [ -z "$current_head" ] || [ "$current_head" = "$existing_head" ]; then
                        # HEAD unknown or unchanged: suppress this write (stale re-emission)
                        should_suppress=true
                    fi
                else
                    # No existing head; suppress
                    should_suppress=true
                fi
            fi
        fi

        # GUARD 2: Id-less same-HEAD contradiction guard, asymmetric (fallback)
        # APPROVED contradictions are rejected id-less (fail-safe), CHANGES_REQUIRED always proceeds (escalation)
        if [ -z "$instance_id" ] && [ -n "$existing_verdict" ] && ! $should_suppress; then
            # No instance ID and existing marker has verdict: check for contradiction at same HEAD
            if [ "$existing_verdict" != "$verdict" ]; then
                if [ "$verdict" = "APPROVED" ]; then
                    # Id-less APPROVED: only proceed if HEAD moved
                    if [ -z "$current_head" ] || [ -z "$existing_head" ] || [ "$current_head" = "$existing_head" ]; then
                        # Same HEAD or unknown: suppress (fail-safe, no instance tracking)
                        should_suppress=true
                    fi
                fi
                # If CHANGES_REQUIRED: always proceed (escalation always safe, no tracking needed)
            fi
        fi

        if $should_suppress; then
            # Log suppression audit and exit
            timestamp=$(date -u +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || printf '%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
            oldstr="${existing_verdict:--}"
            headstr="${current_head:--}"
            guardname="instance-dedupe"
            [ -z "$instance_id" ] && guardname="same-head-approve"
            printf '%s guard=%s old=%s new=%s head=%s\n' "$timestamp" "$guardname" "$oldstr" "$verdict" "$headstr" >> "$suppressed_file" 2>/dev/null || true
            exit 0
        fi
    fi

    # Ensure variables are defined (they're used outside the verdict guard)
    : "${current_head:=}"
    : "${instance_id:=}"
    : "${sources_file:=}"
    : "${review_dir:=}"
    : "${marker:=}"

    # Write the marker FIRST (with error handling), then append id to sources file
    # Always write at least the timestamp (records that reviewer ran); add verdict/head only if verdict was parsed
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || printf '%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

    # Write marker atomically with temp file — build via printf for reliability
    tmp="$marker.tmp.$$"
    {
        printf '%s' "$timestamp"
        [ -n "$verdict" ] && printf '\nverdict=%s' "$verdict"
        [ -n "$current_head" ] && printf '\nhead=%s' "$current_head"
        true
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$marker" 2>/dev/null || exit 0

    # Only after successful marker write, append id to sources file (if non-null and verdict was parsed)
    if [ -n "$verdict" ] && [ -n "$instance_id" ]; then
        printf '%s\n' "$instance_id" >> "$sources_file" 2>/dev/null || true
    fi

    # Prune markers older than 7 days
    [ -n "$review_dir" ] && find "$review_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true

exit 0
