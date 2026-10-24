#Requires -Version 7.0
# record-subagent-run.ps1 — recorder for the peer-review final gate, hardened against stale overwrites.
#
# Fires on two events (both registered in hooks/hooks.json via the agentic-framework plugin):
#   - PostToolUse (matcher Task|Agent): a reviewer subagent call returned. A launch
#     acknowledgement writes nothing and leaves an existing verdict untouched. Two forms: the
#     payload object (tool_response is an object whose status is "async_launched" or whose
#     isAsync is true), and the text form (first non-blank line begins
#     "Async agent launched successfully", case-sensitive, and the next non-blank line matches ^agentId:[ \t]*[A-Za-z0-9._-]+). The Agent tool returns at launch on
#     current Claude Code.
#   - SubagentStop: a reviewer subagent finished. Report text = last_assistant_message when it
#     holds a whole-line VERDICT:, else the transcript's (agent_transcript_path) last
#     SubagentHandback tool_use input.message, else its last assistant text blocks.
#
# Known divergences from record-subagent-run.sh (accepted, documented, not fixed):
#   - ConvertFrom-Json fails on a transcript line with case-colliding keys (jq accepts them), so
#     this script falls back to an earlier line.
#   - ConvertFrom-Json parses an ISO-date-only input.message as a date (jq keeps the string).
#
# Writes a per-session marker that hooks/stop-peer-review-gate.ps1 checks:
#   line 1: ISO timestamp (legacy format ends here)
#   line 2: verdict=APPROVED|CHANGES_REQUIRED — present only when the report text
#           contains the standardized "VERDICT:" line (agents/peer-review-critic.md), from either
#           report source above.
#   line 3: head=<sha> (git HEAD at time of verdict record; enables HEAD-qualified guards).
# The verdict line must occupy a whole line; of qualifying lines the LAST wins, so
# quoted mentions cannot spoof the real one. A marker without a verdict line keeps
# the legacy "reviewer ran" semantics (the gate treats it as unlocking — fail-open).
#
# code-review-gatekeeper (bare or agentic-framework:-scoped) is recorded the same way into
# <state>/code-review/<session>, plus a last line target=<text> from the report's first
# "Target:" line (CR removed, trimmed, printable ASCII only, max 200 chars).
#
# Stale-verdict hardening (applies only when a verdict is parsed):
#   1. Instance dedupe, HEAD-qualified (primary): Resolves an instance ID from the payload
#      (SubagentStop: first non-empty of agent_id, agent_session_id, subagent_id, task_id,
#      or full agent_transcript_path run through [^\w-] strip; PostToolUse: tool_use_id).
#      A per-session sources file tracks consumed IDs. If ID is non-empty and already
#      consumed: PROCEED only when current HEAD ≠ empty AND old HEAD ≠ empty AND they differ
#      (genuine re-review after commits). Otherwise SUPPRESS and audit.
#      Hand-back instance id: when the report came from a SubagentHandback block the id is
#      <agent_id>-hb-<block id> (sanitised); such an id already consumed is suppressed whatever HEAD did.
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
    $hbToolUseId = $null
    $reviewSub = 'peer-review'
    $agentRx = '^(agentic-framework:)?(peer-review-critic|code-review-gatekeeper)$'
    if ([string]$payload.hook_event_name -eq 'SubagentStop') {
        if ([string]$payload.agent_type -notmatch $agentRx) { exit 0 }
        if ([string]$payload.agent_type -match 'code-review-gatekeeper$') { $reviewSub = 'code-review' }
        $reportText = [string]$payload.last_assistant_message
        $verdictRx = '(?m)^\s*VERDICT:[ \t]*(APPROVED|CHANGES_REQUIRED)[ \t]*\r?$'
        if (-not [regex]::IsMatch(($reportText -replace "`r", ''), $verdictRx)) {
            # No verdict in last_assistant_message (the report arrives via a SubagentHandback
            # tool call): read it from the transcript, last 16 MiB (the report is the final
            # assistant line), malformed lines skipped.
            $reportText = ''
            $tpath = [string]$payload.agent_transcript_path
            if ($tpath -and (Test-Path -LiteralPath $tpath -PathType Leaf)) {
                try {
                    $fs = [IO.File]::Open($tpath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                    try {
                        $seeked = $fs.Length -gt 16777216
                        if ($seeked) { $null = $fs.Seek($fs.Length - 16777216, [IO.SeekOrigin]::Begin) }
                        $buf = [byte[]]::new([Math]::Min($fs.Length, 16777216))
                        $n = 0
                        while ($n -lt $buf.Length) {
                            $k = $fs.Read($buf, $n, $buf.Length - $n)
                            if ($k -le 0) { break }
                            $n += $k
                        }
                    } finally { $fs.Dispose() }
                    $tlines = ([Text.Encoding]::UTF8.GetString($buf, 0, $n) -replace "`r", '') -split "`n"
                    if ($seeked) { $tlines = if ($tlines.Count -gt 1) { $tlines[1..($tlines.Count - 1)] } else { @() } }
                    $handback = $null
                    $hbId = $null
                    $lastText = $null
                    for ($i = $tlines.Count - 1; $i -ge 0; $i--) {
                        $ln = $tlines[$i]
                        if (-not $ln.Trim()) { continue }
                        $hasHb = $ln.Contains('SubagentHandback')
                        if (-not $hasHb -and $null -ne $lastText) { continue }
                        try { $o = $ln | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                        if ($o -isnot [pscustomobject] -or [string]$o.type -cne 'assistant') { continue }
                        $content = $o.message.content
                        if ($content -isnot [array]) { continue }
                        if ($hasHb) {
                            $hbs = @($content | Where-Object {
                                $_ -is [pscustomobject] -and [string]$_.type -ceq 'tool_use' -and [string]$_.name -ceq 'SubagentHandback' -and $_.input.message -is [string]
                            })
                            if ($hbs.Count -gt 0) {
                                $handback = $hbs[$hbs.Count - 1].input.message
                                if ($hbs[$hbs.Count - 1].id -is [string] -and $hbs[$hbs.Count - 1].id) { $hbId = $hbs[$hbs.Count - 1].id }
                                break
                            }
                        }
                        if ($null -eq $lastText) {
                            $tb = @($content | ForEach-Object {
                                if ($_ -is [string]) { , $_ }
                                elseif ($_ -is [pscustomobject] -and [string]$_.type -ceq 'text' -and $_.text -is [string]) { , $_.text }
                            })
                            if ($tb.Count -gt 0) { $lastText = $tb -join "`n" }
                        }
                    }
                    if ($null -ne $handback) { $reportText = $handback; $hbToolUseId = $hbId }
                    elseif ($null -ne $lastText) { $reportText = $lastText }
                } catch {
                    $reportText = ''
                }
            }
        }
    } else {
        # PostToolUse (Task|Agent). The response field is tool_response on current
        # builds and tool_output in the documented schema; the report text is a
        # plain string, an object carrying a content[] array of text blocks, or a
        # bare array of such blocks.
        if ([string]$payload.tool_input.subagent_type -notmatch $agentRx) { exit 0 }
        if ([string]$payload.tool_input.subagent_type -match 'code-review-gatekeeper$') { $reviewSub = 'code-review' }
        $resp = $payload.tool_response
        if ($null -eq $resp -or ($resp -is [string] -and $resp -eq '')) { $resp = $payload.tool_output }
        # Launch acknowledgement, object form: exit before any directory or file is touched
        if ($null -ne $resp -and -not ($resp -is [string]) -and -not ($resp -is [System.Collections.IList]) -and (($resp.status -is [string] -and $resp.status -ceq 'async_launched') -or($resp.isAsync -is [bool] -and $resp.isAsync))) { exit 0 }
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
        # Launch acknowledgement (Agent tool returned at launch): the report comes later via SubagentStop
        $firstLine = ($reportText -replace "`r", '') -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1
        if ($firstLine -and $firstLine -cmatch '^\s*Async agent launched successfully') {
            # Text form needs the next non-blank line to be the agentId: line, else it is an ordinary report
            $nonBlank = @(($reportText -replace "`r", '') -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2)
            if ($nonBlank.Count -ge 2 -and $nonBlank[1] -cmatch '^agentId:[ \t]*[A-Za-z0-9._-]+') { exit 0 }
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
    $reviewDir = Join-Path $stateRoot $reviewSub
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
        $isHbId = $false
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
            # Report came from a SubagentHandback block: one instance id per hand-back
            $hbClean = ([string]$hbToolUseId) -creplace '[^A-Za-z0-9_-]', ''
            if ($hbClean -and $instanceId) {
                $instanceId = "$instanceId-hb-$hbClean"
                $isHbId = $true
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

            if ($alreadyConsumed -and $isHbId) {
                # Hand-back id already recorded: a continued reviewer re-reading its old report; no HEAD exception
                $shouldSuppress = $true
            } elseif ($alreadyConsumed) {
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
            try {
                [IO.File]::AppendAllText($suppressedFile, $auditLine + "`n", [System.Text.UTF8Encoding]($false))
            } catch {
                # best-effort append; fail-open
            }
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

    if ($reviewSub -eq 'code-review' -and $reportText) {
        $tline = ($reportText -replace "`r", '') -split "`n" | Where-Object {
            $_.StartsWith('**Target:**', [System.StringComparison]::Ordinal) -or $_.StartsWith('Target:', [System.StringComparison]::Ordinal)
        } | Select-Object -First 1
        if ($null -ne $tline) {
            if ($tline.StartsWith('**Target:**', [System.StringComparison]::Ordinal)) { $t = $tline.Substring(11) } else { $t = $tline.Substring(7) }
            # non-ASCII dropped BEFORE trimming (the .sh order)
            $t = ($t -replace '[^\x20-\x7E]', '').Trim()
            if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
            if ($t) { $lines += "target=$t" }
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
        try {
            [IO.File]::AppendAllText($sourcesFile, $instanceId + "`n", [System.Text.UTF8Encoding]($false))
        } catch {
            # best-effort append; fail-open
        }
    }

    # Prune markers older than 7 days (single pass covers marker + verdict-sources + verdict-suppressed files)
    Get-ChildItem -Path $reviewDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    exit 0
} catch {
    exit 0
}
