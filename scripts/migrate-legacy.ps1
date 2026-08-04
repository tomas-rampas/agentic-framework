#Requires -Version 7.3
<#
.SYNOPSIS
  Migrates legacy framework installs to the plugin pipeline.

.DESCRIPTION
  Removes legacy hook registrations and hook script files, optionally cleans up
  user-scope MCP servers, and removes git-tracked files if ~/.claude is this
  repository clone. Protected runtime paths are preserved. By default runs as
  dry-run (no changes); pass -Apply to make changes.

.PARAMETER Apply
  Switch: perform destructive changes (backups, removals). Dry-run if not set.

.PARAMETER RemoveMcp
  Switch: remove framework-shaped MCP servers from user-scope ~/.claude.json.
  Requires explicit consent due to destructive nature.

.PARAMETER ClaudeHome
  Path to the Claude Code config directory (default: ~/.claude). Enables
  sandbox testing.

.EXAMPLE
  pwsh -NoProfile -File scripts/migrate-legacy.ps1
  pwsh -NoProfile -File scripts/migrate-legacy.ps1 -Apply -RemoveMcp
#>
param(
    [switch]$Apply,
    [switch]$RemoveMcp,
    [string]$ClaudeHome = (Join-Path $HOME '.claude')
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$claudeHome = $ClaudeHome
$claudeJsonPath = Join-Path (Split-Path $claudeHome -Parent) '.claude.json'

# ── Helpers ────────────────────────────────────────────────────────────────────

function Get-CanonJson($node) {
    if ($null -eq $node) { return 'null' }
    if ($node -is [System.Collections.IDictionary]) {
        $parts = @($node.Keys) | Sort-Object | ForEach-Object {
            (ConvertTo-Json ([string]$_) -Compress) + ':' + (Get-CanonJson $node[$_])
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($node -is [System.Management.Automation.PSCustomObject]) {
        $parts = $node.PSObject.Properties | Sort-Object Name | ForEach-Object {
            (ConvertTo-Json $_.Name -Compress) + ':' + (Get-CanonJson $_.Value)
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
        $parts = @($node) | ForEach-Object { Get-CanonJson $_ }
        return '[' + ($parts -join ',') + ']'
    }
    return (ConvertTo-Json $node -Compress -Depth 2)
}

# Framework hook script names to remove
$frameworkHookNames = @(
    'stop-peer-review-gate.ps1',
    'record-subagent-run.ps1',
    'session-start-context.ps1',
    'pretooluse-delegation-hint.ps1'
)

# Framework MCP server names
$frameworkMcpNames = @(
    'filesystem',
    'context7',
    'serena',
    'sequential-thinking',
    'fetch'
)

# Protected runtime paths (never delete these)
$protectedPaths = @(
    'CLAUDE.md',
    '.state',
    'settings.local.json',
    '.credentials.json',
    'settings.json',
    '.claude.json',
    'projects',
    'todos',
    'memory',
    'statsig',
    'ide',
    'shell-snapshots',
    'plugins',
    'backup'
)

# Test if a server definition is framework-shaped
# Framework-shaped: exactly the shipped command and args (directory/path values may differ)
function Test-FrameworkShapedServer([string]$name, $serverDef) {
    $shapeMap = @{
        'filesystem' = @{
            'command' = 'npx'
            'expectedArgs' = @('-y', '@modelcontextprotocol/server-filesystem')
            'varArgIndex' = 2  # third arg is a variable path (exactly one variable arg, so total count = 3)
        }
        'context7' = @{
            'command' = 'npx'
            'expectedArgs' = @('-y', '@upstash/context7-mcp')
            'exactArgCount' = 2  # no variable args; must be exactly 2
        }
        'serena' = @{
            'command' = 'uvx'
            'expectedArgs' = @('--from', 'git+https://github.com/oraios/serena', 'serena', 'start-mcp-server', '--context', 'ide-assistant')
            'exactArgCount' = 6  # no variable args; must be exactly 6
        }
        'sequential-thinking' = @{
            'command' = 'npx'
            'expectedArgs' = @('-y', '@modelcontextprotocol/server-sequential-thinking')
            'exactArgCount' = 2  # no variable args; must be exactly 2
        }
        'fetch' = @{
            'command' = 'uvx'
            'expectedArgs' = @('mcp-server-fetch')
            'exactArgCount' = 1  # no variable args; must be exactly 1
        }
    }

    if (-not $shapeMap.Contains($name)) { return $false }
    $shape = $shapeMap[$name]

    # Check command
    if ($serverDef -is [System.Collections.IDictionary]) {
        if ([string]$serverDef['command'] -ne $shape['command']) { return $false }
        if (-not $serverDef.Contains('args')) {
            $argVals = @()
        } else {
            $argsVal = $serverDef['args']
            # Handle string vs array args
            if ($argsVal -is [string]) {
                $argVals = @($argsVal)
            } elseif ($argsVal -is [System.Collections.IEnumerable]) {
                $argVals = @($argsVal)
            } else {
                $argVals = @($argsVal)
            }
        }
    } else {
        return $false
    }

    # Compare args: must match expected args exactly, except for variable arg positions
    $expectedArgs = $shape['expectedArgs']

    # Check if there's a varArgIndex (filesystem has one at index 2, meaning exactly 3 args total)
    if ($shape.Contains('varArgIndex')) {
        $varArgIndex = $shape['varArgIndex']
        # filesystem: exactly 3 args (indices 0, 1, 2)
        if ($argVals.Count -ne $varArgIndex + 1) {
            return $false
        }
        for ($i = 0; $i -lt $expectedArgs.Count; $i++) {
            if ($i -eq $varArgIndex) {
                # Variable arg position - any value is OK
                continue
            }
            if ([string]$argVals[$i] -ne [string]$expectedArgs[$i]) {
                return $false
            }
        }
    } else {
        # No variable args - must match exactly
        $exactCount = $shape['exactArgCount']
        if ($argVals.Count -ne $exactCount) {
            return $false
        }
        for ($i = 0; $i -lt $expectedArgs.Count; $i++) {
            if ([string]$argVals[$i] -ne [string]$expectedArgs[$i]) {
                return $false
            }
        }
    }

    return $true
}

$summary = [ordered]@{}

Write-Host ''
Write-Host '╔════════════════════════════════════════════════════════════════════╗'
Write-Host '║           LEGACY FRAMEWORK INSTALL MIGRATION                       ║'
Write-Host '╚════════════════════════════════════════════════════════════════════╝'
Write-Host ''
Write-Host "Claude home    : $claudeHome"
Write-Host "Claude config  : $claudeJsonPath"
Write-Host "Mode           : $(if ($Apply) { 'APPLY (making changes)' } else { 'DRY-RUN (reporting only)' })"
Write-Host ''

# Paths (repo-relative, forward-slash) that THIS run created or deleted. Section 5's
# dirtiness guard excludes them so it never aborts on damage this script itself caused,
# while still detecting genuine pre-existing or concurrent modifications.
$exitCode = 0
$selfTouchedPaths = [System.Collections.Generic.HashSet[string]]::new()

# COUPLING: this is called only at mutation sites whose target is NOT already protected
# (protected paths are excluded from the dirt filter anyway, so registering them is moot).
# Any future code that creates or deletes a NON-protected path under $claudeHome before
# Section 5 runs MUST register it here, or the guard will abort on its own handiwork.
function Add-SelfTouchedPath([string]$fullPath) {
    $rel = [System.IO.Path]::GetRelativePath($claudeHome, $fullPath)
    [void]$selfTouchedPaths.Add(($rel -replace '\\', '/').ToLowerInvariant())
}

# Shared matcher: is a repo-relative path inside the protected set?
function Test-ProtectedPath([string]$relPath) {
    foreach ($protected in $protectedPaths) {
        if ($relPath -ieq $protected -or $relPath -imatch "^$([regex]::Escape($protected))[/\\]") {
            return $true
        }
    }
    return $false
}

# ── 1. BACKUPS ─────────────────────────────────────────────────────────────────
if ($Apply) {
    Write-Host '== Backups =='
    $backupsCreated = 0

    $settingsPath = Join-Path $claudeHome 'settings.json'
    if (Test-Path $settingsPath) {
        $backup = "$settingsPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $settingsPath $backup -Force
        Add-SelfTouchedPath $backup
        Write-Host "  settings.json: $backup"
        $backupsCreated++
    }

    if (Test-Path $claudeJsonPath) {
        $backup = "$claudeJsonPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $claudeJsonPath $backup -Force
        Write-Host "  .claude.json:  $backup"
        $backupsCreated++
    }

    if ($backupsCreated -eq 0) {
        Write-Host '  (no config files to back up)'
    }
    $summary['backups'] = "$backupsCreated file(s)"
} else {
    $summary['backups'] = '(dry-run: none created)'
}

# ── 2. HOOK DE-REGISTRATION ────────────────────────────────────────────────────
Write-Host ''
Write-Host '== Hook De-registration =='
$settingsPath = Join-Path $claudeHome 'settings.json'
if (-not (Test-Path $settingsPath)) {
    Write-Host '  settings.json not found - nothing to do'
    $summary['hooks'] = 'not found'
} else {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $settings.ContainsKey('hooks')) {
        Write-Host '  no hooks block - nothing to do'
        $summary['hooks'] = 'no hooks block'
    } else {
        $removed = 0
        $preserved = 0
        $hooksBlockChanged = $false

        # Iterate through hook events and clean up entries
        # Handle both nested shape (event -> array of groups -> hooks array) and flat shape (event -> array of commands)
        $hookEvents = @($settings['hooks'].Keys)
        $eventsToRemove = @()

        foreach ($eventName in $hookEvents) {
            $eventArray = @($settings['hooks'][$eventName])
            $filteredEventArray = @()

            foreach ($groupEntry in $eventArray) {
                # Determine if this is a nested group (has 'hooks' key) or flat command
                $isNestedGroup = $groupEntry -is [System.Collections.IDictionary] -and $groupEntry.ContainsKey('hooks')

                if ($isNestedGroup) {
                    # Nested shape: group with inner hooks array
                    $innerHooks = @($groupEntry['hooks'])
                    $filteredInnerHooks = @()

                    foreach ($hook in $innerHooks) {
                        # Collect candidate strings from .command and .args[]
                        $candidates = @()
                        if ($hook -is [System.Collections.IDictionary]) {
                            if ($hook.ContainsKey('command')) {
                                $candidates += [string]$hook['command']
                            }
                            if ($hook.ContainsKey('args') -and $hook['args'] -is [System.Collections.IEnumerable]) {
                                $candidates += @($hook['args'])
                            }
                        }

                        # Check if any candidate ends with a framework hook filename
                        $isFrameworkHook = $false
                        foreach ($candidate in $candidates) {
                            $candStr = [string]$candidate
                            foreach ($hookName in $frameworkHookNames) {
                                # Match if candidate contains (path_sep + name) or starts with name
                                # Handle quoted paths like "C:\...\stop-peer-review-gate.ps1"
                                if ($candStr -imatch [regex]::Escape($hookName)) {
                                    # Further validation: must have path separator before it or be at start
                                    # and must be near the end (accounting for trailing quotes)
                                    $pattern = "(^|[/\\])$([regex]::Escape($hookName))([`"'])?$"
                                    if ($candStr -imatch $pattern) {
                                        $isFrameworkHook = $true
                                        Write-Host "  removed: $eventName -> $hookName"
                                        $removed++
                                        $hooksBlockChanged = $true
                                        break
                                    }
                                }
                            }
                            if ($isFrameworkHook) { break }
                        }

                        if (-not $isFrameworkHook) {
                            $filteredInnerHooks += $hook
                            $preserved++
                        }
                    }

                    # Update or prune the inner hooks array
                    if ($filteredInnerHooks.Count -eq 0) {
                        # Drop the entire group from the event array if its hooks array is empty
                        # (a matcher with no hooks is dead weight)
                    } else {
                        $groupEntry['hooks'] = @($filteredInnerHooks)
                        $filteredEventArray += $groupEntry
                    }
                } else {
                    # Flat shape (old style): entry is directly a command string or simple object
                    $cmd = if ($groupEntry -is [System.Collections.IDictionary] -and $groupEntry.ContainsKey('command')) {
                        [string]$groupEntry['command']
                    } else {
                        [string]$groupEntry
                    }

                    $isFrameworkHook = $false
                    foreach ($hookName in $frameworkHookNames) {
                        # Match if command contains (path_sep + name) or starts with name, near the end
                        $pattern = "(^|[/\\])$([regex]::Escape($hookName))([`"'])?$"
                        if ($cmd -imatch $pattern) {
                            $isFrameworkHook = $true
                            Write-Host "  removed: $eventName -> $hookName"
                            $removed++
                            $hooksBlockChanged = $true
                            break
                        }
                    }

                    if (-not $isFrameworkHook) {
                        $filteredEventArray += $groupEntry
                        $preserved++
                    }
                }
            }

            # Update or prune the event array
            if ($filteredEventArray.Count -eq 0) {
                $eventsToRemove += $eventName
                $hooksBlockChanged = $true
            } else {
                $settings['hooks'][$eventName] = @($filteredEventArray)
            }
        }

        # Remove empty events
        foreach ($eventName in $eventsToRemove) {
            $settings['hooks'].Remove($eventName)
        }

        # Remove empty hooks block
        if ($settings['hooks'].Count -eq 0) {
            $settings.Remove('hooks')
            $hooksBlockChanged = $true
        }

        # Write changes (only with -Apply)
        if ($hooksBlockChanged) {
            if ($Apply) {
                # Atomic write with round-trip verification
                $tmp = "$settingsPath.tmp-$PID"
                try {
                    $settings | ConvertTo-Json -Depth 64 | Set-Content -Path $tmp -NoNewline
                    $reparsed = Get-Content $tmp -Raw | ConvertFrom-Json -AsHashtable
                    if ((Get-CanonJson $reparsed) -ne (Get-CanonJson $settings)) {
                        throw "Round-trip verification failed for $settingsPath - original left untouched."
                    }
                    Move-Item $tmp $settingsPath -Force
                    Write-Host "  wrote settings.json"
                } finally {
                    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
                }
            } else {
                Write-Host "  (dry-run: would write settings.json)"
            }
        }

        $summary['hooks'] = "$removed removed, $preserved preserved"
    }
}

# ── 3. HOOK FILE REMOVAL ───────────────────────────────────────────────────────
Write-Host ''
Write-Host '== Hook File Removal =='
$hooksDir = Join-Path $claudeHome 'hooks'
$filesDeleted = 0
foreach ($hookName in $frameworkHookNames) {
    $hookPath = Join-Path $hooksDir $hookName
    if (Test-Path $hookPath) {
        if ($Apply) {
            Remove-Item $hookPath -Force
            Add-SelfTouchedPath $hookPath
            Write-Host "  deleted: $hookName"
        } else {
            Write-Host "  (dry-run: would delete $hookName)"
        }
        $filesDeleted++
    }
}
if ($filesDeleted -eq 0) {
    Write-Host '  (no framework hook files found)'
}
$summary['hook files'] = "$filesDeleted deleted"

# ── 4. MCP CLEANUP ─────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== MCP Server Cleanup =='
if ($RemoveMcp) {
    if (-not (Test-Path $claudeJsonPath)) {
        Write-Host '  .claude.json not found - nothing to do'
        $summary['mcp'] = 'config missing'
    } else {
        $userConfig = $null
        $mcpOk = $true
        try {
            $userConfig = Get-Content $claudeJsonPath -Raw | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Warning "  .claude.json exists but is not valid JSON - MCP step skipped, file untouched."
            $summary['mcp'] = 'skipped (unparseable)'
            $mcpOk = $false
        }

        if ($mcpOk -and ($null -eq $userConfig['mcpServers'] -or -not ($userConfig['mcpServers'] -is [System.Collections.IDictionary]))) {
            Write-Host '  no mcpServers block - nothing to do'
            $summary['mcp'] = 'no servers'
        } elseif ($mcpOk) {
            $frameworkRemoved = 0
            $customizedKept = 0
            $foreignKept = 0
            $serversToRemove = @()

            foreach ($serverName in $frameworkMcpNames) {
                # Case-insensitive match
                $userKey = @($userConfig['mcpServers'].Keys) | Where-Object { [string]$_ -ieq $serverName } | Select-Object -First 1
                if ($null -ne $userKey) {
                    $serverDef = $userConfig['mcpServers'][$userKey]

                    # Determine if framework-shaped vs customized
                    $isFrameworkShaped = Test-FrameworkShapedServer $serverName $serverDef

                    if ($isFrameworkShaped) {
                        $serversToRemove += $userKey
                        Write-Host "  removed: $userKey (framework-shaped)"

                        # Note if it had baked tokens
                        if ($serverDef -is [System.Collections.IDictionary] -and $serverDef['env']) {
                            foreach ($envKey in $serverDef['env'].Keys) {
                                if ($envKey -ieq 'CONTEXT7_API_KEY' -and $serverDef['env'][$envKey]) {
                                    Write-Host "           (baked CONTEXT7_API_KEY token was removed)"
                                }
                            }
                        }
                        $frameworkRemoved++
                    } else {
                        Write-Host "  kept: $userKey (customized)"
                        $customizedKept++
                    }
                }
            }

            # Count foreign servers (not in framework list)
            foreach ($userServerName in $userConfig['mcpServers'].Keys) {
                if (@($frameworkMcpNames) -inotcontains $userServerName) {
                    $foreignKept++
                }
            }
            if ($foreignKept -gt 0) {
                Write-Host "  kept: $foreignKept non-framework server(s)"
            }

            # Remove framework-shaped servers (only with -Apply)
            if ($serversToRemove.Count -gt 0) {
                if ($Apply) {
                    foreach ($key in $serversToRemove) {
                        $userConfig['mcpServers'].Remove($key)
                    }

                    # Atomic write
                    $tmp = "$claudeJsonPath.tmp-$PID"
                    try {
                        $userConfig | ConvertTo-Json -Depth 100 | Set-Content -Path $tmp -NoNewline
                        $reparsed = Get-Content $tmp -Raw | ConvertFrom-Json -AsHashtable
                        if ((Get-CanonJson $reparsed) -ne (Get-CanonJson $userConfig)) {
                            throw "Round-trip verification failed for $claudeJsonPath - original left untouched."
                        }
                        Move-Item $tmp $claudeJsonPath -Force
                        Write-Host "  wrote .claude.json"
                    } finally {
                        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
                    }
                } else {
                    Write-Host "  (dry-run: would remove $($serversToRemove.Count) server(s))"
                }
            } else {
                Write-Host '  nothing to remove'
            }

            $summary['mcp'] = "$frameworkRemoved removed, $customizedKept customized kept, $foreignKept foreign kept"
        }
    }
} else {
    # Report what would be removed
    if (-not (Test-Path $claudeJsonPath)) {
        Write-Host '  (dry-run: no .claude.json to check)'
        $summary['mcp'] = 'not checked (use -RemoveMcp)'
    } else {
        $userConfig = $null
        try {
            $userConfig = Get-Content $claudeJsonPath -Raw | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Host '  (dry-run: .claude.json unparseable)'
            $summary['mcp'] = 'unparseable (skip with -RemoveMcp)'
        }

        if ($userConfig -and ($null -ne $userConfig['mcpServers'] -and $userConfig['mcpServers'] -is [System.Collections.IDictionary])) {
            $wouldRemove = @()
            foreach ($serverName in $frameworkMcpNames) {
                $userKey = @($userConfig['mcpServers'].Keys) | Where-Object { [string]$_ -ieq $serverName } | Select-Object -First 1
                if ($null -ne $userKey) {
                    $serverDef = $userConfig['mcpServers'][$userKey]
                    if (Test-FrameworkShapedServer $serverName $serverDef) {
                        $wouldRemove += $userKey
                    }
                }
            }
            if ($wouldRemove.Count -gt 0) {
                Write-Host "  (dry-run: -RemoveMcp would remove: $($wouldRemove -join ', '))"
                $summary['mcp'] = "would remove $($wouldRemove.Count) server(s) (use -RemoveMcp)"
            } else {
                Write-Host '  (dry-run: no framework-shaped servers to remove)'
                $summary['mcp'] = 'none to remove (use -RemoveMcp if needed)'
            }
        }
    }
}

# ── 5. CHECKOUT CLEANUP ────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== Checkout Cleanup =='
$gitDir = Join-Path $claudeHome '.git'
$claudeJsonInHome = Join-Path $claudeHome 'claude.json'
if ((Test-Path $gitDir) -and (Test-Path $claudeJsonInHome)) {
    Write-Host '  detected: ~/.claude is a git clone'

    # Get tracked files (read-only)
    $trackedFiles = @()
    try {
        $output = git -C $claudeHome ls-files 2>$null
        if ($LASTEXITCODE -eq 0) {
            $trackedFiles = @($output | Where-Object { $_ })
        }
    } catch {
        # Git failed; proceed with empty tracked files list
    }

    $fileCount = $trackedFiles.Count

    if ($fileCount -eq 0) {
        Write-Host '  (no tracked files found)'
        $summary['checkout'] = 'no tracked files'
    } else {
        # Check for dirty working tree or unpushed commits before allowing cleanup
        $checkoutCanProceed = $true
        $checkoutAbortReason = ''

        if ($Apply) {
            # Live dirtiness check, filtered before evaluation. Two classes of noise are
            # excluded so they never abort the run:
            #   (a) protected paths - cleanup never touches them, so dirt there is harmless
            #       (a locally-modified CLAUDE.md is the common personalization);
            #   (b) paths this run itself created or deleted (tracked in $selfTouchedPaths).
            # Anything left is genuine pre-existing or concurrent modification -> abort.
            # -c core.quotepath=false: emit non-ASCII paths literally instead of octal-escaped,
            # so path matching below cannot be bypassed by encoding.
            $statusOutput = @(git -C $claudeHome -c core.quotepath=false status --porcelain 2>$null)
            if ($LASTEXITCODE -eq 0 -and $statusOutput) {
                $genuineDirt = @()
                foreach ($line in $statusOutput) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    # Porcelain v1: "XY <path>" ; renames/copies: "XY <old> -> <new>"
                    $entry = if ($line.Length -gt 3) { $line.Substring(3) } else { '' }
                    if ($entry -match '\s->\s') { $entry = ($entry -split '\s->\s', 2)[-1] }
                    $entry = $entry.Trim().Trim('"')
                    if (-not $entry) { continue }
                    $norm = ($entry -replace '\\', '/').TrimEnd('/')
                    if (Test-ProtectedPath $norm) { continue }
                    if ($selfTouchedPaths.Contains($norm.ToLowerInvariant())) { continue }
                    $genuineDirt += $norm
                }
                if ($genuineDirt.Count -gt 0) {
                    $checkoutCanProceed = $false
                    $checkoutAbortReason = 'uncommitted changes'
                    Write-Host "  dirty (unexpected): $(($genuineDirt | Select-Object -First 5) -join ', ')"
                }
            }

            # Check for unpushed commits
            if ($checkoutCanProceed) {
                $unpushedOutput = git -C $claudeHome log --branches --not --remotes --oneline 2>$null
                if ($LASTEXITCODE -eq 0 -and $unpushedOutput) {
                    $checkoutCanProceed = $false
                    $checkoutAbortReason = 'unpushed commits'
                }
            }

            if (-not $checkoutCanProceed) {
                Write-Host "  ABORT: Cannot proceed - $checkoutAbortReason in ~/.claude"
                Write-Host "  Please commit or stash your work, and push any pending commits before running migration again."
                Write-Warning "Checkout cleanup was SKIPPED ($checkoutAbortReason in $claudeHome). Migration is INCOMPLETE - exiting with code 2."
                $summary['checkout'] = "aborted ($checkoutAbortReason)"
                $exitCode = 2
            }
        }

        # Filter out protected paths. Same matcher as the dirt filter above: the guard is
        # only sound while {paths the dirt filter ignores} is a subset of {paths this
        # filter protects}, so both must go through Test-ProtectedPath.
        # git ls-files emits forward-slashed, repo-relative paths already.
        $filesToDelete = @()
        foreach ($file in $trackedFiles) {
            if (-not (Test-ProtectedPath (($file -replace '\\', '/').TrimEnd('/')))) {
                $filesToDelete += $file
            }
        }

        if ($Apply -and $checkoutCanProceed) {
            # Delete tracked files
            foreach ($file in $filesToDelete) {
                $path = Join-Path $claudeHome $file
                if (Test-Path $path) {
                    Remove-Item $path -Force -ErrorAction SilentlyContinue
                }
            }

            # Prune empty directories (exclude protected and reparse points)
            $dirs = Get-ChildItem $claudeHome -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) } |
                Sort-Object -Property FullName -Descending
            foreach ($dir in $dirs) {
                # GetRelativePath returns backslashed segments on Windows; normalize to the
                # forward-slash convention Test-ProtectedPath is fed everywhere else.
                $relPath = [System.IO.Path]::GetRelativePath($claudeHome, $dir.FullName)
                $relPath = ($relPath -replace '\\', '/').TrimEnd('/')
                $isProtected = Test-ProtectedPath $relPath
                if (-not $isProtected -and (Test-Path $dir) -and @(Get-ChildItem $dir -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item $dir -Force -ErrorAction SilentlyContinue
                }
            }

            # Delete .git
            if (Test-Path $gitDir) {
                Remove-Item $gitDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            Write-Host "  deleted $($filesToDelete.Count) tracked file(s) and .git directory"
        } elseif (-not $Apply) {
            # Dry-run: show first 20 files
            $display = $filesToDelete | Select-Object -First 20
            Write-Host "  (dry-run: would delete $($filesToDelete.Count) tracked file(s)):"
            foreach ($file in $display) {
                Write-Host "    $file"
            }
            if ($filesToDelete.Count -gt 20) {
                Write-Host "    ... and $($filesToDelete.Count - 20) more"
            }
        }
        # Only update summary if checkout didn't abort (preserve abort message)
        if ($checkoutCanProceed) {
            $summary['checkout'] = "$fileCount tracked file(s), .git"
        }
        # If Apply but not checkoutCanProceed: abort message already printed, don't print anything else
    }
} else {
    Write-Host '  ~/.claude is not a git clone - nothing to do'
    $summary['checkout'] = 'not a clone'
}

# ── 6. NEXT STEPS ──────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== Next Steps =='
Write-Host '  1. /plugin marketplace add tomas-rampas/agentic-framework'
Write-Host '  2. /plugin install agentic-framework@agentic-framework'
Write-Host '  3. (optional) /plugin install agentic-framework-mcp@agentic-framework'
Write-Host '  4. (optional) /agentic-framework-mcp:setup'
Write-Host '  5. Restart Claude Code'

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '== Summary =='
foreach ($k in $summary.Keys) { Write-Host ("  {0,-15} {1}" -f "$($k):", $summary[$k]) }
Write-Host ''
if ($exitCode -eq 0) {
    Write-Host 'Migration complete.'
} else {
    Write-Host 'Migration INCOMPLETE - see warnings above.'
}
Write-Host ''
exit $exitCode
