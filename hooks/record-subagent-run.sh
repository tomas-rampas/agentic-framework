#!/bin/sh
# record-subagent-run.sh — recorder for the peer-review final gate, hardened against stale overwrites.
#
# Fires on two events (both registered in hooks/hooks.json via the agentic-framework plugin):
#   - PostToolUse (matcher Task|Agent): a reviewer subagent call returned. A launch
#     acknowledgement writes nothing. It is either an object response whose status is
#     async_launched or whose isAsync is true, or text whose first non-blank line begins
#     "Async agent launched successfully". The Agent tool returns at launch on current
#     Claude Code.
#   - SubagentStop: a reviewer subagent finished. Report text = last_assistant_message when it
#     holds a whole-line VERDICT:, else the transcript at agent_transcript_path (its LAST 16 MiB: the
#     report is the final assistant line, followed by a user tool_result line): the last
#     SubagentHandback tool_use input.message, else the last assistant text blocks.
#
# Writes a per-session marker that hooks/stop-peer-review-gate.sh checks:
#   line 1: ISO timestamp (legacy format ends here)
#   line 2: verdict=APPROVED|CHANGES_REQUIRED — present only when the report text
#           contains the standardized "VERDICT:" line (agents/peer-review-critic.md), from either
#           report source above.
#   line 3: head=<sha> (git HEAD at time of verdict record; enables HEAD-qualified guards).
# code-review-gatekeeper (bare or agentic-framework:-scoped) is recorded the same way into
# <state>/code-review/<session>, plus a last line target=<text> from the report's first
# "Target:" line (CR removed, trimmed, printable ASCII only, max 200 chars).
#
# Stale-verdict hardening: instance dedupe, HEAD-qualified; id-less same-HEAD contradiction guard.
#   A report taken from a SubagentHandback block has instance id <agent_id>-hb-<that block's tool_use id>,
#   suppressed once recorded whatever HEAD did (a continued reviewer stopping without a new hand-back).
#   The text-form launch test needs the next non-blank line to be "agentId: <id>" too. A transcript over
#   16 MiB is read from its last 16 MiB with the cut window's partial first line dropped.
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

    # Determine state directory (also holds the transcript scratch file)
    stateRoot="${CLAUDE_STATE_DIR:-}"
    if [ -z "$stateRoot" ]; then
        stateRoot="$HOME/.claude/.state"
    fi

    # Determine event type and extract report text
    hook_event_name=$(printf '%s' "$payload" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0
    report_text=""
    hb_id=""
    review_sub="peer-review"

    if [ "$hook_event_name" = "SubagentStop" ]; then
        # SubagentStop path
        agent_type=$(printf '%s' "$payload" | jq -r '.agent_type // ""' 2>/dev/null) || exit 0
        # Case-insensitive match: ^(agentic-framework:)?peer-review-critic$
        agent_type_lower=$(printf '%s' "$agent_type" | tr '[:upper:]' '[:lower:]')
        case "$agent_type_lower" in
            peer-review-critic|agentic-framework:peer-review-critic|code-review-gatekeeper|agentic-framework:code-review-gatekeeper)
                case "$agent_type_lower" in *code-review-gatekeeper) review_sub="code-review" ;; esac
                report_text=$(printf '%s' "$payload" | jq -r '.last_assistant_message // ""' 2>/dev/null) || exit 0
                if ! printf '%s' "$report_text" | tr -d '\r' | grep -qE '^[[:space:]]*VERDICT:[[:blank:]]*(APPROVED|CHANGES_REQUIRED)[[:blank:]]*$'; then
                    # No verdict in last_assistant_message: read the report from the transcript
                    tpath=$(printf '%s' "$payload" | jq -r '.agent_transcript_path // ""' 2>/dev/null) || tpath=""
                    report_text=""
                    if [ -n "$tpath" ] && [ -f "$tpath" ] && [ -r "$tpath" ]; then
                        review_dir="$stateRoot/$review_sub"
                        mkdir -p "$review_dir" 2>/dev/null || true
                        hb_tmp=$(umask 077; mktemp "$review_dir/.hb.XXXXXX" 2>/dev/null) || hb_tmp=""
                        if [ -n "$hb_tmp" ]; then
                            trap 'rm -f "$hb_tmp"' EXIT
                            trap 'rm -f "$hb_tmp"; exit 0' INT TERM HUP
                            # jq reads a FILE (piping a large file into jq.exe is ~7x slower)
                            tsize=$(wc -c < "$tpath" 2>/dev/null | tr -d ' \r') || tsize=0
                            if [ "${tsize:-0}" -gt 16777216 ] 2>/dev/null; then
                                # the cut window's first line is partial: drop it
                                tail -c 16777216 -- "$tpath" 2>/dev/null | sed 1d | tr -d '\r' > "$hb_tmp" 2>/dev/null; tail_rc=$?
                            else
                                tail -c 16777216 -- "$tpath" 2>/dev/null | tr -d '\r' > "$hb_tmp" 2>/dev/null; tail_rc=$?
                            fi
                            if [ "$tail_rc" -eq 0 ]; then
                                hb_pair=$(jq -c -n -R '
                                  def blocks: (.message | if type == "object" then .content else null end) | if type == "array" then . else [] end;
                                  [inputs | fromjson? | objects | select(.type == "assistant")] as $a
                                  | ([$a[] | [blocks[] | select(type == "object" and .type == "tool_use" and .name == "SubagentHandback" and (.input | type) == "object" and (.input.message | type) == "string")
                                              | [(if (.id | type) == "string" then .id else null end), .input.message]] | last // empty] | last)
                                    // ([$a[] | [blocks[] | if type == "string" then . elif type == "object" and .type == "text" and (.text | type) == "string" then .text else empty end]
                                              | select(length > 0) | join("\n")] | last | if . == null then null else [null, .] end)
                                    // [null, ""]' "$hb_tmp" 2>/dev/null) || hb_pair=""
                                if [ -n "$hb_pair" ]; then
                                    report_text=$(printf '%s' "$hb_pair" | jq -r '.[1] // empty' 2>/dev/null) || report_text=""
                                    hb_id=$(printf '%s' "$hb_pair" | jq -r '.[0] // empty' 2>/dev/null) || hb_id=""
                                fi
                            fi
                            rm -f "$hb_tmp"
                        fi
                    fi
                fi
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
            peer-review-critic|agentic-framework:peer-review-critic|code-review-gatekeeper|agentic-framework:code-review-gatekeeper)
                case "$subagent_type_lower" in *code-review-gatekeeper) review_sub="code-review" ;; esac
                # Structured launch acknowledgement (the payload's tool_response is the tool data object)
                is_launch=$(printf '%s' "$payload" | jq -r '([.tool_response, .tool_output] | map(select(. != null and . != "")) | .[0] // "") | type == "object" and ((.status == "async_launched") or (.isAsync == true))' 2>/dev/null | tr -d '\r') || exit 0
                [ "$is_launch" = "true" ] && exit 0
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
                # Launch acknowledgement (Agent tool returned at launch): the report comes later via SubagentStop
                first_line=$(printf '%s' "$report_text" | tr -d '\r' | grep -m1 -E '[^[:space:]]') || first_line=""
                if printf '%s' "$first_line" | grep -qE '^[[:space:]]*Async agent launched successfully'; then
                    # ... and the next non-blank line must be "agentId: <id>", else it is an ordinary report
                    second_line=$(printf '%s' "$report_text" | tr -d '\r' | grep -E '[^[:space:]]' | sed -n 2p) || second_line=""
                    if printf '%s' "$second_line" | grep -qE '^agentId:[[:blank:]]*[A-Za-z0-9._-]+'; then
                        exit 0
                    fi
                fi
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

    review_dir="$stateRoot/$review_sub"
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

        # Report came from a SubagentHandback block: one instance id per hand-back
        hb_form=false
        if [ -n "$instance_id" ] && [ -n "$hb_id" ]; then
            hb_clean=$(printf '%s' "$hb_id" | tr -cd 'A-Za-z0-9_-')
            if [ -n "$hb_clean" ]; then
                instance_id="${instance_id}-hb-${hb_clean}"
                hb_form=true
            fi
        fi

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
                # Instance already recorded: require HEAD to have moved (dedupe always needs new work);
                # a hand-back instance id is never re-recorded, whatever HEAD did
                if $hb_form; then
                    should_suppress=true
                elif [ -n "$existing_head" ]; then
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

    # code-review marker only: first line beginning "Target:" (or Markdown-bold "**Target:**"),
    # CR removed, non-ASCII dropped BEFORE trimming, trimmed, capped at 200
    target=""
    if [ "$review_sub" = "code-review" ] && [ -n "$report_text" ]; then
        target=$(printf '%s' "$report_text" | tr -d '\r' | grep -m1 -E '^(\*\*Target:\*\*|Target:)' | sed -e 's/^\*\*Target:\*\*//' -e 's/^Target://' | LC_ALL=C tr -cd '\040-\176' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | cut -c1-200) || target=""
    fi

    # Write marker atomically with temp file — build via printf for reliability
    tmp="$marker.tmp.$$"
    {
        printf '%s' "$timestamp"
        [ -n "$verdict" ] && printf '\nverdict=%s' "$verdict"
        [ -n "$current_head" ] && printf '\nhead=%s' "$current_head"
        [ -n "$target" ] && printf '\ntarget=%s' "$target"
        true
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$marker" 2>/dev/null || exit 0

    # Only after successful marker write, append id to sources file (if non-null and verdict was parsed)
    if [ -n "$verdict" ] && [ -n "$instance_id" ]; then
        printf '%s\n' "$instance_id" >> "$sources_file" 2>/dev/null || true
    fi

    # Prune markers older than 7 days
    [ -n "$review_dir" ] && find "$review_dir" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true

exit 0
