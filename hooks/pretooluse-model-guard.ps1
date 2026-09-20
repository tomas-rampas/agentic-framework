#Requires -Version 7.0
# pretooluse-model-guard.ps1 — blocking PreToolUse hook (matcher: Task|Agent).
#
# Prevents any subagent from running on the top model tier (a normalised model
# value containing the substring "fable", e.g. fable, claude-fable-5-1,
# fable[1m]), prevents a fork (subagent_type "fork") from being issued with any
# model override since a fork always inherits its parent's model regardless of
# an override, and prevents built-in agents (Explore, Plan, general-purpose,
# claude) from silently inheriting the parent model when no tier is set
# anywhere in the resolution chain — including a user-side floor
# (CLAUDE_CODE_SUBAGENT_MODEL) whose own value is empty or itself contains
# "fable". Non-string tool_input.model/subagent_type values (bool, number,
# array, object, null, absent) normalise to empty, matched via an -is [string]
# test so that a wrong-typed field never resolves to text a substring/case
# match could accidentally hit. tool_input itself must be a JSON object (an
# empty object still qualifies and denies as general-purpose); any other
# shape (absent, null, string, array, ...) is an unrecognised payload and
# passes silently rather than being misread as a built-in agent. Never
# blocks a framework agent that has its
# own frontmatter default. Fail-open: any error or unparseable stdin => exit
# 0, no output. Disable via env AF_MODEL_GUARD=off (case-insensitive).
#
# Registered in hooks/hooks.json via the agentic-framework plugin (PreToolUse: Task|Agent).

function Get-NormalizedString {
    param($Value)
    if ($Value -is [string]) { return $Value.Trim().ToLower() }
    return ''
}

function Write-Deny {
    param([string]$Reason)
    [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'deny'
            permissionDecisionReason = $Reason
        }
    } | ConvertTo-Json -Compress -Depth 5
}

try {
    if ($env:AF_MODEL_GUARD -and $env:AF_MODEL_GUARD.ToLower() -eq 'off') { exit 0 }

    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop

    if (-not ($payload.tool_input -is [System.Management.Automation.PSCustomObject])) { exit 0 }

    $model = Get-NormalizedString $payload.tool_input.model
    $stype = Get-NormalizedString $payload.tool_input.subagent_type

    if ($stype -eq 'fork') {
        Write-Deny '[model-guard] A fork always runs on its parent model and ignores the model override. Start a fresh agent with an explicit model instead of a fork.'
        exit 0
    }

    if ($model -like '*fable*') {
        Write-Deny '[model-guard] Sub-agents must not run on the top model tier. Re-issue this Agent call with model set to opus, sonnet or haiku.'
        exit 0
    }

    $floor = Get-NormalizedString $env:CLAUDE_CODE_SUBAGENT_MODEL
    $floorSet = ($floor -ne '') -and (-not ($floor -like '*fable*'))

    $builtinMap = @{
        ''                 = 'general-purpose'
        'explore'          = 'Explore'
        'plan'              = 'Plan'
        'general-purpose'  = 'general-purpose'
        'claude'           = 'claude'
    }

    if (-not $model -and -not $floorSet -and $builtinMap.ContainsKey($stype)) {
        $type = $builtinMap[$stype]
        $tier = if ($type -eq 'Explore') { 'haiku' } else { 'sonnet' }
        Write-Deny "[model-guard] Built-in agent $type has no default tier and would inherit the parent model. Re-issue this Agent call with model set to $tier."
        exit 0
    }

    exit 0
} catch {
    exit 0
}
