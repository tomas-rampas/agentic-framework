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
    [string]$Path = (Join-Path $HOME '.claude/CLAUDE.md'),
    [switch]$DryRun,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$title = '# Claude Code CLI - Agent Execution Framework'
# Latin1 maps bytes to chars one to one, so reading and writing never alters a byte.
$latin1 = [System.Text.Encoding]::Latin1
$utf8 = [System.Text.UTF8Encoding]::new($false)

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
    return $Segment.TrimEnd("`n").TrimEnd("`r")
}

if ($Rest -and $Rest.Count -gt 0) {
    [Console]::Error.WriteLine("migrate-global-claude-md: unexpected argument: $($Rest -join ' ')")
    exit 2
}
# One resolution for every API below: a relative -Path must mean the same file to
# Test-Path, Copy-Item and the .NET file calls (the .NET current directory can differ).
$Path = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    [Console]::Error.WriteLine("migrate-global-claude-md: file not found: $Path")
    exit 2
}
$refDir = Join-Path $PSScriptRoot 'legacy-policy'
$refFiles = @(Get-ChildItem -LiteralPath $refDir -Filter 'claude-md-v*.md' -File -ErrorAction SilentlyContinue)
if ($refFiles.Count -eq 0) {
    [Console]::Error.WriteLine("migrate-global-claude-md: no reference policies in $refDir")
    exit 2
}

$known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($f in $refFiles) {
    foreach ($seg in (Read-Segment ([System.IO.File]::ReadAllText($f.FullName, $latin1)))) {
        $l = Get-LineText $seg
        if ($l -match '\S') { [void]$known.Add($l) }
    }
}

$text = [System.IO.File]::ReadAllText($Path, $latin1)
$segs = Read-Segment $text
$start = -1   # zero-based index of the title line
$end = $segs.Count   # zero-based index of the first line after the block
$bad = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $segs.Count; $i++) {
    $l = Get-LineText $segs[$i]
    if ($start -lt 0) {
        if ($l -ceq $title) { $start = $i }
        continue
    }
    if ($l.StartsWith('# ') -and -not $known.Contains($l)) { $end = $i; break }
    if ($l -match '\S' -and -not $known.Contains($l)) {
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
    for ($i = $start; $i -lt $end; $i++) { Write-Output (ConvertTo-Display (Get-LineText $segs[$i])) }
    exit 0
}

$backup = '{0}.bak-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
if (Test-Path -LiteralPath $backup) {
    [Console]::Error.WriteLine("migrate-global-claude-md: backup already exists, refusing to overwrite: $backup")
    exit 2
}
Copy-Item -LiteralPath $Path -Destination $backup -ErrorAction Stop
$sb = [System.Text.StringBuilder]::new()
for ($i = 0; $i -lt $segs.Count; $i++) {
    if ($i -lt $start -or $i -ge $end) { [void]$sb.Append($segs[$i]) }
}
$bytes = $latin1.GetBytes($sb.ToString())
[System.IO.File]::WriteAllBytes($Path, $bytes)

Write-Output "migrated: removed lines $first-$last ($count lines) from $Path"
Write-Output "backup: $backup"
exit 0
