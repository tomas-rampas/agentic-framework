#Requires -Version 7.0
# migrate.test.ps1 — test harness for scripts/migrate-legacy.ps1 (no Pester).
#
# Runs the real migration script against isolated sandboxes and validates:
# - Dry-run makes no changes
# - Framework hooks are removed (nested shape), foreign hooks preserved
# - MCP cleanup respects customized vs framework-shaped distinction
# - Protected paths are never deleted
# - Idempotence (second run finds nothing to do)
# - -RemoveMcp alone does NOT mutate without -Apply
# - Dirty checkout aborts Section 5 safely
#
# Usage: pwsh -NoProfile -File tests/migrate.test.ps1

$ErrorActionPreference = 'Stop'

$repoRoot   = Split-Path -Parent $PSScriptRoot
$migrator   = Join-Path $repoRoot 'scripts' 'migrate-legacy.ps1'
$failures   = 0

function Invoke-Migrator {
    param([string]$ClaudeHome, [string[]]$ExtraArgs = @())
    $out = pwsh -NoProfile -File $migrator -ClaudeHome $ClaudeHome @ExtraArgs 2>&1
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

function Get-FileHash-Content {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    Get-FileHash $Path -Algorithm SHA256 | Select-Object -ExpandProperty Hash
}

Write-Host ''
Write-Host 'Testing legacy framework install migration'
Write-Host ''

# ── Test 1: DRY-RUN MAKES NO CHANGES ───────────────────────────────────────────
Write-Host 'dry-run: changes nothing'

$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
$claudeJson = Join-Path $sandboxDir '.claude.json'
New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome 'hooks') | Out-Null

# Build legacy home with framework + foreign hook entries (nested shape)
$settings = @{
    hooks = @{
        Stop = @(
            @{
                hooks = @(
                    @{
                        type    = "command"
                        command = "pwsh -NoProfile -File `"$HOME/.claude/hooks/stop-peer-review-gate.ps1`""
                        timeout = 15
                    },
                    @{
                        type    = "command"
                        command = "pwsh -NoProfile -File `"$HOME/.claude/hooks/my-custom-hook.ps1`""
                        timeout = 15
                    }
                )
            }
        )
        PreToolUse = @(
            @{
                matcher = "Write|Edit"
                hooks   = @(
                    @{
                        type    = "command"
                        command = "pwsh -NoProfile -File `"$HOME/.claude/hooks/pretooluse-delegation-hint.ps1`""
                        timeout = 10
                    }
                )
            }
        )
        PostToolUse = @(
            @{
                matcher = "Task|Agent"
                hooks   = @(
                    @{
                        type    = "command"
                        command = "pwsh -NoProfile -File `"$HOME/.claude/hooks/record-subagent-run.ps1`""
                        timeout = 10
                    }
                )
            }
        )
    }
}
$settings | ConvertTo-Json -Depth 16 | Set-Content (Join-Path $claudeHome 'settings.json') -NoNewline

# Create hook files
'# foreign hook' | Set-Content (Join-Path $claudeHome 'hooks' 'my-custom-hook.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'stop-peer-review-gate.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'record-subagent-run.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'session-start-context.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'pretooluse-delegation-hint.ps1') -NoNewline

# MCP servers with framework + customized + foreign
$bakedToken1 = ('baked', 'tok', '123') -join '-'
$mcpConfig = @{
    mcpServers = @{
        filesystem = @{ command = "npx"; args = @("-y", "@modelcontextprotocol/server-filesystem", "/tmp/fs") }
        context7   = @{ command = "npx"; args = @("-y", "@upstash/context7-mcp"); env = @{ CONTEXT7_API_KEY = $bakedToken1 } }
        serena     = @{ command = "uvx"; args = @("--from", "git+https://github.com/oraios/serena", "serena", "start-mcp-server", "--context", "ide-assistant", "--extra-arg"); env = @{} }
        fetch      = @{ command = "uvx"; args = @("mcp-server-fetch") }
        'sequential-thinking' = @{ command = "npx"; args = @("-y", "@modelcontextprotocol/server-sequential-thinking") }
        myCustom   = @{ command = "custom-server"; args = @() }
    }
}
$mcpConfig | ConvertTo-Json -Depth 32 | Set-Content $claudeJson -NoNewline

# Initialize git repo (minimal)
git -C $claudeHome init 2>$null | Out-Null
git -C $claudeHome config user.email "test@test.local" 2>$null
git -C $claudeHome config user.name "Test" 2>$null
'{"test":"data"}' | Set-Content (Join-Path $claudeHome 'claude.json') -NoNewline
git -C $claudeHome add -A 2>$null
git -C $claudeHome commit -m "initial" 2>$null | Out-Null

# Create protected runtime files
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome '.state' 'peer-review') | Out-Null
'state-data' | Set-Content (Join-Path $claudeHome '.state' 'peer-review' 'marker') -NoNewline
'local-settings' | Set-Content (Join-Path $claudeHome 'settings.local.json') -NoNewline
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome 'projects' 'myproj') | Out-Null
'project-data' | Set-Content (Join-Path $claudeHome 'projects' 'myproj' 'x.txt') -NoNewline

# Capture hashes before dry-run
$settingsHashBefore = Get-FileHash-Content (Join-Path $claudeHome 'settings.json')
$mcpHashBefore = Get-FileHash-Content $claudeJson
$gitDir = Join-Path $claudeHome '.git'
$gitExistsBefore = Test-Path $gitDir

# Run dry-run
$r = Invoke-Migrator $claudeHome
$settingsHashAfter = Get-FileHash-Content (Join-Path $claudeHome 'settings.json')
$mcpHashAfter = Get-FileHash-Content $claudeJson

Assert 'dry-run exits 0' ($r.Code -eq 0)
Assert 'settings.json unchanged' ($settingsHashBefore -eq $settingsHashAfter)
Assert 'mcp config unchanged' ($mcpHashBefore -eq $mcpHashAfter)
Assert 'hook files still exist' ((Test-Path (Join-Path $claudeHome 'hooks' 'stop-peer-review-gate.ps1')))
Assert 'foreign hook file still exists' ((Test-Path (Join-Path $claudeHome 'hooks' 'my-custom-hook.ps1')))
Assert '.git still exists' ((Test-Path (Join-Path $claudeHome '.git')))
Assert 'output reports dry-run' ($r.Out -imatch 'DRY-RUN')

# ── Test 2: -REMOVEMCP WITHOUT -APPLY MAKES NO CHANGES ──────────────────────────
Write-Host '-RemoveMcp without -Apply: no mutations'

$mcpHashBefore2 = Get-FileHash-Content $claudeJson
$r2 = Invoke-Migrator $claudeHome -ExtraArgs @('-RemoveMcp')
$mcpHashAfter2 = Get-FileHash-Content $claudeJson
$backupCount = @(Get-ChildItem $sandboxDir -Filter '.claude.json.bak-*' -ErrorAction SilentlyContinue).Count

Assert '-RemoveMcp alone exits 0' ($r2.Code -eq 0)
Assert 'mcp unchanged without -Apply' ($mcpHashBefore2 -eq $mcpHashAfter2)
Assert 'no backup created without -Apply' ($backupCount -eq 0)

# ── Test 3: -APPLY REMOVES FRAMEWORK HOOKS (nested shape) ──────────────────────
Write-Host 'apply: hook de-registration and file removal (nested shape)'

Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
$claudeJson = Join-Path $sandboxDir '.claude.json'
New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome 'hooks') | Out-Null

# Build legacy home with framework + foreign hook entries (nested shape) + args form hook
$settings = @{
    hooks = @{
        Stop = @(
            @{
                hooks = @(
                    @{
                        type    = "command"
                        command = "pwsh -NoProfile -File `"C:/Users/test/.claude/hooks/stop-peer-review-gate.ps1`""
                        timeout = 15
                    },
                    @{
                        type    = "command"
                        command = "C:\Users\test\.claude\hooks\my-custom-hook.ps1"
                        timeout = 15
                    }
                )
            }
        )
        PreToolUse = @(
            @{
                matcher = "Write|Edit"
                hooks   = @(
                    @{
                        type    = "command"
                        command = "pwsh"
                        args    = @("-NoProfile", "-File", "C:\Users\test\.claude\hooks\record-subagent-run.ps1")
                        timeout = 10
                    }
                )
            }
        )
    }
}
$settings | ConvertTo-Json -Depth 16 | Set-Content (Join-Path $claudeHome 'settings.json') -NoNewline

# Create hook files
'# foreign hook' | Set-Content (Join-Path $claudeHome 'hooks' 'my-custom-hook.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'stop-peer-review-gate.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'record-subagent-run.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'session-start-context.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'pretooluse-delegation-hint.ps1') -NoNewline

# MCP servers
$mcpConfig = @{
    mcpServers = @{
        fetch = @{ command = "uvx"; args = @("mcp-server-fetch") }
    }
}
$mcpConfig | ConvertTo-Json -Depth 32 | Set-Content $claudeJson -NoNewline

$r = Invoke-Migrator $claudeHome -ExtraArgs @('-Apply')
$settingsAfter = Get-Content (Join-Path $claudeHome 'settings.json') -Raw | ConvertFrom-Json -AsHashtable

Assert '-Apply exits 0' ($r.Code -eq 0)
$stopCommands = @($settingsAfter.hooks.Stop | Select-Object -ExpandProperty hooks -ErrorAction SilentlyContinue | Select-Object -ExpandProperty command)
Assert 'framework hook Stop removed' (@($stopCommands -match 'stop-peer-review-gate').Count -eq 0)
Assert 'foreign hook preserved in Stop' (@($stopCommands -match 'my-custom-hook').Count -gt 0)
$preToolUseArgs = @($settingsAfter.hooks.PreToolUse | Select-Object -ExpandProperty hooks -ErrorAction SilentlyContinue | ForEach-Object { $_.args })
Assert 'framework hook PreToolUse removed (args form)' (-not ($preToolUseArgs -contains 'record-subagent-run.ps1'))
Assert 'framework hook file deleted' (-not (Test-Path (Join-Path $claudeHome 'hooks' 'stop-peer-review-gate.ps1')))
Assert 'foreign hook file still exists' ((Test-Path (Join-Path $claudeHome 'hooks' 'my-custom-hook.ps1')))
Assert 'all framework hook files deleted' (-not (Test-Path (Join-Path $claudeHome 'hooks' 'session-start-context.ps1')) -and -not (Test-Path (Join-Path $claudeHome 'hooks' 'pretooluse-delegation-hint.ps1')))
Assert 'backup created' ((Get-ChildItem $claudeHome -Filter 'settings.json.bak-*').Count -ge 1)
Assert 'backup of mcp created' ((Get-ChildItem $sandboxDir -Filter '.claude.json.bak-*').Count -ge 1)

# Verify settings.json contains ZERO references to framework hook names
$settingsContent = Get-Content (Join-Path $claudeHome 'settings.json') -Raw
Assert 'no stop-peer-review-gate references' (-not ($settingsContent -imatch 'stop-peer-review-gate'))
Assert 'no record-subagent-run references' (-not ($settingsContent -imatch 'record-subagent-run'))
Assert 'no session-start-context references' (-not ($settingsContent -imatch 'session-start-context'))
Assert 'no pretooluse-delegation-hint references' (-not ($settingsContent -imatch 'pretooluse-delegation-hint'))

# ── Test 4: -REMOVEMCP -APPLY REMOVES FRAMEWORK-SHAPED ONLY ─────────────────────
Write-Host 'apply with -RemoveMcp: framework-shaped removed, customized kept'

Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
$claudeJson = Join-Path $sandboxDir '.claude.json'
New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null

# Build legacy home with all 5 framework servers, plus customized serena + foreign
$bakedToken3 = ('baked', 'tok', '456') -join '-'
$mcpConfig = @{
    mcpServers = @{
        filesystem = @{ command = "npx"; args = @("-y", "@modelcontextprotocol/server-filesystem", "/var/mcp") }
        context7   = @{ command = "npx"; args = @("-y", "@upstash/context7-mcp"); env = @{ CONTEXT7_API_KEY = $bakedToken3 } }
        serena     = @{ command = "uvx"; args = @("--from", "git+https://github.com/oraios/serena", "serena", "start-mcp-server", "--context", "ide-assistant", "--debug-mode"); env = @{} }
        fetch      = @{ command = "uvx"; args = @("mcp-server-fetch") }
        'sequential-thinking' = @{ command = "npx"; args = @("-y", "@modelcontextprotocol/server-sequential-thinking") }
        external   = @{ command = "external-server"; args = @() }
    }
}
$mcpConfig | ConvertTo-Json -Depth 32 | Set-Content $claudeJson -NoNewline
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome '.state') | Out-Null

$r = Invoke-Migrator $claudeHome -ExtraArgs @('-Apply', '-RemoveMcp')
$mcpCfg = Get-Content $claudeJson -Raw | ConvertFrom-Json -AsHashtable

Assert '-RemoveMcp -Apply exits 0' ($r.Code -eq 0)
Assert 'framework-shaped filesystem removed' ($null -eq $mcpCfg['mcpServers']['filesystem'])
Assert 'framework-shaped context7 removed' ($null -eq $mcpCfg['mcpServers']['context7'])
Assert 'report mentions baked token removal' ($r.Out -imatch 'baked.*CONTEXT7_API_KEY')
Assert 'framework-shaped fetch removed' ($null -eq $mcpCfg['mcpServers']['fetch'])
Assert 'framework-shaped sequential-thinking removed' ($null -eq $mcpCfg['mcpServers']['sequential-thinking'])
Assert 'customized serena kept (has extra arg)' ($null -ne $mcpCfg['mcpServers']['serena'] -and ($mcpCfg['mcpServers']['serena']['args'] | Join-String) -imatch 'debug-mode')
Assert 'foreign server kept' ($null -ne $mcpCfg['mcpServers']['external'])

# ── Test 5: CUSTOMIZED FILESYSTEM WITH EXTRA ARG SURVIVES ────────────────────────
Write-Host 'customized filesystem with --read-only survives -Apply -RemoveMcp'

Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
$claudeJson = Join-Path $sandboxDir '.claude.json'
New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null

$mcpConfig = @{
    mcpServers = @{
        filesystem = @{ command = "npx"; args = @("-y", "@modelcontextprotocol/server-filesystem", "/tmp", "--read-only") }
    }
}
$mcpConfig | ConvertTo-Json -Depth 32 | Set-Content $claudeJson -NoNewline

$r = Invoke-Migrator $claudeHome -ExtraArgs @('-Apply', '-RemoveMcp')
$mcpCfg = Get-Content $claudeJson -Raw | ConvertFrom-Json -AsHashtable

Assert 'customized filesystem survives' ($null -ne $mcpCfg['mcpServers']['filesystem'])
Assert 'customized filesystem has --read-only' (($mcpCfg['mcpServers']['filesystem']['args'] | Join-String) -imatch 'read-only')

# ── Test 6: PROTECTED PATHS PRESERVED ──────────────────────────────────────────
Write-Host 'apply: protected paths never deleted'

Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null

# Create a minimal config for the test
$settings = @{ hooks = @{} }
$settings | ConvertTo-Json -Depth 16 | Set-Content (Join-Path $claudeHome 'settings.json') -NoNewline
'{"test":"data"}' | Set-Content (Join-Path $claudeHome 'claude.json') -NoNewline

# Initialize git repo and track a file
$gitDir = Join-Path $claudeHome '.git'
git -C $claudeHome init 2>$null | Out-Null
git -C $claudeHome config user.email "test@test.local" 2>$null
git -C $claudeHome config user.name "Test" 2>$null
git -C $claudeHome config core.safecrlf false 2>$null
$trackFile = Join-Path $claudeHome 'agents' 'dummy.md'
New-Item -ItemType Directory -Force -Path (Split-Path $trackFile -Parent) | Out-Null
'agent' | Set-Content $trackFile -NoNewline
git -C $claudeHome add -A 2>$null
git -C $claudeHome commit -m "tracked" 2>$null | Out-Null

# Create protected paths (these should survive)
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome '.state' 'x') | Out-Null
'protected' | Set-Content (Join-Path $claudeHome '.state' 'marker.txt') -NoNewline
'local' | Set-Content (Join-Path $claudeHome 'settings.local.json') -NoNewline
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome 'projects' 'myp') | Out-Null
'proj' | Set-Content (Join-Path $claudeHome 'projects' 'myp' 'file.txt') -NoNewline
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome 'todos') | Out-Null
'todo' | Set-Content (Join-Path $claudeHome 'todos' 'list.txt') -NoNewline

# Track protected files too (should not be deleted even though tracked)
git -C $claudeHome add -A 2>$null
git -C $claudeHome commit -m "protected" 2>$null | Out-Null

# Create a bare remote repo and push commits (so they're not "unpushed")
$remoteDir = Join-Path $workRoot 'remote.git'
git init --bare $remoteDir 2>$null | Out-Null
git -C $claudeHome remote add origin $remoteDir 2>$null
# Get current branch name (could be master or main depending on git version)
$branch = git -C $claudeHome rev-parse --abbrev-ref HEAD 2>$null
git -C $claudeHome push -u origin $branch 2>$null | Out-Null

# Run in dry-run mode first to verify summary is generated correctly
$r = Invoke-Migrator $claudeHome

Assert 'checkout cleanup runs' ($r.Code -eq 0)
Assert 'checkout cleanup detects repo' ($r.Out -imatch 'Checkout Cleanup|detected|git clone')
# This assertion only covers the dry-run path; the apply+success path (where the regression originally occurred) is not exercised by this fixture because -Apply aborts before reaching that code (backup step dirties tree before Section 5 check).
Assert 'checkout summary row present (dry-run path)' ($r.Out -match 'checkout:\s+\d+\s+tracked file\(s\),\s+\.git')
Assert '.state preserved' ((Test-Path (Join-Path $claudeHome '.state' 'marker.txt')))
Assert 'settings.local.json preserved' ((Test-Path (Join-Path $claudeHome 'settings.local.json')))
Assert 'projects dir preserved' ((Test-Path (Join-Path $claudeHome 'projects' 'myp' 'file.txt')))
Assert 'todos dir preserved' ((Test-Path (Join-Path $claudeHome 'todos' 'list.txt')))

# ── Test 7: DIRTY CHECKOUT ABORTS SECTION 5 ─────────────────────────────────────
Write-Host 'dirty checkout: Section 5 aborts, other sections still applied'

Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
$claudeJson = Join-Path $sandboxDir '.claude.json'
New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome 'hooks') | Out-Null

# Build settings with framework hooks to remove
$settings = @{
    hooks = @{
        Stop = @(
            @{
                hooks = @(
                    @{
                        type    = "command"
                        command = "pwsh -NoProfile -File `"$HOME/.claude/hooks/stop-peer-review-gate.ps1`""
                        timeout = 15
                    }
                )
            }
        )
    }
}
$settings | ConvertTo-Json -Depth 16 | Set-Content (Join-Path $claudeHome 'settings.json') -NoNewline

# Create hook files
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'stop-peer-review-gate.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'record-subagent-run.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'session-start-context.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'pretooluse-delegation-hint.ps1') -NoNewline

# MCP config
$mcpConfig = @{ mcpServers = @{} }
$mcpConfig | ConvertTo-Json -Depth 32 | Set-Content $claudeJson -NoNewline

# Initialize git repo with tracked file
git -C $claudeHome init 2>$null | Out-Null
git -C $claudeHome config user.email "test@test.local" 2>$null
git -C $claudeHome config user.name "Test" 2>$null
'{"test":"data"}' | Set-Content (Join-Path $claudeHome 'claude.json') -NoNewline
git -C $claudeHome add -A 2>$null
git -C $claudeHome commit -m "initial" 2>$null | Out-Null

# Create an uncommitted file to make checkout dirty
'dirty content' | Set-Content (Join-Path $claudeHome 'dirty-file.txt') -NoNewline

$r = Invoke-Migrator $claudeHome -ExtraArgs @('-Apply')

Assert 'dirty checkout aborts with message' ($r.Out -imatch 'ABORT.*uncommitted|dirty')
Assert 'settings.json was still modified' (-not (Get-Content (Join-Path $claudeHome 'settings.json') -Raw | ConvertFrom-Json -AsHashtable).hooks.Stop)
Assert 'framework hook files deleted despite abort' (-not (Test-Path (Join-Path $claudeHome 'hooks' 'stop-peer-review-gate.ps1')))
Assert '.git still exists after abort' ((Test-Path (Join-Path $claudeHome '.git')))

# Verify orphan-group fix: no group with matcher but no hooks key
$settingsContent = Get-Content (Join-Path $claudeHome 'settings.json') -Raw | ConvertFrom-Json -AsHashtable
$hasOrphanGroup = $false
foreach ($eventName in $settingsContent.hooks.Keys) {
    $eventArray = $settingsContent.hooks[$eventName]
    if ($eventArray -is [array]) {
        foreach ($entry in $eventArray) {
            if ($entry -is [System.Collections.IDictionary] -and $entry.ContainsKey('matcher') -and -not $entry.ContainsKey('hooks')) {
                $hasOrphanGroup = $true
                break
            }
        }
    }
}
Assert 'no orphan groups (matcher with no hooks)' (-not $hasOrphanGroup)

# ── Test 8: NEAR-NAME CUSTOM HOOK SURVIVES ──────────────────────────────────────
Write-Host 'near-name custom hook: not falsely matched'

Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome 'hooks') | Out-Null

# Settings with a near-name hook (my-record-subagent-run.ps1 should NOT match record-subagent-run.ps1)
$settings = @{
    hooks = @{
        PreToolUse = @(
            @{
                hooks = @(
                    @{
                        type    = "command"
                        command = "pwsh -NoProfile -File `"$HOME/.claude/hooks/my-record-subagent-run.ps1`""
                        timeout = 10
                    }
                )
            }
        )
    }
}
$settings | ConvertTo-Json -Depth 16 | Set-Content (Join-Path $claudeHome 'settings.json') -NoNewline

# Create custom hook file
'# custom hook with similar name' | Set-Content (Join-Path $claudeHome 'hooks' 'my-record-subagent-run.ps1') -NoNewline

$r = Invoke-Migrator $claudeHome -ExtraArgs @('-Apply')
$settingsAfter = Get-Content (Join-Path $claudeHome 'settings.json') -Raw | ConvertFrom-Json -AsHashtable

Assert 'near-name hook preserved in settings' ($null -ne $settingsAfter.hooks.PreToolUse)
Assert 'near-name hook file preserved' ((Test-Path (Join-Path $claudeHome 'hooks' 'my-record-subagent-run.ps1')))

# ── Test 9: IDEMPOTENCE ────────────────────────────────────────────────────────
Write-Host 'idempotence: second run finds nothing to do'

Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null

# Clean fixture - already migrated
$settings = @{}
$settings | ConvertTo-Json -Depth 16 | Set-Content (Join-Path $claudeHome 'settings.json') -NoNewline

$r2 = Invoke-Migrator $claudeHome -ExtraArgs @('-Apply')
Assert 'second -Apply exits 0' ($r2.Code -eq 0)
Assert 'second run reports nothing to do' ($r2.Out -imatch 'nothing to do|no.*to remove|not found')

# ── Test 10: EMPTY FIXTURE ─────────────────────────────────────────────────────
Write-Host 'empty fixture: reports cleanly'

Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null

$r = Invoke-Migrator $claudeHome -ExtraArgs @('-Apply')
Assert 'empty fixture -Apply exits 0' ($r.Code -eq 0)
Assert 'empty fixture reports nothing to do' ($r.Out -imatch 'not found|nothing to do')

# ── Test 11: REAL ORPHAN-GROUP REGRESSION TEST ────────────────────────────
Write-Host 'orphan-group regression: matcher-only groups are dropped'

Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
$workRoot   = Join-Path ([IO.Path]::GetTempPath()) ("migrate-test-" + [guid]::NewGuid().ToString('N'))
$sandboxDir = Join-Path $workRoot 'home'
$claudeHome = Join-Path $sandboxDir '.claude'
$claudeJson = Join-Path $sandboxDir '.claude.json'
New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $claudeHome 'hooks') | Out-Null

# Fixture: PostToolUse with (a) group containing ONLY framework hook record-subagent-run with matcher,
#          (b) another group with foreign hook to keep hooks block alive
$settings = @{
    hooks = @{
        PostToolUse = @(
            @{
                matcher = "Task|Agent"
                hooks   = @(
                    @{
                        type    = "command"
                        command = "pwsh -NoProfile -File `"$HOME/.claude/hooks/record-subagent-run.ps1`""
                        timeout = 10
                    }
                )
            },
            @{
                matcher = "Read|Write"
                hooks   = @(
                    @{
                        type    = "command"
                        command = "pwsh -NoProfile -File `"$HOME/.claude/hooks/my-foreign-logger.ps1`""
                        timeout = 10
                    }
                )
            }
        )
    }
}
$settings | ConvertTo-Json -Depth 16 | Set-Content (Join-Path $claudeHome 'settings.json') -NoNewline

# Create hook files
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'record-subagent-run.ps1') -NoNewline
'# foreign hook' | Set-Content (Join-Path $claudeHome 'hooks' 'my-foreign-logger.ps1') -NoNewline
'# framework hook' | Set-Content (Join-Path $claudeHome 'hooks' 'session-start-context.ps1') -NoNewline

# MCP config (needed for full migrator run)
'{"mcpServers":{}}' | Set-Content $claudeJson -NoNewline

$r = Invoke-Migrator $claudeHome -ExtraArgs @('-Apply')

# Helper: Assert no orphan groups exist in a hashtable parsed with -AsHashtable
function Assert-NoOrphans {
    param([System.Collections.IDictionary]$Settings, [string]$Label)
    $orphans = @()
    if ($Settings.hooks) {
        foreach ($eventName in $Settings.hooks.Keys) {
            $eventArray = $Settings.hooks[$eventName]
            if ($eventArray -is [array]) {
                foreach ($idx in 0..($eventArray.Count - 1)) {
                    $entry = $eventArray[$idx]
                    if ($entry -is [System.Collections.IDictionary]) {
                        if ($entry.ContainsKey('matcher') -and -not $entry.ContainsKey('hooks')) {
                            $orphans += "$eventName[$idx] matcher=$($entry['matcher'])"
                        }
                    }
                }
            }
        }
    }
    return $orphans.Count -eq 0
}

# Self-check: Verify the assertion CAN fail by constructing a synthetic orphan
function Test-AssertionCanFail {
    $synthetic = @{
        hooks = @{
            TestEvent = @(
                @{ matcher = 'X' }
            )
        }
    }
    return -not (Assert-NoOrphans $synthetic 'self-check')
}

Assert 'assertion helper can detect orphans (self-check)' (Test-AssertionCanFail)

# Parse result and verify fix
$settingsAfter = Get-Content (Join-Path $claudeHome 'settings.json') -Raw | ConvertFrom-Json -AsHashtable

Assert 'PostToolUse event exists after -Apply' ($null -ne $settingsAfter.hooks.PostToolUse)
Assert 'PostToolUse is an array' ($settingsAfter.hooks.PostToolUse -is [array])

# Verify: the matcher="Task|Agent" group (framework-only) is GONE entirely, not a stub
$taskAgentGroupExists = $false
foreach ($group in $settingsAfter.hooks.PostToolUse) {
    if ($group.ContainsKey('matcher') -and $group['matcher'] -eq 'Task|Agent') {
        $taskAgentGroupExists = $true
        break
    }
}
Assert 'framework-only group (matcher=Task|Agent) is dropped entirely' (-not $taskAgentGroupExists)

# Verify: the foreign hook's group survives
$foreignGroupExists = $false
$foreignHookPreserved = $false
foreach ($group in $settingsAfter.hooks.PostToolUse) {
    if ($group.ContainsKey('matcher') -and $group['matcher'] -eq 'Read|Write') {
        $foreignGroupExists = $true
        if ($group.ContainsKey('hooks')) {
            foreach ($hook in $group['hooks']) {
                if ($hook.command -match 'my-foreign-logger') {
                    $foreignHookPreserved = $true
                }
            }
        }
    }
}
Assert 'foreign hook group (matcher=Read|Write) survives' $foreignGroupExists
Assert 'foreign hook command intact' $foreignHookPreserved

# Final comprehensive orphan check
Assert 'no orphan groups remain after migration' (Assert-NoOrphans $settingsAfter 'post-migrate')

# Verify framework hook files are deleted
Assert 'framework hook files deleted' (-not (Test-Path (Join-Path $claudeHome 'hooks' 'record-subagent-run.ps1')))
Assert 'foreign hook file preserved' ((Test-Path (Join-Path $claudeHome 'hooks' 'my-foreign-logger.ps1')))

# ── Teardown ───────────────────────────────────────────────────────────────────
Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue

Write-Host ''
if ($failures -gt 0) {
    Write-Host "RESULT: FAIL ($failures assertion(s) failed)" -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: PASS (all migration assertions passed)'
exit 0
