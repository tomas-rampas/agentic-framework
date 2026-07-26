#Requires -Version 7.0
# pretooluse-delegation-hint.ps1 — advisory PreToolUse hook (matcher: Write|Edit).
#
# Detects the technology of the file being written from its extension and suggests
# the matching specialist subagent, at most once per session per suggested agent.
# Never blocks; fail-open: any error => exit 0 with no output.
#
# Registered in hooks/hooks.json via the agentic-framework plugin (PreToolUse: Write|Edit).

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop

    $filePath = [string]($payload.tool_input.file_path ?? $payload.tool_input.path ?? '')
    if (-not $filePath) { exit 0 }

    $techMap = @{
        '.rs'   = @{ tech = 'Rust';             agent = 'rust-expert' }
        '.py'   = @{ tech = 'Python';           agent = 'python-expert' }
        '.ts'   = @{ tech = 'TypeScript';       agent = 'typescript-expert' }
        '.tsx'  = @{ tech = 'TypeScript/React'; agent = 'typescript-expert' }
        '.js'   = @{ tech = 'JavaScript';       agent = 'typescript-expert' }
        '.jsx'  = @{ tech = 'JavaScript/React'; agent = 'typescript-expert' }
        '.cs'   = @{ tech = 'C#/.NET';          agent = 'csharp-expert' }
        '.go'   = @{ tech = 'Go';               agent = 'go-expert' }
        '.java' = @{ tech = 'Java';             agent = 'java-expert' }
        '.sh'   = @{ tech = 'Bash/Shell';       agent = 'bash-expert' }
        '.ps1'  = @{ tech = 'PowerShell';       agent = 'powershell-expert' }
        '.sql'  = @{ tech = 'SQL/Database';     agent = 'database-specialist' }
        '.mq5'  = @{ tech = 'MQL5';             agent = 'mql-trading-dev' }
        '.mq4'  = @{ tech = 'MQL4';             agent = 'mql-trading-dev' }
        '.mqh'  = @{ tech = 'MQL include';      agent = 'mql-trading-dev' }
    }
    $ext  = [IO.Path]::GetExtension($filePath).ToLower()
    $info = $techMap[$ext]
    if (-not $info) { exit 0 }

    $sessionId = ([string]$payload.session_id) -replace '[^\w-]', ''
    if ($sessionId) {
        $stateRoot = $env:CLAUDE_STATE_DIR
        if (-not $stateRoot) { $stateRoot = Join-Path $HOME '.claude/.state' }
        $hintDir = Join-Path $stateRoot 'delegation-hints'
        $seen    = Join-Path $hintDir "$sessionId-$($info.agent)"
        if (Test-Path $seen) { exit 0 }
        New-Item -ItemType Directory -Force -Path $hintDir | Out-Null
        New-Item -ItemType File -Force -Path $seen | Out-Null

        Get-ChildItem -Path $hintDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    @{
        suppressOutput = $true
        systemMessage  = "[delegation-hint] $($info.tech) file detected - consider delegating implementation work to the $($info.agent) subagent."
    } | ConvertTo-Json -Compress
    exit 0
} catch {
    exit 0
}
