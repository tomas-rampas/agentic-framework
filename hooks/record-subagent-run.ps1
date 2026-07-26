#Requires -Version 7.0
# record-subagent-run.ps1 — recorder for the peer-review final gate, hardened against stale overwrites.
#
# Fires on two events (both registered in hooks/hooks.json via the agentic-framework plugin):
#   - PostToolUse (matcher Task|Agent): a peer-review-critic subagent call completed
#     (or, for background launches, started — those carry no report text yet).
#   - SubagentStop: a peer-review-critic subagent finished; last_assistant_message
#     carries its final report.
#
# Writes a per-session marker that hooks/stop-peer-review-gate.ps1 checks:
#   line 1: ISO timestamp (legacy format ends here)
#   line 2: verdict=APPROVED|CHANGES_REQUIRED — present only when the report text
#           contains the standardized "VERDICT:" line (agents/peer-review-critic.md).
#   line 3: head=<sha> (git HEAD at time of verdict record; enables HEAD-qualified guards).
# The verdict line must occupy a whole line; of qualifying lines the LAST wins, so
# quoted mentions cannot spoof the real one. A marker without a verdict line keeps
# the legacy "reviewer ran" semantics (the gate treats it as unlocking — fail-open).
#
# Stale-verdict hardening (applies only when a verdict is parsed):
#   1. Instance dedupe, HEAD-qualified (primary): Resolves an instance ID from the payload
#      (SubagentStop: first non-empty of agent_id, agent_session_id, subagent_id, task_id,
#      or full agent_transcript_path run through [^\w-] strip; PostToolUse: tool_use_id).
#      A per-session sources file tracks consumed IDs. If ID is non-empty and already
#      consumed: PROCEED only when current HEAD ≠ empty AND old HEAD ≠ empty AND they differ
#      (genuine re-review after commits). Otherwise SUPPRESS and audit.
#   2. Id-less same-HEAD contradiction guard, asymmetric (fallback): When ID is empty and
#      existing marker holds a DIFFERENT verdict: if new verdict is CHANGES_REQUIRED, always
#      PROCEED (escalation safe). If new is APPROVED (displacing CHANGES_REQUIRED), PROCEED
#      only when current HEAD ≠ empty AND old HEAD ≠ empty AND they differ; else SUPPRESS
#      and audit (fail-safe toward locked gate).
#
# A run that parsed a verdict overwrites the marker: the latest review is the one
# that counts, which is what a fix → re-review loop needs. Suppression events append
# to <state>/peer-review/<sessionId>.verdict-suppressed (audit trail; errors ignored).
# A run with NO parseable verdict never downgrades an existing verdict-bearing marker
# — both events fire for the same run (and a background launch's PostToolUse has no report
# text), so an unconditional overwrite would erase a real CHANGES_REQUIRED and unlock.
# Silent and fail-open; also prunes markers older than 7 days.
#
# Concurrency note: No cross-process lock on sources/marker files; near-simultaneous hook
# firings can race during read-decide-write. Accepted; fail direction is reduced protection.

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop

    $sessionId = ([string]$payload.session_id) -replace '[^\w-]', ''
    if (-not $sessionId) { exit 0 }

    $reportText = ''
    if ([string]$payload.hook_event_name -eq 'SubagentStop') {
        if ([string]$payload.agent_type -notmatch '^(agentic-framework:)?peer-review-critic$') { exit 0 }
        $reportText = [string]$payload.last_assistant_message
    } else {
        # PostToolUse (Task|Agent). The response field is tool_response on current
        # builds and tool_output in the documented schema; the report text is a
        # plain string, an object carrying a content[] array of text blocks, or a
        # bare array of such blocks.
        if ([string]$payload.tool_input.subagent_type -notmatch '^(agentic-framework:)?peer-review-critic$') { exit 0 }
        $resp = $payload.tool_response
        if ($null -eq $resp) { $resp = $payload.tool_output }
        $blocks = $null
        if ($resp -is [string]) {
            $reportText = $resp
        } elseif ($resp -is [System.Collections.IEnumerable]) {
            $blocks = @($resp)
        } elseif ($null -ne $resp -and $null -ne $resp.content) {
            $blocks = @($resp.content)
        }
        if ($null -ne $blocks) {
            $reportText = ($blocks | ForEach-Object {
                if ($_ -is [string]) { $_ }
                elseif ($null -ne $_ -and $null -ne $_.text) { [string]$_.text }
            }) -join "`n"
        }
    }

    $verdict = $null
    if ($reportText) {
        # Whole-line match only: quoted or mid-line mentions never count. Last wins.
        $m = [regex]::Matches($reportText, '(?m)^\s*VERDICT:[ \t]*(APPROVED|CHANGES_REQUIRED)[ \t]*\r?$')
        if ($m.Count -gt 0) { $verdict = $m[$m.Count - 1].Groups[1].Value }
    }

    $stateRoot = $env:CLAUDE_STATE_DIR
    if (-not $stateRoot) { $stateRoot = Join-Path $HOME '.claude/.state' }
    $reviewDir = Join-Path $stateRoot 'peer-review'
    New-Item -ItemType Directory -Force -Path $reviewDir | Out-Null
    $marker = Join-Path $reviewDir $sessionId

    # No-downgrade guard: a verdict-less event must not erase a recorded verdict.
    if ($null -eq $verdict -and (Test-Path $marker)) {
        $existing = Get-Content -Path $marker -Raw -ErrorAction SilentlyContinue
        if ($existing -match 'verdict=') { exit 0 }
    }

    # Only apply stale-verdict guards when a verdict was parsed.
    if ($null -ne $verdict) {
        # Initialize variables used in all guards and suppression logging
        $currentHead = ''
        $instanceId = $null
        $existingVerdict = $null
        $existingHead = ''
        $sourcesFile = ''
        $suppressedFile = ''

        # Compute git HEAD once, early, reused in all guards (collapse duplicate git calls)
        $cwd = [string]$payload.cwd
        if (-not $cwd) { $cwd = (Get-Location).Path }

        if (Test-Path $cwd) {
            $headOutput = @(git -C $cwd rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $headOutput.Count -gt 0) {
                $currentHead = [string]$headOutput[0]
            }
        }

        # ────────────────────────────────────────────────────────────────────────
        # GUARD 1: Instance dedupe, HEAD-qualified (primary prevention)
        # ────────────────────────────────────────────────────────────────────────
        if ([string]$payload.hook_event_name -eq 'SubagentStop') {
            # Try fields in priority order; undocumented so coalesce defensively.
            $instanceId = [string]$payload.agent_id
            if (-not $instanceId) { $instanceId = [string]$payload.agent_session_id }
            if (-not $instanceId) { $instanceId = [string]$payload.subagent_id }
            if (-not $instanceId) { $instanceId = [string]$payload.task_id }
            # Fallback: use full agent_transcript_path run through [^\w-] strip (avoid leaf-name collisions)
            if (-not $instanceId -and $payload.agent_transcript_path) {
                $instanceId = ([string]$payload.agent_transcript_path -replace '[^\w-]', '')
            }
        } else {
            # PostToolUse: use tool_use_id
            $instanceId = [string]$payload.tool_use_id
        }

        # Sanitize with same rules as session_id
        $instanceId = ($instanceId -replace '[^\w-]', '').Trim()
        if ($instanceId -eq '') { $instanceId = $null }

        $sourcesFile = Join-Path $reviewDir "$sessionId.verdict-sources"
        $suppressedFile = Join-Path $reviewDir "$sessionId.verdict-suppressed"

        $shouldSuppress = $false

        # Extract existing marker data (if it exists) for both guards and audit logging
        if (Test-Path $marker) {
            $existing = Get-Content -Path $marker -Raw -ErrorAction SilentlyContinue
            $m = [regex]::Matches($existing, '(?m)^\s*verdict=(APPROVED|CHANGES_REQUIRED)\s*$')
            if ($m.Count -gt 0) {
                $existingVerdict = $m[$m.Count - 1].Groups[1].Value
            }
            $m = [regex]::Matches($existing, '(?m)^\s*head=(.+?)\s*$')
            if ($m.Count -gt 0) {
                $existingHead = $m[$m.Count - 1].Groups[1].Value
            }
        }

        if ($null -ne $instanceId) {
            # Check if this instance was already consumed
            $alreadyConsumed = $false
            if (Test-Path $sourcesFile) {
                $consumed = Get-Content -Path $sourcesFile -ErrorAction SilentlyContinue
                # Case-sensitive comparison
                if ($consumed -ccontains $instanceId) {
                    $alreadyConsumed = $true
                }
            }

            if ($alreadyConsumed) {
                # Instance already recorded: PROCEED only if HEAD provably moved
                # (genuine re-review of new commits). Dedupe is SYMMETRIC by design:
                # first verdict per instance per HEAD wins, in both directions —
                # the threat model is a same-instance re-emission of an already-
                # delivered report (see tests R2.b/R8.b). Do not "fix" this to
                # always-allow CHANGES_REQUIRED; that reintroduces the stale-CR
                # relock this guard exists to prevent.
                if ($existingHead) {
                    if ((-not $currentHead) -or ($currentHead -eq $existingHead)) {
                        # HEAD unknown or unchanged: suppress this write
                        $shouldSuppress = $true
                    }
                } else {
                    # No existing head; suppress (shouldn't happen but fail safe)
                    $shouldSuppress = $true
                }
            }
        }

        # ────────────────────────────────────────────────────────────────────────
        # GUARD 2: Id-less same-HEAD contradiction guard, asymmetric (fallback)
        # ────────────────────────────────────────────────────────────────────────
        if ($null -eq $instanceId -and $existingVerdict -and -not $shouldSuppress) {
            # No instance ID and existing marker has verdict: check for contradiction at same HEAD
            # Asymmetric: V_new == CHANGES_REQUIRED → always proceed (escalation safe)
            # V_new == APPROVED → proceed only if HEAD moved
            if ($existingVerdict -ne $verdict) {
                if ($verdict -eq 'APPROVED') {
                    # Trying to displace CHANGES_REQUIRED with APPROVED: check HEAD
                    if ((-not $currentHead) -or (-not $existingHead) -or ($currentHead -eq $existingHead)) {
                        # Same HEAD or unknown: suppress (fail-safe)
                        $shouldSuppress = $true
                    }
                }
                # If CHANGES_REQUIRED, always proceed (escalation always safe)
            }
        }

        if ($shouldSuppress) {
            # Log suppression audit and exit
            $timestamp = Get-Date -Format 'o'
            $oldStr = if ($null -ne $existingVerdict) { $existingVerdict } else { '-' }
            $headStr = if ($currentHead) { $currentHead } else { '-' }
            $guardName = if ($null -ne $instanceId) { 'instance-dedupe' } else { 'same-head-approve' }
            $auditLine = "$timestamp guard=$guardName old=$oldStr new=$verdict head=$headStr"
            Add-Content -Path $suppressedFile -Value $auditLine -ErrorAction SilentlyContinue
            exit 0
        }
    }

    # Write the marker FIRST (with error handling), then append id to sources file
    # Always write at least the timestamp (records that reviewer ran); add verdict/head only if verdict was parsed
    $lines = @((Get-Date -Format 'o'))
    if ($verdict) {
        $lines += "verdict=$verdict"
        if ($currentHead) {
            $lines += "head=$currentHead"
        }
    }

    try {
        Set-Content -Path $marker -Value ($lines -join "`n") -NoNewline -ErrorAction Stop
    } catch {
        # Marker write failed; exit without consuming the id
        exit 0
    }

    # Only after successful marker write, append id to sources file (if non-null and verdict was parsed)
    if ($verdict -and $null -ne $instanceId) {
        Add-Content -Path $sourcesFile -Value $instanceId -ErrorAction SilentlyContinue
    }

    # Prune markers older than 7 days (single pass covers marker + verdict-sources + verdict-suppressed files)
    Get-ChildItem -Path $reviewDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    exit 0
} catch {
    exit 0
}
