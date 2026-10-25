#Requires -Version 7.0
param([string]$HookRoot = (Split-Path -Parent $PSScriptRoot), [string]$CaseFilter = '*')
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('docs-gate-' + [guid]::NewGuid().ToString('N'))
$savedState = $env:CLAUDE_STATE_DIR
$savedSwitch = $env:AF_CODE_REVIEW_GATE
$savedIdentity = @{}
foreach ($key in @('GH_REPO','GH_HOST','GLAB_REPO','GITLAB_REPO','GITLAB_HOST')) { $savedIdentity[$key] = [Environment]::GetEnvironmentVariable($key) }
$failures = 0; $passed = 0; $skipped = 0
function G([string[]]$A) { $o = & git -C $script:repo @A 2>$null; if ($LASTEXITCODE -ne 0) { throw 'Fixture git command failed.' }; return ($o -join "`n") }
function Write-Fixture([string]$Path, [string]$Value = 'prose') {
    $p = Join-Path $script:repo $Path
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p)) | Out-Null
    [IO.File]::WriteAllText($p, $Value, [Text.UTF8Encoding]::new($false))
}
function Save-Fixture { $null = G @('add', '-A'); $null = G @('commit', '-qm', 'fixture') }
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    Remove-Item Env:AF_CODE_REVIEW_GATE -ErrorAction Ignore
    $cases = Get-Content (Join-Path $PSScriptRoot 'docs-only-cases.json') -Raw | ConvertFrom-Json
    foreach ($c in $cases) {
        if ($c.name -notlike $CaseFilter) { continue }
        foreach ($key in $savedIdentity.Keys) { [Environment]::SetEnvironmentVariable($key, $null) }
        $script:repo = Join-Path $root ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:repo | Out-Null
        $null = G @('init', '-q', '-b', 'main')
        $null = G @('config', 'user.name', 'test'); $null = G @('config', 'user.email', 'test@example.invalid')
        $null = G @('config', 'commit.gpgsign', 'false')
        Write-Fixture 'README.md'; Write-Fixture 'app.cs' 'base'; Save-Fixture
        $base = G @('rev-parse', 'HEAD')
        if ($c.action -eq 'gitlink') {
            $null = G @('update-index', '--add', '--cacheinfo', "160000,$base,module")
            $null = G @('commit', '-qm', 'base gitlink')
            $base = G @('rev-parse', 'HEAD')
            [IO.Directory]::CreateDirectory((Join-Path $script:repo 'module')) | Out-Null
        }
        $null = G @('remote', 'add', 'origin', "$script:repo.nowhere")
        $null = G @('update-ref', 'refs/remotes/origin/main', $base)
        $null = G @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
        $null = G @('checkout', '-qb', 'feature/docs')
        if ($c.action -eq 'control-name' -and $IsWindows) { $skipped++; continue }
        switch ($c.action) {
            'add' { Write-Fixture $c.path }
            'mixed' { Write-Fixture 'README.md' 'new'; Write-Fixture 'app.cs' 'new' }
            'nested-relative' { Write-Fixture 'docs/guide.md' 'new'; Write-Fixture 'app.cs' 'new' }
            'gitlink' { Write-Fixture 'README.md' 'new'; $null = G @('update-index', '--cacheinfo', "160000,$base,module") }
            'history' { Write-Fixture 'app.cs' 'new'; Save-Fixture; Write-Fixture 'README.md' 'new' }
            'rename-code-doc' { $null = G @('mv', '--', 'app.cs', 'renamed.md') }
            'rename-doc-code' { $null = G @('mv', '--', 'README.md', 'renamed.py') }
            'rename-doc-doc' { $null = G @('mv', '--', 'README.md', 'renamed.md') }
            'delete-doc' { $null = G @('rm', '--', 'README.md') }
            'control-name' { Write-Fixture "app.cs`nnotes.md" }
            default { Write-Fixture 'README.md' 'new' }
        }
        Save-Fixture
        if ($c.action -eq 'executable') { $null = G @('update-index', '--chmod=+x', 'README.md'); $null = G @('commit', '-qm', 'mode') }
        $head = G @('rev-parse', 'HEAD')
        $null = G @('update-ref', 'refs/remotes/origin/feature/docs', $head)
        switch ($c.action) {
            'nested-relative' { $null = G @('config', 'diff.relative', 'true') }
            'multiple-remotes' { $null = G @('remote', 'add', 'another', "$script:repo.another") }
            'gitlink' { $null = G @('config', 'diff.ignoreSubmodules', 'all') }
            'dirty' { Write-Fixture 'app.cs' 'dirty' }
            'staged' { Write-Fixture 'app.cs' 'dirty'; $null = G @('add', '--', 'app.cs') }
            'untracked' { Write-Fixture 'new.py' 'code' }
            'dirty-doc' { Write-Fixture 'README.md' 'dirty' }
            'unknown-base' { $null = G @('update-ref', '-d', 'refs/remotes/origin/main') }
            'diff-failed' { $null = G @('config', 'diff.orderFile', (Join-Path $root 'missing-order-file')) }
            'unknown-head' { $null = G @('update-ref', '-d', 'refs/remotes/origin/feature/docs') }
            'remote-mismatch' { $null = G @('update-ref', 'refs/remotes/origin/feature/docs', $base) }
            'diverged' {
                $null = G @('checkout', '-q', 'main'); Write-Fixture 'app.cs' 'destination'; Save-Fixture
                $tip = G @('rev-parse', 'HEAD'); $null = G @('update-ref', 'refs/remotes/origin/main', $tip)
                $null = G @('checkout', '-q', 'feature/docs')
            }
        }
        $command = switch ($c.command) { 'push' { 'git push origin HEAD:main' }; 'mr' { 'glab mr create --target-branch main' }; default { 'gh pr create --base main' } }
        if ($c.options) { $command += ' ' + ($c.options -join ' ') }
        if ($c.envName) { [Environment]::SetEnvironmentVariable($c.envName, 'foreign/project') }
        $cwd = if ($c.action -eq 'nested-relative') { Join-Path $script:repo 'docs' } else { $script:repo }
        $env:CLAUDE_STATE_DIR = Join-Path $root 'state'
        $payload = @{ session_id = 'docs-only'; cwd = $cwd; tool_name = 'Bash'; tool_input = @{ command = $command } } | ConvertTo-Json -Compress
        $output = $payload | pwsh -NoProfile -File (Join-Path $HookRoot 'hooks/pretooluse-code-review-gate.ps1')
        $code = $LASTEXITCODE; $text = $output -join "`n"
        $allowed = $text.Length -eq 0
        if ($code -eq 0 -and $allowed -eq $c.allow -and ($allowed -or $text -match '"permissionDecision":"deny"')) { $passed++; Write-Output "PASS $($c.name)" }
        else { $failures++; Write-Output "FAIL $($c.name)" }
    }
} finally {
    $env:CLAUDE_STATE_DIR = $savedState; $env:AF_CODE_REVIEW_GATE = $savedSwitch
    foreach ($key in $savedIdentity.Keys) { [Environment]::SetEnvironmentVariable($key, $savedIdentity[$key]) }
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Output "RESULT: $passed passed, $skipped skipped, $failures failed"
if ($failures) { exit 1 }; exit 0
