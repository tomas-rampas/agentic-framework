#Requires -Version 7.0
# session-start-context.ps1 — SessionStart hook. Its stdout is injected into the
# session context, so this is the one advisory hook whose output the model sees.
#
# Reports the branch / unreviewed-commit state so the model knows whether the
# peer-review final gate (Stop hook) is armed, plus a one-line routing reminder.
# Fail-open: any error => exit 0 with no output.
#
# Registered in hooks/hooks.json via the agentic-framework plugin (SessionStart).

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop

    $cwd = [string]$payload.cwd
    if (-not $cwd -or -not (Test-Path $cwd)) { $cwd = (Get-Location).Path }

    $inTree = git -C $cwd rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $inTree -ne 'true') { exit 0 }

    $branch = git -C $cwd rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $branch) { exit 0 }

    if ($branch -in @('main', 'master', 'HEAD')) {
        Write-Output "[session-context] On '$branch'. The peer-review Stop gate applies only to feature branches."
        exit 0
    }

    $base = $null
    foreach ($candidate in @('origin/main', 'origin/master', 'main', 'master')) {
        git -C $cwd rev-parse --verify --quiet $candidate *> $null
        if ($LASTEXITCODE -eq 0) { $base = $candidate; break }
    }

    if ($base) {
        $ahead = git -C $cwd rev-list --count "$base..HEAD" 2>$null
        if ($LASTEXITCODE -eq 0 -and [int]$ahead -gt 0) {
            Write-Output "[session-context] Branch '$branch' is $ahead commit(s) ahead of $base. The peer-review final gate (Stop hook) blocks ending a session with committed, unreviewed work — run the peer-review-critic subagent before finishing. Route specialist work to the matching subagent (run /agentic-framework:list-agents for routing guidance)."
            exit 0
        }
    }

    Write-Output "[session-context] Branch '$branch' — no commits ahead of base; peer-review gate idle."
    exit 0
} catch {
    exit 0
}
