---
name: hook-config-generator
description: Guide for adding a new real Claude Code hook to this framework (PowerShell 7 script in hooks/, registration in settings.template.json, tests, validation, install) — use when asked to create, generate, or extend a hook or quality gate.
---

# Adding a New Hook

Hooks in this framework are real Claude Code hooks: PowerShell 7 scripts in `hooks/` that read a JSON payload on stdin and optionally emit a JSON decision on stdout. They are registered in `hooks/hooks.json` (exec-form with `${CLAUDE_PLUGIN_ROOT}` variable substitution) and automatically loaded by Claude Code when the agentic-framework plugin is installed. Study `hooks/stop-peer-review-gate.ps1` (blocking Stop gate) and `hooks/pretooluse-delegation-hint.ps1` (advisory) as reference implementations before writing anything.

## Hook Contract

- Input: JSON on stdin. Common fields: `session_id`, `cwd`, `tool_name`, `tool_input`, and `stop_hook_active` (Stop hooks only).
- Output: nothing (allow silently), or one compressed JSON object on stdout.
  - Blocking (Stop-like gates only): `@{ decision = 'block'; reason = $reason } | ConvertTo-Json -Compress`
  - Advisory: `@{ suppressOutput = $true; systemMessage = "[hint] ..." } | ConvertTo-Json -Compress`
- Exit code: always `0`. Fail-open is mandatory — wrap the entire body in `try { ... } catch { exit 0 }`. A hook must never break the session on error, malformed stdin, or non-git context.

## Step 1: Write hooks/<name>.ps1

Rules every hook script must follow:

1. First line: `#Requires -Version 7.0` (validation enforces this pin).
2. Header comment: what it does, which event/matcher it registers under, and that it is fail-open.
3. Read stdin once: `$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop` inside the `try`.
4. Bail early with `exit 0` on any precondition failure (missing fields, wrong tool, unmapped file type).
5. Sanitize `session_id` before using it in a path: `([string]$payload.session_id) -replace '[^\w\-.]', ''`.
6. Persist per-session state (dedupe markers, "fired once" flags) under `$env:CLAUDE_STATE_DIR`, falling back to `Join-Path $HOME '.claude/.state'`. Prune files older than ~7 days.
7. For Stop hooks: check `$payload.stop_hook_active` first and `exit 0` if true (loop safety), and bound repeat blocks with a `.fired` marker — an empty marker for a fire-once gate, or a counter file when a bounded number of re-fires is intended (the peer-review gate uses a counter: 1 block with no review, up to 3 on a `CHANGES_REQUIRED` verdict).
8. Never reference retired agent or file names — `bash scripts/validate-hooks.sh` scans hook scripts for deprecated names and fails on any hit.
9. Blocking output is reserved for Stop-like gates; everything else must be advisory (`systemMessage`) or silent.

## Step 2: Register in hooks/hooks.json

Add an entry under the matching event. The event name must be one of the real Claude Code events: `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Notification`, `Stop`, `SubagentStop`, `SessionStart`, `SessionEnd`, `PreCompact` — anything else fails validation.

```json
"PostToolUse": [
  {
    "matcher": "Write|Edit",
    "hooks": [
      {
        "type": "command",
        "command": "pwsh",
        "args": ["-NoProfile", "-File", "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.ps1"],
        "timeout": 10
      }
    ]
  }
]
```

- Event keys (PreToolUse, PostToolUse, Stop, etc.) live inside the top-level `hooks` object — the structure is `{ "hooks": { "Stop": [...], "PostToolUse": [...] } }`.
- `matcher` is a regex over tool names for tool events (omit it for Stop/SessionStart-style events).
- Use `${CLAUDE_PLUGIN_ROOT}` as the path prefix — Claude Code substitutes it at runtime to the installed plugin root.
- Use a short `timeout` in seconds (10 for advisory, 15 for git-inspecting gates).
- If the event already has an entry with the same matcher, append your hook to its inner `hooks` array instead of adding a duplicate matcher block.

## Step 3: Add tests to tests/hooks.test.ps1

The harness is plain pwsh (no Pester): it builds a throwaway git repo and an isolated `CLAUDE_STATE_DIR`, pipes synthetic stdin JSON to each script via `Invoke-Hook`, and asserts on output and exit code. Add a `Write-Host "<name>.ps1"` section with at minimum:

- the happy path (expected output or marker file created),
- each early-exit precondition (wrong tool, unmapped input, marker already present),
- once-per-session dedupe behavior if the hook uses markers,
- fail-open on malformed stdin: `Invoke-Hook '<name>.ps1' 'not json'` must exit 0.

Run: `pwsh -NoProfile -File tests/hooks.test.ps1` — exit 0 means all assertions passed.

## Step 4: Validate

Run `bash scripts/validate-hooks.sh`. It enforces registration parity and must pass:

- every script registered in `hooks/hooks.json` exists in `hooks/`,
- every `hooks/*.ps1` is registered (no dead scripts),
- every registered event is a real Claude Code hook event,
- every script pins PowerShell 7,
- no deprecated names appear in hook scripts.

The same checks run inside `bash scripts/validate-consistency.sh` (the full check battery) and in CI, so an unregistered or orphaned hook fails the build. Run the full battery too if you touched anything beyond `hooks/` and `hooks/hooks.json`.

## Step 5: Deploy

The hook is automatically deployed when the agentic-framework plugin is updated or reinstalled. Restart any running Claude Code session to pick up the new hook, or:

```bash
/plugin uninstall agentic-framework
/plugin install agentic-framework@claude-agentic-framework
# then restart Claude Code
```

## Worked Example: Advisory Agent-Edit Reminder

An advisory PostToolUse hook that reminds, once per session, to run the consistency battery after an agent definition is edited.

`hooks/posttooluse-agent-edit-hint.ps1`:

```powershell
#Requires -Version 7.0
# posttooluse-agent-edit-hint.ps1 — advisory PostToolUse hook (matcher: Write|Edit).
# After a file under agents/ is modified, reminds (once per session) to run the
# consistency validation. Never blocks; fail-open: any error => exit 0, no output.

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop

    $filePath = [string]($payload.tool_input.file_path ?? '')
    if ($filePath -notmatch '[\\/]agents[\\/][^\\/]+\.md$') { exit 0 }

    $sessionId = ([string]$payload.session_id) -replace '[^\w\-.]', ''
    if (-not $sessionId) { exit 0 }

    $stateRoot = $env:CLAUDE_STATE_DIR
    if (-not $stateRoot) { $stateRoot = Join-Path $HOME '.claude/.state' }
    $hintDir = Join-Path $stateRoot 'agent-edit-hints'
    $seen    = Join-Path $hintDir $sessionId
    if (Test-Path $seen) { exit 0 }
    New-Item -ItemType Directory -Force -Path $hintDir | Out-Null
    New-Item -ItemType File -Force -Path $seen | Out-Null

    @{
        suppressOutput = $true
        systemMessage  = '[agent-edit-hint] Agent definition modified - run bash scripts/validate-consistency.sh before committing.'
    } | ConvertTo-Json -Compress
    exit 0
} catch {
    exit 0
}
```

Registration — append to the existing `PostToolUse` array in `hooks/hooks.json`:

```json
{
  "matcher": "Write|Edit",
  "hooks": [
    {
      "type": "command",
      "command": "pwsh",
      "args": ["-NoProfile", "-File", "${CLAUDE_PLUGIN_ROOT}/hooks/posttooluse-agent-edit-hint.ps1"],
      "timeout": 10
    }
  ]
}
```

Tests — add to `tests/hooks.test.ps1` before the teardown section:

```powershell
Write-Host "posttooluse-agent-edit-hint.ps1"

$r = Invoke-Hook 'posttooluse-agent-edit-hint.ps1' (New-Payload @{ session_id = 'e1'; tool_name = 'Edit'; tool_input = @{ file_path = 'D:/repo/agents/rust-expert.md' } })
Assert 'hints on agent file edit' ($r.Code -eq 0 -and $r.Out -match 'validate-consistency' -and $r.Out -match '"systemMessage"')

$r = Invoke-Hook 'posttooluse-agent-edit-hint.ps1' (New-Payload @{ session_id = 'e1'; tool_name = 'Edit'; tool_input = @{ file_path = 'D:/repo/agents/go-expert.md' } })
Assert 'hints at most once per session' ($r.Code -eq 0 -and -not $r.Out)

$r = Invoke-Hook 'posttooluse-agent-edit-hint.ps1' (New-Payload @{ session_id = 'e2'; tool_name = 'Edit'; tool_input = @{ file_path = 'D:/repo/README.md' } })
Assert 'silent for non-agent files' ($r.Code -eq 0 -and -not $r.Out)

$r = Invoke-Hook 'posttooluse-agent-edit-hint.ps1' 'not json'
Assert 'fail-open on malformed stdin' ($r.Code -eq 0)
```

Then run `pwsh -NoProfile -File tests/hooks.test.ps1` and `bash scripts/validate-hooks.sh`. The hook is automatically deployed when the agentic-framework plugin is updated or reinstalled — restart Claude Code to load it.

## Completion Checklist

- Script in `hooks/` pins PS7, reads stdin JSON, fails open, exits 0 on every path.
- Registered in `hooks/hooks.json` under a valid event with matcher and timeout (using `${CLAUDE_PLUGIN_ROOT}`).
- Test cases added to `tests/hooks.test.ps1`; harness passes.
- `bash scripts/validate-hooks.sh` passes (parity, events, PS7 pin, no deprecated names).
- Plugin reinstalled or updated; live session restarted to load the hook.
