#Requires -Version 7.0
# pretooluse-model-guard.ps1 — blocking PreToolUse hook (matcher: Task|Agent).
#
# Denies two things it can recognise from the call alone: every fork
# (subagent_type "fork"), since a fork always inherits its parent's model and
# ignores any override; and a normalised model value containing the substring
# "fable" (e.g. fable, claude-fable-5-1, fable[1m]), the top model tier. A
# BUILT-IN agent (Explore, Plan, general-purpose, claude, or no type given)
# issued with no model and no usable floor is REWRITTEN rather than denied:
# the hook returns updatedInput with model set to its tier, so the call
# proceeds automatically with no user step. The floor is the env var
# CLAUDE_CODE_SUBAGENT_MODEL, and it counts as usable only when it is
# non-empty and itself free of "fable"; an unusable floor (empty, or itself
# "fable") is what routes a built-in call into the rewrite.
#
# MEASURED (Claude Code 2.1.278, Agent tool): updatedInput for the Agent tool
# must echo the COMPLETE original tool_input, not just the changed key — a
# partial updatedInput (e.g. {"model":"haiku"} alone) replaces the whole
# input, so prompt/description/subagent_type vanish and schema validation
# rejects the call. The rewrite path emits no permissionDecision at all
# (tested to work and to leave the user's own permission rules alone); only
# hookSpecificOutput.updatedInput plus a top-level systemMessage. Every other
# original key comes back unchanged and in its original position; model is
# replaced in place if present, else appended last.
#
# ROUND-TRIP INTEGRITY: this is parsed and re-emitted with System.Text.Json
# (JsonDocument + Utf8JsonWriter), never ConvertFrom-Json/ConvertTo-Json,
# because ConvertFrom-Json silently turns an ISO-date-shaped string into a
# [datetime] and ConvertTo-Json re-serialises it in a different format —
# corrupting an echoed prompt/description that happens to look like a
# timestamp. Stdin is read as raw UTF-8 bytes via
# [Console]::OpenStandardInput() (not [Console]::In, which does not decode
# UTF-8 on Windows) and stdout is written as BOM-less UTF-8 bytes via
# [Console]::OpenStandardOutput(), so non-ASCII text (accented letters,
# emoji/surrogate pairs) and control characters inside prompt/description
# survive exactly.
#
# KNOWN LIMIT: any OTHER agent type — a framework agent, a user-scope agent,
# another plugin's agent — spawned with no model is never touched here,
# because this hook cannot read that agent's frontmatter. If its definition
# carries no `model:` line it silently inherits the caller's tier, and the
# only cover for that case is the user-side floor above.
#
# Non-string tool_input.model/subagent_type values (bool, number, array,
# object, null, absent) normalise to empty, so a wrong-typed field never
# resolves to text a substring/case match could accidentally hit. tool_input
# itself must be a JSON object (an empty object still qualifies and rewrites
# to {"model":"sonnet"}); any other shape (absent, null, string, array, ...)
# is an unrecognised payload and passes silently rather than being misread as
# a built-in agent. Fail-open: any error or unparseable stdin => exit 0, no
# output. Disable via env AF_MODEL_GUARD=off (case-insensitive).
#
# Registered in hooks/hooks.json via the agentic-framework plugin (PreToolUse: Task|Agent).
# DENY cases (fork, fable) are byte-identical with the .sh twin; REWRITE
# cases may legitimately differ in JSON escaping of echoed strings and are
# compared as canonical JSON (jq -S -c .) in the equivalence suite instead.

using namespace System.Text.Json

function Get-NormalizedFromElement {
    param([JsonElement]$Obj, [string]$Name)
    $prop = New-Object JsonElement
    if ($Obj.TryGetProperty($Name, [ref]$prop) -and $prop.ValueKind -eq [JsonValueKind]::String) {
        return $prop.GetString().Trim().ToLowerInvariant()
    }
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

function Write-BytesToStdout {
    param([byte[]]$Bytes)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($Bytes, 0, $Bytes.Length)
    $stdout.Flush()
}

try {
    if ($env:AF_MODEL_GUARD -and $env:AF_MODEL_GUARD.ToLowerInvariant() -eq 'off') { exit 0 }

    $stdin = [Console]::OpenStandardInput()
    $ms = New-Object System.IO.MemoryStream
    $stdin.CopyTo($ms)
    if ($ms.Length -eq 0) { exit 0 }
    $ms.Position = 0

    $doc = [JsonDocument]::Parse($ms)
    $root = $doc.RootElement

    $toolInput = New-Object JsonElement
    if (-not $root.TryGetProperty('tool_input', [ref]$toolInput)) { exit 0 }
    if ($toolInput.ValueKind -ne [JsonValueKind]::Object) { exit 0 }

    $model = Get-NormalizedFromElement $toolInput 'model'
    $stype = Get-NormalizedFromElement $toolInput 'subagent_type'

    if ($stype -eq 'fork') {
        Write-Deny '[model-guard] A fork always runs on its parent model and ignores the model override. Start a fresh agent with an explicit model instead, and pass it the context it needs. Set AF_MODEL_GUARD=off to disable this guard.'
        exit 0
    }

    if ($model -like '*fable*') {
        Write-Deny '[model-guard] Sub-agents must not run on the top model tier. Re-issue this Agent call with model set to opus, sonnet or haiku. Set AF_MODEL_GUARD=off to disable this guard.'
        exit 0
    }

    $floorRaw = [string]$env:CLAUDE_CODE_SUBAGENT_MODEL
    $floor = $floorRaw.Trim().ToLowerInvariant()
    $floorSet = ($floor -ne '') -and (-not ($floor -like '*fable*'))

    $builtinMap = @{
        ''                = 'general-purpose'
        'explore'         = 'Explore'
        'plan'            = 'Plan'
        'general-purpose' = 'general-purpose'
        'claude'          = 'claude'
    }

    if (-not $model -and -not $floorSet -and $builtinMap.ContainsKey($stype)) {
        $type = $builtinMap[$stype]
        $tier = if ($type -eq 'Explore') { 'haiku' } else { 'sonnet' }
        $systemMessage = "[model-guard] Built-in agent $type had no model and would inherit the session model. Model set to $tier. Set AF_MODEL_GUARD=off to disable this guard."

        $outMs = New-Object System.IO.MemoryStream
        $writerOptions = New-Object JsonWriterOptions
        $writer = New-Object Utf8JsonWriter($outMs, $writerOptions)
        try {
            $writer.WriteStartObject()
            $writer.WriteStartObject('hookSpecificOutput')
            $writer.WriteString('hookEventName', 'PreToolUse')
            $writer.WriteStartObject('updatedInput')
            $modelWritten = $false
            foreach ($prop in $toolInput.EnumerateObject()) {
                if ($prop.Name -eq 'model') {
                    $writer.WriteString('model', $tier)
                    $modelWritten = $true
                } else {
                    $writer.WritePropertyName($prop.Name)
                    $prop.Value.WriteTo($writer)
                }
            }
            if (-not $modelWritten) { $writer.WriteString('model', $tier) }
            $writer.WriteEndObject()
            $writer.WriteEndObject()
            $writer.WriteString('systemMessage', $systemMessage)
            $writer.WriteEndObject()
        } finally {
            $writer.Flush()
            $writer.Dispose()
        }
        Write-BytesToStdout $outMs.ToArray()
        exit 0
    }

    exit 0
} catch {
    exit 0
}
