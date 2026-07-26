#Requires -Version 7.0
# stop-peer-review-gate.ps1 — blocking Stop hook enforcing the peer-review final gate.
#
# Blocks ending a session when the current feature branch has committed work ahead
# of its base and the latest peer-review-critic run this session did not APPROVE:
#   - no session marker            -> reviewer never ran   -> block (at most 1x/session)
#   - marker verdict=CHANGES_REQUIRED -> review failed     -> block (at most 3 blocks/session total)
#   - marker verdict=APPROVED      -> allow
#   - marker without a verdict line (legacy recorder)      -> allow (fail-open)
#
# The .fired marker is a block counter (its absence = 0; empty/non-numeric content
# = 1, which is the pre-verdict on-disk format). Loop-safe (stop_hook_active),
# fail-open: any error, parse failure, or non-git context => exit 0 with no output.
#
# Registered in hooks/hooks.json via the agentic-framework plugin.
# Session markers are written by hooks/record-subagent-run.ps1.

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop

    if ($payload.stop_hook_active) { exit 0 }

    $sessionId = ([string]$payload.session_id) -replace '[^\w-]', ''
    if (-not $sessionId) { exit 0 }

    $stateRoot = $env:CLAUDE_STATE_DIR
    if (-not $stateRoot) { $stateRoot = Join-Path $HOME '.claude/.state' }
    $reviewDir = Join-Path $stateRoot 'peer-review'
    $marker    = Join-Path $reviewDir $sessionId
    $fired     = Join-Path $reviewDir "$sessionId.fired"

    $verdict = $null   # $null = reviewer never ran; '' = ran, no parseable verdict (legacy)
    if (Test-Path $marker) {
        $verdict = ''
        $content = Get-Content -Path $marker -Raw -ErrorAction SilentlyContinue
        if ($content -match 'verdict=(APPROVED|CHANGES_REQUIRED)') { $verdict = $Matches[1] }
        if ($verdict -in @('APPROVED', '')) { exit 0 }   # approved, or legacy ran-marker => allow
    }

    $blockCount = 0
    if (Test-Path $fired) {
        $blockCount = 1
        $raw = (Get-Content -Path $fired -Raw -ErrorAction SilentlyContinue)
        if ($raw -and ($raw.Trim() -match '^\d+$')) { $blockCount = [int]$raw.Trim() }
    }

    # Budget: 1 block when the reviewer never ran (status quo, not a per-turn nag);
    # up to 3 blocks total once a CHANGES_REQUIRED verdict exists, so the
    # fix -> re-review loop gets bounded enforcement, never an infinite one.
    $maxBlocks = if ($verdict -eq 'CHANGES_REQUIRED') { 3 } else { 1 }
    if ($blockCount -ge $maxBlocks) { exit 0 }

    $cwd = [string]$payload.cwd
    if (-not $cwd -or -not (Test-Path $cwd)) { $cwd = (Get-Location).Path }

    $inTree = git -C $cwd rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $inTree -ne 'true') { exit 0 }

    $branch = git -C $cwd rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $branch -or $branch -eq 'HEAD') { exit 0 }
    if ($branch -in @('main', 'master')) { exit 0 }

    $base = $null
    foreach ($candidate in @('origin/main', 'origin/master', 'main', 'master')) {
        git -C $cwd rev-parse --verify --quiet $candidate *> $null
        if ($LASTEXITCODE -eq 0) { $base = $candidate; break }
    }
    if (-not $base) { exit 0 }

    $ahead = git -C $cwd rev-list --count "$base..HEAD" 2>$null
    if ($LASTEXITCODE -ne 0 -or [int]$ahead -eq 0) { exit 0 }

    # Uncommitted work means the session is mid-flight; the gate only guards
    # "done" states (committed, clean tree, unreviewed or unapproved).
    $dirty = git -C $cwd status --porcelain 2>$null
    if ($LASTEXITCODE -ne 0 -or $dirty) { exit 0 }

    New-Item -ItemType Directory -Force -Path $reviewDir | Out-Null
    Set-Content -Path $fired -Value ([string]($blockCount + 1)) -NoNewline

    if ($verdict -eq 'CHANGES_REQUIRED') {
        $reason = "Peer-review final gate: peer-review-critic reviewed branch '$branch' this session and " +
                  'returned CHANGES_REQUIRED. Resolve every BLOCKER/MAJOR finding, then re-run the ' +
                  'peer-review-critic subagent (Task tool, subagent_type: peer-review-critic) until it ' +
                  'returns VERDICT: APPROVED, or ask the user to explicitly waive the gate.'
    } else {
        $reason = "Peer-review final gate: branch '$branch' has $ahead commit(s) ahead of $base that have not " +
                  'been peer reviewed this session. Launch the peer-review-critic subagent (Task tool, ' +
                  "subagent_type: peer-review-critic) to review the branch diff against $base and resolve " +
                  'every BLOCKER/MAJOR finding, or ask the user to explicitly waive the gate.'
    }
    @{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress
    exit 0
} catch {
    exit 0
}
