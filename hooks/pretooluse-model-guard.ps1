#Requires -Version 7.0
# pretooluse-model-guard.ps1 — blocking PreToolUse hook (matcher: Task|Agent).
#
# Denies three things it can recognise from the call alone: every fork
# (subagent_type "fork"), since a fork always inherits its parent's model and
# ignores any override; a normalised model value containing the substring
# "fable" (e.g. fable, claude-fable-5-1, fable[1m]), the top model tier; and a
# BUILT-IN agent (Explore, Plan, general-purpose, claude, or no type given)
# issued with no model and no usable floor, since those inherit the parent
# model with no frontmatter default of their own. The floor is the env var
# CLAUDE_CODE_SUBAGENT_MODEL, and it counts as usable only when it is
# non-empty and itself free of "fable".
#
# KNOWN LIMIT: any OTHER agent type — a framework agent, a user-scope agent,
# another plugin's agent — spawned with no model is never denied here,
# because this hook cannot read that agent's frontmatter. If its definition
# carries no `model:` line it silently inherits the caller's tier, and the
# only cover for that case is the user-side floor above.
#
# Non-string tool_input.model/subagent_type values (bool, number, array,
# object, null, absent) normalise to empty, matched via an -is [string]
# test so that a wrong-typed field never resolves to text a substring/case
# match could accidentally hit. tool_input itself must be a JSON object (an
# empty object still qualifies and denies as general-purpose); any other
# shape (absent, null, string, array, ...) is an unrecognised payload and
# passes silently rather than being misread as a built-in agent. Fail-open:
# any error or unparseable stdin => exit 0, no output. Disable via env
# AF_MODEL_GUARD=off (case-insensitive).
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
        Write-Deny '[model-guard] A fork always runs on its parent model and ignores the model override. Start a fresh agent with an explicit model instead, and pass it the context it needs. Set AF_MODEL_GUARD=off to disable this guard.'
        exit 0
    }

    if ($model -like '*fable*') {
        Write-Deny '[model-guard] Sub-agents must not run on the top model tier. Re-issue this Agent call with model set to opus, sonnet or haiku. Set AF_MODEL_GUARD=off to disable this guard.'
        exit 0
    }

    $floor = Get-NormalizedString $env:CLAUDE_CODE_SUBAGENT_MODEL
    $floorSet = ($floor -ne '') -and (-not ($floor -like '*fable*'))

    $builtinMap = @{
        ''                 = 'general-purpose'
        'explore'          = 'Explore'
        'plan'             = 'Plan'
        'general-purpose'  = 'general-purpose'
        'claude'           = 'claude'
    }

    if (-not $model -and -not $floorSet -and $builtinMap.ContainsKey($stype)) {
        $type = $builtinMap[$stype]
        $tier = if ($type -eq 'Explore') { 'haiku' } else { 'sonnet' }
        Write-Deny "[model-guard] Built-in agent $type has no default tier and would inherit the parent model. Re-issue this Agent call with model set to $tier. Set AF_MODEL_GUARD=off to disable this guard."
        exit 0
    }

    exit 0
} catch {
    exit 0
}
