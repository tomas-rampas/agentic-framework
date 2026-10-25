#Requires -Version 7.0
<#
.SYNOPSIS
Removes the legacy framework policy block from the user-level CLAUDE.md (REQ-013).

.DESCRIPTION
Since 5.2.0 the plugin delivers the policy at session start (hooks/session-start-context),
so the copy in ~/.claude/CLAUDE.md is redundant. The block starts at the first line
"# Claude Code CLI - Agent Execution Framework" and ends before the next line starting
with "# " that is not part of a shipped policy text. Every byte outside the block, line
endings included, is preserved. A copy is written beside the file as
CLAUDE.md.bak-<yyyyMMdd-HHmmss> before anything changes. Equivalent to
migrate-global-claude-md.sh.

Exit codes: 0 migrated, dry run, or nothing to do (idempotent); 2 usage or file error;
3 refused because the block holds non-blank lines found in none of the bundled reference
policies (scripts/legacy-policy/*.md): the differing lines are printed, nothing is
changed and no backup is written.

.PARAMETER Path
File to migrate. Default: ~/.claude/CLAUDE.md.

.PARAMETER DryRun
Print the lines that would be removed and change nothing.

.EXAMPLE
pwsh -NoProfile -File scripts/migrate-global-claude-md.ps1 -DryRun
#>
[CmdletBinding()]
param(
    # Home folder as Node's os.homedir() resolves it: USERPROFILE on Windows, HOME elsewhere, then $HOME.
    [string]$Path = $(
        $h = if ($IsWindows) { $env:USERPROFILE } else { $env:HOME }
        if ([string]::IsNullOrEmpty($h)) { $h = $HOME }
        [System.IO.Path]::Combine($h, '.claude/CLAUDE.md')
    ),
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$title = '# Claude Code CLI - Agent Execution Framework'
# Latin1 maps bytes to chars one to one, so reading and writing never alters a byte.
# Files are read as raw bytes through GetString: ReadAllText would sniff a BOM and decode
# in another encoding. A UTF-8 BOM at the start of the target is outside the block: it is
# ignored for the title comparison and kept in the output.
$latin1 = [System.Text.Encoding]::Latin1
$utf8 = [System.Text.UTF8Encoding]::new($false)
$bom = [string]([char]0xEF) + [char]0xBB + [char]0xBF

function Read-Segment {
    # Splits raw text into segments that keep their own line terminator.
    param([string]$Text)
    if ($Text.Length -eq 0) { return , @() }
    return , @([regex]::Split($Text, '(?<=\n)') | Where-Object { $_.Length -gt 0 })
}

function ConvertTo-Display {
    param([string]$Latin1Text)
    return $utf8.GetString($latin1.GetBytes($Latin1Text))
}

function Get-LineText {
    param([string]$Segment)
    # Exactly one LF, then exactly one CR (as the .sh twin's sub(/\r$/, "")).
    $t = $Segment
    if ($t.EndsWith("`n", [System.StringComparison]::Ordinal)) { $t = $t.Substring(0, $t.Length - 1) }
    if ($t.EndsWith("`r", [System.StringComparison]::Ordinal)) { $t = $t.Substring(0, $t.Length - 1) }
    return $t
}

if ($Rest -and $Rest.Count -gt 0) {
    [Console]::Error.WriteLine("migrate-global-claude-md: unexpected argument: $($Rest -join ' ')")
    exit 2
}
# -Path is a filesystem path, never a PSPath: a name such as awk::start=3/CLAUDE.md must
# not parse as a provider-qualified path. A relative path is anchored at the PowerShell
# location (the .NET current directory can differ); ~ is not expanded (the default is
# absolute; pass an absolute or cwd-relative path).
if ([System.IO.Path]::IsPathRooted($Path)) {
    $Path = [System.IO.Path]::GetFullPath($Path)
} else {
    $Path = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $Path))
}
if (-not [System.IO.File]::Exists($Path)) {
    [Console]::Error.WriteLine("migrate-global-claude-md: file not found: $Path")
    exit 2
}
$refDir = Join-Path $PSScriptRoot 'legacy-policy'
$refFiles = @(Get-ChildItem -LiteralPath $refDir -Filter 'claude-md-v*.md' -File -ErrorAction SilentlyContinue)
if ($refFiles.Count -eq 0) {
    [Console]::Error.WriteLine("migrate-global-claude-md: no reference policies in $refDir")
    exit 2
}

# The installed plugin (what sessions run) must carry POLICY.md (5.2.0 or later).
$pluginId = 'agentic-framework@agentic-framework'
$installPath = $null
$installedJson = '<unresolved home folder>'
$hasPolicy = $false
# Everything that can throw (null home, unmapped drive, bad JSON) stays inside the try:
# a failure only produces the warning, never an exit.
try {
    $userHome = if ($IsWindows) { $env:USERPROFILE } else { $env:HOME }
    if ([string]::IsNullOrEmpty($userHome)) { $userHome = $HOME }
    $installedJson = [System.IO.Path]::Combine($userHome, '.claude/plugins/installed_plugins.json')
    $inst = [System.IO.File]::ReadAllText($installedJson) | ConvertFrom-Json -AsHashtable
    $entries = @($inst['plugins'][$pluginId])
    # Prefer the user-scope entry: a project-scope install can be listed first.
    $chosen = @($entries | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['scope'] -eq 'user' }) + $entries | Select-Object -First 1
    $installPath = [string]$chosen['installPath']
    $hasPolicy = [System.IO.File]::Exists([System.IO.Path]::Combine($installPath, 'POLICY.md'))
} catch { $hasPolicy = $false }
if ([string]::IsNullOrEmpty($installPath) -or -not $hasPolicy) {
    $shown = if ($installPath) { $installPath } else { "<not found in $installedJson>" }
    [Console]::Error.WriteLine("migrate-global-claude-md: warning: the installed agentic-framework plugin at $shown has no POLICY.md; sessions get no policy until the plugin is updated to 5.2.0 or later")
}
if (-not [System.IO.File]::Exists((Join-Path $PSScriptRoot '../POLICY.md'))) {
    [Console]::Error.WriteLine("migrate-global-claude-md: warning: this script's folder has no POLICY.md ($(Join-Path $PSScriptRoot '../POLICY.md'))")
}

$known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($f in $refFiles) {
    foreach ($seg in (Read-Segment ($latin1.GetString([System.IO.File]::ReadAllBytes($f.FullName))))) {
        $l = (Get-LineText $seg).Replace("`r", '')   # the .sh twin strips every CR from the references
        if ($l -match '[^ \t]') { [void]$known.Add($l) }
    }
}

$text = $latin1.GetString([System.IO.File]::ReadAllBytes($Path))
$hasBom = $text.StartsWith($bom, [System.StringComparison]::Ordinal)
$segs = Read-Segment $text
$start = -1   # zero-based index of the title line
$end = $segs.Count   # zero-based index of the first line after the block
$bad = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $segs.Count; $i++) {
    $l = Get-LineText $segs[$i]
    if ($start -lt 0) {
        if ($i -eq 0 -and $hasBom) { $l = $l.Substring(3) }
        if ([string]::Equals($l, $title, [System.StringComparison]::Ordinal)) { $start = $i }
        continue
    }
    if ($l.StartsWith('# ', [System.StringComparison]::Ordinal) -and -not $known.Contains($l)) { $end = $i; break }
    if ($l -match '[^ \t]' -and -not $known.Contains($l)) {
        $bad.Add(('{0}: {1}' -f ($i + 1), (ConvertTo-Display $l)))
    }
}

if ($start -lt 0) {
    Write-Output "nothing to do: no framework policy block in $Path"
    exit 0
}

$first = $start + 1
$last = $end   # one-based number of the last block line
if ($bad.Count -gt 0) {
    Write-Output "REFUSED: the framework block in $Path (lines $first-$last) holds lines found in none of the shipped policies; nothing changed, no backup written."
    Write-Output 'Differing lines (line number: text):'
    foreach ($b in $bad) { Write-Output $b }
    exit 3
}

$count = $end - $start
if ($DryRun) {
    Write-Output "dry run: would remove lines $first-$last ($count lines) from ${Path}:"
    for ($i = $start; $i -lt $end; $i++) {
        $l = Get-LineText $segs[$i]
        if ($i -eq 0 -and $hasBom) { $l = $l.Substring(3) }
        Write-Output (ConvertTo-Display $l)
    }
    exit 0
}

$backup = '{0}.bak-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
$backupTaken = [System.IO.File]::Exists($backup) -or [System.IO.Directory]::Exists($backup)
if (-not $backupTaken) {
    # Dangling symlink: neither Exists call sees it.
    try { $backupTaken = [bool](Get-Item -LiteralPath $backup -Force -ErrorAction Ignore) } catch { $backupTaken = $false }
}
if ($backupTaken) {
    [Console]::Error.WriteLine("migrate-global-claude-md: backup already exists, refusing to overwrite: $backup")
    exit 2
}
[System.IO.File]::Copy($Path, $backup, $false)
$sb = [System.Text.StringBuilder]::new()
# The BOM is not part of the block: keep it when the block's first line carried it.
if ($hasBom -and $start -eq 0) { [void]$sb.Append($bom) }
for ($i = 0; $i -lt $segs.Count; $i++) {
    if ($i -lt $start -or $i -ge $end) { [void]$sb.Append($segs[$i]) }
}
$bytes = $latin1.GetBytes($sb.ToString())
[System.IO.File]::WriteAllBytes($Path, $bytes)

Write-Output "migrated: removed lines $first-$last ($count lines) from $Path"
Write-Output "backup: $backup"
exit 0
