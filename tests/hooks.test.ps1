#Requires -Version 7.0
# hooks.test.ps1 — plain-pwsh test harness for hooks/*.ps1 (no Pester dependency).
#
# Builds a throwaway git repo + isolated state dir (CLAUDE_STATE_DIR), feeds each
# hook synthetic stdin JSON, and asserts on output/exit codes. Exit 0 = all pass.
#
# Usage: pwsh -NoProfile -File tests/hooks.test.ps1

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$hooksDir = Join-Path $repoRoot 'hooks'
$failures = 0

$workRoot = Join-Path ([IO.Path]::GetTempPath()) ("hooks-test-" + [guid]::NewGuid().ToString('N'))
$stateDir = Join-Path $workRoot 'state'
$scratch  = Join-Path $workRoot 'scratch-repo'
New-Item -ItemType Directory -Force -Path $stateDir, $scratch | Out-Null
$env:CLAUDE_STATE_DIR = $stateDir

function Invoke-Hook {
    param([string]$Script, [string]$StdinJson)
    $out = $StdinJson | pwsh -NoProfile -File (Join-Path $hooksDir $Script) 2>$null
    return [pscustomobject]@{ Out = [string]($out -join "`n"); Code = $LASTEXITCODE }
}

function Assert {
    param([string]$Name, [bool]$Condition)
    if ($Condition) {
        Write-Host "  PASS  $Name"
    } else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        $script:failures++
    }
}

function New-Payload([hashtable]$Fields) { $Fields | ConvertTo-Json -Compress -Depth 8 }

# ── Scratch repo: main with 1 commit, feature/x 1 commit ahead, clean tree ──────
git -C $scratch init -q -b main
git -C $scratch config user.email 'test@test.local'
git -C $scratch config user.name  'hooks-test'
Set-Content -Path (Join-Path $scratch 'a.txt') -Value 'one'
git -C $scratch add -A; git -C $scratch commit -qm 'init'
git -C $scratch checkout -qb feature/x
Set-Content -Path (Join-Path $scratch 'b.txt') -Value 'two'
git -C $scratch add -A; git -C $scratch commit -qm 'feature work'

Write-Host "stop-peer-review-gate.ps1"

$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 's1'; stop_hook_active = $true; cwd = $scratch })
Assert 'loop-safety: stop_hook_active=true allows' ($r.Code -eq 0 -and -not $r.Out)

$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 's2'; stop_hook_active = $false; cwd = $scratch })
Assert 'blocks: feature branch ahead, clean tree, no marker' ($r.Code -eq 0 -and $r.Out -match '"decision":"block"' -and $r.Out -match 'peer-review-critic')

$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 's2'; stop_hook_active = $false; cwd = $scratch })
Assert 'fires at most once per session (.fired marker)' ($r.Code -eq 0 -and -not $r.Out)

New-Item -ItemType Directory -Force -Path (Join-Path $stateDir 'peer-review') | Out-Null
Set-Content -Path (Join-Path $stateDir 'peer-review' 's3') -Value 'reviewed'
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 's3'; stop_hook_active = $false; cwd = $scratch })
Assert 'allows when peer-review marker exists' ($r.Code -eq 0 -and -not $r.Out)

Set-Content -Path (Join-Path $scratch 'dirty.txt') -Value 'wip'
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 's4'; stop_hook_active = $false; cwd = $scratch })
Assert 'allows when working tree is dirty' ($r.Code -eq 0 -and -not $r.Out)
Remove-Item (Join-Path $scratch 'dirty.txt') -Force

git -C $scratch checkout -q main
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 's5'; stop_hook_active = $false; cwd = $scratch })
Assert 'allows on base branch (main)' ($r.Code -eq 0 -and -not $r.Out)
git -C $scratch checkout -q feature/x

$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 's6'; stop_hook_active = $false; cwd = $workRoot })
Assert 'allows outside a git worktree' ($r.Code -eq 0 -and -not $r.Out)

$r = Invoke-Hook 'stop-peer-review-gate.ps1' 'this is not json'
Assert 'fail-open on malformed stdin' ($r.Code -eq 0 -and -not $r.Out)

Write-Host "record-subagent-run.ps1"

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r1'; tool_name = 'Task'; tool_input = @{ subagent_type = 'peer-review-critic' } })
$m1 = Get-Content (Join-Path $stateDir 'peer-review' 'r1') -Raw -ErrorAction SilentlyContinue
Assert 'writes marker for peer-review-critic run' ($r.Code -eq 0 -and (Test-Path (Join-Path $stateDir 'peer-review' 'r1')))
Assert 'marker without report text carries no verdict line' ($m1 -notmatch 'verdict=')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r2'; tool_name = 'Task'; tool_input = @{ subagent_type = 'rust-expert' } })
Assert 'ignores other subagents' ($r.Code -eq 0 -and -not (Test-Path (Join-Path $stateDir 'peer-review' 'r2')))

$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'r1'; stop_hook_active = $false; cwd = $scratch })
Assert 'integration: recorded run unlocks the stop gate' ($r.Code -eq 0 -and -not $r.Out)

$r = Invoke-Hook 'record-subagent-run.ps1' 'not json either'
Assert 'fail-open on malformed stdin' ($r.Code -eq 0)

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v1'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = "Review done.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'v1') -Raw
Assert 'parses verdict from string tool_response' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v2'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = @{ status = 'completed'; content = @(@{ type = 'text'; text = "Findings...`nVERDICT: CHANGES_REQUIRED" }) } })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'v2') -Raw
Assert 'parses verdict from content-array tool_response' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v3'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; last_assistant_message = "Solid work overall.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'v3') -Raw
Assert 'SubagentStop path records verdict from last_assistant_message' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v4'; hook_event_name = 'SubagentStop'; agent_type = 'rust-expert'; last_assistant_message = 'VERDICT: APPROVED' })
Assert 'SubagentStop ignores other agent types' ($r.Code -eq 0 -and -not (Test-Path (Join-Path $stateDir 'peer-review' 'v4')))

# Boundary: plugin-scoped agent type 'otherplugin:peer-review-critic' should NOT match
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v4b'; hook_event_name = 'SubagentStop'; agent_type = 'otherplugin:peer-review-critic'; last_assistant_message = "Review done.`nVERDICT: APPROVED" })
Assert 'SubagentStop ignores otherplugin:peer-review-critic (only agentic-framework:peer-review-critic allowed)' ($r.Code -eq 0 -and -not (Test-Path (Join-Path $stateDir 'peer-review' 'v4b')))

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v5'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'review-v5-1'; last_assistant_message = "The format is `"VERDICT: APPROVED`" normally, but here:`nVERDICT: CHANGES_REQUIRED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'v5') -Raw
Assert 'last VERDICT occurrence wins over earlier quoted one' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v5'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'review-v5-2'; last_assistant_message = "Re-review after fixes.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'v5') -Raw
Assert 're-review overwrites marker (latest verdict wins)' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED' -and $m -notmatch 'CHANGES_REQUIRED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v6'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; last_assistant_message = "Blockers remain.`nVERDICT: CHANGES_REQUIRED" })
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v6'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = @{ status = 'launched_in_background'; agentId = 'a1b2c3' } })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'v6') -Raw
Assert 'no-downgrade: verdict-less event preserves CHANGES_REQUIRED' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED')
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'v6'; stop_hook_active = $false; cwd = $scratch })
Assert 'no-downgrade: gate still blocks after verdict-less event' ($r.Code -eq 0 -and $r.Out -match '"decision":"block"')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v7'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = @(@{ type = 'text'; text = "Report body.`nVERDICT: CHANGES_REQUIRED" }) })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'v7') -Raw
Assert 'parses verdict from bare-array tool_response' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v8'; hook_event_name = 'PostToolUse'; tool_name = 'Task'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_output = "Documented-schema field.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'v8') -Raw
Assert 'falls back to tool_output when tool_response absent' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v9'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; last_assistant_message = "CRLF payload.`r`nVERDICT: APPROVED`r`n" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'v9') -Raw
Assert 'parses verdict from CRLF report text' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'v10'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; last_assistant_message = 'Reviews normally end with "VERDICT: APPROVED" but this one timed out.' })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'v10') -Raw
Assert 'mid-line quoted verdict does not count (anchored regex)' ($r.Code -eq 0 -and $m -notmatch 'verdict=')

# R7: gate integration — 3-line markers with head= line work correctly
$headNow = git -C $scratch rev-parse HEAD
Set-Content -Path (Join-Path $stateDir 'peer-review' 'r7-approved') -Value "2026-07-18T00:00:00.0000000+02:00`nverdict=APPROVED`nhead=$headNow" -NoNewline
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'r7-approved'; stop_hook_active = $false; cwd = $scratch })
Assert 'R7.a: gate allows 3-line APPROVED marker' ($r.Code -eq 0 -and -not $r.Out)

Set-Content -Path (Join-Path $stateDir 'peer-review' 'r7-blocked') -Value "2026-07-18T00:00:00.0000000+02:00`nverdict=CHANGES_REQUIRED`nhead=$headNow" -NoNewline
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'r7-blocked'; stop_hook_active = $false; cwd = $scratch })
Assert 'R7.b: gate blocks 3-line CHANGES_REQUIRED marker' ($r.Code -eq 0 -and $r.Out -match '"decision":"block"')

Write-Host "stop-peer-review-gate.ps1 (verdict-aware)"

Set-Content -Path (Join-Path $stateDir 'peer-review' 'g1') -Value "2026-07-18T00:00:00.0000000+02:00`nverdict=APPROVED" -NoNewline
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g1'; stop_hook_active = $false; cwd = $scratch })
Assert 'allows on verdict=APPROVED marker' ($r.Code -eq 0 -and -not $r.Out)

Set-Content -Path (Join-Path $stateDir 'peer-review' 'g2') -Value "2026-07-18T00:00:00.0000000+02:00`nverdict=CHANGES_REQUIRED" -NoNewline
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g2'; stop_hook_active = $false; cwd = $scratch })
Assert 'blocks on verdict=CHANGES_REQUIRED (1st)' ($r.Code -eq 0 -and $r.Out -match '"decision":"block"' -and $r.Out -match 'CHANGES_REQUIRED')
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g2'; stop_hook_active = $false; cwd = $scratch })
Assert 'blocks on verdict=CHANGES_REQUIRED (2nd)' ($r.Code -eq 0 -and $r.Out -match '"decision":"block"')
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g2'; stop_hook_active = $false; cwd = $scratch })
Assert 'blocks on verdict=CHANGES_REQUIRED (3rd)' ($r.Code -eq 0 -and $r.Out -match '"decision":"block"')
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g2'; stop_hook_active = $false; cwd = $scratch })
Assert 'block budget exhausted after 3 blocks -> allows' ($r.Code -eq 0 -and -not $r.Out)

Set-Content -Path (Join-Path $stateDir 'peer-review' 'g2') -Value "2026-07-18T00:00:00.0000000+02:00`nverdict=APPROVED" -NoNewline
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g2'; stop_hook_active = $false; cwd = $scratch })
Assert 'later APPROVED marker allows regardless of block count' ($r.Code -eq 0 -and -not $r.Out)

# Pre-verdict on-disk format: .fired existed as an empty file (counts as 1 block)
Set-Content -Path (Join-Path $stateDir 'peer-review' 'g3') -Value "2026-07-18T00:00:00.0000000+02:00`nverdict=CHANGES_REQUIRED" -NoNewline
New-Item -ItemType File -Force -Path (Join-Path $stateDir 'peer-review' 'g3.fired') | Out-Null
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g3'; stop_hook_active = $false; cwd = $scratch })
Assert 'legacy empty .fired counts as 1 (2nd block granted)' ($r.Code -eq 0 -and $r.Out -match '"decision":"block"')
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g3'; stop_hook_active = $false; cwd = $scratch })
Assert 'legacy .fired base: 3rd block granted' ($r.Code -eq 0 -and $r.Out -match '"decision":"block"')
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g3'; stop_hook_active = $false; cwd = $scratch })
Assert 'legacy .fired base: budget exhausted -> allows' ($r.Code -eq 0 -and -not $r.Out)

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'g4'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'review-g4-1'; last_assistant_message = "Blockers found.`nVERDICT: CHANGES_REQUIRED" })
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g4'; stop_hook_active = $false; cwd = $scratch })
Assert 'integration: recorded CHANGES_REQUIRED blocks the gate' ($r.Code -eq 0 -and $r.Out -match '"decision":"block"' -and $r.Out -match 'CHANGES_REQUIRED')
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'g4'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'review-g4-2'; last_assistant_message = "Fixed and re-reviewed.`nVERDICT: APPROVED" })
$r = Invoke-Hook 'stop-peer-review-gate.ps1' (New-Payload @{ session_id = 'g4'; stop_hook_active = $false; cwd = $scratch })
Assert 'integration: recorded APPROVED re-review unlocks the gate' ($r.Code -eq 0 -and -not $r.Out)

Write-Host "record-subagent-run.ps1 (stale-verdict hardening)"

# ──────────────────────────────────────────────────────────────────────────────
# Instance dedupe (primary guard against stale overwrites)
# ──────────────────────────────────────────────────────────────────────────────

# R1: stop#1 id=X APPROVED → marker APPROVED; stop#2 SAME id=X contradicting CHANGES_REQUIRED → marker STILL APPROVED
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r1'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'instance-X'; last_assistant_message = "Review done.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r1') -Raw
Assert 'R1.a: initial APPROVED recorded with instance id' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r1'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'instance-X'; last_assistant_message = "Actually, blockers found.`nVERDICT: CHANGES_REQUIRED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r1') -Raw
Assert 'R1.b: same id=X stale stop does not overwrite APPROVED' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED' -and $m -notmatch 'CHANGES_REQUIRED')

# R2: stop#1 id=Y CHANGES_REQUIRED; stop#2 same id=Y APPROVED → marker STILL CHANGES_REQUIRED (dedupe guards against bypass)
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r2'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'instance-Y'; last_assistant_message = "Blockers remain.`nVERDICT: CHANGES_REQUIRED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r2') -Raw
Assert 'R2.a: initial CHANGES_REQUIRED recorded with instance id' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r2'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'instance-Y'; last_assistant_message = "Actually all clear.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r2') -Raw
Assert 'R2.b: same id=Y stale stop does not bypass gate' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED' -and $m -notmatch 'APPROVED')

# R3: different ids at same HEAD, both with verdicts → latest id wins
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r3'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'review-A'; cwd = $scratch; last_assistant_message = "Review A passed.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r3') -Raw
Assert 'R3.a: first review (A) APPROVED' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r3'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'review-B'; cwd = $scratch; last_assistant_message = "Review B found issues.`nVERDICT: CHANGES_REQUIRED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r3') -Raw
Assert 'R3.b: different id=B replaces A, CHANGES_REQUIRED wins' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED')

# ──────────────────────────────────────────────────────────────────────────────
# Same-HEAD contradiction guard (fallback when id is empty or unresolvable)
# Asymmetric semantics: escalation (CHANGES_REQUIRED) always lands; APPROVED suppressed at same HEAD
# ──────────────────────────────────────────────────────────────────────────────

# R4 (flipped): id-ABSENT, asymmetric same-HEAD guard
# (a) CHANGES_REQUIRED recorded first
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r4a'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; cwd = $scratch; last_assistant_message = "Blockers found.`nVERDICT: CHANGES_REQUIRED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r4a') -Raw
Assert 'R4.a: id-absent CHANGES_REQUIRED recorded at HEAD' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED' -and $m -match 'head=')

# (b) APPROVED at same HEAD → suppressed (stays CHANGES_REQUIRED), audit line written
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r4a'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; cwd = $scratch; last_assistant_message = "Re-review: all clear.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r4a') -Raw
$suppressed = Get-Content (Join-Path $stateDir 'peer-review' 'r4a.verdict-suppressed') -Raw -ErrorAction SilentlyContinue
Assert 'R4.b: id-absent APPROVED at same HEAD suppressed (stays CHANGES_REQUIRED)' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED' -and $m -notmatch 'APPROVED')
Assert 'R4.b: suppression audit line created with guard=same-head-approve' ($r.Code -eq 0 -and $suppressed -match 'guard=same-head-approve')

# R4 (asymmetric escalation): APPROVED recorded first, then CHANGES_REQUIRED → escalates
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r4b'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; cwd = $scratch; last_assistant_message = "No issues found.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r4b') -Raw
Assert 'R4.c: id-absent APPROVED recorded at HEAD' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED' -and $m -match 'head=')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r4b'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; cwd = $scratch; last_assistant_message = "Actually blockers found.`nVERDICT: CHANGES_REQUIRED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r4b') -Raw
Assert 'R4.d: id-absent CHANGES_REQUIRED at same HEAD escalates over APPROVED' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED' -and $m -notmatch 'APPROVED')

# R5: id-absent, HEAD MOVES → verdicts can change (fix → re-review)
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r5'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; cwd = $scratch; last_assistant_message = "Initial review: blockers.`nVERDICT: CHANGES_REQUIRED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r5') -Raw
Assert 'R5.a: CHANGES_REQUIRED recorded at HEAD1' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED')

# Simulate a fix by advancing HEAD
Set-Content -Path (Join-Path $scratch 'fix.txt') -Value 'fixed'
git -C $scratch add -A; git -C $scratch commit -qm 'fix blockers'

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r5'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; cwd = $scratch; last_assistant_message = "Re-review after fix: all clear.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r5') -Raw
Assert 'R5.b: id-absent APPROVED at HEAD2 allowed despite earlier CHANGES_REQUIRED' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED')

# Reset for remaining tests
git -C $scratch reset -q --hard HEAD~1

# R6: regression — verdict-less event never downgrades; PostToolUse tool_use_id participates in dedupe
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r6'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; tool_use_id = 'use-123'; last_assistant_message = "Status: needs work.`nVERDICT: CHANGES_REQUIRED" })
Assert 'R6.a: initial CHANGES_REQUIRED recorded' ($r.Code -eq 0)

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r6'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_use_id = 'use-456'; tool_response = @{ status = 'background' } })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r6') -Raw
Assert 'R6.b: no-downgrade still active on verdict-less PostToolUse' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r6'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_use_id = 'use-456'; tool_response = "Re-run with same id.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r6') -Raw
Assert 'R6.c: tool_use_id dedupe on verdict-bearing events (use-456 is new to verdicts)' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED')

# R6.d: demonstrate dedupe with tool_use_id on a second verdict-bearing appearance
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r6'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_use_id = 'use-456'; tool_response = "Third attempt contradicts.`nVERDICT: CHANGES_REQUIRED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r6') -Raw
Assert 'R6.d: same tool_use_id on repeat verdict (use-456 already listed) blocked' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED')

# ──────────────────────────────────────────────────────────────────────────────
# NEW: HEAD-qualified instance dedupe (HEAD moved → re-review allowed)
# ──────────────────────────────────────────────────────────────────────────────

# R7: same id at different HEAD → records (fix → re-review succeeds)
$headBefore = git -C $scratch rev-parse HEAD
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r7'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'instance-Z'; cwd = $scratch; last_assistant_message = "Initial review: blockers.`nVERDICT: CHANGES_REQUIRED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r7') -Raw
Assert 'R7.a: id=Z CHANGES_REQUIRED recorded at HEAD1' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED' -and $m -match "head=$headBefore")

# Advance HEAD (simulate a fix commit)
Set-Content -Path (Join-Path $scratch 'r7-fix.txt') -Value 'fixed'
git -C $scratch add -A; git -C $scratch commit -qm 'fix for r7'
$headAfter = git -C $scratch rev-parse HEAD

# Same id at new HEAD → records (dedupe allows re-review because HEAD moved)
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r7'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'instance-Z'; cwd = $scratch; last_assistant_message = "Re-review after fix: all clear.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r7') -Raw
Assert 'R7.b: same id=Z at HEAD2 records APPROVED (HEAD moved)' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED' -and $m -match "head=$headAfter")

# Reset for R8
git -C $scratch reset -q --hard HEAD~1

# ──────────────────────────────────────────────────────────────────────────────
# NEW: same id, same HEAD → suppressed (no re-review without commits)
# ──────────────────────────────────────────────────────────────────────────────

# R8: same id at same HEAD → suppressed both directions
$headStatic = git -C $scratch rev-parse HEAD
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r8'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'instance-W'; cwd = $scratch; last_assistant_message = "Review: approved.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r8') -Raw
Assert 'R8.a: id=W APPROVED recorded at HEAD' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED' -and $m -match "head=$headStatic")

# Same id, same HEAD, contradicting verdict → suppressed (stays APPROVED), audit line written
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'r8'; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'instance-W'; cwd = $scratch; last_assistant_message = "Re-check: blockers.`nVERDICT: CHANGES_REQUIRED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'r8') -Raw
$suppressed = Get-Content (Join-Path $stateDir 'peer-review' 'r8.verdict-suppressed') -Raw -ErrorAction SilentlyContinue
Assert 'R8.b: same id=W at same HEAD suppressed (stays APPROVED)' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED' -and $m -notmatch 'CHANGES_REQUIRED')
Assert 'R8.b: suppression audit line created with guard=instance-dedupe' ($r.Code -eq 0 -and $suppressed -match 'guard=instance-dedupe')

Write-Host "record-subagent-run.ps1 (plugin-scoped agent names)"

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'plugin-sub1'; hook_event_name = 'SubagentStop'; agent_type = 'agentic-framework:peer-review-critic'; last_assistant_message = "Review done.`nVERDICT: APPROVED" })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'plugin-sub1') -Raw -ErrorAction SilentlyContinue
Assert 'SubagentStop with plugin-scoped agent_type records verdict' ($r.Code -eq 0 -and (Test-Path (Join-Path $stateDir 'peer-review' 'plugin-sub1')))
Assert 'plugin-scoped SubagentStop marker contains APPROVED verdict' ($r.Code -eq 0 -and $m -match 'verdict=APPROVED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'plugin-post1'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'agentic-framework:peer-review-critic' }; tool_response = @{ status = 'completed'; content = @(@{ type = 'text'; text = "Review done.`nVERDICT: CHANGES_REQUIRED" }) } })
$m = Get-Content (Join-Path $stateDir 'peer-review' 'plugin-post1') -Raw -ErrorAction SilentlyContinue
Assert 'PostToolUse with plugin-scoped subagent_type records verdict' ($r.Code -eq 0 -and (Test-Path (Join-Path $stateDir 'peer-review' 'plugin-post1')))
Assert 'plugin-scoped PostToolUse marker contains CHANGES_REQUIRED verdict' ($r.Code -eq 0 -and $m -match 'verdict=CHANGES_REQUIRED')

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'plugin-neg-impostor'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'agentic-framework:impostor-agent' }; tool_response = "VERDICT: APPROVED" })
Assert 'PostToolUse with wrong plugin-scoped agent does not record' ($r.Code -eq 0 -and -not (Test-Path (Join-Path $stateDir 'peer-review' 'plugin-neg-impostor')))

$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'plugin-neg-other'; hook_event_name = 'SubagentStop'; agent_type = 'otherplugin:some-agent'; last_assistant_message = "VERDICT: APPROVED" })
Assert 'SubagentStop with different plugin agent does not record' ($r.Code -eq 0 -and -not (Test-Path (Join-Path $stateDir 'peer-review' 'plugin-neg-other')))

Write-Host "[RECORD-SUBAGENT-RUN-CR] record-subagent-run.ps1 — code-review marker"

function Get-Lines([string]$Path) { if (Test-Path $Path) { (Get-Content $Path -Raw) -split "`n" } else { @() } }
$crDir = Join-Path $stateDir 'code-review'
$prDir = Join-Path $stateDir 'peer-review'
$headSha = (git -C $scratch rev-parse HEAD).Trim()

# CR-1: APPROVED with Target -> four-line marker under code-review/, nothing under peer-review/
$tgt = 'feature/x vs origin/main (abc1234..def5678); fallback: none'
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'cr1'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'code-review-gatekeeper' }; tool_response = "Review.`nTarget: $tgt`nVERDICT: APPROVED" })
$ln = Get-Lines (Join-Path $crDir 'cr1')
Assert '[RECORD-SUBAGENT-RUN-CR-1] code-review marker exists' ($r.Code -eq 0 -and (Test-Path (Join-Path $crDir 'cr1')))
Assert '[RECORD-SUBAGENT-RUN-CR-1] four lines: verdict, head, target' ($ln.Count -eq 4 -and $ln[1] -eq 'verdict=APPROVED' -and $ln[2] -eq "head=$headSha" -and $ln[3] -eq "target=$tgt")
Assert '[RECORD-SUBAGENT-RUN-CR-1] no peer-review marker' (-not (Test-Path (Join-Path $prDir 'cr1')))

# CR-2: peer-review-critic writes nothing under code-review/
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'cr2'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = "Target: x`nVERDICT: APPROVED" })
Assert '[RECORD-SUBAGENT-RUN-CR-2] peer-review marker written' ($r.Code -eq 0 -and (Test-Path (Join-Path $prDir 'cr2')))
Assert '[RECORD-SUBAGENT-RUN-CR-2] no code-review marker' (-not (Test-Path (Join-Path $crDir 'cr2')))
Assert '[RECORD-SUBAGENT-RUN-CR-2] no target= in peer-review marker' ((Get-Content (Join-Path $prDir 'cr2') -Raw) -notmatch 'target=')

# CR-3: no Target line -> three lines
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'cr3'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'code-review-gatekeeper' }; tool_response = "No target here.`nVERDICT: CHANGES_REQUIRED" })
$ln = Get-Lines (Join-Path $crDir 'cr3')
Assert '[RECORD-SUBAGENT-RUN-CR-3] three lines, no target' ($r.Code -eq 0 -and $ln.Count -eq 3 -and $ln[1] -eq 'verdict=CHANGES_REQUIRED' -and $ln[2] -like 'head=*')

# CR-4: instance dedupe at same HEAD
$null = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'cr4'; cwd = $scratch; tool_use_id = 'toolu_X'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'code-review-gatekeeper' }; tool_response = 'VERDICT: CHANGES_REQUIRED' })
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'cr4'; cwd = $scratch; tool_use_id = 'toolu_X'; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_input = @{ subagent_type = 'code-review-gatekeeper' }; tool_response = 'VERDICT: APPROVED' })
$sup = Join-Path $crDir 'cr4.verdict-suppressed'
Assert '[RECORD-SUBAGENT-RUN-CR-4] marker still CHANGES_REQUIRED' ($r.Code -eq 0 -and (Get-Content (Join-Path $crDir 'cr4') -Raw) -match 'verdict=CHANGES_REQUIRED')
Assert '[RECORD-SUBAGENT-RUN-CR-4] one suppression line guard=instance-dedupe' ((Test-Path $sup) -and @(Get-Content $sup).Count -eq 1 -and (Get-Content $sup -Raw) -match 'guard=instance-dedupe')

# CR-5: scoped, mixed-case SubagentStop
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'cr5'; hook_event_name = 'SubagentStop'; agent_type = 'AgentiC-Framework:Code-Review-Gatekeeper'; last_assistant_message = "Done.`nTarget:   main..HEAD  `nVERDICT: APPROVED" })
$m = if (Test-Path (Join-Path $crDir 'cr5')) { Get-Content (Join-Path $crDir 'cr5') -Raw } else { '' }
Assert '[RECORD-SUBAGENT-RUN-CR-5] scoped SubagentStop records verdict and trimmed target' ($r.Code -eq 0 -and $m -match '(?m)^verdict=APPROVED$' -and $m -match '(?m)^target=main\.\.HEAD$')

# CR-6: sanitization (CR removed, non-ASCII dropped, 200-char cap)
$long = 'a' * 250
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'cr6'; hook_event_name = 'SubagentStop'; agent_type = 'code-review-gatekeeper'; last_assistant_message = ("Target: caf" + [char]0xE9 + "-" + $long + "`r`nVERDICT: APPROVED") })
$m = if (Test-Path (Join-Path $crDir 'cr6')) { Get-Content (Join-Path $crDir 'cr6') -Raw } else { '' }
$val = ((($m -split "`n") | Where-Object { $_ -like 'target=*' } | Select-Object -First 1) -replace '^target=', '')
Assert '[RECORD-SUBAGENT-RUN-CR-6] target is 200 printable ASCII chars, CR and e-acute dropped' ($r.Code -eq 0 -and $val.Length -eq 200 -and $val -match '^[\x20-\x7E]+$' -and $val.StartsWith('caf-'))

# CR-7: Markdown-bold **Target:** label; non-ASCII dropped BEFORE trimming (an e-acute at
# each edge of the value would leave an edge space if trimming ran first)
$cr7v = 'feat/x vs origin/main (abc1234..def5678); fallback: none'
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'cr7'; hook_event_name = 'SubagentStop'; agent_type = 'code-review-gatekeeper'; last_assistant_message = ("Done.`n**Target:** " + [char]0xE9 + "  $cr7v " + [char]0xA0 + " " + [char]0xE9 + "`nVERDICT: APPROVED") })
$m = if (Test-Path (Join-Path $crDir 'cr7')) { Get-Content (Join-Path $crDir 'cr7') -Raw } else { '' }
$val = ((($m -split "`n") | Where-Object { $_.StartsWith('target=', [System.StringComparison]::Ordinal) } | Select-Object -First 1) -replace '^target=', '')
Assert '[RECORD-SUBAGENT-RUN-CR-7] bold **Target:** label recorded, value trimmed after non-ASCII removal' ($r.Code -eq 0 -and [string]::Equals($val, $cr7v))
Write-Host "[RECORD-SUBAGENT-RUN-HB] record-subagent-run.ps1 — hand-back report from the sub-agent transcript"

$hbDir = Join-Path $workRoot 'hb'
New-Item -ItemType Directory -Force -Path $hbDir | Out-Null
function Format-TranscriptLine([string]$Type, [string]$Ts, $Content) {
    [ordered]@{ type = $Type; timestamp = $Ts; message = [ordered]@{ role = $Type; content = @($Content) } } | ConvertTo-Json -Compress -Depth 8
}
# Transcript fixture: user, assistant text, [assistant SubagentHandback tool_use], final user tool_result.
function Write-TranscriptFile([string]$Name, [string]$HandBack, [string]$LastText, [string]$ToolUseId = 'toolu_01HB') {
    $rows = @(
        (Format-TranscriptLine 'user' '2026-10-22T17:44:40.100Z' @{ type = 'text'; text = 'Review the branch.' }),
        (Format-TranscriptLine 'assistant' '2026-10-22T17:44:45.200Z' @{ type = 'text'; text = $LastText })
    )
    if ($HandBack) {
        $rows += (Format-TranscriptLine 'assistant' '2026-10-22T17:44:49.753Z' ([ordered]@{ type = 'tool_use'; id = $ToolUseId; name = 'SubagentHandback'; input = [ordered]@{ message = $HandBack }; caller = @{ type = 'direct' } }))
    }
    $rows += (Format-TranscriptLine 'user' '2026-10-22T17:44:50.300Z' @{ type = 'tool_result'; tool_use_id = $ToolUseId; content = '{"success":true,"message":"Report delivered to your caller."}' })
    $p = Join-Path $hbDir $Name
    [IO.File]::WriteAllText($p, (($rows -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $p
}
function Get-Text([string]$Path) { if (Test-Path $Path) { Get-Content $Path -Raw } else { '' } }

$hbTgt = 'feat/x vs origin/main (abc1234..def5678)'
$hbReport = "Target: $hbTgt`n...`nVERDICT: APPROVED"
$hbT = Write-TranscriptFile 'ok.jsonl' $hbReport 'Reviewing...'

# HB-1: gatekeeper, empty last_assistant_message, report only in the transcript
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb1'; cwd = $scratch; hook_event_name = 'SubagentStop'; agent_type = 'code-review-gatekeeper'; agent_id = 'hb1agent'; last_assistant_message = ''; agent_transcript_path = $hbT })
$ln = Get-Lines (Join-Path $crDir 'hb1')
Assert '[RECORD-SUBAGENT-RUN-HB-1] four-line code-review marker from the transcript hand-back' ($r.Code -eq 0 -and $ln.Count -eq 4 -and $ln[1] -eq 'verdict=APPROVED' -and $ln[2] -eq "head=$headSha" -and $ln[3] -eq "target=$hbTgt")
Assert '[RECORD-SUBAGENT-RUN-HB-1] no peer-review marker' (-not (Test-Path (Join-Path $prDir 'hb1')))
Assert '[RECORD-SUBAGENT-RUN-HB-1] .verdict-sources holds <agent_id>-hb-<hand-back tool_use id>' ((Get-Text (Join-Path $crDir 'hb1.verdict-sources')).Trim() -ceq 'hb1agent-hb-toolu_01HB')

# HB-2: peer-review-critic, bare and plugin-scoped
foreach ($at in @('peer-review-critic', 'agentic-framework:peer-review-critic')) {
    $sid = 'hb2-' + ($at -replace '[^\w]', '')
    $r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = $sid; cwd = $scratch; hook_event_name = 'SubagentStop'; agent_type = $at; agent_id = "a$sid"; last_assistant_message = ''; agent_transcript_path = $hbT })
    Assert "[RECORD-SUBAGENT-RUN-HB-2] $at marker carries verdict=APPROVED" ($r.Code -eq 0 -and (Get-Text (Join-Path $prDir $sid)) -match '(?m)^verdict=APPROVED$' -and -not (Test-Path (Join-Path $crDir $sid)))
}

# HB-3: a verdict in last_assistant_message wins over the transcript
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb3'; cwd = $scratch; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'hb3agent'; last_assistant_message = "Findings.`nVERDICT: CHANGES_REQUIRED"; agent_transcript_path = $hbT })
Assert '[RECORD-SUBAGENT-RUN-HB-3] last_assistant_message verdict wins over the transcript' ($r.Code -eq 0 -and (Get-Text (Join-Path $prDir 'hb3')) -match '(?m)^verdict=CHANGES_REQUIRED$')

# HB-4: no hand-back, the last assistant text block ends with the verdict
$hbT4 = Write-TranscriptFile 'text.jsonl' '' "All good.`nVERDICT: APPROVED"
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb4'; cwd = $scratch; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'hb4agent'; last_assistant_message = ''; agent_transcript_path = $hbT4 })
Assert '[RECORD-SUBAGENT-RUN-HB-4] verdict taken from the last assistant text block' ($r.Code -eq 0 -and (Get-Text (Join-Path $prDir 'hb4')) -match '(?m)^verdict=APPROVED$')

# HB-5: missing transcript path, directory path -> timestamp-only marker
$n = 0
foreach ($bad in @((Join-Path $hbDir 'does-not-exist.jsonl'), $hbDir)) {
    $n++
    $sid = "hb5-$n"
    $r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = $sid; cwd = $scratch; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = "a$sid"; last_assistant_message = ''; agent_transcript_path = $bad })
    $ln = Get-Lines (Join-Path $prDir $sid)
    Assert "[RECORD-SUBAGENT-RUN-HB-5] unreadable transcript path #$n -> exit 0, timestamp-only marker" ($r.Code -eq 0 -and $ln.Count -eq 1 -and (Get-Text (Join-Path $prDir $sid)) -notmatch 'verdict=')
}

# HB-6: PostToolUse launch acknowledgement writes nothing (array and string forms)
$ack = "Async agent launched successfully. (This tool result is internal metadata — never quote or paste any part of it, including the agentId below, into a user-facing reply.)`nagentId: 0123456789abcdef0 (internal ID - do not mention to user.)`nThe agent works in the background."
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6a'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_use_id = 'toolu_ack1'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = @(@{ type = 'text'; text = $ack }) })
Assert '[RECORD-SUBAGENT-RUN-HB-6] launch ack as content array writes no marker' ($r.Code -eq 0 -and -not (Test-Path (Join-Path $prDir 'hb6a')))
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6b'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_use_id = 'toolu_ack2'; tool_input = @{ subagent_type = 'code-review-gatekeeper' }; tool_response = $ack })
Assert '[RECORD-SUBAGENT-RUN-HB-6] launch ack as plain string writes no marker' ($r.Code -eq 0 -and -not (Test-Path (Join-Path $crDir 'hb6b')))
$null = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6c'; cwd = $scratch; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'hb6cagent'; last_assistant_message = 'VERDICT: CHANGES_REQUIRED' })
$before = Get-Text (Join-Path $prDir 'hb6c'); $srcBefore = Get-Text (Join-Path $prDir 'hb6c.verdict-sources')
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6c'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_use_id = 'toolu_ack3'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = @(@{ type = 'text'; text = $ack }) })
Assert '[RECORD-SUBAGENT-RUN-HB-6] launch ack leaves an existing CHANGES_REQUIRED marker and sources unchanged' ($r.Code -eq 0 -and $before -match 'verdict=CHANGES_REQUIRED' -and (Get-Text (Join-Path $prDir 'hb6c')) -ceq $before -and (Get-Text (Join-Path $prDir 'hb6c.verdict-sources')) -ceq $srcBefore)

# HB-6 text form, first line is the phrase but the next non-blank line is not agentId: -> an ordinary report (timestamp-only marker)
$ackBad = "Async agent launched successfully. A reviewer note, not an acknowledgement.`nThe agent works in the background."
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6f'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_use_id = 'toolu_ack6'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = $ackBad })
$ln = Get-Lines (Join-Path $prDir 'hb6f')
Assert '[RECORD-SUBAGENT-RUN-HB-6] phrase without an agentId: second line is an ordinary report (timestamp-only marker)' ($r.Code -eq 0 -and $ln.Count -eq 1 -and (Get-Text (Join-Path $prDir 'hb6f')) -notmatch 'verdict=')

# HB-6 object form: the payload shape (tool_response is the tool data object)
$ackObj = @{ agentId = 'aa304bc86dde44d40'; canContinueAgent = $true; canReadOutputFile = $false; description = 'x'; isAsync = $true; outputFile = 'C:\t\a.output'; prompt = 'short'; resolvedModel = 'claude-sonnet-5-5'; status = 'async_launched' }
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6d'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_use_id = 'toolu_ack4'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = $ackObj })
Assert '[RECORD-SUBAGENT-RUN-HB-6] launch ack as object (async_launched) writes no marker' ($r.Code -eq 0 -and -not (Test-Path (Join-Path $prDir 'hb6d')))
$null = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6e'; cwd = $scratch; hook_event_name = 'SubagentStop'; agent_type = 'peer-review-critic'; agent_id = 'hb6eagent'; last_assistant_message = 'VERDICT: CHANGES_REQUIRED' })
$before = Get-Text (Join-Path $prDir 'hb6e'); $srcBefore = Get-Text (Join-Path $prDir 'hb6e.verdict-sources')
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6e'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_use_id = 'toolu_ack5'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = $ackObj })
Assert '[RECORD-SUBAGENT-RUN-HB-6] launch ack as object leaves an existing CHANGES_REQUIRED marker and sources unchanged' ($r.Code -eq 0 -and $before -match 'verdict=CHANGES_REQUIRED' -and (Get-Text (Join-Path $prDir 'hb6e')) -ceq $before -and (Get-Text (Join-Path $prDir 'hb6e.verdict-sources')) -ceq $srcBefore)

# HB-6 off-spec objects: isAsync:true alone (no status) counts as a launch (the .sh compares isAsync == true); a completed object is an ordinary report
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6g'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_use_id = 'toolu_ack7'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = @{ isAsync = $true } })
Assert '[RECORD-SUBAGENT-RUN-HB-6] object with only isAsync:true (no status) writes no marker' ($r.Code -eq 0 -and -not (Test-Path (Join-Path $prDir 'hb6g')))
$doneObj = @{ status = 'completed'; content = @(@{ type = 'text'; text = "Done.`nVERDICT: APPROVED" }) }
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6h'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_use_id = 'toolu_ack8'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = $doneObj })
Assert '[RECORD-SUBAGENT-RUN-HB-6] non-launch object (status completed) still records the verdict' ($r.Code -eq 0 -and (Get-Text (Join-Path $prDir 'hb6h')) -match '(?m)^verdict=APPROVED$')
$arrObj = @{ status = @('async_launched'); content = @(@{ type = 'text'; text = "Done.`nVERDICT: APPROVED" }) }
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb6i'; cwd = $scratch; hook_event_name = 'PostToolUse'; tool_name = 'Agent'; tool_use_id = 'toolu_ack9'; tool_input = @{ subagent_type = 'peer-review-critic' }; tool_response = $arrObj })
Assert '[RECORD-SUBAGENT-RUN-HB-6] status as array is not a launch; verdict recorded' ($r.Code -eq 0 -and (Get-Text (Join-Path $prDir 'hb6i')) -match '(?m)^verdict=APPROVED$')

# HB-7: transcript larger than 16 MiB, hand-back beyond its first 16 MiB (the report is read from the tail)
$hb7 = Join-Path $hbDir 'big.jsonl'
$filler = Format-TranscriptLine 'assistant' '2026-10-22T17:44:42.000Z' @{ type = 'text'; text = ('x' * 4000) }
$sw = [IO.StreamWriter]::new($hb7, $false, [Text.UTF8Encoding]::new($false))
try {
    $sw.NewLine = "`n"
    $sw.WriteLine((Format-TranscriptLine 'user' '2026-10-22T17:44:40.100Z' @{ type = 'text'; text = 'Review the branch.' }))
    for ($i = 0; $i -lt 4300; $i++) { $sw.WriteLine($filler) }
    $sw.WriteLine((Format-TranscriptLine 'assistant' '2026-10-22T17:44:49.753Z' ([ordered]@{ type = 'tool_use'; id = 'toolu_hb7'; name = 'SubagentHandback'; input = [ordered]@{ message = $hbReport }; caller = @{ type = 'direct' } })))
    $sw.WriteLine((Format-TranscriptLine 'user' '2026-10-22T17:44:50.300Z' @{ type = 'tool_result'; tool_use_id = 'toolu_hb7'; content = '{"success":true}' }))
} finally { $sw.Dispose() }
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload @{ session_id = 'hb7'; cwd = $scratch; hook_event_name = 'SubagentStop'; agent_type = 'code-review-gatekeeper'; agent_id = 'hb7agent'; last_assistant_message = ''; agent_transcript_path = $hb7 })
$ln = Get-Lines (Join-Path $crDir 'hb7')
Assert '[RECORD-SUBAGENT-RUN-HB-7] transcript over 16 MiB: hand-back in the tail still records verdict and target' ((Get-Item $hb7).Length -gt 16777216 -and $r.Code -eq 0 -and $ln.Count -eq 4 -and $ln[1] -eq 'verdict=APPROVED' -and $ln[3] -eq "target=$hbTgt")
Remove-Item -LiteralPath $hb7 -Force -ErrorAction SilentlyContinue

# HB-8: a continued reviewer (same transcript, same hand-back) after HEAD moved is suppressed; a new hand-back records
$hb8T1 = Write-TranscriptFile 'hb8a.jsonl' "Target: $hbTgt`nVERDICT: APPROVED" 'Reviewing...' 'toolu_hb8a'
$hb8Pl = @{ session_id = 'hb8'; cwd = $scratch; hook_event_name = 'SubagentStop'; agent_type = 'code-review-gatekeeper'; agent_id = 'hb8agent'; last_assistant_message = ''; agent_transcript_path = $hb8T1 }
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload $hb8Pl)
$h1 = (git -C $scratch rev-parse HEAD).Trim()
$srcFile = Join-Path $crDir 'hb8.verdict-sources'; $supFile = Join-Path $crDir 'hb8.verdict-suppressed'
Assert '[RECORD-SUBAGENT-RUN-HB-8] first hand-back recorded at H1' ($r.Code -eq 0 -and (Get-Text (Join-Path $crDir 'hb8')) -match 'verdict=APPROVED' -and (Get-Text (Join-Path $crDir 'hb8')) -match "head=$h1")
git -C $scratch commit -q --allow-empty -m 'hb8 moves head'
$h2 = (git -C $scratch rev-parse HEAD).Trim()
$mBefore = Get-Text (Join-Path $crDir 'hb8'); $sBefore = Get-Text $srcFile
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload $hb8Pl)
Assert '[RECORD-SUBAGENT-RUN-HB-8] same hand-back after HEAD moved: marker unchanged (head=H1)' ($r.Code -eq 0 -and $h1 -ne $h2 -and (Get-Text (Join-Path $crDir 'hb8')) -ceq $mBefore -and $mBefore -match "head=$h1")
Assert '[RECORD-SUBAGENT-RUN-HB-8] one .verdict-suppressed line, guard=instance-dedupe; .verdict-sources unchanged' (@(Get-Lines $supFile | Where-Object { $_ }).Count -eq 1 -and (Get-Text $supFile) -match 'guard=instance-dedupe' -and (Get-Text $srcFile) -ceq $sBefore)
$hb8T2 = Write-TranscriptFile 'hb8b.jsonl' "Target: $hbTgt`nVERDICT: CHANGES_REQUIRED" 'Reviewing...' 'toolu_hb8b'
$hb8Pl2 = $hb8Pl.Clone(); $hb8Pl2['agent_transcript_path'] = $hb8T2
$r = Invoke-Hook 'record-subagent-run.ps1' (New-Payload $hb8Pl2)
Assert '[RECORD-SUBAGENT-RUN-HB-8] new hand-back after HEAD moved records CHANGES_REQUIRED at H2 with a second sources line' ($r.Code -eq 0 -and (Get-Text (Join-Path $crDir 'hb8')) -match 'verdict=CHANGES_REQUIRED' -and (Get-Text (Join-Path $crDir 'hb8')) -match "head=$h2" -and (@(Get-Lines $srcFile | Where-Object { $_ }) -join ',') -ceq 'hb8agent-hb-toolu_hb8a,hb8agent-hb-toolu_hb8b')
git -C $scratch reset -q --hard HEAD~1

Write-Host "session-start-context.ps1"

$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'c1'; cwd = $scratch })
Assert 'reports ahead-of-base state on feature branch' ($r.Code -eq 0 -and $r.Out -match 'ahead of' -and $r.Out -match 'feature/x')

git -C $scratch checkout -q main
$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'c2'; cwd = $scratch })
Assert 'reports base-branch state on main' ($r.Code -eq 0 -and $r.Out -match "On 'main'" -and $r.Out -match 'code-review-gatekeeper')
git -C $scratch checkout -q feature/x

$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'c3'; cwd = $workRoot })
Assert 'silent outside a git worktree' ($r.Code -eq 0 -and -not $r.Out)

$policyText = [IO.File]::ReadAllText((Join-Path $repoRoot 'POLICY.md')).TrimEnd("`n")
$marker = '<!-- agentic-framework: policy inline -->'
$polDir = Join-Path $workRoot 'policy-cwd'
New-Item -ItemType Directory -Force -Path (Join-Path $polDir 'sub') | Out-Null
$env:CLAUDE_PLUGIN_ROOT = $repoRoot

$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'p1'; source = 'startup'; cwd = $polDir })
Assert 'policy: startup in scratch dir prints POLICY.md exactly' ($r.Code -eq 0 -and $r.Out -ceq $policyText)

$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'p2'; source = 'startup'; cwd = $scratch })
$lines = $r.Out -split "`n", 2
Assert 'policy: git repo prints branch line, then POLICY.md exactly' ($r.Code -eq 0 -and $lines[0] -match 'ahead of' -and $lines[1] -ceq $policyText)

foreach ($src in 'resume', 'clear', 'compact') {
    $r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'p3'; source = $src; cwd = $polDir })
    Assert "policy: source $src prints the policy" ($r.Code -eq 0 -and $r.Out -ceq $policyText)
}

$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'p4'; source = 'other'; cwd = $polDir })
Assert 'policy: unknown source prints no policy' ($r.Code -eq 0 -and -not $r.Out)

Set-Content -Path (Join-Path $scratch 'CLAUDE.md') -Value "# proj`n$marker" -NoNewline
$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'p5'; source = 'startup'; cwd = $scratch })
Assert 'policy: marker in <cwd>/CLAUDE.md suppresses the policy, branch line kept' ($r.Code -eq 0 -and $r.Out -match 'ahead of' -and $r.Out -notmatch 'Agentic Framework Policy')
Remove-Item (Join-Path $scratch 'CLAUDE.md') -Force

[IO.File]::WriteAllText((Join-Path $polDir 'CLAUDE.md'), "# proj`r`n$marker`r`n")
$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'p6'; source = 'resume'; cwd = $polDir })
Assert 'policy: marker with CRLF line endings is honoured' ($r.Code -eq 0 -and -not $r.Out)

[IO.File]::WriteAllText((Join-Path $polDir 'CLAUDE.md'), "# proj`n$marker trailing`n")
$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'p7'; source = 'startup'; cwd = $polDir })
Assert 'policy: near-miss marker line does not suppress the policy' ($r.Code -eq 0 -and $r.Out -ceq $policyText)
Remove-Item (Join-Path $polDir 'CLAUDE.md') -Force

Set-Content -Path (Join-Path $polDir 'sub/CLAUDE.md') -Value $marker
$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'p8'; source = 'startup'; cwd = $polDir })
Assert 'policy: marker only in <cwd>/sub/CLAUDE.md still prints the policy' ($r.Code -eq 0 -and $r.Out -ceq $policyText)

Set-Content -Path (Join-Path $workRoot 'CLAUDE.md') -Value $marker
$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'p9'; source = 'startup'; cwd = $polDir })
Assert "policy: marker only in the parent's CLAUDE.md still prints the policy" ($r.Code -eq 0 -and $r.Out -ceq $policyText)
Remove-Item (Join-Path $workRoot 'CLAUDE.md') -Force

$emptyRoot = Join-Path $workRoot 'policy-emptyroot'
New-Item -ItemType Directory -Force -Path $emptyRoot | Out-Null
$env:CLAUDE_PLUGIN_ROOT = $emptyRoot
$r = Invoke-Hook 'session-start-context.ps1' (New-Payload @{ session_id = 'p10'; source = 'startup'; cwd = $polDir })
Remove-Item Env:\CLAUDE_PLUGIN_ROOT
Assert 'policy: missing POLICY.md prints nothing extra, exit 0' ($r.Code -eq 0 -and -not $r.Out)

$r = Invoke-Hook 'session-start-context.ps1' '{{{'
Assert 'fail-open on malformed stdin' ($r.Code -eq 0)

Write-Host "pretooluse-delegation-hint.ps1"

$r = Invoke-Hook 'pretooluse-delegation-hint.ps1' (New-Payload @{ session_id = 'd1'; tool_name = 'Write'; tool_input = @{ file_path = 'C:/tmp/lib.rs' } })
Assert 'suggests rust-expert for .rs file' ($r.Code -eq 0 -and $r.Out -match 'rust-expert' -and $r.Out -match '"systemMessage"')

$r = Invoke-Hook 'pretooluse-delegation-hint.ps1' (New-Payload @{ session_id = 'd1'; tool_name = 'Write'; tool_input = @{ file_path = 'C:/tmp/main.rs' } })
Assert 'hints at most once per session per agent' ($r.Code -eq 0 -and -not $r.Out)

$r = Invoke-Hook 'pretooluse-delegation-hint.ps1' (New-Payload @{ session_id = 'd2'; tool_name = 'Write'; tool_input = @{ file_path = 'C:/tmp/notes.txt' } })
Assert 'silent for unmapped extensions' ($r.Code -eq 0 -and -not $r.Out)

$r = Invoke-Hook 'pretooluse-delegation-hint.ps1' '[broken'
Assert 'fail-open on malformed stdin' ($r.Code -eq 0)

Write-Host "pretooluse-model-guard.ps1"

# Save and clear both guard-relevant env vars for the whole block, restoring
# in finally, so a machine-wide CLAUDE_CODE_SUBAGENT_MODEL (or a stray
# AF_MODEL_GUARD) never leaks into a case that assumes it is unset.
$savedFloor = $env:CLAUDE_CODE_SUBAGENT_MODEL
$savedGuard = $env:AF_MODEL_GUARD
Remove-Item Env:\CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction SilentlyContinue
Remove-Item Env:\AF_MODEL_GUARD -ErrorAction SilentlyContinue

try {
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_name = 'Agent'; tool_input = @{ subagent_type = 'Explore'; model = 'fable' } })
    Assert 'denies model=fable (A)' ($r.Code -eq 0 -and $r.Out -match '"permissionDecision":"deny"' -and $r.Out -match 'top model tier')

    foreach ($mv in 'Fable', 'FABLE') {
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'x'; model = $mv } })
        Assert "mixed-case ($mv) denied like fable (EDGE-002)" ($r.Code -eq 0 -and $r.Out -match '"permissionDecision":"deny"')
    }

    # REQ-007 / EDGE-003: executors are capped at sonnet
    foreach ($c in @(@('bash-expert','opus'), @('agentic-framework:powershell-expert','claude-opus-5-5'), @('bash-expert','Opus'), @('bash-expert','OPUS'), @('bash-expert','opus-5-5'))) {
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = $c[0]; model = $c[1] } })
        Assert "executor $($c[0]) + $($c[1]) denied (REQ-007)" ($r.Code -eq 0 -and $r.Out -match '"permissionDecision":"deny"' -and $r.Out -match 'capped at sonnet')
    }
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'bash-expert'; model = 'sonnet' } })
    Assert 'executor + sonnet allowed (REQ-007)' ($r.Code -eq 0 -and -not $r.Out)
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'bash-expert' } })
    Assert 'executor with no model allowed and not rewritten (REQ-007)' ($r.Code -eq 0 -and -not $r.Out)
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'rust-expert'; model = 'opus' } })
    Assert 'non-executor + opus allowed (REQ-007)' ($r.Code -eq 0 -and -not $r.Out)
    try {
        $env:AF_MODEL_GUARD = 'off'
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'bash-expert'; model = 'opus' } })
        Assert 'executor + opus with AF_MODEL_GUARD=off allowed (REQ-007)' ($r.Code -eq 0 -and -not $r.Out)
    } finally {
        Remove-Item Env:\AF_MODEL_GUARD -ErrorAction SilentlyContinue
    }

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore' } })
    Assert 'rewrites built-in Explore with no model and no floor (B)' ($r.Code -eq 0 -and $r.Out -notmatch 'permissionDecision' -and $r.Out -match 'Built-in agent Explore' -and $r.Out -match 'Model set to haiku' -and $r.Out -match '"model":"haiku"')

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{} })
    Assert 'empty subagent_type treated as general-purpose, rewritten (B)' ($r.Code -eq 0 -and $r.Out -notmatch 'permissionDecision' -and $r.Out -match 'Built-in agent general-purpose' -and $r.Out -match 'Model set to sonnet' -and $r.Out -match '"updatedInput":\{"model":"sonnet"\}')

    try {
        $env:CLAUDE_CODE_SUBAGENT_MODEL = 'sonnet'
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore' } })
        Assert 'built-in agent passes when CLAUDE_CODE_SUBAGENT_MODEL floor is set (EDGE-003)' ($r.Code -eq 0 -and -not $r.Out)
    } finally {
        Remove-Item Env:\CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction SilentlyContinue
    }

    foreach ($st in 'python-expert', 'agentic-framework:python-expert') {
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = $st } })
        Assert "framework agent ($st) without model passes silently (EDGE-004)" ($r.Code -eq 0 -and -not $r.Out)
    }

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'python-expert'; model = 'sonnet' } })
    Assert 'passes silently for a properly-tiered call (C)' ($r.Code -eq 0 -and -not $r.Out)

    try {
        $env:AF_MODEL_GUARD = 'off'
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore'; model = 'fable' } })
        Assert 'AF_MODEL_GUARD=off disables the guard (EDGE-005)' ($r.Code -eq 0 -and -not $r.Out)
    } finally {
        Remove-Item Env:\AF_MODEL_GUARD -ErrorAction SilentlyContinue
    }

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' 'not json'
    Assert 'fail-open on malformed stdin (EDGE-001)' ($r.Code -eq 0 -and -not $r.Out)

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'fork' } })
    Assert 'fork denied regardless of model (EDGE-009)' ($r.Code -eq 0 -and $r.Out -match 'runs on its parent model')

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Fork'; model = 'sonnet' } })
    Assert 'Fork with explicit model still denied (EDGE-009)' ($r.Code -eq 0 -and $r.Out -match 'runs on its parent model')

    try {
        $env:CLAUDE_CODE_SUBAGENT_MODEL = 'sonnet'
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'fork' } })
        Assert 'fork with floor set still denied (EDGE-009)' ($r.Code -eq 0 -and $r.Out -match 'runs on its parent model')
    } finally {
        Remove-Item Env:\CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction SilentlyContinue
    }

    try {
        $env:AF_MODEL_GUARD = 'off'
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'fork' } })
        Assert 'fork silent when AF_MODEL_GUARD=off (EDGE-009)' ($r.Code -eq 0 -and -not $r.Out)
    } finally {
        Remove-Item Env:\AF_MODEL_GUARD -ErrorAction SilentlyContinue
    }

    foreach ($mv in 'claude-fable-5-1', ' fable', 'fable ', 'fable[1m]', 'FABLE') {
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'agentic-framework:python-expert'; model = $mv } })
        Assert "model=[$mv] denied reason A (EDGE-010)" ($r.Code -eq 0 -and $r.Out -match 'top model tier')
    }

    foreach ($fv in 'fable', ' Fable ') {
        try {
            $env:CLAUDE_CODE_SUBAGENT_MODEL = $fv
            $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore' } })
            Assert "floor=[$fv] does not count as set, rewrites Explore (EDGE-011)" ($r.Code -eq 0 -and $r.Out -match 'Built-in agent Explore')
        } finally {
            Remove-Item Env:\CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction SilentlyContinue
        }
    }

    try {
        $env:CLAUDE_CODE_SUBAGENT_MODEL = 'haiku'
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore' } })
        Assert 'floor=haiku silences the guard (EDGE-011)' ($r.Code -eq 0 -and -not $r.Out)
    } finally {
        Remove-Item Env:\CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction SilentlyContinue
    }

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'agentic-framework:python-expert'; model = $false } })
    Assert 'model=false framework agent silent (EDGE-012)' ($r.Code -eq 0 -and -not $r.Out)

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore'; model = @() } })
    Assert 'model=[] Explore rewritten to haiku (EDGE-012)' ($r.Code -eq 0 -and $r.Out -match 'Built-in agent Explore' -and $r.Out -match '"model":"haiku"')

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = @(); model = $false } })
    Assert 'subagent_type=[] treated as general-purpose (EDGE-012)' ($r.Code -eq 0 -and $r.Out -match 'Built-in agent general-purpose')

    foreach ($bad in '{"tool_input":"x"}', '{"tool_input":[1]}', '{"tool_input":null}', '{}') {
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' $bad
        Assert "non-object tool_input ($bad) silent (EDGE-013)" ($r.Code -eq 0 -and -not $r.Out)
    }

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{}}'
    Assert 'empty-object tool_input rewritten to sonnet, general-purpose (EDGE-013)' ($r.Code -eq 0 -and $r.Out -match 'Built-in agent general-purpose' -and $r.Out -match '"updatedInput":\{"model":"sonnet"\}')

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'my-custom-agent' } })
    Assert 'unknown agent without model is NOT denied (known limit: frontmatter is invisible to the hook) (EDGE-016)' ($r.Code -eq 0 -and -not $r.Out)

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'other-plugin:some-agent' } })
    Assert 'other-plugin-scoped unknown agent is NOT denied (known limit) (EDGE-016)' ($r.Code -eq 0 -and -not $r.Out)

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'my-custom-agent'; model = 'fable' } })
    Assert 'top-tier rule still binds for unknown agents (reason A) (EDGE-016)' ($r.Code -eq 0 -and $r.Out -match 'top model tier')

    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'my-custom-agent'; model = 'haiku' } })
    Assert 'unknown agent with a legitimate tier is silent (EDGE-016)' ($r.Code -eq 0 -and -not $r.Out)

    foreach ($st in 'Explore', 'Plan', 'general-purpose', 'claude', '') {
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = $st } })
        Assert "stype=[$st] rewrite has no permissionDecision key (EDGE-019a)" ($r.Code -eq 0 -and $r.Out -notmatch 'permissionDecision')
        Assert "stype=[$st] systemMessage present (EDGE-019a)" ($r.Code -eq 0 -and $r.Out -match '"systemMessage"')
        $expectTier = if ($st -eq 'Explore') { 'haiku' } else { 'sonnet' }
        Assert "stype=[$st] rewritten to $expectTier (EDGE-019a)" ($r.Code -eq 0 -and $r.Out -match [regex]::Escape("`"model`":`"$expectTier`""))
    }

    # NOTE: assertions below parse $r.Out with System.Text.Json (JsonDocument),
    # never ConvertFrom-Json — that cmdlet auto-converts an ISO-date-shaped
    # JSON string into a [datetime] (measured: ConvertFrom-Json on
    # '{"d":"2026-09-20T10:00:00Z"}' yields a DateTime, not a string), which is
    # exactly the corruption this hook must avoid, and using it here to verify
    # the hook's own output would hide that bug rather than catch it.
    # Utf8JsonWriter also HTML-escapes <, >, &, " by default (< etc.), so
    # a raw-text regex on the escaped form is brittle; comparing decoded
    # .GetString() values is what actually proves round-trip fidelity.

    # [ordered] is required here: a plain @{} hashtable does not preserve key
    # insertion order through ConvertTo-Json, which would falsely fail this
    # order-sensitive assertion regardless of the hook's own behavior.
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload ([ordered]@{ tool_input = [ordered]@{ description = 'd'; prompt = 'p'; subagent_type = 'general-purpose'; run_in_background = $true; name = 'x' } }))
    $doc19b = [System.Text.Json.JsonDocument]::Parse($r.Out)
    $ui19b = $doc19b.RootElement.GetProperty('hookSpecificOutput').GetProperty('updatedInput')
    $names19b = @($ui19b.EnumerateObject() | ForEach-Object { $_.Name })
    Assert 'every original key preserved, model appended last (EDGE-019b)' (
        $r.Code -eq 0 -and
        ($names19b -join ',') -eq 'description,prompt,subagent_type,run_in_background,name,model' -and
        $ui19b.GetProperty('model').GetString() -eq 'sonnet'
    )

    $rawPrompt = 'zluty kun <tag> & "quoted" \back\slash'
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore'; prompt = $rawPrompt; description = '2026-09-20T10:00:00Z' } })
    Assert 'integrity payload rewrite exits 0 (EDGE-019c)' ($r.Code -eq 0)
    $doc19c = [System.Text.Json.JsonDocument]::Parse($r.Out)
    $ui19c = $doc19c.RootElement.GetProperty('hookSpecificOutput').GetProperty('updatedInput')
    Assert 'prompt round-trips exactly (EDGE-019c)' ($ui19c.GetProperty('prompt').GetString() -eq $rawPrompt)
    Assert 'ISO-date-shaped description round-trips exactly as a string (EDGE-019c)' ($ui19c.GetProperty('description').GetString() -eq '2026-09-20T10:00:00Z')

    $bigPrompt = 'a' * 200000
    $swBig = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore'; prompt = $bigPrompt } })
    $swBig.Stop()
    Assert '200KB-prompt rewrite exits 0 within timeout (EDGE-019d)' ($r.Code -eq 0 -and $r.Out -match '"model":"haiku"')
    Write-Host "  INFO  ps1 200KB-prompt wall time: $($swBig.ElapsedMilliseconds) ms"

    foreach ($badModel in $false, @(), '   ') {
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore'; model = $badModel } })
        Assert "model=[$badModel] rewrites to haiku (EDGE-019e)" ($r.Code -eq 0 -and $r.Out -match '"model":"haiku"')
        $modelKeyCount = ([regex]::Matches($r.Out, '"model"\s*:')).Count
        Assert "model=[$badModel] results in exactly one model key (EDGE-019e)" ($modelKeyCount -eq 1)
    }

    # EDGE-021: lone-surrogate bypass, duplicate fields, off-switch trimming.
    # Raw JSON strings (not New-Payload/hashtable) so the \ud800 escape and
    # duplicate object fields survive literally on the wire; PowerShell
    # hashtables cannot hold a duplicate key.

    # (a) fork + lone surrogate in prompt -> still denied reason C
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"subagent_type":"fork","prompt":"a\ud800b"}}'
    Assert 'fork+surrogate still denied reason C (EDGE-021a)' ($r.Code -eq 0 -and $r.Out -match 'runs on its parent model')

    # (b) model=fable + lone surrogate in prompt -> still denied reason A
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"subagent_type":"agentic-framework:python-expert","model":"fable","prompt":"a\ud800b"}}'
    Assert 'fable+surrogate still denied reason A (EDGE-021b)' ($r.Code -eq 0 -and $r.Out -match 'top model tier')

    # (c) Explore, no model, lone surrogate in prompt -> cannot echo safely,
    # falls back to deny rather than inheriting the session tier (M1 fix).
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"subagent_type":"Explore","prompt":"a\ud800b"}}'
    Assert 'Explore+surrogate falls back to deny (EDGE-021c)' ($r.Code -eq 0 -and $r.Out -match 'could not be rewritten safely')

    # (d) framework agent, no model, lone surrogate in prompt -> silent
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"subagent_type":"agentic-framework:python-expert","prompt":"a\ud800b"}}'
    Assert 'framework-agent+surrogate silent, cannot echo exactly (EDGE-021d)' ($r.Code -eq 0 -and -not $r.Out)

    # (e) duplicate "model" -> rewrite, raw output has exactly one model field, valued haiku
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"model":"fable","model":"","subagent_type":"Explore","prompt":"p"}}'
    $modelKeyCount21e = ([regex]::Matches($r.Out, '"model"\s*:')).Count
    Assert 'dup-model raw output has exactly one model field (EDGE-021e)' ($r.Code -eq 0 -and $modelKeyCount21e -eq 1)
    Assert 'dup-model rewrites to haiku (EDGE-021e)' ($r.Out -match '"model":"haiku"')

    # (f) duplicate "subagent_type": fork then Explore -> rewrite, last value wins (Explore)
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"subagent_type":"fork","subagent_type":"Explore","prompt":"p"}}'
    $subtypeKeyCount21f = ([regex]::Matches($r.Out, '"subagent_type"\s*:')).Count
    Assert 'dup-subagent_type raw output has exactly one field (EDGE-021f)' ($r.Code -eq 0 -and $subtypeKeyCount21f -eq 1)
    Assert 'dup-subagent_type fork-then-Explore rewrites with Explore (EDGE-021f)' ($r.Out -match '"subagent_type":"Explore"')

    # (f, reversed) Explore then fork -> last value wins (fork) -> denied reason C
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"subagent_type":"Explore","subagent_type":"fork","prompt":"p"}}'
    Assert 'dup-subagent_type Explore-then-fork denied reason C (EDGE-021f)' ($r.Code -eq 0 -and $r.Out -match 'runs on its parent model')

    # (g) AF_MODEL_GUARD with surrounding/trailing whitespace still disables the guard
    try {
        $env:AF_MODEL_GUARD = ' off '
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore'; model = 'fable' } })
        Assert 'AF_MODEL_GUARD=" off " (padded) disables the guard (EDGE-021g)' ($r.Code -eq 0 -and -not $r.Out)
    } finally {
        Remove-Item Env:\AF_MODEL_GUARD -ErrorAction SilentlyContinue
    }
    try {
        $env:AF_MODEL_GUARD = 'OFF  '
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' (New-Payload @{ tool_input = @{ subagent_type = 'Explore'; model = 'fable' } })
        Assert 'AF_MODEL_GUARD="OFF  " (trailing space) disables the guard (EDGE-021g)' ($r.Code -eq 0 -and -not $r.Out)
    } finally {
        Remove-Item Env:\AF_MODEL_GUARD -ErrorAction SilentlyContinue
    }

    # EDGE-022: per-field surrogate sanitising (B1), rewrite fallback-deny (M1), case-sensitive fields (m1)

    # (a) lone surrogate INSIDE the model field itself -> deny reason A
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"subagent_type":"agentic-framework:python-expert","model":"fable\ud800","prompt":"p"}}'
    Assert 'model-field-surrogate denied reason A (EDGE-022a)' ($r.Code -eq 0 -and $r.Out -match 'top model tier')

    # (b) lone surrogate INSIDE the model field on a fork -> deny reason C
    # (one bad field must not suppress the OTHER field's check)
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"subagent_type":"fork","model":"sonnet\ud800","prompt":"p"}}'
    Assert 'fork-model-field-surrogate denied reason C (EDGE-022b)' ($r.Code -eq 0 -and $r.Out -match 'runs on its parent model')

    # (c) lone surrogate INSIDE subagent_type: sanitised value is not a
    # recognised built-in name -> silent (pinned agreed behaviour)
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"subagent_type":"Explore\ud800"}}'
    Assert 'subagent-type-field-surrogate silent (EDGE-022c)' ($r.Code -eq 0 -and -not $r.Out)

    # (d) Explore/Plan/no-type, no model, lone surrogate in prompt -> falls
    # back to deny naming TYPE/TIER; no updatedInput anywhere
    foreach ($case in @(
        @{ Payload = '{"tool_input":{"subagent_type":"Explore","prompt":"a\ud800b"}}'; Tier = 'haiku'; Label = 'Explore' },
        @{ Payload = '{"tool_input":{"subagent_type":"Plan","prompt":"a\ud800b"}}'; Tier = 'sonnet'; Label = 'Plan' },
        @{ Payload = '{"tool_input":{"prompt":"a\ud800b"}}'; Tier = 'sonnet'; Label = 'no-type' }
    )) {
        $r = Invoke-Hook 'pretooluse-model-guard.ps1' $case.Payload
        Assert "$($case.Label) fallback-deny names tier $($case.Tier) (EDGE-022d)" ($r.Code -eq 0 -and $r.Out -match "model set to $($case.Tier)")
        Assert "$($case.Label) fallback-deny has no updatedInput key (EDGE-022d)" (-not ($r.Out -match 'updatedInput'))
    }

    # (e) framework agent, no model, lone surrogate in prompt -> still silent
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"subagent_type":"agentic-framework:python-expert","prompt":"a\ud800b"}}'
    Assert 'framework-agent-surrogate silent (EDGE-022e)' ($r.Code -eq 0 -and -not $r.Out)

    # (f) case-variant field: caller's "Model" survives, exactly one lowercase "model" field
    $r = Invoke-Hook 'pretooluse-model-guard.ps1' '{"tool_input":{"description":"d","prompt":"p","Model":"zzz","subagent_type":"Explore"}}'
    $lowerModelCount22f = ([regex]::Matches($r.Out, '"model"\s*:')).Count
    Assert 'case-variant-field preserves caller Model (EDGE-022f)' ($r.Code -eq 0 -and $r.Out -match '"Model":"zzz"')
    Assert 'case-variant-field has exactly one lowercase model field (EDGE-022f)' ($lowerModelCount22f -eq 1)
} finally {
    if ($null -ne $savedFloor) { $env:CLAUDE_CODE_SUBAGENT_MODEL = $savedFloor } else { Remove-Item Env:\CLAUDE_CODE_SUBAGENT_MODEL -ErrorAction SilentlyContinue }
    if ($null -ne $savedGuard) { $env:AF_MODEL_GUARD = $savedGuard } else { Remove-Item Env:\AF_MODEL_GUARD -ErrorAction SilentlyContinue }
}

# ── pretooluse-code-review-gate.ps1 (REQ-004, EDGE-001 .. EDGE-008) ───────────
# Mirrors the [PRETOOLUSE-CODE-REVIEW-GATE-*] sections of tests/hooks.test.sh.
$script:GateState = $stateDir
$script:GateRun = $null
$script:GateHome = $null
$script:GF = @{}

function Add-GateCommit([string]$Dir, [string]$Msg) {
    Add-Content -Path (Join-Path $Dir 'f.txt') -Value $Msg
    git -C $Dir add -A 2>$null | Out-Null
    git -C $Dir commit -q -m $Msg 2>$null | Out-Null
}

function Initialize-GateRepoBare([string]$Dir, [string]$Branch = 'main') {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    git -C $Dir init -q -b $Branch
    git -C $Dir config user.email 'test@test.local'
    git -C $Dir config user.name 'hooks-test'
    git -C $Dir config commit.gpgsign false
}

# Repo with origin/<branch> one commit behind <branch>, origin/HEAD -> origin/<branch>, feat/x at the tip.
# The remote URL points at a path that does not exist; nothing here ever contacts it.
function Build-GateRepo([string]$Dir, [string]$Branch = 'main') {
    Initialize-GateRepoBare $Dir $Branch
    Add-GateCommit $Dir 'c1'
    git -C $Dir remote add origin "$Dir.nowhere"
    git -C $Dir update-ref "refs/remotes/origin/$Branch" (git -C $Dir rev-parse HEAD)
    git -C $Dir symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$Branch"
    Add-GateCommit $Dir 'c2'
    git -C $Dir branch feat/x
}

function Build-GateFixtures([string]$Root) {
    $f = @{}
    $f.M = Join-Path $Root 'm';   Build-GateRepo $f.M 'main'
    $f.XS = Join-Path $Root 'xs'; Copy-Item -Recurse $f.M $f.XS; git -C $f.XS checkout -q feat/x
    $f.X = Join-Path $Root 'x';   Copy-Item -Recurse $f.XS $f.X; Add-GateCommit $f.X 'c3'
    $f.U = Join-Path $Root 'u';   Copy-Item -Recurse $f.X $f.U
    git -C $f.U config branch.feat/x.remote origin
    git -C $f.U config branch.feat/x.merge refs/heads/main
    $f.U2 = Join-Path $Root 'u2'; Copy-Item -Recurse $f.X $f.U2
    git -C $f.U2 update-ref refs/remotes/origin/feat/x (git -C $f.U2 rev-parse main)
    git -C $f.U2 config branch.feat/x.remote origin
    git -C $f.U2 config branch.feat/x.merge refs/heads/feat/x
    $f.MT = Join-Path $Root 'mt'; Copy-Item -Recurse $f.X $f.MT; git -C $f.MT config push.default matching
    $f.DY = Join-Path $Root 'dy'; Copy-Item -Recurse $f.X $f.DY; Add-Content -Path (Join-Path $f.DY 'f.txt') -Value 'dirty'
    $f.SB = Join-Path $Root 'sb'; Copy-Item -Recurse $f.X $f.SB; Build-GateRepo (Join-Path $f.SB 'sub') 'main'
    $f.DT = Join-Path $Root 'dt'; Copy-Item -Recurse $f.M $f.DT; git -C $f.DT checkout -q --detach
    $f.EQ = Join-Path $Root 'eq'; Copy-Item -Recurse $f.X $f.EQ
    git -C $f.EQ update-ref refs/remotes/origin/main (git -C $f.EQ rev-parse main)
    $f.MS = Join-Path $Root 'ms'; Build-GateRepo $f.MS 'master'
    # <home>/other: on main, one ahead of origin/main
    $f.HOME = Join-Path $Root 'home'; $f.OTH = Join-Path $f.HOME 'other'; Build-GateRepo $f.OTH 'main'
    # main one commit behind origin/main
    $f.BH = Join-Path $Root 'bh'; Copy-Item -Recurse $f.X $f.BH; git -C $f.BH checkout -q main
    git -C $f.BH update-ref refs/remotes/origin/main (git -C $f.BH rev-parse feat/x)
    # branch.main.remote=upstream
    $f.UP = Join-Path $Root 'up'; Copy-Item -Recurse $f.M $f.UP
    git -C $f.UP remote add upstream "$($f.UP).nowhere-up"
    git -C $f.UP update-ref refs/remotes/upstream/main (git -C $f.UP rev-parse 'main~1')
    git -C $f.UP update-ref refs/remotes/origin/main (git -C $f.UP rev-parse main)
    git -C $f.UP config branch.main.remote upstream
    # not a git work tree
    $f.PL = Join-Path $Root 'plain'; New-Item -ItemType Directory -Force -Path $f.PL | Out-Null
    $script:GF = $f
}

# Write a code-review marker: '-' omits a line.
function Set-GateMarker([string]$Sid, [string]$Verdict, [string]$Head, [string]$Target) {
    $d = Join-Path $script:GateState 'code-review'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    $t = '2026-10-21T00:00:00Z'
    if ($Verdict -ne '-') { $t += "`nverdict=$Verdict" }
    if ($Head -ne '-') { $t += "`nhead=$Head" }
    if ($Target -ne '-') { $t += "`ntarget=$Target" }
    [IO.File]::WriteAllText((Join-Path $d $Sid), $t)
}

# A marker whose target carries the real reviewed range (<merge-base>..<HEAD>) of $Dir.
function Set-GateRealMarker([string]$Sid, [string]$Dir, [string]$Prefix, [string]$BaseRef, [string]$Verdict = 'APPROVED', [string]$Head = '') {
    $h = (git -C $Dir rev-parse HEAD).Trim()
    $mb = (git -C $Dir merge-base $BaseRef HEAD).Trim()
    if (-not $Head) { $Head = $h }
    Set-GateMarker $Sid $Verdict $Head "$Prefix ($mb..$h); fallback: none"
}

function Invoke-GateRaw([string]$Raw, $GateEnv = $null) {
    $savedGate = $env:AF_CODE_REVIEW_GATE
    $savedState = $env:CLAUDE_STATE_DIR
    $savedHome = $env:HOME
    $env:CLAUDE_STATE_DIR = $script:GateState
    if ($script:GateHome) { $env:HOME = $script:GateHome }
    if ($null -ne $GateEnv) { $env:AF_CODE_REVIEW_GATE = [string]$GateEnv } else { Remove-Item Env:\AF_CODE_REVIEW_GATE -ErrorAction SilentlyContinue }
    try { $script:GateRun = Invoke-Hook 'pretooluse-code-review-gate.ps1' $Raw }
    finally {
        if ($null -ne $savedGate) { $env:AF_CODE_REVIEW_GATE = $savedGate } else { Remove-Item Env:\AF_CODE_REVIEW_GATE -ErrorAction SilentlyContinue }
        $env:CLAUDE_STATE_DIR = $savedState
        if ($null -ne $savedHome) { $env:HOME = $savedHome } else { Remove-Item Env:\HOME -ErrorAction SilentlyContinue }
    }
}

function Invoke-Gate([string]$Sid, [string]$Cwd, [string]$Cmd, $GateEnv = $null, [string]$Tool = 'Bash') {
    Invoke-GateRaw (New-Payload @{ session_id = $Sid; cwd = $Cwd; tool_name = $Tool; tool_input = @{ command = $Cmd } }) $GateEnv
}

function Assert-GateAllow([string]$Label) {
    Assert $Label ($script:GateRun.Code -eq 0 -and -not $script:GateRun.Out)
}

function Assert-GateDeny([string]$Label, [string[]]$Needle = @(), [bool]$AlsoTrue = $true) {
    $ok = ($script:GateRun.Code -eq 0 -and $AlsoTrue)
    $reason = ''
    try {
        $j = $script:GateRun.Out | ConvertFrom-Json
        if ($j.hookSpecificOutput.permissionDecision -ne 'deny') { $ok = $false }
        $reason = [string]$j.hookSpecificOutput.permissionDecisionReason
    } catch { $ok = $false }
    foreach ($n in $Needle) { if (-not $reason.Contains($n)) { $ok = $false } }
    Assert $Label $ok
}

# Decision S.5: a row whose command is a plain form (S.2) keeps its table decision;
# every other row is denied as not plain, whatever the table column says.
$script:GatePlain = 'not a plain push or pull request command'

# One EDGE-001 row: $Expect is allow | none | src | unconf | plain | loc | norepo | stale.
# $Fix is a fixture key of $script:GF or an absolute directory.
function Test-GateRow([string]$Row, [string]$Fix, [string]$Expect, [string]$Cmd, [string]$Extra = '', [string]$Tool = 'Bash') {
    # $Row is 'EDGE-001 row <nn>'; the session id is r<nn>
    $Nn = $Row.Substring('EDGE-001 row '.Length)
    $shown = $Cmd.Replace("`n", '\n').Replace("`r", '<CR>')
    $label = "${Row}: $shown"
    if ($Tool -eq 'PowerShell') { $label += ' [PowerShell]' }
    $cwd = if ($script:GF.ContainsKey($Fix)) { $script:GF[$Fix] } else { $Fix }
    Invoke-Gate "r$Nn" $cwd $Cmd $null $Tool
    if ($Expect -eq 'allow') { Assert-GateAllow $label; return }
    $want = switch ($Expect) {
        'none'   { 'review is recorded' }
        'src'    { 'checked-out commit' }
        'unconf' { 'configured remote' }
        'plain'  { $script:GatePlain }
        'loc'    { 'does not exist or is not a git work tree' }
        'norepo' { 'not a git work tree' }
        'stale'  { 'stale' }
    }
    $needles = @($want)
    if ($Extra) { $needles += $Extra }
    Assert-GateDeny $label $needles
}

function Test-GateRowPs([string]$Row, [string]$Fix, [string]$Expect, [string]$Cmd, [string]$Extra = '') {
    Test-GateRow $Row $Fix $Expect $Cmd $Extra 'PowerShell'
}

Write-Host "pretooluse-code-review-gate.ps1"
Write-Host "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE001] 201-row command decision table (decision S)"
$script:GateState = Join-Path $workRoot 'gate-state-1'
Build-GateFixtures (Join-Path $workRoot 'gate-fx-1')
Set-GateRealMarker 'r42' $script:GF.M 'main vs origin/main' 'refs/remotes/origin/main'
Set-GateRealMarker 'r125' $script:GF.M 'main vs origin/main' 'refs/remotes/origin/main'
Set-GateRealMarker 'r126' $script:GF.M 'main vs origin/main' 'refs/remotes/origin/main'

Test-GateRow 'EDGE-001 row 01' M none 'git push' 'main vs origin/main'
Test-GateRow 'EDGE-001 row 02' X allow 'git push'
Test-GateRow 'EDGE-001 row 03' U none 'git push' 'feat/x vs origin/main'
Test-GateRow 'EDGE-001 row 04' U2 allow 'git push'
Test-GateRow 'EDGE-001 row 05' MT src 'git push'
Test-GateRow 'EDGE-001 row 06' X src 'git push origin main'
Test-GateRow 'EDGE-001 row 07' XS src 'git push origin main'
Test-GateRow 'EDGE-001 row 08' M none 'git push origin HEAD'
Test-GateRow 'EDGE-001 row 09' M none 'git push origin HEAD:main'
Test-GateRow 'EDGE-001 row 10' M none 'git push origin main:main'
Test-GateRow 'EDGE-001 row 11' MS none 'git push origin HEAD:refs/heads/master' 'master vs origin/master'
Test-GateRow 'EDGE-001 row 12' M none 'git push origin +HEAD:main'
Test-GateRow 'EDGE-001 row 13' M none 'git push --force origin main'
Test-GateRow 'EDGE-001 row 14' M none 'git push --force-with-lease origin +main'
Test-GateRow 'EDGE-001 row 15' M plain 'git push --repo=origin HEAD:main'
Test-GateRow 'EDGE-001 row 16' M none 'git push -o ci.skip origin main'
Test-GateRow 'EDGE-001 row 17' X plain 'git push origin feat/x main'
Test-GateRow 'EDGE-001 row 18' M none 'git push origin main --tags'
Test-GateRow 'EDGE-001 row 19' DY none 'git push origin feat/x:main'
Test-GateRow 'EDGE-001 row 20' M unconf 'git push https://host/r.git main'
Test-GateRow 'EDGE-001 row 21' M plain 'git push origin main 2>&1 | tail'
Test-GateRow 'EDGE-001 row 22' M none 'git push 2>&1'
Test-GateRow 'EDGE-001 row 23' X allow 'git push -u origin feat/x'
Test-GateRow 'EDGE-001 row 24' M allow 'git push origin HEAD:feat/x'
Test-GateRow 'EDGE-001 row 25' M allow 'git push --tags'
Test-GateRow 'EDGE-001 row 26' M allow 'git push origin v1.2.0'
Test-GateRow 'EDGE-001 row 27' M allow 'git push --dry-run origin main'
Test-GateRow 'EDGE-001 row 28' M allow 'git push -n origin main'
Test-GateRow 'EDGE-001 row 29' X allow 'git push origin :main'
Test-GateRow 'EDGE-001 row 30' X allow 'git push --delete origin main'
Test-GateRow 'EDGE-001 row 31' X allow 'git push -d origin main'
Test-GateRow 'EDGE-001 row 32' X plain 'git push --all origin'
Test-GateRow 'EDGE-001 row 33' M plain 'git push --all origin'
Test-GateRow 'EDGE-001 row 34' EQ plain 'git push --all origin'
Test-GateRow 'EDGE-001 row 35' M plain 'git push --mirror origin'
Test-GateRow 'EDGE-001 row 36' SB none 'git -C sub push origin main' 'main vs origin/main'
Test-GateRow 'EDGE-001 row 37' SB none 'cd sub && git push' 'main vs origin/main'
Test-GateRow 'EDGE-001 row 38' SB plain '(cd sub && git push origin main); git status'
Test-GateRow 'EDGE-001 row 39' M plain 'cd "$(git rev-parse --show-toplevel)" && git push'
Test-GateRow 'EDGE-001 row 40' M plain 'git add -A && git commit -m x && git push'
Test-GateRow 'EDGE-001 row 41' X plain 'git add -A && git commit -m x && git push'
Test-GateRow 'EDGE-001 row 42' M plain 'git commit --amend --no-edit && git push --force-with-lease origin main'
Test-GateRow 'EDGE-001 row 43' X plain 'git checkout main && git push'
Test-GateRow 'EDGE-001 row 44' M plain 'git merge feat/x && git push origin main'
Test-GateRow 'EDGE-001 row 45' U2 plain 'git pull && git push'
Test-GateRow 'EDGE-001 row 46' X plain 'git switch - && git push'
Test-GateRow 'EDGE-001 row 47' M plain 'git push origin main && gh pr create --fill'
Test-GateRow 'EDGE-001 row 48' M plain 'git commit -m "docs: gate git push to main"'
$row49 = @('git commit -m "$(cat <<''EOF''', 'git push origin main', 'EOF', ')"') -join "`n"
Test-GateRow 'EDGE-001 row 49' M plain $row49
Test-GateRow 'EDGE-001 row 50' X src 'git push origin "main"'
Test-GateRow 'EDGE-001 row 51' M plain 'echo git push origin main'
Test-GateRow 'EDGE-001 row 52' M plain 'FOO=1 git push'
Test-GateRow 'EDGE-001 row 53' M plain 'AF_CODE_REVIEW_GATE=off git push'
Test-GateRow 'EDGE-001 row 54' M plain 'sudo git push origin main'
Test-GateRow 'EDGE-001 row 55' M plain 'sudo -u deploy git push origin main'
Test-GateRow 'EDGE-001 row 56' M plain 'timeout 30 git push origin main'
Test-GateRow 'EDGE-001 row 57' M plain 'git.exe push origin main'
Test-GateRow 'EDGE-001 row 58' M plain '/usr/bin/git push origin main'
Test-GateRow 'EDGE-001 row 59' M plain '& git push origin main'
Test-GateRow 'EDGE-001 row 60' M plain "sh -c 'git push origin main'"
Test-GateRow 'EDGE-001 row 61' M plain 'bash -c "git fetch && git push origin HEAD:main"'
Test-GateRow 'EDGE-001 row 62' M plain 'eval "git push origin main"'
Test-GateRow 'EDGE-001 row 63' M plain 'git push origin main "unbalanced'
Test-GateRow 'EDGE-001 row 64' M allow 'git commit -m "unbalanced'
Test-GateRow 'EDGE-001 row 65' DT src 'git push origin main'
Test-GateRow 'EDGE-001 row 66' X none 'gh pr create --fill' 'gh pr create denied'
Test-GateRow 'EDGE-001 row 67' X none 'gh pr create --draft --fill'
Test-GateRow 'EDGE-001 row 68' X none 'gh pr create --web'
Test-GateRow 'EDGE-001 row 69' X none 'gh pr create --base develop --fill' 'feat/x vs develop'
Test-GateRow 'EDGE-001 row 70' X plain 'gh pr create -Bdevelop --fill'
Test-GateRow 'EDGE-001 row 71' X none 'gh pr create -b "text" --fill' 'feat/x vs main'
Test-GateRow 'EDGE-001 row 72' X src 'gh pr create --head=other --fill'
Test-GateRow 'EDGE-001 row 73' X src 'gh pr create --head owner:feat/x --fill'
Test-GateRow 'EDGE-001 row 74' X allow 'gh pr create --dry-run'
Test-GateRow 'EDGE-001 row 75' X allow 'gh pr view 12'
Test-GateRow 'EDGE-001 row 76' X allow 'gh pr merge 12'
Test-GateRow 'EDGE-001 row 77' X allow 'gh api repos/o/r/pulls -X POST'
Test-GateRow 'EDGE-001 row 78' X none 'glab mr create --fill' 'glab mr create denied'
Test-GateRow 'EDGE-001 row 79' X none 'glab mr new --fill'
Test-GateRow 'EDGE-001 row 80' X none 'glab mr create --target-branch develop --fill' 'feat/x vs develop'
Test-GateRow 'EDGE-001 row 81' X src 'glab mr create -s other --fill'
Test-GateRow 'EDGE-001 row 82' X allow 'glab mr list'

# rows 83-96: PowerShell dialect (tool_name PowerShell)
$othW = $script:GF.OTH
Test-GateRowPs 'EDGE-001 row 83' M plain 'if ($?) { git push origin main }'
Test-GateRowPs 'EDGE-001 row 84' M plain 'try { git push origin main } catch { Write-Error $_ }'
Test-GateRowPs 'EDGE-001 row 85' M plain '$out = git push origin main 2>&1'
Test-GateRowPs 'EDGE-001 row 86' X plain '$url = gh pr create --fill'
Test-GateRowPs 'EDGE-001 row 87' M plain '$r = @(git push origin main)'
Test-GateRowPs 'EDGE-001 row 88' M plain 'foreach ($b in @("main")) { git push origin $b }'
Test-GateRowPs 'EDGE-001 row 89' M plain '. { git push origin main }'
Test-GateRowPs 'EDGE-001 row 90' M plain 'iex "git push origin main"'
Test-GateRowPs 'EDGE-001 row 91' X none "Set-Location '$othW'; git push origin main" 'main vs origin/main'
Test-GateRowPs 'EDGE-001 row 92' X none "cd $othW; git push origin main" 'main vs origin/main'
Test-GateRowPs 'EDGE-001 row 93' X none "git -C $othW push origin main" 'main vs origin/main'
Test-GateRowPs 'EDGE-001 row 94' M loc 'git -C C:\nope\x push origin main'
Test-GateRowPs 'EDGE-001 row 95' M plain "echo hi`rgit push origin main"
Test-GateRowPs 'EDGE-001 row 96' M none ('git push origin ' + [char]0x201C + 'main' + [char]0x201D)

# rows 97-133: POSIX completeness, refspec forms, redirection, caps
$othFwd = $script:GF.OTH.Replace('\', '/')
Test-GateRow 'EDGE-001 row 97' M plain 'f() { git push origin main; }; f'
Test-GateRow 'EDGE-001 row 98' M plain 'git push -u origin "$(git branch --show-current)"'
Test-GateRow 'EDGE-001 row 99' X plain 'git push -u origin "$(git branch --show-current)"'
Test-GateRow 'EDGE-001 row 100' M plain 'B=main; git push origin "$B"'
Test-GateRow 'EDGE-001 row 101' X plain 'git push origin HEAD:"$B"'
Test-GateRow 'EDGE-001 row 102' M none 'git push origin @'
Test-GateRow 'EDGE-001 row 103' M none 'git push origin HEAD:heads/main'
Test-GateRow 'EDGE-001 row 104' X plain 'git push origin :'
Test-GateRow 'EDGE-001 row 105' M plain "git push origin 'refs/heads/*:refs/heads/*'"
Test-GateRow 'EDGE-001 row 106' M plain 'git push --dry-run --no-dry-run origin main'
Test-GateRow 'EDGE-001 row 107' M plain 'git push -d --no-delete origin main'
Test-GateRow 'EDGE-001 row 108' X none 'gh pr new --fill'
Test-GateRow 'EDGE-001 row 109' X plain 'git push --branches origin'
Test-GateRow 'EDGE-001 row 110' X plain 'git -c push.default=matching push'
Test-GateRow 'EDGE-001 row 111' X plain 'git -c remote.origin.push=HEAD:main push'
Test-GateRow 'EDGE-001 row 112' X plain "GIT_DIR=$othFwd/.git git push"
Test-GateRow 'EDGE-001 row 113' X plain "git --git-dir=$othFwd/.git push origin main"
$script:GateHome = $script:GF.HOME
Test-GateRow 'EDGE-001 row 114' X none 'cd ~/other && git push origin main' 'main vs origin/main'
$script:GateHome = $null
Test-GateRow 'EDGE-001 row 115' M plain "echo `$'\'' ; git push origin main ; echo \'"
Test-GateRow 'EDGE-001 row 116' M plain "echo `$((1<<2))`ngit push origin main"
Test-GateRow 'EDGE-001 row 117' M plain 'echo "$(case a in a) true ;; esac; git push origin main)"'
Test-GateRow 'EDGE-001 row 118' M plain "bash -c `"bash -c 'git push origin main'`""
Test-GateRow 'EDGE-001 row 119' M plain "git `$'push' origin main"
Test-GateRow 'EDGE-001 row 120' M plain 'Git push origin main'
Test-GateRow 'EDGE-001 row 121' M plain 'GIT.exe push origin main'
Test-GateRow 'EDGE-001 row 122' M plain 'time -p git push origin main'
Test-GateRow 'EDGE-001 row 123' M plain 'command -p git push origin main'
Test-GateRow 'EDGE-001 row 124' M plain 'exec -a x git push origin main'
Test-GateRow 'EDGE-001 row 125' M plain 'git update-ref refs/heads/main HEAD~1 && git push --force origin main'
Test-GateRow 'EDGE-001 row 126' M plain 'gh pr checkout 5 && git push origin HEAD:main'
Test-GateRow 'EDGE-001 row 127' BH none 'git push --force origin main'
Test-GateRow 'EDGE-001 row 128' UP none 'git push' 'main vs upstream/main'
Test-GateRow 'EDGE-001 row 129' PL norepo 'gh pr create -R owner/repo --head feat/x --base main --fill' 'gh pr create denied'
Test-GateRow 'EDGE-001 row 130' X plain 'glab mr create --fill "unbalanced'

# 131: about 5 KB of chained decoys (under the 64 KB cap) is a chain: not plain
$r131 = ('false && git push origin x; ' * 150) + 'git push origin main'
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Gate 'r131' $script:GF.M $r131
$sw.Stop(); $t131 = [int]$sw.ElapsedMilliseconds
Assert-GateDeny "EDGE-001 row 131: 150 x 'false && git push origin x; ' then git push origin main: not plain, decided in $t131 ms (limit 15000)" @($script:GatePlain) ($t131 -lt 15000)
$r132 = 'git push origin main "' + ('a' * 102400) + '"'
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Gate 'r132' $script:GF.M $r132
$sw.Stop(); $t132 = [int]$sw.ElapsedMilliseconds
Assert-GateDeny "EDGE-001 row 132: git push origin main then one 100 KB quoted word: size cap, decided in $t132 ms (limit 15000)" @('unresolvable', 'longer than 64 KB') ($t132 -lt 15000)
Test-GateRow 'EDGE-001 row 133' M plain 'if false; then :; elif git push origin main; then :; fi'

# rows 134-175
$plW = $script:GF.PL
$plFwd = $script:GF.PL.Replace('\', '/')
$xFwd = $script:GF.X.Replace('\', '/')
$headX1 = (git -C $script:GF.X rev-parse HEAD).Trim()
$headBh = (git -C $script:GF.BH rev-parse HEAD).Trim()
Test-GateRowPs 'EDGE-001 row 134' M plain 'if(1){git push origin main}'
Test-GateRowPs 'EDGE-001 row 135' M plain 'try{git push origin main}catch{}'
Test-GateRowPs 'EDGE-001 row 136' M plain '1|%{git push origin main }'
Test-GateRowPs 'EDGE-001 row 137' M plain '<# x #> git push origin main'
Test-GateRowPs 'EDGE-001 row 138' M plain ('$x = @"' + "`n" + 'a"' + "`n" + '"@; git push origin main # "')
Test-GateRowPs 'EDGE-001 row 139' X plain "git push origin ('HEAD:main')"
Test-GateRow 'EDGE-001 row 140' M plain 'f(){ git push origin main;}; f'
Test-GateRow 'EDGE-001 row 141' M plain 'f()(git push origin main); f'
Test-GateRow 'EDGE-001 row 142' M plain 'case a in a) git "push" origin main;; esac'
Test-GateRow 'EDGE-001 row 143' X plain 'case a in a) git push origin HEAD:main;; esac'
Test-GateRow 'EDGE-001 row 144' M plain "false && cd $plFwd; git push origin main"
Test-GateRow 'EDGE-001 row 145' M plain "cd $plFwd && cd - && git push origin main"
Test-GateRow 'EDGE-001 row 146' M plain "pushd $plFwd; popd; git push origin main"
Test-GateRow 'EDGE-001 row 147' M loc "cd $plFwd; git push origin main"
Test-GateRow 'EDGE-001 row 148' M plain 'git push origin ma[i]n'
Test-GateRow 'EDGE-001 row 149' M plain 'git push origin mai?'
$gfPc = Join-Path $workRoot 'gate-fx-1-pc'; Copy-Item -Recurse $script:GF.X $gfPc
git -C $gfPc config remote.origin.push HEAD:refs/heads/main
Test-GateRow 'EDGE-001 row 150' $gfPc none 'git push' 'feat/x vs origin/main'
Test-GateRow 'EDGE-001 row 151' X plain "HOME=$plFwd git push origin"

$r152 = ''; $dots = './'
for ($n152 = 1; $n152 -le 31; $n152++) { $r152 += "git -C $xFwd/$dots push; "; $dots += './' }
$r152 += "git -C $othFwd push origin main"
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Gate 'r152' $script:GF.M $r152
$sw.Stop(); $t152 = [int]$sw.ElapsedMilliseconds
Assert-GateDeny "EDGE-001 row 152: 31 x 'git -C <repo>/./ push' (distinct spellings) then git -C <other> push origin main: not plain, decided in $t152 ms (limit 8000)" @($script:GatePlain) ($t152 -lt 8000)

Test-GateRow 'EDGE-001 row 153' M plain 'git $(printf push) origin main'
Test-GateRow 'EDGE-001 row 154' M plain 'X=git; $X push origin main'
Test-GateRow 'EDGE-001 row 155' M plain 'git pu${x}sh origin main'
Set-GateMarker 'r156' 'APPROVED' $headX1 "feat/x vs main ($((git -C $script:GF.X rev-parse main).Trim())..$headX1); fallback: none"
Test-GateRow 'EDGE-001 row 156' X stale 'gh pr create --base main --fill' 'not an ancestor of origin/main'
# origin/feat/x one commit ahead of HEAD
$gfRh = Join-Path $workRoot 'gate-fx-1-rh'; Copy-Item -Recurse $script:GF.X $gfRh
git -C $gfRh checkout -q -b tmp157 2>$null; Add-GateCommit $gfRh 'c4'
git -C $gfRh update-ref refs/remotes/origin/feat/x tmp157
git -C $gfRh checkout -q feat/x 2>$null; git -C $gfRh branch -q -D tmp157
Set-GateRealMarker 'r157' $gfRh 'feat/x vs main' 'refs/remotes/origin/main'
Test-GateRow 'EDGE-001 row 157' $gfRh stale 'gh pr create --fill' 'origin/feat/x'
Set-GateRealMarker 'r158' $script:GF.M 'main vs origin/main' 'refs/remotes/origin/main'
Test-GateRow 'EDGE-001 row 158' M plain 'git fetch --update-head-ok . other:main && git push origin main'
Test-GateRow 'EDGE-001 row 159' X plain ("git -C $othFwd push origin " + '"$(git branch --show-current)"')
Test-GateRow 'EDGE-001 row 160' M plain 'git checkout . && git push'
Test-GateRow 'EDGE-001 row 161' M plain 'git checkout README.md; git push'
Test-GateRow 'EDGE-001 row 162' X plain 'git rebase feat/x main && git push'
Test-GateRow 'EDGE-001 row 163' X plain 'git symbolic-ref HEAD refs/heads/main && git push'
# MSYS drive form /<drive>/...
$u2Fwd = $script:GF.U2.Replace('\', '/')
$u2Msys = if ($u2Fwd -match '^([A-Za-z]):(.*)$') { '/' + $Matches[1].ToLowerInvariant() + $Matches[2] } else { $u2Fwd }
Test-GateRow 'EDGE-001 row 164' M allow "cd $u2Msys && git push"
Test-GateRow 'EDGE-001 row 165' X plain 'echo main | xargs git push origin'
Set-GateMarker 'r166' 'APPROVED' $headBh "main vs origin/main ($headBh..$headBh); fallback: none"
Test-GateRow 'EDGE-001 row 166' BH stale 'git push --force origin main' 'is empty'
$r167Body = (@('a new line of text') * 3700) -join "`n"
Invoke-Gate 'r167' $script:GF.M ("cat > out.txt <<'EOF'`n" + $r167Body + "`nEOF")
Assert-GateAllow "EDGE-001 row 167: cat > out.txt <<'EOF' with a 70 KB body naming no push: oversize, allowed"
Test-GateRowPs 'EDGE-001 row 168' X allow 'git push -u origin feat/x *>&1'
Set-GateRealMarker 'r169' $script:GF.M 'main vs origin/main' 'refs/remotes/origin/main'
Test-GateRow 'EDGE-001 row 169' M plain 'git branch -f main HEAD~1 && git push --force origin main'
Set-GateRealMarker 'r170' $script:GF.M 'main vs origin/main' 'refs/remotes/origin/main'
Test-GateRow 'EDGE-001 row 170' M plain 'glab mr checkout 3 && git push origin HEAD:main'
Test-GateRow 'EDGE-001 row 171' X plain "export GIT_DIR=$othFwd/.git; git push origin main"
Test-GateRowPs 'EDGE-001 row 172' X plain "`$env:GIT_DIR='$othW/.git'; git push origin main"
Test-GateRowPs 'EDGE-001 row 173' M plain "Push-Location '$plW'; Pop-Location; git push origin main"
Test-GateRowPs 'EDGE-001 row 174' X plain "chdir $othW; git push origin main"
Test-GateRowPs 'EDGE-001 row 175' M plain "if (`$false) { Set-Location '$plW' }; git push origin main"
# PowerShell location prefix moves the review target on every host (HOME = the fixture home, whose other/ is on main)
$script:GateHome = $script:GF.HOME
Invoke-Gate 'r175b' $script:GF.X 'cd ~\other; git push origin main' $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.3-bis m row 175b: PowerShell cd ~\other; git push origin main reviews the other repository: main vs origin/main' @('review is recorded', 'main vs origin/main')
$script:GateHome = $null

# rows 176-201
$gfDm = Join-Path $workRoot 'gate-fx-1-dm'; Copy-Item -Recurse $script:GF.X $gfDm   # main, dirty, feat/x differs
git -C $gfDm checkout -q main 2>$null
Add-Content -Path (Join-Path $gfDm 'f.txt') -Value 'dirty'
$gfY = Join-Path $workRoot 'gate-fx-1-y'; Copy-Item -Recurse $script:GF.X $gfY       # feat/y tracking origin/main
git -C $gfY checkout -q -b feat/y 2>$null
git -C $gfY config branch.feat/y.remote origin
git -C $gfY config branch.feat/y.merge refs/heads/main
$gfY2 = Join-Path $workRoot 'gate-fx-1-y2'; Copy-Item -Recurse $gfY $gfY2            # same, push.default unset
git -C $gfY config push.default upstream
$gfYr = Join-Path $workRoot 'gate-fx-1-yr'; Copy-Item -Recurse $script:GF.X $gfYr
git -C $gfYr checkout -q -b feat/y 2>$null
git -C $gfYr config remote.origin.push refs/heads/feat/y:refs/heads/main
$pl2W = Join-Path $workRoot 'gate-fx-1-plain2'; New-Item -ItemType Directory -Force -Path $pl2W | Out-Null
$pl2Fwd = $pl2W.Replace('\', '/')
Test-GateRow 'EDGE-001 row 176' $gfDm plain 'git checkout feat/x; git push'
Test-GateRow 'EDGE-001 row 177' M plain 'git checkout -b feat/x; git push -u origin HEAD'
Test-GateRow 'EDGE-001 row 178' X plain 'git checkout -Bmain && git push origin HEAD'
Test-GateRow 'EDGE-001 row 179' X plain 'git switch --force-create=main && git push origin HEAD'
Test-GateRow 'EDGE-001 row 180' $gfY none 'git push -u origin feat/y' 'feat/y vs origin/main'
Test-GateRow 'EDGE-001 row 181' $gfY2 plain 'git -c push.default=upstream push origin feat/y'
Test-GateRow 'EDGE-001 row 182' $gfYr none 'git push origin feat/y' 'feat/y vs origin/main'
Test-GateRow 'EDGE-001 row 183' M plain "false &&`n cd $plFwd`ngit push origin main"
Test-GateRow 'EDGE-001 row 184' M plain "echo x |`ncd $plFwd; git push origin main"
Test-GateRow 'EDGE-001 row 185' M plain "pushd $plFwd; cd $pl2Fwd; popd; git push origin main"
Test-GateRow 'EDGE-001 row 186' M plain "cd $plFwd; popd; git push origin main"
Test-GateRow 'EDGE-001 row 187' X plain "eval `"cd $othFwd`"; git push origin main"
Test-GateRow 'EDGE-001 row 188' M plain 'coproc git push origin main'
Test-GateRow 'EDGE-001 row 189' M plain "cat <<EOF`n`$(git push origin main)`nEOF"
Test-GateRow 'EDGE-001 row 190' M plain "git p\`nush origin main"
Test-GateRow 'EDGE-001 row 191' M plain 'cmd=push; git $cmd origin main'
Set-GateRealMarker 'r192' $script:GF.M 'main vs origin/main' 'refs/remotes/origin/main'
Test-GateRow 'EDGE-001 row 192' M plain 'git stash list && git push origin HEAD:main'
$savedSeconds = $env:SECONDS
$env:SECONDS = '100'
try { Invoke-Gate 'r193' $script:GF.U2 'git push' }
finally { if ($null -ne $savedSeconds) { $env:SECONDS = $savedSeconds } else { Remove-Item Env:\SECONDS -ErrorAction SilentlyContinue } }
Assert-GateAllow 'EDGE-001 row 193: git push (feat/x with upstream, SECONDS=100 in the hook environment)'
Test-GateRow 'EDGE-001 row 194' X plain "GIT_DIR=$othFwd/.git gh pr create --fill"
Test-GateRowPs 'EDGE-001 row 195' M plain 'git checkout -b feat/x; git push -u origin HEAD'
Test-GateRowPs 'EDGE-001 row 196' M plain "git rev-parse --verify --quiet nope &&`n Set-Location '$plW'`ngit push origin main"
Test-GateRowPs 'EDGE-001 row 197' M plain "Push-Location '$plW'; Set-Location '$pl2W'; Pop-Location; git push origin main"

# 198: old git (< 2.31) rejects --end-of-options; the chain is denied before any git call.
# 199: a git that takes 9 s per call; the plain push runs out of the 8 s budget.
# The wrappers are git.ps1 scripts first on PATH (the hook resolves git through PATH).
$realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$oldGit = Join-Path $workRoot 'oldgit'; $slowGit = Join-Path $workRoot 'slowgit'
New-Item -ItemType Directory -Force -Path $oldGit, $slowGit | Out-Null
Set-Content -Path (Join-Path $oldGit 'git.ps1') -Value @(
    "`$ia = [array]::IndexOf(`$args, 'rev-parse'); `$ie = [array]::IndexOf(`$args, '--end-of-options')"
    "if (`$ia -ge 0 -and `$ie -gt `$ia) { [Console]::Error.WriteLine('usage: git rev-parse [<options>] <args>...'); exit 129 }"
    "& '$realGit' @args; exit `$LASTEXITCODE")
Set-Content -Path (Join-Path $slowGit 'git.ps1') -Value @(
    'Start-Sleep -Seconds 9'
    "& '$realGit' @args; exit `$LASTEXITCODE")
$savedPath = $env:PATH
try {
    $env:PATH = $oldGit + [System.IO.Path]::PathSeparator + $savedPath
    Invoke-Gate 'r198' $script:GF.X 'git checkout main && git push'
    Assert-GateDeny 'EDGE-001 row 198: git checkout main && git push (git wrapper rejecting rev-parse --end-of-options)' @($script:GatePlain)
    $env:PATH = $slowGit + [System.IO.Path]::PathSeparator + $savedPath
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Gate 'r199' $script:GF.M 'git push origin main'
    $sw.Stop(); $t199 = [int]$sw.ElapsedMilliseconds
    Assert-GateDeny "EDGE-001 row 199: git push origin main (git wrapper sleeping 9 s per call): decided in $t199 ms (limit 15000)" @('ran out of time') ($t199 -lt 15000)
} finally { $env:PATH = $savedPath }
Test-GateRow 'EDGE-001 row 200' M plain 'git switch --create feat/z && git push -u origin HEAD'
# Row 201: a PowerShell backtick continuation before CRLF joins into "git push", so the
# text is a candidate; the backtick and the newline make it not plain.
Test-GateRowPs 'EDGE-001 row 201' M plain "git pu```r`nsh origin main"

Write-Host "[PRETOOLUSE-CODE-REVIEW-GATE-REQ004] unlock rule and deny wordings"
$script:GateState = Join-Path $workRoot 'gate-state-2'
Build-GateFixtures (Join-Path $workRoot 'gate-fx-2')
$GF = $script:GF
$headX = (git -C $GF.X rev-parse HEAD).Trim()
$otherSha = '0123456789abcdef0123456789abcdef01234567'

Invoke-Gate 'rq1' $GF.X 'gh pr create --fill'
Assert-GateDeny 'REQ-004 no marker: gh pr create denied with all five parts' @(
    'gh pr create', 'feat/x vs main', 'Agent tool', 'subagent_type: code-review-gatekeeper',
    'agentic-framework:code-review', 'VERDICT: APPROVED', 'AF_CODE_REVIEW_GATE=off', 'review is recorded')
$shape = $null
try { $shape = $script:GateRun.Out | ConvertFrom-Json } catch { }
Assert 'REQ-004 deny JSON shape and key order' ($null -ne $shape -and
    (($shape.PSObject.Properties.Name -join ',') -eq 'hookSpecificOutput') -and
    (($shape.hookSpecificOutput.PSObject.Properties.Name -join ',') -eq 'hookEventName,permissionDecision,permissionDecisionReason') -and
    $shape.hookSpecificOutput.hookEventName -ceq 'PreToolUse')
Assert 'REQ-004 reason has no angle brackets or ampersands' ($script:GateRun.Out -notmatch '[<>&]')
Assert 'REQ-004 output is ASCII' ($script:GateRun.Out -cnotmatch '[^\x20-\x7e]')

Invoke-Gate 'rq1b' $GF.X 'git push origin HEAD:main'
Assert-GateDeny 'REQ-004 no marker: push names target with commit count' @('git push', 'feat/x vs origin/main (2 commits ahead)')

# a PR's reviewed range starts on the destination's remote-tracking ref (I-ter.8)
Set-GateRealMarker 'rq2' $GF.X 'feat/x vs main' 'refs/remotes/origin/main'
Invoke-Gate 'rq2' $GF.X 'gh pr create --fill'
Assert-GateAllow 'REQ-004 APPROVED marker at HEAD, base matches: gh pr create allowed'

Set-GateRealMarker 'rq3' $GF.X "PR #7 $headX vs origin/main" 'refs/remotes/origin/main'
Invoke-Gate 'rq3' $GF.X 'git push origin HEAD:main'
Assert-GateAllow "REQ-004 APPROVED 'PR #7 <sha> vs origin/main' marker: git push origin HEAD:main allowed"

Set-GateRealMarker 'rq4' $GF.X 'feat/x vs main' 'refs/heads/main' 'APPROVED' $otherSha
Invoke-Gate 'rq4' $GF.X 'gh pr create --fill'
Assert-GateDeny 'REQ-004 marker head differs from HEAD: denied as stale' @('stale', $otherSha, $headX)

Set-GateRealMarker 'rq5' $GF.X 'feat/x vs develop' 'refs/heads/main'
Invoke-Gate 'rq5' $GF.X 'gh pr create --fill'
Assert-GateDeny 'REQ-004 marker base differs from destination: denied naming both' @('Base mismatch', 'develop', 'main')

$noCover = 'did not cover the branch against its destination'
Set-GateMarker 'rq6a' 'APPROVED' $headX "uncommitted @ $headX (3 files)"
Invoke-Gate 'rq6a' $GF.X 'gh pr create --fill'
Assert-GateDeny "REQ-004 non-branch target 'uncommitted @': denied" @($noCover)
Set-GateMarker 'rq6b' 'APPROVED' $headX "paths a.sh b.sh @ $headX"
Invoke-Gate 'rq6b' $GF.X 'gh pr create --fill'
Assert-GateDeny "REQ-004 non-branch target 'paths ... @': denied" @($noCover)
Set-GateMarker 'rq6c' 'APPROVED' $headX "paths a.sh b.sh in PR #3 $headX"
Invoke-Gate 'rq6c' $GF.X 'gh pr create --fill'
Assert-GateDeny "REQ-004 non-branch target 'paths ... in PR': denied" @($noCover)
Set-GateMarker 'rq6d' 'APPROVED' $headX '-'
Invoke-Gate 'rq6d' $GF.X 'gh pr create --fill'
Assert-GateDeny 'REQ-004 marker with no target line: denied' @($noCover)

Set-GateRealMarker 'rq7' $GF.X 'feat/x vs main' 'refs/heads/main' 'CHANGES_REQUIRED'
Invoke-Gate 'rq7' $GF.X 'gh pr create --fill'
Assert-GateDeny 'REQ-004 CHANGES_REQUIRED at HEAD: wording asks to resolve findings and re-run' @('CHANGES_REQUIRED', 'Resolve every open finding', 're-run the review')

Invoke-Gate 'rq8' $GF.X 'gh pr create --fill' 'off'
Assert-GateAllow 'REQ-004 AF_CODE_REVIEW_GATE=off allows gh pr create'
Invoke-Gate 'rq8' $GF.M 'git push origin main' ' OFF '
Assert-GateAllow "REQ-004 AF_CODE_REVIEW_GATE=' OFF ' (trimmed, case-insensitive) allows git push origin main"
Invoke-Gate 'rq8' $GF.X 'gh pr create --fill' 'on'
Assert-GateDeny 'REQ-004 AF_CODE_REVIEW_GATE=on does not disable the gate' @('review is recorded')

Invoke-Gate 'rq9' $GF.M 'AF_CODE_REVIEW_GATE=off git push'
Assert-GateDeny 'REQ-004 inline AF_CODE_REVIEW_GATE=off git push on main still denied (not a plain command, decision S)' @($script:GatePlain)

Invoke-GateRaw 'this is not json {'
Assert-GateAllow 'REQ-004 malformed stdin: exit 0, empty output'
Invoke-GateRaw (New-Payload @{ session_id = 'rq10'; cwd = $GF.X; tool_name = 'Bash'; tool_input = @{ description = 'x' } })
Assert-GateAllow 'REQ-004 payload without tool_input.command: exit 0, empty output'

# The multi-segment dangling-token cases (rq11a 'cd sub; git -C<LF>git push', rq11b
# 'echo ...; gh pr create --head') are withdrawn with the segment parser (decision S):
# chains are not plain. The plain dangling option stays.
Set-GateRealMarker 'rq11b' $GF.X 'feat/x vs main' 'refs/remotes/origin/main'
Invoke-Gate 'rq11b' $GF.X 'gh pr create --head'
Assert-GateAllow "REQ-004 dangling 'gh pr create --head' reads an empty source"
Invoke-Gate 'rq11c' $GF.M 'git -C'
Assert-GateAllow "REQ-004 'git -C' alone names no push: not a candidate"
Invoke-Gate 'rq11d' $GF.M 'git -C push'
Assert-GateDeny "REQ-004 'git -C push' (dangling -C value, no push word after it): not plain" @($script:GatePlain)

# S.2 quoted literal tokens: banned characters inside a clean quoted string are data
Invoke-Gate 'rq12a' $GF.X 'gh pr create --title "fix (x)" --fill'
Assert-GateDeny 'REQ-004 quoted title with parentheses is plain: no-marker deny' @('review is recorded')
Invoke-Gate 'rq12b' $GF.X 'git push origin "main"'
Assert-GateDeny 'REQ-004 quoted refspec is plain: source-not-HEAD deny' @('checked-out commit')
Invoke-Gate 'rq12c' $GF.X 'gh pr create --title "x; git push origin main" --fill'
Assert-GateDeny 'REQ-004 quoted title with ; and push text is data: no-marker deny' @('review is recorded')
Invoke-Gate 'rq12d' $GF.X 'gh pr create --title "$T" --fill'
Assert-GateDeny 'REQ-004 quoted title with a variable is not plain' @($script:GatePlain)
Invoke-Gate 'rq12f' $GF.M 'git push origin "refs/heads/*:refs/heads/*"'
Assert-GateDeny 'REQ-004 quoted wildcard refspec is not plain' @($script:GatePlain)
Invoke-Gate 'rq12g' $GF.X 'git push origin "feat/x:main"'
Assert-GateDeny 'REQ-004 quoted literal refspec stays plain: no-marker deny' @('review is recorded')
Invoke-Gate 'rq12e' $GF.X "sh -c 'git push origin main'"
Assert-GateDeny 'REQ-004 sh -c wrapper with quoted push is not plain' @($script:GatePlain)

# W_PLAIN wording verbatim
Invoke-Gate 'rq13' $GF.M 'git add -A && git commit -m x && git push'
Assert-GateDeny 'REQ-004 W_PLAIN sentence verbatim' @('The command text is not a plain push or pull request command. The gate allows a push or a PR/MR creation only as its own command with literal names: git push REMOTE REFSPEC, gh pr create ..., glab mr create ..., optionally after one cd DIR (joined by a double ampersand or a semicolon) or as git -C DIR push. Split chained commands, variables, substitutions, wrappers and scripts into separate plain commands; pass a multi-line PR body with --body-file. If this command is not a push or a PR creation, its text still mentions one: reword it or move the text to a file.')

# --- first review round of decision S (S.1 two spellings, S.3-bis a to l) ---
# S.1: non-candidates pass with no git call
Invoke-Gate 'rqa1' $GF.M 'git stash push -m wip'
Assert-GateAllow "REQ-004 S.1 'git stash push -m wip' is not a candidate"
Invoke-Gate 'rqa2' $GF.M 'git config push.default simple'
Assert-GateAllow "REQ-004 S.1 'git config push.default simple' is not a candidate"
Invoke-Gate 'rqa3' $GF.M 'gh issue create --title x'
Assert-GateAllow "REQ-004 S.1 'gh issue create --title x' is not a candidate"
# S.1: the second spelling (only ${ and } removed) and curly quotes / $' make candidates
$gcases = @'
${GIT:-git} push origin main
git ${CMD:-push} origin main
gh pr ${C:-create} --fill
echo '${'; git push origin HEAD:main; echo '}'
echo ${x:-$(git push origin HEAD:main)}
git pu${x}sh origin main
git pu$''sh origin main
'@
foreach ($gcase in ($gcases -split "`r?`n")) {
    if (-not $gcase) { continue }
    Invoke-Gate 'rqa4' $GF.M $gcase
    Assert-GateDeny "REQ-004 S.1 candidate in a second spelling is not plain: $gcase" @($script:GatePlain)
}
Invoke-Gate 'rqa5' $GF.M ('git p' + [char]0x201C + [char]0x201D + 'ush origin main')
Assert-GateDeny 'REQ-004 S.1 curly quotes inside the word push still make a candidate' @($script:GatePlain)

# S.2 / S.3-bis: session id sanitised before the candidate and size tests
$bigCmd = 'git push origin ' + ('a' * 70000)
Invoke-Gate '' $GF.M $bigCmd
Assert-GateAllow 'REQ-004 S.2 oversize candidate with an empty session id exits 0 silently'
Invoke-Gate '!!!' $GF.M $bigCmd
Assert-GateAllow "REQ-004 S.2 oversize candidate with session id '!!!' exits 0 silently"

# S.3: ~user and a quoted tilde directory are not plain (Bash does not expand a quoted tilde)
Invoke-Gate 'rqa6' $GF.M 'cd ~root && git push origin main'
Assert-GateDeny 'REQ-004 S.3 cd ~user is not plain' @($script:GatePlain)
Invoke-Gate 'rqa7' $GF.M 'cd "~/x" && git push origin main'
Assert-GateDeny 'REQ-004 S.3 Bash quoted cd "~/x" is not plain' @($script:GatePlain)
Invoke-Gate 'rqa7b' $GF.M "git -C '~/x' push origin main"
Assert-GateDeny "REQ-004 S.3 Bash quoted git -C '~/x' is not plain" @($script:GatePlain)

# S.3-bis b: an empty quoted value is one literal token
Invoke-Gate 'rqa8' $GF.X 'gh pr create --title "x" --body ""'
Assert-GateDeny 'REQ-004 S.3-bis empty double-quoted --body is plain: no-marker deny' @('review is recorded')
Invoke-Gate 'rqa8b' $GF.X "gh pr create --title x --body ''"
Assert-GateDeny 'REQ-004 S.3-bis empty single-quoted --body is plain: no-marker deny' @('review is recorded')

# S.3-bis c: PowerShell option values and high bytes
$nbsp = [string][char]0xA0
Invoke-Gate 'rqa9' $GF.X "git push --force-with-lease=a${nbsp}b origin main" $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.3-bis PowerShell NBSP inside --force-with-lease= is not plain' @($script:GatePlain)
Invoke-Gate 'rqa9b' $GF.X ('git push -o "a\ ' + $nbsp + 'b" origin main') $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.3-bis PowerShell NBSP inside an unclean quoted -o value is not plain' @($script:GatePlain)

# S.3-bis d, l: short-option clusters, --dry-run=<value>
Invoke-Gate 'rqa10' $GF.X 'gh pr create -fHother'
Assert-GateDeny 'REQ-004 S.3-bis gh short-option cluster -fHother is not plain' @($script:GatePlain)
Invoke-Gate 'rqa10b' $GF.X 'gh pr create -dB develop'
Assert-GateDeny 'REQ-004 S.3-bis gh short-option cluster -dB is not plain' @($script:GatePlain)
Invoke-Gate 'rqa11' $GF.X 'gh pr create --dry-run --dry-run=false'
Assert-GateDeny 'REQ-004 S.3-bis gh --dry-run then --dry-run=false is not plain' @($script:GatePlain)
Invoke-Gate 'rqa11b' $GF.X 'gh pr create --recover -B --fill'
Assert-GateDeny "REQ-004 S.3-bis l,r --recover consumes '-B' as its value, so -B does not swallow --fill: target feat/x vs main" @('review is recorded', 'feat/x vs main')
# round 3 (S.3-bis v): glab value-taking options that are not the branches
Invoke-Gate 'rqa11c' $GF.X 'glab mr create -H -b --target-branch develop'
Assert-GateDeny "REQ-004 S.3-bis v glab -H consumes '-b' as its value: target feat/x vs develop" @('review is recorded', 'feat/x vs develop')
Invoke-Gate 'rqa11d' $GF.X 'glab mr create -i 12 --fill'
Assert-GateDeny 'REQ-004 S.3-bis v glab -i takes an issue number, not a branch: target feat/x vs main' @('review is recorded', 'feat/x vs main')

# S.3-bis f: map_ref follows query_refspecs (a colon-less remote.<r>.push entry is skipped)
$gfCl = Join-Path $workRoot 'gate-cl'
Copy-Item -Recurse $GF.X $gfCl
git -C $gfCl checkout -q -b feat/y
git -C $gfCl config branch.feat/y.remote origin
git -C $gfCl config branch.feat/y.merge refs/heads/main
git -C $gfCl config push.default upstream
git -C $gfCl config remote.origin.push refs/heads/feat/y
Invoke-Gate 'rqa12' $gfCl 'git push origin feat/y'
Assert-GateDeny 'REQ-004 S.3-bis colon-less remote.origin.push entry is skipped: bare feat/y remaps through upstream to main' @('review is recorded', 'origin/main')

# S.3-bis h: more than one colon in a refspec
Invoke-Gate 'rqa13' $GF.X 'git push origin :/c3:main'
Assert-GateDeny 'REQ-004 S.3-bis refspec with two colons is not plain' @($script:GatePlain)

# S.3-bis i: a UNC directory is decided before any filesystem access
$swUnc = [Diagnostics.Stopwatch]::StartNew()
Invoke-Gate 'rqa14' $GF.X 'cd //192.0.2.7/x; git push origin HEAD:main'
$swUnc.Stop(); $tUnc = [int]$swUnc.ElapsedMilliseconds
Assert-GateDeny "REQ-004 S.3-bis UNC cd //host/x is not plain, decided in $tUnc ms (limit 2000)" @($script:GatePlain) ($tUnc -lt 2000)
Invoke-Gate 'rqa14b' $GF.X 'git -C //192.0.2.7/x push origin HEAD:main'
Assert-GateDeny 'REQ-004 S.3-bis UNC git -C //host/x is not plain' @($script:GatePlain)

# S.3-bis j: repository state of the push fail-open
$gfOr = Join-Path $workRoot 'gate-orph'
Copy-Item -Recurse $GF.X $gfOr
git -C $gfOr checkout -q --orphan orph
Invoke-Gate 'rqa15' $gfOr 'git push origin feat/x:main'
Assert-GateDeny 'REQ-004 S.3-bis unborn HEAD in a repository with refs: source-not-HEAD rule applies' @('checked-out commit')
$gfEmpty = Join-Path $workRoot 'gate-empty'
New-Item -ItemType Directory -Force -Path $gfEmpty | Out-Null
git -C $gfEmpty init -q -b main
Invoke-Gate 'rqa16' $gfEmpty 'git push origin feat/x:main'
Assert-GateAllow 'REQ-004 S.3-bis repository with no refs at all stays fail-open'
$gfBare = Join-Path $workRoot 'gate-bare.git'
git init -q --bare -b main $gfBare
Invoke-Gate 'rqa17' $gfBare 'git push origin HEAD:main'
Assert-GateDeny 'REQ-004 S.3-bis bare repository cwd is gated: W_LOC' @('does not exist or is not a git work tree')
Invoke-Gate 'rqa18' (Join-Path $GF.X '.git') 'git push origin HEAD:main'
Assert-GateDeny 'REQ-004 S.3-bis cwd inside .git is gated: W_LOC' @('does not exist or is not a git work tree')

# S.3-bis k, T.6: the at-cap -q push through FORM and the token stage; the deadline is checked after the token stage
$qCmd = 'git push' + (' -q' * 21300)
$swQ = [Diagnostics.Stopwatch]::StartNew()
Invoke-Gate 'rqa19' $GF.X $qCmd
$swQ.Stop(); $tQ = [int]$swQ.ElapsedMilliseconds
if ($tQ -ge 15000) { Assert "REQ-004 S.3-bis git push + 21300 x -q: took $tQ ms (limit 15000)" $false }
elseif (-not $script:GateRun.Out -and $script:GateRun.Code -eq 0) { Assert "REQ-004 S.3-bis git push + 21300 x -q: decided plain in $tQ ms (under the 8 s budget on this host; limit 15000)" $true }
else { Assert-GateDeny "REQ-004 S.3-bis git push + 21300 x -q: W_TIME in $tQ ms (limit 15000)" @('ran out of time') }

# --- second review round of decision S (S.3-bis i, j, m to u) ---
# item 1: the stash exclusion needs both previous words to be exactly 'git stash'
$gfSd = Join-Path $workRoot 'gate-sd'
New-Item -ItemType Directory -Force -Path $gfSd | Out-Null
Copy-Item -Recurse $GF.X (Join-Path $gfSd 'stash')
Invoke-Gate 'rqb1' $gfSd 'git -C stash push origin main'
Assert-GateDeny "REQ-004 S.1 'git -C stash push origin main' is a candidate (relative stash dir, judged: source-not-HEAD)" @('checked-out commit')
$sdStash = (Join-Path $gfSd 'stash').Replace('\', '/')
Invoke-Gate 'rqb1b' $GF.M "git -C $sdStash push origin main"
Assert-GateDeny "REQ-004 S.1 'git -C <abs>/stash push origin main' is a candidate (judged: source-not-HEAD)" @('checked-out commit')
Invoke-Gate 'rqb1c' $GF.M 'git -c a.b=stash push origin main'
Assert-GateDeny "REQ-004 S.1 'git -c a.b=stash push origin main' is a candidate and not plain" @($script:GatePlain)
Invoke-Gate 'rqb1d' $GF.M 'git stash push -m wip'
Assert-GateAllow "REQ-004 S.1 'git stash push -m wip' stays a non-candidate"
# round 3 (S.1): the stash exemption is anchored to the start of the text
Invoke-Gate 'rqs1' $GF.M 'git -C git/stash push origin main'
Assert-GateDeny "REQ-004 S.1 anchored: 'git -C git/stash push origin main' is a candidate (judged: W_LOC, no such dir)" @('does not exist or is not a git work tree')
Invoke-Gate 'rqs2' $GF.M 'git stash push; git push origin main'
Assert-GateDeny "REQ-004 S.1 anchored: 'git stash push; git push origin main' is not plain" @($script:GatePlain)
Invoke-Gate 'rqs3' $GF.M 'cd x && git stash push'
Assert-GateDeny "REQ-004 S.1 anchored: 'cd x && git stash push' is a candidate and not plain" @($script:GatePlain)
Invoke-Gate 'rqs4' $GF.M 'echo; git stash push'
Assert-GateDeny "REQ-004 S.1 anchored: 'echo; git stash push' is a candidate and not plain" @($script:GatePlain)
Invoke-Gate 'rqs5' $GF.M 'git stash push;'
Assert-GateAllow "REQ-004 S.1 anchored: 'git stash push;' begins with git stash push and is not a candidate"
Invoke-Gate 'rqs6' $GF.M 'git stash push|cat'
Assert-GateAllow "REQ-004 S.1 anchored: 'git stash push|cat' is not a candidate"
Invoke-Gate 'rqs7' $GF.M 'git/stash push'
Assert-GateAllow "REQ-004 S.1 anchored: 'git/stash push' is not a candidate (words are runs bounded by non-alphanumerics)"

# item 2: the candidate test strips U+201A, U+201B and U+201E too
$c201e = [string][char]0x201E; $c201a = [string][char]0x201A; $c201b = [string][char]0x201B
Invoke-Gate 'rqb2' $GF.M "git pu$c201e${c201e}sh origin main" $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.1 PowerShell git pu<U+201E><U+201E>sh is a candidate and not plain (T.7a: a quoted keyword)' @($script:GatePlain)
Invoke-Gate 'rqb2b' $GF.M "git pu$c201a${c201b}sh origin main" $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.1 PowerShell git pu<U+201A><U+201B>sh is a candidate and not plain (T.7a)' @($script:GatePlain)
Invoke-Gate 'rqb2c' $GF.M "git pu$c201e${c201e}sh origin main"
Assert-GateDeny 'REQ-004 S.1 Bash git pu<U+201E><U+201E>sh is a candidate and not plain' @($script:GatePlain)
Invoke-Gate 'rqb2d' $GF.M "git pu$c201a${c201b}sh origin main"
Assert-GateDeny 'REQ-004 S.1 Bash git pu<U+201A><U+201B>sh is a candidate and not plain' @($script:GatePlain)

# decision T: the regex grammar's refinements (T.7), the default-value spellings (T.2)
# and the token-stage ambiguities (T.4)
Invoke-Gate 'rt7a1' $GF.M '"git" push origin main'
Assert-GateDeny 'REQ-004 T.7a: "git" push origin main is not plain (quoted keyword)' @($script:GatePlain)
Invoke-Gate 'rt7a2' $GF.M 'git pu""sh origin main' $null 'PowerShell'
Assert-GateDeny 'REQ-004 T.7a: PowerShell git pu""sh origin main is not plain (quoted keyword)' @($script:GatePlain)
Invoke-Gate 'rt7a3' $GF.M 'git "push" origin main'
Assert-GateDeny 'REQ-004 T.7a: git "push" origin main is not plain' @($script:GatePlain)
Invoke-Gate 'rt7b' $GF.X "gh pr create --title 'it''s'" $null 'PowerShell'
Assert-GateDeny "REQ-004 T.7b: PowerShell 'it''s' (a doubled quote) is not plain" @($script:GatePlain)
Invoke-Gate 'rt7c' $GF.X "gh pr create --title a'x'`"y`"" $null 'PowerShell'
Assert-GateDeny "REQ-004 T.7c: PowerShell a'x'`"y`" (two adjacent quoted strings) is not plain" @($script:GatePlain)
Invoke-Gate 'rt7c2' $GF.X "gh pr create --title a'x'b" $null 'PowerShell'
Assert-GateDeny "REQ-004 T.7c: PowerShell a'x'b (one quoted string inside a bare word) stays plain: judged" @('feat/x vs main', 'review is recorded')
Invoke-Gate 'rt7d' $GF.X "gh pr create --title @'x'" $null 'PowerShell'
Assert-GateDeny "REQ-004 T.7d: PowerShell @'x' is not plain" @($script:GatePlain)
Invoke-Gate 'rt7d2' $GF.X 'gh pr create --title @' $null 'PowerShell'
Assert-GateDeny 'REQ-004 T.7d: PowerShell bare @ stays plain: judged' @('feat/x vs main', 'review is recorded')
Invoke-Gate 'rt7e1' $GF.X 'gh pr create --fill > "out file"'
Assert-GateDeny 'REQ-004 T.7e: a quoted redirection target is not plain' @($script:GatePlain)
Invoke-Gate 'rt7e2' $GF.X "gh pr create --fill > ''"
Assert-GateDeny "REQ-004 T.7e: an empty quoted redirection target is not plain" @($script:GatePlain)
Invoke-Gate 'rt7e3' $GF.X 'gh pr create --fill > out.txt'
Assert-GateDeny 'REQ-004 T.7e: a bare redirection target stays plain: judged' @('feat/x vs main', 'review is recorded')
Invoke-Gate 'rt7f1' $GF.M 'echo git${a-push'
Assert-GateAllow 'REQ-004 T.7f: an unclosed ${ removes the rest of spelling 1: echo git${a-push is not a candidate'
Invoke-Gate 'rt7f2' $GF.M 'echo ${ git push origin main'
Assert-GateDeny 'REQ-004 T.7f: spelling 2 still sees the tail after an unclosed ${: a candidate, not plain' @($script:GatePlain)
Invoke-Gate 'rt7g1' $GF.M "git stash`r`npush -m wip"
Assert-GateAllow 'REQ-004 T.7g: CR and LF are both separators: git stash CRLF push stays exempt'
Invoke-Gate 'rt7g2' $GF.M "echo x`r`ngit push origin main"
Assert-GateDeny 'REQ-004 T.7g: a push after a CRLF is a candidate and not plain' @($script:GatePlain)
Invoke-Gate 'rt2a' $GF.M 'git pu${a:-s}h origin main'
Assert-GateDeny 'REQ-004 T.2: git pu${a:-s}h origin main is a candidate (spelling 3), not plain' @($script:GatePlain)
Invoke-Gate 'rt2b' $GF.M 'git pu${a-s}h origin main'
Assert-GateDeny 'REQ-004 T.2: git pu${a-s}h origin main is a candidate (spelling 3), not plain' @($script:GatePlain)
Invoke-Gate 'rt2c' $GF.M 'g${a:-i}t push origin main'
Assert-GateDeny 'REQ-004 T.2: g${a:-i}t push origin main is a candidate (spelling 3), not plain' @($script:GatePlain)
Invoke-Gate 'rt2d' $GF.M 'git pu${a:-${b}}sh origin main'
Assert-GateDeny 'REQ-004 T.2: git pu${a:-${b}}sh origin main is a candidate (spelling 3), not plain' @($script:GatePlain)
Invoke-Gate 'rt4a' $GF.M 'git push -o -n origin main'
Assert-GateDeny 'REQ-004 T.4: git push -o -n origin main on main is judged (-n is the -o value, not a dry run)' @('main vs origin/main', 'review is recorded')
Invoke-Gate 'rt4b' $GF.X 'gh pr create --title --base develop'
Assert-GateDeny 'REQ-004 T.4: --title --base develop: --title consumes --base, the default base is used' @('feat/x vs main', 'review is recorded')
Invoke-Gate 'rt4c' $GF.X 'gh pr create --base a --base b'
Assert-GateDeny 'REQ-004 T.4: --base a --base b: the last base wins' @('feat/x vs b', 'review is recorded')
Invoke-Gate 'rt4d' $GF.X 'gh pr create --title " --base x" --base dev --head=me --base last'
Assert-GateDeny 'REQ-004 T.4: a quoted " --base x" is the title; head me, base last' @('source me is not HEAD', 'feat/x vs last')
Invoke-Gate 'rt4e' $GF.X 'gh pr create --title "a > b" 2>&1'
Assert-GateDeny 'REQ-004 T.4: gh pr create --title "a > b" 2>&1 is plain (the quoted > is data): judged' @('feat/x vs main', 'review is recorded')
Invoke-Gate 'rt4f' $GF.X 'gh pr create --head'
Assert-GateDeny 'REQ-004 T.4: a trailing --head leaves the source empty: judged at HEAD' @('feat/x vs main', 'review is recorded')
Invoke-Gate 'rt4g' $GF.M 'git push origin main -o'
Assert-GateDeny 'REQ-004 T.4: a trailing -o is an unread option: not plain' @($script:GatePlain)
Invoke-Gate 'rt4h' $GF.M 'git push a b c'
Assert-GateDeny 'REQ-004 T.4: a third positional is not plain' @($script:GatePlain)
Invoke-Gate 'rt4i' $GF.M 'git push origin ""'
Assert-GateDeny 'REQ-004 T.4: an empty positional is not plain' @($script:GatePlain)
Invoke-Gate 'rt4j' $GF.M 'git push -o ci.skip --dry-run origin main'
Assert-GateAllow 'REQ-004 T.4: -o ci.skip --dry-run origin main is a dry run (allowed)'
Invoke-Gate 'rt4k' $GF.M 'git push -o "a b" origin main' $null 'PowerShell'
Assert-GateDeny 'REQ-004 T.4: PowerShell -o value outside the push alphabet is not plain' @($script:GatePlain)
Invoke-Gate 'rt4l' $GF.M 'git push -o "a b" origin main'
Assert-GateDeny 'REQ-004 T.4: Bash -o value is any literal: judged' @('main vs origin/main', 'review is recorded')
Invoke-Gate 'rt4m' $GF.X 'gh pr create --body "" -H feat/x'
Assert-GateDeny 'REQ-004 T.4: --body "" consumes the empty word; -H feat/x is HEAD: judged' @('feat/x vs main', 'review is recorded')
Invoke-Gate 'rt4n' $GF.SB 'cd sub;git push origin main'
Assert-GateDeny 'REQ-004 T.4: cd sub;git push origin main (no blanks around ;) is plain: judged in sub' @('main vs origin/main', 'review is recorded')
Invoke-Gate 'rt4o' $GF.M 'cd "a;b" && git push origin main'
Assert-GateDeny 'REQ-004 T.4: cd "a;b" && ...: the quoted ; is data (no such directory: W_LOC)' @('does not exist or is not a git work tree')
Invoke-Gate 'rt4p' $GF.M "git push origin main`r"
Assert-GateDeny 'REQ-004 T.3: a trailing CR is trailing white space: judged' @('main vs origin/main', 'review is recorded')
Invoke-Gate 'rt4q' $GF.M ('git push origin main' + (' ' * 32768))
Assert-GateDeny 'REQ-004 T.3: a 32 KB trailing blank run is plain: judged' @('main vs origin/main', 'review is recorded')
Invoke-Gate 'rt4r' $GF.X "gh pr create --title caf$([char]0xE9)"
Assert-GateDeny 'REQ-004 T.3: Bash bare high byte is plain: judged' @('feat/x vs main', 'review is recorded')
Invoke-Gate 'rt4s' $GF.X "gh pr create --title caf$([char]0xE9)" $null 'PowerShell'
Assert-GateDeny 'REQ-004 T.3: PowerShell bare high byte is not plain' @($script:GatePlain)
Invoke-Gate 'rt4t' $GF.M ('git push origin main ' + ([string][char]0x2018 * 21846))
Assert-GateDeny 'REQ-004 T.2: 21,846 x U+2018 after a push (65,559 bytes) is over 64 KB by bytes: W_SIZE' @('longer than 64 KB')
Invoke-Gate 'rt4u' $GF.M 'cd ~"/x" && git push origin main'
Assert-GateDeny 'REQ-004 T.5: Bash cd ~"/x" (raw text not ~/...) is not plain (TILDE)' @($script:GatePlain)

# item 3 (S.3-bis s): the candidate test is linear; 300 KB of short words ending in a push
$big2 = ('ab c ' * 75000) + 'git push origin main'
$swBig = [Diagnostics.Stopwatch]::StartNew()
Invoke-Gate 'rqb3' $GF.M $big2
$swBig.Stop(); $tBig = [int]$swBig.ElapsedMilliseconds
Assert-GateDeny "REQ-004 S.3-bis s 300 KB of short words ending in git push: W_SIZE in $tBig ms (limit 5000)" @('longer than 64 KB') ($tBig -lt 5000)
$big2 = $null
$big3 = ('${x}a' * 60000) + ' git push origin main'
$swBig3 = [Diagnostics.Stopwatch]::StartNew()
Invoke-Gate 'rqb3b' $GF.M $big3
$swBig3.Stop(); $tBig3 = [int]$swBig3.ElapsedMilliseconds
Assert-GateDeny "REQ-004 S.3-bis s 300 KB of `${x}a ending in git push: W_SIZE in $tBig3 ms (limit 5000)" @('longer than 64 KB') ($tBig3 -lt 5000)
$big3 = $null

# S.3-bis s, linearity: each timed shape at n and 2n (300 KB and 600 KB); t(2n) < 3 t(n) + 200 ms
function Measure-GateShape([string]$Sid, [string]$Cmd) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Gate $Sid $GF.M $Cmd
    $sw.Stop()
    return [int]$sw.ElapsedMilliseconds
}
# Each shape: text at n and 2n, the needle both must be denied with, and the size label.
$lin = [ordered]@{
    'short words'  = @{ Gen = { param($k) ('ab c ' * (60000 * $k)) + 'git push origin main' }; Needle = 'longer than 64 KB'; Size = '300/600 KB' }
    '${x}a'        = @{ Gen = { param($k) ('${x}a' * (60000 * $k)) + ' git push origin main' }; Needle = 'longer than 64 KB'; Size = '300/600 KB' }
    'long word'    = @{ Gen = { param($k) ('a' * (300000 * $k)) + ' ; git push origin main' }; Needle = 'longer than 64 KB'; Size = '300/600 KB' }
    '-q flags'     = @{ Gen = { param($k) 'git push' + (' -q' * (5325 * $k)) + ' origin main' }; Needle = 'review is recorded'; Size = '5325/10650 x -q' }
    'spaces'       = @{ Gen = { param($k) 'git push' + (' ' * (32700 * $k)) + 'origin main' }; Needle = 'review is recorded'; Size = '32700/65400 spaces' }
    'SOH a'        = @{ Gen = { param($k) ("$([char]1)a" * (150000 * $k)) + ' git push origin main' }; Needle = 'longer than 64 KB'; Size = '300/600 KB' }
    'U+2018'       = @{ Gen = { param($k) ([string][char]0x2018 * (100000 * $k)) + ' git push origin main' }; Needle = 'longer than 64 KB'; Size = '300/600 KB' }
}
$linI = 0
foreach ($ln in $lin.Keys) {
    $linI++
    $sh = $lin[$ln]
    $cmdN = & $sh.Gen 1; $cmd2N = & $sh.Gen 2
    $t1 = Measure-GateShape "rlin${linI}a" $cmdN
    Assert-GateDeny "REQ-004 S.3-bis s $ln at n ($($sh.Size)): decided in $t1 ms (limit 5000)" @($sh.Needle) ($t1 -lt 5000)
    $t2 = Measure-GateShape "rlin${linI}b" $cmd2N
    Assert-GateDeny "REQ-004 S.3-bis s $ln at 2n ($($sh.Size)): decided in $t2 ms (limit 10000)" @($sh.Needle) ($t2 -lt 10000)
    Assert "REQ-004 S.3-bis s $ln is linear: t(2n) $t2 ms < 3 x t(n) $t1 ms + 200" ($t2 -lt 3 * $t1 + 200)
}
$cmdN = $null; $cmd2N = $null

# item 4 (S.3-bis i): mixed-separator UNC directories are decided before any filesystem access
$swUnc = [Diagnostics.Stopwatch]::StartNew()
Invoke-Gate 'rqb4' $GF.X "cd '\/192.0.2.7/x'; git push origin HEAD:main"
Assert-GateDeny "REQ-004 S.3-bis i Bash cd '\/host/x' is not plain" @($script:GatePlain)
Invoke-Gate 'rqb4b' $GF.X "cd '/\192.0.2.7\x'; git push origin HEAD:main"
Assert-GateDeny "REQ-004 S.3-bis i Bash cd '/\host\x' is not plain" @($script:GatePlain)
Invoke-Gate 'rqb4c' $GF.X 'git -C \/192.0.2.7/x push origin HEAD:main' $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.3-bis i PowerShell git -C \/host/x is not plain' @($script:GatePlain)
Invoke-Gate 'rqb4d' $GF.X 'Set-Location /\192.0.2.7\x; git push origin HEAD:main' $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.3-bis i PowerShell Set-Location /\host\x is not plain' @($script:GatePlain)
$swUnc.Stop(); $tUnc2 = [int]$swUnc.ElapsedMilliseconds
Assert "REQ-004 S.3-bis i four mixed-separator UNC rows decided in $tUnc2 ms (limit 8000)" ($tUnc2 -lt 8000)

# item 5 (S.3-bis m): a leading slash is Bash-dialect only; ~\ is accepted like ~/
Invoke-Gate 'rqb5' $GF.M 'cd / && git push origin HEAD:main'
Assert-GateDeny 'REQ-004 S.3-bis m Bash cd / is plain and judged: W_LOC' @('does not exist or is not a git work tree')
Invoke-Gate 'rqb5b' $GF.M 'cd /; git push origin HEAD:main' $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.3-bis m PowerShell cd / is not plain' @($script:GatePlain)
$script:GateHome = $script:GF.HOME
Invoke-Gate 'rqb5c' $GF.M 'cd ~\other; git push origin HEAD:main' $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.3-bis m PowerShell cd ~\other is accepted like ~/other: judged' @('review is recorded')
$script:GateHome = $null

# item 6 (S.3-bis n): a quote before the first unquoted slash stops the tilde expansion
foreach ($tcase in @('cd ~"/x" && git push origin main', 'cd ""~/x && git push origin main', 'cd ~""/x && git push origin main')) {
    Invoke-Gate 'rqb6' $GF.M $tcase
    Assert-GateDeny "REQ-004 S.3-bis n Bash quoted tilde is not plain: $tcase" @($script:GatePlain)
}
$script:GateHome = $script:GF.HOME
Invoke-Gate 'rqb6b' $GF.M 'cd ~/"other" && git push origin HEAD:main'
Assert-GateDeny 'REQ-004 S.3-bis n Bash quote after the first slash keeps the tilde: judged' @('review is recorded')
$script:GateHome = $null

# item 7 (S.3-bis t): a PowerShell word that begins with a quoted string may not continue
Invoke-Gate 'rqb7' $GF.X 'git push origin "feat"main' $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.3-bis t PowerShell "feat"main is not plain' @($script:GatePlain)
Invoke-Gate 'rqb7b' $GF.X "git push origin 'x'main" $null 'PowerShell'
Assert-GateDeny "REQ-004 S.3-bis t PowerShell 'x'main is not plain" @($script:GatePlain)
Invoke-Gate 'rqb7c' $GF.X 'git push origin "feat/x"' $null 'PowerShell'
Assert-GateAllow 'REQ-004 S.3-bis t PowerShell a whole quoted word stays plain (feat/x is not gated)'

# push_val (S.3-bis c, r): the push alphabet for option values in the PowerShell dialect
Invoke-Gate 'rqb8' $GF.X 'git push -o "a b" origin feat/x' $null 'PowerShell'
Assert-GateDeny 'REQ-004 S.3-bis r PowerShell -o "a b" is not plain (push_val)' @($script:GatePlain)
Invoke-Gate 'rqb8b' $GF.X "git push '--force-with-lease=a b' origin feat/x" $null 'PowerShell'
Assert-GateDeny "REQ-004 S.3-bis r PowerShell '--force-with-lease=a b' is not plain (push_val)" @($script:GatePlain)
Invoke-Gate 'rqb8c' $GF.X 'git push -o ab origin feat/x' $null 'PowerShell'
Assert-GateAllow 'REQ-004 S.3-bis r PowerShell -o ab (inside the alphabet) stays plain: not gated'
Invoke-Gate 'rqb8d' $GF.X 'git push -o "a b" origin feat/x'
Assert-GateAllow 'REQ-004 S.3-bis r Bash -o "a b" is plain: not gated (push_val is PowerShell-only)'

# item 8 (S.3-bis o, r): W_REFMAP
$gfRm = Join-Path $workRoot 'gate-rm'
Copy-Item -Recurse $GF.X $gfRm
git -C $gfRm config remote.origin.push 'refs/heads/feat/x:refs/heads/main'
git -C $gfRm config --add remote.origin.push '^refs/heads/zzz'
Invoke-Gate 'rqb9' $gfRm 'git push origin feat/x'
Assert-GateDeny 'REQ-004 S.3-bis o a ^ entry after a matching positive entry denies W_REFMAP' @('does not name a single destination branch')
git -C $gfRm config --unset-all remote.origin.push
git -C $gfRm config remote.origin.push '^refs/heads/zzz'
Invoke-Gate 'rqb9b' $gfRm 'git push origin feat/x'
Assert-GateDeny 'REQ-004 S.3-bis o a lone non-matching ^ entry denies W_REFMAP' @('does not name a single destination branch')
git -C $gfRm config --unset-all remote.origin.push
git -C $gfRm config remote.origin.push 'refs/heads/*:refs/heads/main'
Invoke-Gate 'rqb9c' $gfRm 'git push origin feat/x'
Assert-GateDeny 'REQ-004 S.3-bis r a pattern entry with an unresolvable destination denies W_REFMAP' @('does not name a single destination branch')
git -C $gfRm config --unset-all remote.origin.push
git -C $gfRm config remote.origin.push 'refs/heads/feat/x:refs/heads/main'
Invoke-Gate 'rqb9d' $gfRm 'git push origin feat/x'
Assert-GateDeny 'REQ-004 S.3-bis o a plain mapping entry still resolves (to main): no-marker deny' @('review is recorded', 'origin/main')

# item 9 (S.3-bis j, u): an unborn HEAD in a repository with other refs
Invoke-Gate 'rqb10' $gfOr 'git push origin HEAD:main'
Assert-GateDeny 'REQ-004 S.3-bis j,x unborn HEAD: HEAD:main gets the source-not-HEAD wording with the no-commit clause' @('checked-out commit', 'is not HEAD (this branch has no commit yet). Check the source out first, then review and push.')
Invoke-Gate 'rqb10b' $gfOr 'gh pr create --head feat --fill'
Assert-GateDeny 'REQ-004 S.3-bis u unborn HEAD: gh pr create --head feat denies with the source-not-HEAD wording' @('checked-out commit', 'feat')
Invoke-Gate 'rqb10c' $gfOr 'gh pr create --fill'
Assert-GateDeny 'REQ-004 S.3-bis u unborn HEAD: gh pr create --fill denies with the source-not-HEAD wording' @('checked-out commit')
Invoke-Gate 'rqb10d' $gfEmpty 'git push origin HEAD:main'
Assert-GateAllow 'REQ-004 S.3-bis j repository with no refs at all: HEAD:main stays fail-open'
Invoke-Gate 'rqb10e' $gfEmpty 'gh pr create --fill'
Assert-GateDeny 'REQ-004 S.3-bis u repository with no refs at all: gh pr create denies W_NOREPO' @('not a git work tree', 'HEAD vs its destination')
# round 3 (S.3-bis w): drive-relative and root-relative directories are not plain
Invoke-Gate 'rqw1' $GF.M 'cd C:; git push origin main' $null 'PowerShell'
Assert-GateDeny "REQ-004 S.3-bis w [PowerShell] 'cd C:; git push origin main' is not plain" @($script:GatePlain)
Invoke-Gate 'rqw3' $GF.M 'git -C \repo push origin main' $null 'PowerShell'
Assert-GateDeny "REQ-004 S.3-bis w [PowerShell] 'git -C \repo push origin main' is not plain" @($script:GatePlain)
Invoke-Gate 'rqw4' $GF.M 'cd D:; git push origin main' $null 'PowerShell'
Assert-GateDeny "REQ-004 S.3-bis w [PowerShell] 'cd D:; git push origin main' is not plain" @($script:GatePlain)
Invoke-Gate 'rqw2' $GF.M 'cd C:repo && git push origin main'
Assert-GateDeny "REQ-004 S.3-bis w 'cd C:repo && git push origin main' is not plain" @($script:GatePlain)
$gmM = $GF.M.Replace('\', '/')
Invoke-Gate 'rqw5' $GF.M "cd $gmM && git push origin HEAD:main"
Assert-GateDeny "REQ-004 S.3-bis w positive control: 'cd <C:/repo> && git push origin HEAD:main' reaches the no-marker deny" @('review is recorded')

# --- gate-round amendments of decision T (T.11 a-d) ---
$bt = [string][char]96
# T.11(a): every S.1 spelling is also tested with each continuation pair read as a space
Invoke-Gate 'rt11a1' $GF.M "x${bt}`r`ngit push origin main" $null 'PowerShell'
Assert-GateDeny 'REQ-004 T.11a: PowerShell x + backtick + CRLF + git push origin main is a candidate and not plain' @($script:GatePlain)
Invoke-Gate 'rt11a2' $GF.M "x${bt}`ngit push origin main${bt}"
Assert-GateDeny 'REQ-004 T.11a: Bash x + backtick + LF + git push origin main + backtick is a candidate and not plain' @($script:GatePlain)
Invoke-Gate 'rt11a3' $GF.M "x${bt}`r`r`ngit push origin main" $null 'PowerShell'
Assert-GateDeny 'REQ-004 T.11a: PowerShell x + backtick + CR CR LF + git push origin main is not plain' @($script:GatePlain)
Invoke-Gate 'rt11a4' $GF.M "git pu${bt}`r`nsh origin main" $null 'PowerShell'
Assert-GateDeny 'REQ-004 T.11a: PowerShell git pu + backtick + CRLF + sh origin main (continuation inside a word) is not plain' @($script:GatePlain)
Invoke-Gate 'rt11a5' $GF.M "git pu${bt}`nsh origin main"
Assert-GateDeny 'REQ-004 T.11a: Bash git pu + backtick + LF + sh origin main (continuation inside a word) is not plain' @($script:GatePlain)

# T.11(b): an expansion that is empty at run time inside a keyword
$t11b = @(
    'git pu$()sh origin main'
    'git pu$(:)sh origin main'
    "git pu${bt}:${bt}sh origin main"
    'git pu$1sh origin main'
    'git pu$@sh origin main'
    'git pu$!sh origin main'
    'gi$*t push origin main'
    'git pu$x"sh" origin main'
    'git pu$($null)sh origin main'
)
foreach ($c11b in $t11b) {
    foreach ($tl in @('Bash', 'PowerShell')) {
        Invoke-Gate 'rt11b' $GF.M $c11b $null $tl
        Assert-GateDeny "REQ-004 T.11b: empty expansion in a keyword is a candidate and not plain [$tl]: $c11b" @($script:GatePlain)
    }
}

# T.11(c): the PowerShell stop-parsing token
$c11c = "gh pr create --% -B dev -t x'q --base main -b '"
Invoke-Gate 'rt11c1' $GF.X $c11c $null 'PowerShell'
Assert-GateDeny 'REQ-004 T.11c: PowerShell gh pr create with --% is not plain' @($script:GatePlain)
Invoke-Gate 'rt11c2' $GF.X "git push --% origin main" $null 'PowerShell'
Assert-GateDeny 'REQ-004 T.11c: PowerShell git push with --% is not plain' @($script:GatePlain)
Invoke-Gate 'rt11c3' $GF.X $c11c
Assert-GateDeny 'REQ-004 T.11c: Bash gh pr create --% is a literal word and stays plain (no-marker deny, base dev)' @('review is recorded', 'vs dev')
Invoke-Gate 'rt11c4' $GF.X "gh pr create '--%' -t 'x --base main'" $null 'PowerShell'
Assert-GateDeny "REQ-004 T.11c: PowerShell quoted stop-parsing token '--%' is not plain" @($script:GatePlain)
Invoke-Gate 'rt11c5' $GF.X 'gh pr create "--%" -B dev -t ''x --base main''' $null 'PowerShell'
Assert-GateDeny 'REQ-004 T.11c: PowerShell quoted stop-parsing token "--%" is not plain' @($script:GatePlain)

# T.11(d): a lone surrogate escape is decided on a copy with U+FFFD, never a fail-open
$m11 = $GF.M.Replace('\', '/')
$sur = [string][char]92 + 'ud800'
$pre11 = '{"session_id":"rt11d","cwd":"' + $m11 + '","tool_name":"Bash","tool_input":{'
Invoke-GateRaw ($pre11 + '"command":"git push origin main #' + $sur + '"}}')
Assert-GateDeny 'REQ-004 T.11d: lone surrogate escape in the command is decided and not plain' @($script:GatePlain)
Invoke-GateRaw ($pre11 + '"command":"git push origin main #' + [string][char]92 + 'uDbFf"}}')
Assert-GateDeny 'REQ-004 T.11d: lone mixed-case high surrogate escape is decided and not plain' @($script:GatePlain)
Invoke-GateRaw ($pre11 + '"description":"' + $sur + '","command":"git push origin main"}}')
Assert-GateDeny 'REQ-004 T.11d: lone surrogate in tool_input.description still decides the command' @('review is recorded')
Invoke-GateRaw ('{"session_id":"rt11d","x":"' + $sur + '","cwd":"' + $m11 + '","tool_name":"Bash","tool_input":{"command":"git push origin main"}}')
Assert-GateDeny 'REQ-004 T.11d: lone surrogate in an unrelated top-level field still decides the command' @('review is recorded')
Invoke-GateRaw ($pre11 + '"command":"git push origin main #' + $sur + '"}')
Assert-GateAllow 'REQ-004 T.11d: a payload with a lone surrogate that is malformed for another reason still exits 0 silently'
Invoke-GateRaw ($pre11 + '"command":"git push origin main #' + [string][char]92 + 'ud83d' + [string][char]92 + 'ude00"}}')
Assert-GateDeny 'REQ-004 T.11d: a valid surrogate pair parses normally and decides' @($script:GatePlain)

# T.11(e): two CRs before the LF form no continuation pair, so the text is not a candidate
Invoke-Gate 'rt11e1' $GF.X ("git pu``" + "`r`r`n" + "sh origin HEAD:main") $null 'PowerShell'
Assert-GateAllow 'REQ-004 T.11e: PowerShell git pu, backtick, CR CR LF, sh origin HEAD:main exits 0 with no output'
Invoke-Gate 'rt11e2' $GF.X ("git pu\" + "`r`r`n" + "sh origin HEAD:main") $null 'Bash'
Assert-GateAllow 'REQ-004 T.11e: Bash git pu, backslash, CR CR LF, sh origin HEAD:main exits 0 with no output'

Write-Host "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE002] marker from an earlier HEAD"
$script:GateState = Join-Path $workRoot 'gate-state-3'
$e2 = Join-Path $workRoot 'gate-e2'
Build-GateRepo $e2 'main'
git -C $e2 checkout -q feat/x
$oldHead = (git -C $e2 rev-parse HEAD).Trim()
Set-GateRealMarker 'e2' $e2 'feat/x vs main' 'refs/remotes/origin/main'
Invoke-Gate 'e2' $e2 'gh pr create --fill'
Assert-GateAllow 'EDGE-002 control: marker at HEAD allows'
Add-GateCommit $e2 'c-after-review'
$newHead = (git -C $e2 rev-parse HEAD).Trim()
Invoke-Gate 'e2' $e2 'gh pr create --fill'
Assert-GateDeny 'EDGE-002 commit after the review: denied, reason says stale and names both shas' @('stale', $oldHead, $newHead)
Invoke-Gate 'e2' $e2 'git push origin HEAD:main'
Assert-GateDeny 'EDGE-002 same marker, push to main: denied as stale' @('stale', $oldHead, $newHead)
# head= equals HEAD, but the reviewed range ends at the earlier commit
Set-GateMarker 'e2r1' 'APPROVED' $newHead "feat/x vs main ($oldHead..$oldHead); fallback: none"
Invoke-Gate 'e2r1' $e2 'gh pr create --fill'
Assert-GateDeny 'EDGE-002 head= is HEAD but the range ends at an earlier sha: denied as stale' @('stale', $oldHead, $newHead)
# a PR #<n> target whose head sha is not HEAD
Set-GateMarker 'e2r2' 'APPROVED' $newHead "PR #9 $oldHead vs main ($oldHead..$oldHead); fallback: none"
Invoke-Gate 'e2r2' $e2 'gh pr create --fill'
Assert-GateDeny "EDGE-002 'PR #9 <sha>' target whose head sha is not HEAD: denied as stale" @('stale', $oldHead)
# an empty range (x..x) while commits are ahead of the destination
Set-GateMarker 'e2r3' 'APPROVED' $newHead "feat/x vs main ($newHead..$newHead); fallback: none"
Invoke-Gate 'e2r3' $e2 'gh pr create --fill'
Assert-GateDeny 'EDGE-002 empty range x..x while commits are ahead: denied as stale' @('stale', 'is empty')

Write-Host "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE003] marker from a non-branch review or another base"
$script:GateState = Join-Path $workRoot 'gate-state-4'
$e3 = Join-Path $workRoot 'gate-e3'
Build-GateRepo $e3 'main'
git -C $e3 checkout -q feat/x
git -C $e3 update-ref refs/remotes/origin/master (git -C $e3 rev-parse 'main~1')
$h = (git -C $e3 rev-parse HEAD).Trim()
Set-GateMarker 'e3a' 'APPROVED' $h "uncommitted @ $h (2 files)"
Invoke-Gate 'e3a' $e3 'git push origin HEAD:main'
Assert-GateDeny "EDGE-003 'uncommitted @ <sha>' target: denied, branch not covered" @($noCover)
Set-GateMarker 'e3b' 'APPROVED' $h "paths src/a.sh src/b.sh @ $h"
Invoke-Gate 'e3b' $e3 'git push origin HEAD:main'
Assert-GateDeny "EDGE-003 'paths <list> @ <sha>' target: denied, branch not covered" @($noCover)
Set-GateMarker 'e3c' 'APPROVED' $h "paths src/a.sh in PR #4 $h"
Invoke-Gate 'e3c' $e3 'git push origin HEAD:main'
Assert-GateDeny "EDGE-003 'paths <list> in PR #<n> <sha>' target: denied, branch not covered" @($noCover)
Set-GateMarker 'e3d' 'APPROVED' $h '-'
Invoke-Gate 'e3d' $e3 'git push origin HEAD:main'
Assert-GateDeny 'EDGE-003 no target line: denied, branch not covered' @($noCover)

Set-GateRealMarker 'e3e' $e3 'feat/x vs origin/main' 'refs/remotes/origin/main'
Invoke-Gate 'e3e' $e3 'git push origin HEAD:master'
Assert-GateDeny "EDGE-003 'feat/x vs origin/main' marker does not unlock push to master: names both" @('Base mismatch', 'origin/main', 'master')
Invoke-Gate 'e3e' $e3 'gh pr create --base develop'
Assert-GateDeny "EDGE-003 'feat/x vs origin/main' marker does not unlock gh pr create --base develop: names both" @('Base mismatch', 'origin/main', 'develop')
Invoke-Gate 'e3e' $e3 'git push origin HEAD:main'
Assert-GateAllow "EDGE-003 control: 'feat/x vs origin/main' marker unlocks push to main (remote prefix removed)"

git -C $e3 branch release/1.0 'main~1'
# the PR's base must have a remote-tracking ref to start from (I-ter.8)
git -C $e3 update-ref refs/remotes/origin/release/1.0 (git -C $e3 rev-parse 'main~1')
Set-GateRealMarker 'e3f' $e3 'feat/x vs release/1.0' 'refs/remotes/origin/release/1.0'
Invoke-Gate 'e3f' $e3 'gh pr create --base release/1.0'
Assert-GateAllow "EDGE-003 'feat/x vs release/1.0' marker unlocks gh pr create --base release/1.0"

Write-Host "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE004] source is not the checked-out commit"
$script:GateState = Join-Path $workRoot 'gate-state-5'
Build-GateFixtures (Join-Path $workRoot 'gate-fx-5')
$GF = $script:GF
$srcMsg = 'checked-out commit'
Invoke-Gate 'e4a' $GF.X 'git push origin feat/y:main'
Assert-GateDeny 'EDGE-004 git push origin feat/y:main on feat/x: source not checked out' @($srcMsg, 'Check the source out first')
Invoke-Gate 'e4b' $GF.X 'git push origin main'
Assert-GateDeny 'EDGE-004 git push origin main on feat/x (different sha): source not checked out' @($srcMsg)
Invoke-Gate 'e4b2' $GF.XS 'git push origin main'
Assert-GateDeny "EDGE-004 git push origin main on feat/x at main's sha: source not checked out" @($srcMsg)
Invoke-Gate 'e4c' $GF.X 'gh pr create --head other --fill'
Assert-GateDeny 'EDGE-004 gh pr create --head other: source not checked out' @($srcMsg)
Set-GateRealMarker 'e4d' $GF.X 'feat/x vs origin/main' 'refs/remotes/origin/main'
Invoke-Gate 'e4d' $GF.X 'git push origin feat/x:main'
Assert-GateAllow 'EDGE-004 clean feat/x:main with an APPROVED matching marker: allowed (source is HEAD)'
Invoke-Gate 'e4e' $GF.DY 'git push origin feat/x:main'
Assert-GateDeny 'EDGE-004 dirty feat/x:main, no marker: the no-marker denial (dirty tree irrelevant)' @('review is recorded')

Write-Host "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE005] nothing to push"
$script:GateState = Join-Path $workRoot 'gate-state-6'
$e5 = Join-Path $workRoot 'gate-e5'
Build-GateRepo $e5 'main'
git -C $e5 update-ref refs/remotes/origin/main (git -C $e5 rev-parse HEAD)
Invoke-Gate 'e5a' $e5 'git push origin main'
Assert-GateAllow 'EDGE-005 origin/main equals HEAD: git push origin main passes'
Invoke-Gate 'e5b' $e5 'git push'
Assert-GateAllow 'EDGE-005 origin/main equals HEAD: bare git push passes'
Invoke-Gate 'e5c' $e5 'git push origin HEAD:main'
Assert-GateAllow 'EDGE-005 origin/main equals HEAD: git push origin HEAD:main passes'
Add-GateCommit $e5 'c3'
Invoke-Gate 'e5d' $e5 'git push origin main'
Assert-GateDeny 'EDGE-005 control: one commit ahead is gated again' @('review is recorded')
# HEAD one commit behind origin/main: a force-push that rewinds the destination is gated
$e5b = Join-Path $workRoot 'gate-e5b'
Build-GateRepo $e5b 'main'
git -C $e5b checkout -q feat/x
Add-GateCommit $e5b 'c3'
git -C $e5b checkout -q main
git -C $e5b update-ref refs/remotes/origin/main (git -C $e5b rev-parse feat/x)
Invoke-Gate 'e5f' $e5b 'git push --force origin main'
Assert-GateDeny 'EDGE-005 HEAD one commit behind origin/main, --force: gated like one ahead' @('review is recorded')
# an equal-sha range (HEAD..HEAD) unlocks nothing while HEAD is behind the remote tip (I-ter.8)
$hB = (git -C $e5b rev-parse HEAD).Trim()
Set-GateMarker 'e5g' 'APPROVED' $hB "main vs origin/main ($hB..$hB); fallback: none"
Invoke-Gate 'e5g' $e5b 'git push --force origin main'
Assert-GateDeny 'EDGE-005 HEAD behind origin/main with an APPROVED (HEAD..HEAD) marker, --force: denied, empty range' @('stale', 'is empty')

Write-Host "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE006] remote-tracking ref unknown or remote unconfigured"
$script:GateState = Join-Path $workRoot 'gate-state-7'
$e6 = Join-Path $workRoot 'gate-e6'
Initialize-GateRepoBare $e6 'main'
Add-GateCommit $e6 'c1'
git -C $e6 remote add origin "$e6.nowhere"
Invoke-Gate 'e6a' $e6 'git push origin main'
Assert-GateDeny 'EDGE-006 no origin/main: denied naming git fetch origin main and the env var' @('git fetch origin main', 'AF_CODE_REVIEW_GATE=off', 'does not yet exist')
Invoke-Gate 'e6b' $e6 'git push https://host/r.git main'
Assert-GateDeny 'EDGE-006 URL remote: denied, asks for a configured remote' @('configured remote')
Assert 'EDGE-006 unconfigured remote gives no fetch hint' (-not $script:GateRun.Out.Contains('git fetch'))
Invoke-Gate 'e6c' $e6 'git push typo main'
Assert-GateDeny 'EDGE-006 typo remote name: denied, asks for a configured remote' @('configured remote')

Write-Host "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE007] fail-open on anything the gate cannot read"
$script:GateState = Join-Path $workRoot 'gate-state-8'
$e7 = Join-Path $workRoot 'gate-e7'
Build-GateRepo $e7 'main'
$e7plain = Join-Path $workRoot 'gate-e7-plain'
$e7empty = Join-Path $workRoot 'gate-e7-empty'
New-Item -ItemType Directory -Force -Path $e7plain, $e7empty | Out-Null
git -C $e7empty init -q -b main
$cmd7 = 'git push origin main'
Invoke-GateRaw 'not json at all'
Assert-GateAllow 'EDGE-007 malformed JSON: exit 0, no output'
Invoke-GateRaw (New-Payload @{ session_id = 'e7'; cwd = $e7; tool_input = $cmd7 })
Assert-GateAllow 'EDGE-007 tool_input is a string, not an object'
Invoke-GateRaw (New-Payload @{ session_id = 'e7'; cwd = $e7; tool_input = @(1, 2) })
Assert-GateAllow 'EDGE-007 tool_input is an array'
Invoke-GateRaw (New-Payload @{ session_id = 'e7'; cwd = $e7; tool_input = @{} })
Assert-GateAllow 'EDGE-007 missing tool_input.command'
Invoke-GateRaw (New-Payload @{ session_id = 'e7'; cwd = $e7; tool_input = @{ command = 42 } })
Assert-GateAllow 'EDGE-007 non-string command (number)'
Invoke-GateRaw (New-Payload @{ session_id = 'e7'; cwd = $e7; tool_input = @{ command = @('git', 'push') } })
Assert-GateAllow 'EDGE-007 non-string command (array)'
Invoke-Gate 'e7' $e7 $cmd7
Assert-GateDeny 'EDGE-007 control: same repo and command with a session id is denied' @('review is recorded')
Invoke-Gate '' $e7 $cmd7
Assert-GateAllow 'EDGE-007 empty session_id'
Invoke-Gate '../..' $e7 $cmd7
Assert-GateAllow 'EDGE-007 session_id empty after sanitising'
Invoke-GateRaw (New-Payload @{ cwd = $e7; tool_input = @{ command = $cmd7 } })
Assert-GateAllow 'EDGE-007 missing session_id'
Invoke-Gate 'e7' $e7plain $cmd7
Assert-GateAllow 'EDGE-007 cwd is not a git work tree'
Invoke-Gate 'e7' $e7empty $cmd7
Assert-GateAllow 'EDGE-007 repository with no commits (unborn HEAD)'
Invoke-GateRaw ''
Assert-GateAllow 'EDGE-007 empty stdin'

Write-Host "[PRETOOLUSE-CODE-REVIEW-GATE-EDGE008] sub-agent runs the push (agent_id in the payload)"
$script:GateState = Join-Path $workRoot 'gate-state-9'
$e8 = Join-Path $workRoot 'gate-e8'
Build-GateRepo $e8 'main'
git -C $e8 checkout -q feat/x
function New-AgentPayload([string]$Sid, [string]$Cmd) {
    New-Payload @{ session_id = $Sid; cwd = $e8; agent_id = 'a1b2c3'; agent_type = 'bash-expert'; tool_name = 'Bash'; tool_input = @{ command = $Cmd } }
}
Invoke-GateRaw (New-AgentPayload 'e8' 'git push origin HEAD:main')
Assert-GateDeny 'EDGE-008 agent_id payload, no marker for the parent session: denied' @('review is recorded')
Set-GateRealMarker 'e8' $e8 'feat/x vs origin/main' 'refs/remotes/origin/main'
Invoke-GateRaw (New-AgentPayload 'e8' 'git push origin HEAD:main')
Assert-GateAllow 'EDGE-008 agent_id payload, matching APPROVED marker of the parent session: allowed'
Invoke-GateRaw (New-AgentPayload 'e8-other' 'gh pr create --fill')
Assert-GateDeny 'EDGE-008 agent_id payload, another session id has no marker: denied' @('review is recorded')

$script:GateState = $stateDir

# ── Teardown ───────────────────────────────────────────────────────────────────
Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
Remove-Item Env:\CLAUDE_STATE_DIR -ErrorAction SilentlyContinue

Write-Host ''
if ($failures -gt 0) {
    Write-Host "RESULT: FAIL ($failures assertion(s) failed)" -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: PASS (all hook assertions passed)'
exit 0
