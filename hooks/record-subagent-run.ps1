#Requires -Version 7.0
# record-subagent-run.ps1 — recorder for the peer-review final gate, hardened against stale overwrites.
#
# Fires on two events (both registered in settings.json, see settings.template.json):
#   - PostToolUse (matcher Task|Agent): a peer-review-critic subagent call completed
#     (or, for background launches, started — those carry no report text yet).
#   - SubagentStop: a peer-review-critic subagent finished; last_assistant_message
#     carries its final report.
#
# Writes a per-session marker that hooks/stop-peer-review-gate.ps1 checks:
#   line 1: ISO timestamp (legacy format ends here)
#   line 2: verdict=APPROVED|CHANGES_REQUIRED — present only when the report text
#           contains the standardized "VERDICT:" line (agents/peer-review-critic.md).
#   line 3: head=<sha> (git HEAD at time of verdict record; enables same-HEAD contradiction guard).
# The verdict line must occupy a whole line; of qualifying lines the LAST wins, so
# quoted mentions cannot spoof the real one. A marker without a verdict line keeps
# the legacy "reviewer ran" semantics (the gate treats it as unlocking — fail-open).
#
# Stale-verdict hardening (applies only when a verdict is parsed):
#   1. Instance dedupe (primary): Resolves an instance ID from the payload (SubagentStop:
#      first non-empty of agent_id, agent_session_id, subagent_id, task_id, or marker
#      basename; PostToolUse: tool_use_id). A per-session sources file tracks consumed IDs.
#      If ID is non-empty and already consumed → no write (repeat of same instance).
#      If ID is non-empty and new → append to sources file after write.
#      NOTE: Field availability is undocumented in Claude Code's hook schema (checked 2026-07-24).
#   2. Same-HEAD contradiction guard (fallback when ID is empty): Stores current git HEAD
#      on line 3 (head=<sha>). If existing marker holds a DIFFERENT verdict and both are
#      at the same non-empty HEAD → no write (presumed stale at unchanged commit).
#      HEAD moved, or either unknown, or same verdict → write proceeds (allows fix → re-review).
#
# A run that parsed a verdict overwrites the marker: the latest review is the one
# that counts, which is what a fix -> re-review loop needs. A run with NO parseable
# verdict never downgrades an existing verdict-bearing marker — both events fire for
# the same run (and a background launch's PostToolUse has no report text), so an
# unconditional overwrite would erase a real CHANGES_REQUIRED and unlock the gate.
# Silent and fail-open; also prunes markers older than 7 days.

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop

    $sessionId = ([string]$payload.session_id) -replace '[^\w-]', ''
    if (-not $sessionId) { exit 0 }

    $reportText = ''
    if ([string]$payload.hook_event_name -eq 'SubagentStop') {
        if ([string]$payload.agent_type -ne 'peer-review-critic') { exit 0 }
        $reportText = [string]$payload.last_assistant_message
    } else {
        # PostToolUse (Task|Agent). The response field is tool_response on current
        # builds and tool_output in the documented schema; the report text is a
        # plain string, an object carrying a content[] array of text blocks, or a
        # bare array of such blocks.
        if ([string]$payload.tool_input.subagent_type -ne 'peer-review-critic') { exit 0 }
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
        # ────────────────────────────────────────────────────────────────────────
        # GUARD 1: Instance dedupe (primary prevention against stale overwrites)
        # ────────────────────────────────────────────────────────────────────────
        $instanceId = $null
        if ([string]$payload.hook_event_name -eq 'SubagentStop') {
            # Try fields in priority order; undocumented so coalesce defensively.
            $instanceId = [string]$payload.agent_id
            if (-not $instanceId) { $instanceId = [string]$payload.agent_session_id }
            if (-not $instanceId) { $instanceId = [string]$payload.subagent_id }
            if (-not $instanceId) { $instanceId = [string]$payload.task_id }
            # Fallback: derive from transcript path basename (minus extension) if present
            if (-not $instanceId -and $payload.agent_transcript_path) {
                $instanceId = [System.IO.Path]::GetFileNameWithoutExtension([string]$payload.agent_transcript_path)
            }
        } else {
            # PostToolUse: use tool_use_id
            $instanceId = [string]$payload.tool_use_id
        }

        # Sanitize with same rules as session_id
        $instanceId = ($instanceId -replace '[^\w-]', '').Trim()
        if ($instanceId -eq '') { $instanceId = $null }

        $sourcesFile = Join-Path $reviewDir "$sessionId.verdict-sources"

        if ($null -ne $instanceId) {
            # Check if this instance was already consumed
            $alreadyConsumed = $false
            if (Test-Path $sourcesFile) {
                $consumed = Get-Content -Path $sourcesFile -ErrorAction SilentlyContinue
                if ($consumed -contains $instanceId) {
                    $alreadyConsumed = $true
                }
            }

            if ($alreadyConsumed) {
                # Instance already recorded; do not re-record.
                exit 0
            }
        }

        # ────────────────────────────────────────────────────────────────────────
        # GUARD 2: Same-HEAD contradiction guard (fallback when ID is empty)
        # ────────────────────────────────────────────────────────────────────────
        $currentHead = ''
        $cwd = [string]$payload.cwd
        if (-not $cwd) { $cwd = (Get-Location).Path }

        if (Test-Path $cwd) {
            $headOutput = @(git -C $cwd rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $headOutput.Count -gt 0) {
                $currentHead = [string]$headOutput[0]
            }
        }

        if ($null -eq $instanceId -and (Test-Path $marker)) {
            # No instance ID: check if existing marker contradicts at same HEAD.
            $existing = Get-Content -Path $marker -Raw -ErrorAction SilentlyContinue
            $existingVerdict = $null
            $existingHead = ''

            # Extract verdict from existing marker
            $m = [regex]::Matches($existing, '(?m)^\s*verdict=(APPROVED|CHANGES_REQUIRED)\s*$')
            if ($m.Count -gt 0) {
                $existingVerdict = $m[$m.Count - 1].Groups[1].Value
            }

            # Extract head from existing marker
            $m = [regex]::Matches($existing, '(?m)^\s*head=(.+?)\s*$')
            if ($m.Count -gt 0) {
                $existingHead = $m[$m.Count - 1].Groups[1].Value
            }

            # If existing verdict differs, current HEAD is non-empty, and both heads match → presume stale
            if ($null -ne $existingVerdict -and $existingVerdict -ne $verdict -and `
                $currentHead -and $existingHead -and $currentHead -eq $existingHead) {
                # Contradiction at unchanged HEAD without instance proof: presumed stale.
                exit 0
            }
        }

        # Write the marker with instance tracking (if ID was resolvable)
        if ($null -ne $instanceId) {
            # Append instance ID to sources file (for dedupe on subsequent calls)
            Add-Content -Path $sourcesFile -Value $instanceId -ErrorAction SilentlyContinue
        }
    }

    $lines = @((Get-Date -Format 'o'))
    if ($verdict) {
        $lines += "verdict=$verdict"
        # Add head line only when a verdict is being recorded
        $cwd = [string]$payload.cwd
        if (-not $cwd) { $cwd = (Get-Location).Path }
        if (Test-Path $cwd) {
            $headOutput = @(git -C $cwd rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and $headOutput.Count -gt 0) {
                $head = [string]$headOutput[0]
                if ($head) {
                    $lines += "head=$head"
                }
            }
        }
    }
    Set-Content -Path $marker -Value ($lines -join "`n") -NoNewline

    Get-ChildItem -Path $reviewDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Also clean up aged sources files (*.verdict-sources)
    Get-ChildItem -Path $reviewDir -Filter '*.verdict-sources' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    exit 0
} catch {
    exit 0
}
