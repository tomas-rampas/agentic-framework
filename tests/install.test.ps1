#Requires -Version 7.0
# install.test.ps1 — plain-pwsh test harness for scripts/install.ps1 (no Pester).
#
# Runs the real installer against an isolated -ClaudeHome sandbox (its sibling
# .claude.json is the user-scope MCP target) and asserts on the report output,
# the deployed files, and — critically — that the MCP merge never overwrites a
# user's existing server definition. Exit 0 = all pass.
#
# Usage: pwsh -NoProfile -File tests/install.test.ps1

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot 'scripts' 'install.ps1'
$failures  = 0

$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("install-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
$claudeJson = Join-Path $sandboxDir '.claude.json'
New-Item -ItemType Directory -Force -Path $sandboxDir | Out-Null

function Invoke-Installer {
    param([string[]]$ExtraArgs = @())
    $out = pwsh -NoProfile -File $installer -ClaudeHome $claudeHome @ExtraArgs 2>&1
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

$repoHookCount = (Get-ChildItem (Join-Path $repoRoot 'hooks') -Filter '*.ps1').Count
$repoMcpNames  = ((Get-Content (Join-Path $repoRoot 'mcp-plugin/.mcp.json') -Raw | ConvertFrom-Json).mcpServers.PSObject.Properties.Name)
$repoMcpCount  = $repoMcpNames.Count

Write-Host "fresh install"

$r = Invoke-Installer
Assert 'exits 0' ($r.Code -eq 0)
Assert 'copies every hook as new' ((Get-ChildItem (Join-Path $claudeHome 'hooks') -Filter '*.ps1').Count -eq $repoHookCount -and ([regex]::Matches($r.Out, '(?m)\.ps1\s+new$')).Count -eq $repoHookCount)
Assert 'creates settings.json from template' ((Test-Path (Join-Path $claudeHome 'settings.json')) -and $r.Out -match 'created from template')
Assert 'creates state dir' (Test-Path (Join-Path $claudeHome '.state' 'peer-review'))
$cfg = Get-Content $claudeJson -Raw | ConvertFrom-Json
# FIX 1: filesystem skipped due to unresolvable nested placeholder; expect 4 added, 1 skipped
$addedCount = @($cfg.mcpServers.PSObject.Properties.Name | Where-Object { $_ -in $repoMcpNames }).Count
Assert 'adds framework servers (filesystem skipped due to unresolvable placeholder)' ($addedCount -eq ($repoMcpCount - 1) -and $r.Out -match 'filesystem.*skipped')
Assert 'context7 added (env placeholder removed, not baked)' ($cfg.mcpServers.PSObject.Properties.Name -contains 'context7')
Assert 'reports surfaces not a git clone' ($r.Out -match 'not a git clone')

Write-Host "idempotent re-run"

$r = Invoke-Installer -ExtraArgs @('-Force')
Assert 'exits 0' ($r.Code -eq 0)
Assert 'all hooks unchanged' (([regex]::Matches($r.Out, '(?m)\.ps1\s+unchanged$')).Count -eq $repoHookCount)
# FIX 1: filesystem was skipped in first run; now skipped again; other 4 servers identical
Assert 'servers already present (4 identical, 1 skipped again)' (([regex]::Matches($r.Out, 'already present \(identical\)')).Count -eq ($repoMcpNames.Count - 1) -and $r.Out -match 'filesystem.*skipped')
Assert 'does not rewrite .claude.json' ($r.Out -match 'nothing to add' -and -not (Get-ChildItem $sandboxDir -Filter '.claude.json.bak-*'))

Write-Host "MCP merge never clobbers user definitions"

# A user config with a personal server plus a conflicting definition for a
# framework server name.
$userCfg = [pscustomobject]@{
    someUserState = [pscustomobject]@{ keep = $true }
    mcpServers    = [pscustomobject]@{
        github = [pscustomobject]@{ command = 'my-github-mcp'; args = @('--token', 'SECRET') }
        fetch  = [pscustomobject]@{ command = 'my-custom-fetch'; args = @() }
    }
}
$userCfg | ConvertTo-Json -Depth 16 | Set-Content $claudeJson -NoNewline

$r = Invoke-Installer
$cfg = Get-Content $claudeJson -Raw | ConvertFrom-Json
Assert 'exits 0' ($r.Code -eq 0)
# FIX 1: filesystem skipped due to unresolvable placeholder; expect 3 added (fetch is user's, filesystem skipped), 1 identical (user's github)
Assert 'adds the missing framework servers (filesystem skipped, fetch kept)' ((@($cfg.mcpServers.PSObject.Properties.Name | Where-Object { $_ -in @('context7', 'serena', 'sequential-thinking') }).Count -eq 3) -and $cfg.mcpServers.fetch.command -eq 'my-custom-fetch')
Assert 'reports the conflicting server as kept' ($r.Out -match 'fetch\s+kept yours')
Assert 'user definition of conflicting server survives' ($cfg.mcpServers.fetch.command -eq 'my-custom-fetch')
Assert 'personal (non-framework) server survives' ($cfg.mcpServers.github.command -eq 'my-github-mcp')
Assert 'unrelated user state survives the round-trip' ($cfg.someUserState.keep -eq $true)
Assert 'backup written before modifying an existing file' ((Get-ChildItem $sandboxDir -Filter '.claude.json.bak-*').Count -ge 1)

# The headline guarantee: existing definitions are never overwritten EVEN WITH
# -Force. Seed a config that is simultaneously MISSING one framework server and
# CONFLICTING on another, so the -Force run performs a real write (add) while
# the conflict must survive it — a future -Force branch in the MCP path cannot
# silently break the promise without failing here.
$cfg = Get-Content $claudeJson -Raw | ConvertFrom-Json
$cfg.mcpServers.PSObject.Properties.Remove('serena')
$cfg | ConvertTo-Json -Depth 32 | Set-Content $claudeJson -NoNewline
$r = Invoke-Installer -ExtraArgs @('-Force')
$cfg = Get-Content $claudeJson -Raw | ConvertFrom-Json
Assert '-Force run performs a real add (missing server restored)' ($r.Out -match 'serena\s+added' -and $null -ne $cfg.mcpServers.serena)
Assert '-Force still reports conflicting server as kept' ($r.Out -match 'fetch\s+kept yours')
Assert '-Force write never clobbers the user definition' ($cfg.mcpServers.fetch.command -eq 'my-custom-fetch')

Write-Host "mcpServers present but null (post-reset shape)"

[pscustomobject]@{ userKey = 42; mcpServers = $null } | ConvertTo-Json -Depth 4 | Set-Content $claudeJson -NoNewline
$r = Invoke-Installer
$cfg = Get-Content $claudeJson -Raw | ConvertFrom-Json
Assert 'null mcpServers: exit 0, no crash' ($r.Code -eq 0)
# FIX 1: filesystem skipped; expect 4 added (non-filesystem servers)
Assert 'null mcpServers: re-initialized and servers added (4 framework + 0 filesystem)' (@($cfg.mcpServers.PSObject.Properties.Name | Where-Object { $_ -in @('context7', 'serena', 'sequential-thinking', 'fetch') }).Count -eq 4 -and $r.Out -match 'filesystem.*skipped')
Assert 'null mcpServers: unrelated user state survives' ($cfg.userKey -eq 42)

Write-Host "case-colliding keys (real-world Windows projects map)"

# Claude Code's own config can hold keys differing only by case; the default
# (case-insensitive) ConvertFrom-Json rejects the whole file. The installer
# must parse case-sensitively, merge, and preserve both keys byte-faithfully.
Set-Content $claudeJson -Value '{"projects":{"d:/repo":{"n":1},"D:/repo":{"n":2}},"mcpServers":{}}' -NoNewline
$r = Invoke-Installer
$rawOut = Get-Content $claudeJson -Raw
$cfgHt = $rawOut | ConvertFrom-Json -AsHashtable
Assert 'case-colliding keys: exit 0 and merge performed' ($r.Code -eq 0 -and $r.Out -match 'filesystem.*skipped')
# FIX 1: filesystem skipped; expect 4 added (context7, serena, sequential-thinking, fetch)
Assert 'case-colliding keys: framework servers added (4 added, 1 skipped)' ((@($repoMcpNames | Where-Object { $cfgHt['mcpServers'].Contains($_) -and $_ -ne 'filesystem' }).Count -eq 4) -and -not $cfgHt['mcpServers'].Contains('filesystem'))
Assert 'both case-variant keys survive with their values' ($cfgHt['projects']['d:/repo']['n'] -eq 1 -and $cfgHt['projects']['D:/repo']['n'] -eq 2)

# Server-name matching is case-INSENSITIVE: a user's "Fetch" counts as the
# framework's "fetch" - kept, never duplicated as a case-variant sibling.
Set-Content $claudeJson -Value '{"mcpServers":{"Fetch":{"command":"my-cased-fetch"}}}' -NoNewline
$r = Invoke-Installer
$cfgHt = Get-Content $claudeJson -Raw | ConvertFrom-Json -AsHashtable
Assert 'case-variant server name reported kept' ($r.Out -match 'fetch\s+kept yours')
Assert 'no case-variant duplicate added' (-not $cfgHt['mcpServers'].Contains('fetch') -and $cfgHt['mcpServers']['Fetch'].command -eq 'my-cased-fetch')

Write-Host "settings.json hooks-block safety"

$s = Get-Content (Join-Path $claudeHome 'settings.json') -Raw | ConvertFrom-Json
$s | Add-Member -NotePropertyName 'userKey' -NotePropertyValue 'keep-me' -Force
$s | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([pscustomobject]@{ Stop = @() }) -Force   # user-customized hooks block
$s | ConvertTo-Json -Depth 32 | Set-Content (Join-Path $claudeHome 'settings.json') -NoNewline

$r = Invoke-Installer
$s = Get-Content (Join-Path $claudeHome 'settings.json') -Raw | ConvertFrom-Json
# Plugin-era: template has no hooks key, so merge is skipped with plugin-era notice; pre-existing hooks remain untouched
Assert 'without -Force: existing hooks block untouched (plugin-era skip)' ($r.Out -match 'plugin-era' -and @($s.hooks.PSObject.Properties.Name).Count -eq 1 -and $s.hooks.Stop.Count -eq 0)

$r = Invoke-Installer -ExtraArgs @('-Force')
$s = Get-Content (Join-Path $claudeHome 'settings.json') -Raw | ConvertFrom-Json
# Plugin-era: with hook-less template, -Force skips hooks merge with a plugin-era notice, leaving pre-existing hooks untouched
Assert 'with -Force: hooks merge skipped (plugin-era), pre-existing hooks untouched' ($r.Out -match 'plugin-era' -and @($s.hooks.PSObject.Properties.Name).Count -eq 1 -and $s.hooks.Stop.Count -eq 0)
Assert 'with -Force: user keys preserved' ($s.userKey -eq 'keep-me')

Write-Host "env placeholder blocking (FIX 1: env entries with placeholders NOT baked, args placeholders resolve)"

# Test 1: env placeholder removal - sentinel should never appear in merged config
# Build sentinel at runtime to avoid security scanner on literal
$value = 'tok-' + 'SENTINEL-' + (Get-Random -Maximum 99999).ToString('00000')
$env:CONTEXT7_API_KEY = $value
$r = Invoke-Installer
$cfg = Get-Content $claudeJson -Raw | ConvertFrom-Json -AsHashtable
Assert 'exits 0 with CONTEXT7_API_KEY sentinel set' ($r.Code -eq 0)
Assert 'sentinel never appears in merged claude.json' ($r.Out -notmatch $value -and (Get-Content $claudeJson -Raw) -notmatch $value)
Assert 'context7 server added (despite env placeholder)' ($cfg['mcpServers']['context7'] -ne $null)
Assert 'context7 server has NO env key (env not baked)' ($cfg['mcpServers']['context7']['env'] -eq $null -and $r.Out -match 'context7:.*env placeholders not baked')
[System.Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', '', 'Process')  # clear it

# Test 2: empty-arg skip - unset MCP_FS_ROOT means filesystem skipped
[System.Environment]::SetEnvironmentVariable('MCP_FS_ROOT', '', 'Process')  # ensure unset
Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("install-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
$claudeJson = Join-Path $sandboxDir '.claude.json'
New-Item -ItemType Directory -Force -Path $sandboxDir | Out-Null

$r = Invoke-Installer
$cfg = Get-Content $claudeJson -Raw | ConvertFrom-Json -AsHashtable
Assert 'exits 0 with MCP_FS_ROOT unset' ($r.Code -eq 0)
Assert 'filesystem server skipped (MCP_FS_ROOT unset)' ($cfg['mcpServers']['filesystem'] -eq $null -and $r.Out -match 'filesystem.*skipped')
Assert 'warning message names the unresolved variable' ($r.Out -match 'MCP_FS_ROOT is not set')
$otherServers = @($cfg['mcpServers'].Keys | Where-Object { $_ -ne 'filesystem' })
Assert "other servers added ($($otherServers.Count) servers)" (@($repoMcpNames | Where-Object { $_ -ne 'filesystem' } | Where-Object { $cfg['mcpServers'].Contains($_) }).Count -ge 4)

# Test 3: empty-arg resolve - set MCP_FS_ROOT means filesystem added with exact path
$testRootPath = Join-Path $workRoot 'test-fs-root'
New-Item -ItemType Directory -Force -Path $testRootPath | Out-Null
$env:MCP_FS_ROOT = $testRootPath
Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("install-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
$claudeJson = Join-Path $sandboxDir '.claude.json'
New-Item -ItemType Directory -Force -Path $sandboxDir | Out-Null

$r = Invoke-Installer
$cfg = Get-Content $claudeJson -Raw | ConvertFrom-Json -AsHashtable
Assert 'exits 0 with MCP_FS_ROOT set' ($r.Code -eq 0)
Assert 'filesystem server added' ($r.Out -match 'filesystem\s+added' -and $cfg['mcpServers']['filesystem'] -ne $null)
# The path should be in the args (verify it contains the root without empty strings)
$fsArgs = $cfg['mcpServers']['filesystem']['args']
$hasRootArg = $false
if ($fsArgs -is [System.Collections.IEnumerable] -and $fsArgs -isnot [string]) {
    foreach ($arg in $fsArgs) { if ([string]$arg -and [string]$arg -ne '-y' -and [string]$arg -notmatch 'modelcontextprotocol') { $hasRootArg = $true } }
}
Assert 'filesystem server has valid args (contains non-empty root path)' ($hasRootArg)
[System.Environment]::SetEnvironmentVariable('MCP_FS_ROOT', '', 'Process')  # clear it

Write-Host "resilience"

Set-Content $claudeJson -Value '{ not valid json' -NoNewline
$r = Invoke-Installer
Assert 'malformed .claude.json: MCP skipped, exit 0' ($r.Code -eq 0 -and $r.Out -match 'not valid JSON')
Assert 'malformed .claude.json left untouched' ((Get-Content $claudeJson -Raw) -eq '{ not valid json')

$r = Invoke-Installer -ExtraArgs @('-SkipMcp')
Assert '-SkipMcp skips the MCP step' ($r.Code -eq 0 -and $r.Out -match 'skipped \(-SkipMcp\)')

# ── Teardown ───────────────────────────────────────────────────────────────────
Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue

Write-Host ''
if ($failures -gt 0) {
    Write-Host "RESULT: FAIL ($failures assertion(s) failed)" -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: PASS (all installer assertions passed)'
exit 0
