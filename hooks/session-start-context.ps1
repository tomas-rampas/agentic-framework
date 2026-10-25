#Requires -Version 7.0
# session-start-context.ps1 — SessionStart hook. Its stdout is injected into the
# session context, so this is the one advisory hook whose output the model sees.
#
# Two outputs:
#   1. A branch / unreviewed-commit line so the model knows whether the peer-review
#      final gate (Stop hook) is armed, plus a one-line routing reminder.
#   2. The framework policy: the full, unmodified content of POLICY.md at the plugin
#      root, printed after the branch line on source startup, resume, clear and
#      compact (any other or absent source prints no policy), unless <cwd>/CLAUDE.md holds the
#      exact marker line  <!-- agentic-framework: policy inline -->  (REQ-009).
#      The marker is honoured only in <cwd>/CLAUDE.md; parent and child directories
#      are not consulted (EDGE-005). A missing POLICY.md prints nothing extra.
#      The plugin root is CLAUDE_PLUGIN_ROOT, else this script's parent directory.
# Output is written as UTF-8 without BOM with LF line endings; the policy bytes are
# passed through untouched.
# Fail-open: any error => exit 0 (whatever was already built is still printed).
#
# Registered in hooks/hooks.json via the agentic-framework plugin (SessionStart).

$Marker = '<!-- agentic-framework: policy inline -->'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Get-BranchLine {
    param([string]$Cwd)
    $inTree = git -C $Cwd rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0 -or $inTree -ne 'true') { return $null }

    $branch = git -C $Cwd rev-parse --abbrev-ref HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $branch) { return $null }

    if ($branch -in @('main', 'master', 'HEAD')) {
        return "[session-context] On '$branch'. The peer-review Stop gate applies only to feature branches; a push to main/master, and gh pr create or glab mr create, need a code-review-gatekeeper review first (pretooluse-code-review-gate denies them until one is recorded)."
    }

    $base = $null
    foreach ($candidate in @('origin/main', 'origin/master', 'main', 'master')) {
        git -C $Cwd rev-parse --verify --quiet $candidate *> $null
        if ($LASTEXITCODE -eq 0) { $base = $candidate; break }
    }

    if ($base) {
        $ahead = git -C $Cwd rev-list --count "$base..HEAD" 2>$null
        if ($LASTEXITCODE -eq 0 -and [int]$ahead -gt 0) {
            return "[session-context] Branch '$branch' is $ahead commit(s) ahead of $base. The peer-review final gate (Stop hook) blocks ending a session with committed, unreviewed work — run the peer-review-critic subagent before finishing. Route specialist work to the matching subagent (run /agentic-framework:list-agents for routing guidance)."
        }
    }

    return "[session-context] Branch '$branch' — no commits ahead of base; peer-review gate idle."
}

$out = [System.IO.MemoryStream]::new()
try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop

    $cwd = [string]$payload.cwd
    if (-not $cwd -or -not (Test-Path -LiteralPath $cwd)) { $cwd = (Get-Location).Path }
    $sourceKind = [string]$payload.source

    $line = Get-BranchLine -Cwd $cwd
    if ($line) {
        $b = $utf8.GetBytes($line + "`n")
        $out.Write($b, 0, $b.Length)
    }

    if ($sourceKind -in @('startup', 'resume', 'clear', 'compact')) {
        $root = $env:CLAUDE_PLUGIN_ROOT
        if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
        $policy = Join-Path $root 'POLICY.md'
        if (Test-Path -LiteralPath $policy -PathType Leaf) {
            $inline = $false
            $claudeMd = Join-Path $cwd 'CLAUDE.md'
            if (Test-Path -LiteralPath $claudeMd -PathType Leaf) {
                # Decode as UTF-8 without BOM detection (no UTF-16/UTF-32 sniffing), strip one
                # leading U+FEFF, remove every CR and split on LF alone; compare ordinally.
                # Matches the .sh twin (tr -d '\r' | sed BOM | grep -x -F) on UTF-8 input.
                # An unreadable file leaves $inline false, so the policy is printed (as in the .sh twin).
                try {
                    $text = [Text.UTF8Encoding]::new($false).GetString([IO.File]::ReadAllBytes($claudeMd))
                    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
                    $text = $text.Replace("`r", '')
                    foreach ($l in $text.Split("`n")) {
                        if ([string]::Equals($l, $Marker, [StringComparison]::Ordinal)) { $inline = $true; break }
                    }
                } catch { $inline = $false }
            }
            if (-not $inline) {
                $b = [System.IO.File]::ReadAllBytes($policy)
                $out.Write($b, 0, $b.Length)
            }
        }
    }
} catch {
    # fail-open: print whatever was built so far
    $null = $_
}
try {
    $stdout = [Console]::OpenStandardOutput()
    $out.WriteTo($stdout)
    $stdout.Flush()
} catch { $null = $_ }
exit 0
