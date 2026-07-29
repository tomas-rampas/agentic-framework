---
name: hook-config-generator
description: Guide for adding a new real Claude Code hook to this framework as a .ps1/.sh pair (registration in hooks/hooks.json as a shell-form chain, tests in both suites, validation) — use when asked to create, generate, or extend a hook or quality gate.
---

# Adding a New Hook

Hooks in this framework are real Claude Code hooks: implemented as both PowerShell 7 (`.ps1`) and POSIX shell (`.sh`) scripts in `hooks/` that read a JSON payload on stdin and optionally emit a JSON decision on stdout. They are registered in `hooks/hooks.json` as a shell-form fallback chain (`sh dispatch.sh <name> || pwsh -NoProfile -File <name>.ps1`) and automatically loaded by Claude Code when the agentic-framework plugin is installed. On Linux/macOS, the dispatcher runs the `.sh` script; on Windows, the `.ps1` script runs (either via dispatch on Git Bash systems or directly if `sh` is unavailable). Study `hooks/stop-peer-review-gate.ps1` and `hooks/stop-peer-review-gate.sh` (blocking Stop gate pair) and `hooks/pretooluse-delegation-hint.ps1` and `hooks/pretooluse-delegation-hint.sh` (advisory pair) as reference implementations before writing anything.

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
10. Output JSON only — any error in the script → `exit 0`, never partial output or stderr.

## Step 2: Write hooks/<name>.sh

The POSIX shell twin, used on Linux/macOS via dispatch.sh:

1. First line: `#!/bin/sh` (shebang for POSIX sh, dash, bash — never bash-only syntax).
2. Second line: `set -u` (fail on undefined variables; validation enforces this pin).
3. Header comment: what it does, which event/matcher it registers under, and that it is fail-open.
4. Read stdin once: `payload=$(cat)` at the top, inside the `trap` or early-exit handler.
5. Bail early with `exit 0` on any precondition failure; use `jq` for JSON parsing (it is a framework dependency).
6. Sanitize `session_id` before using it in a path: `session_id=$(printf "%s" "$session_id" | sed 's/[^-._[:alnum:]]//g')`.
7. Persist per-session state under `${CLAUDE_STATE_DIR:=$HOME/.claude/.state}` (same as PowerShell side); use `mkdir -p` and `touch` for markers.
8. For Stop hooks: check `stop_hook_active` field (via `jq`) first and `exit 0` if true; use the same `.fired` marker strategy as the .ps1.
9. Fail-open always: wrap the whole body in a trap handler that `exit 0` on any error, or use `|| exit 0` guards at each step.
10. Output JSON only — use `jq` to emit compressed JSON (`jq -c`), never partial output.
11. Line endings: .gitattributes enforces LF on *.sh; the script must produce LF-only output for sidecar files (markers, verdict records).
12. Byte-identical output to the .ps1 version — same JSON structure, same field order (jq -c --sort-keys helps), same state file format (LF-only, same field order).

## Step 3: Add the Hook Name to dispatch.sh's Case Allowlist

The dispatcher `hooks/dispatch.sh` is a shell-form router that detects the platform (POSIX vs MINGW/MSYS/CYGWIN) and runs the appropriate script. It has a hardcoded allowlist of hook names — if a hook is not listed, the dispatcher exits 0 silently on POSIX (a silent no-op).

Open `hooks/dispatch.sh` and add your hook name to the case statement (this matches the real file — the allowlist branch is an empty pass-through; platform routing happens further down):

```sh
hook=${1:-}
case "$hook" in
  stop-peer-review-gate|record-subagent-run|session-start-context|pretooluse-delegation-hint|your-new-hook) ;;
  *) exit 0 ;;
esac
```

**Warning**: skipping this step means the hook will silently do nothing on POSIX systems — registration in hooks/hooks.json is not enough. On Windows, the .ps1 runs directly via pwsh, so it will still fire; but POSIX users will see no behavior.

## Step 4: Register in hooks/hooks.json

Add an entry under the matching event. The event name must be one of the real Claude Code events: `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Notification`, `Stop`, `SubagentStop`, `SessionStart`, `SessionEnd`, `PreCompact` — anything else fails validation.

```json
"PostToolUse": [
  {
    "matcher": "Write|Edit",
    "hooks": [
      {
        "type": "command",
        "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/dispatch.sh\" <name> || pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/hooks/<name>.ps1\"",
        "timeout": 10
      }
    ]
  }
]
```

- The command is a single shell-form fallback chain string — NO `args` and NO `shell` field (pinning a shell would defeat the platform fallback). The `|| pwsh` arm fires only when `sh` cannot spawn (Windows without Git Bash); on every other path `dispatch.sh` routes and exits 0.
- Event keys (PreToolUse, PostToolUse, Stop, etc.) live inside the top-level `hooks` object — the structure is `{ "hooks": { "Stop": [...], "PostToolUse": [...] } }`.
- `matcher` is a regex over tool names for tool events (omit it for Stop/SessionStart-style events).
- Use `${CLAUDE_PLUGIN_ROOT}` as the path prefix — Claude Code substitutes it at runtime to the installed plugin root.
- Use a short `timeout` in seconds (10 for advisory, 15 for git-inspecting gates).
- If the event already has an entry with the same matcher, append your hook to its inner `hooks` array instead of adding a duplicate matcher block.

## Step 5: Add tests to both harnesses

The pwsh harness (`tests/hooks.test.ps1`) is plain pwsh (no Pester): it builds a throwaway git repo and an isolated `CLAUDE_STATE_DIR`, pipes synthetic stdin JSON to each script via `Invoke-Hook`, and asserts on output and exit code. Add a `Write-Host "<name>.ps1"` section with at minimum:

- the happy path (expected output or marker file created),
- each early-exit precondition (wrong tool, unmapped input, marker already present),
- once-per-session dedupe behavior if the hook uses markers,
- fail-open on malformed stdin: `Invoke-Hook '<name>.ps1' 'not json'` must exit 0.

Mirror the same cases in the POSIX harness (`tests/hooks.test.sh`): open a new `section`, pipe the synthetic payload straight into the script (`printf '%s' "$payload" | sh hooks/<name>.sh`), and use its `assert_*` helpers. If the hook writes state files, also add a fixture to `tests/hooks-equivalence.test.sh` — both implementations must produce byte-identical files and stdout.

Run: `pwsh -NoProfile -File tests/hooks.test.ps1` and `bash tests/hooks.test.sh` — exit 0 from each means all assertions passed.

## Step 6: Validate

Run `bash scripts/validate-hooks.sh`. It enforces pair parity and must pass:

- every hook registered in `hooks/hooks.json` has BOTH `hooks/<name>.ps1` and `hooks/<name>.sh` on disk,
- every `hooks/*.ps1` and `hooks/*.sh` on disk is registered (no orphans on either side; `dispatch.sh` excluded),
- `hooks/dispatch.sh` exists and every registered chain references it,
- every registered event is a real Claude Code hook event,
- every `.ps1` pins PowerShell 7; every `.sh` starts with `#!/bin/sh` and sets `set -u`,
- no deprecated names appear in hook scripts.

The same checks run inside `bash scripts/validate-consistency.sh` (the full check battery) and in CI, so an unregistered or orphaned hook fails the build. Note the validator does NOT parse dispatch.sh's name allowlist — Step 3 stays your responsibility. Run the full battery too if you touched anything beyond `hooks/` and `hooks/hooks.json`.

## Step 7: Deploy

The hook is automatically deployed when the agentic-framework plugin is updated or reinstalled. Restart any running Claude Code session to pick up the new hook, or:

```bash
/plugin uninstall agentic-framework
/plugin install agentic-framework@agentic-framework
# then restart Claude Code
```

## Worked Example: Advisory Agent-Edit Reminder

An advisory PostToolUse hook that reminds, once per session, to run the consistency battery after an agent definition is edited. Implemented as a pair.

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

`hooks/posttooluse-agent-edit-hint.sh` (POSIX shell twin — same logic, POSIX-only):

```sh
#!/bin/sh
set -u
# posttooluse-agent-edit-hint.sh — advisory PostToolUse hook (matcher: Write|Edit).
# After a file under agents/ is modified, reminds (once per session) to run the
# consistency validation. Never blocks; fail-open: any error => exit 0, no output.

trap 'exit 0' EXIT INT TERM

payload=$(cat)
file_path=$(printf "%s" "$payload" | jq -r '.tool_input.file_path // ""')
if ! printf "%s" "$file_path" | grep -qE '.*/agents/[^/]+\.md$'; then
  exit 0
fi

session_id=$(printf "%s" "$payload" | jq -r '.session_id // ""' | sed 's/[^-._[:alnum:]]//g')
if [ -z "$session_id" ]; then
  exit 0
fi

state_root="${CLAUDE_STATE_DIR:=$HOME/.claude/.state}"
hint_dir="$state_root/agent-edit-hints"
seen="$hint_dir/$session_id"

if [ -f "$seen" ]; then
  exit 0
fi

mkdir -p "$hint_dir"
touch "$seen"

printf '%s\n' \
  '{"suppressOutput":true,"systemMessage":"[agent-edit-hint] Agent definition modified - run bash scripts/validate-consistency.sh before committing."}' | jq -c .
exit 0
```

Registration — add to `hooks/hooks.json` under `PostToolUse`:

```json
{
  "matcher": "Write|Edit",
  "hooks": [
    {
      "type": "command",
      "command": "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/dispatch.sh\" posttooluse-agent-edit-hint || pwsh -NoProfile -File \"${CLAUDE_PLUGIN_ROOT}/hooks/posttooluse-agent-edit-hint.ps1\"",
      "timeout": 10
    }
  ]
}
```

Also add the name to the case statement in `hooks/dispatch.sh`:

```sh
case "$hook" in
  stop-peer-review-gate|record-subagent-run|session-start-context|pretooluse-delegation-hint|posttooluse-agent-edit-hint) ;;
  *) exit 0 ;;
esac
```

Tests — add to `tests/hooks.test.ps1`:

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

And add to `tests/hooks.test.sh` (the harness sets `RUN_OUT`/`RUN_RC` and provides `section` + `assert_*` helpers; hooks are invoked by piping the payload straight into the script):

```sh
section "posttooluse-agent-edit-hint.sh"

payload=$(jq -cn '{session_id:"e1", tool_name:"Edit", tool_input:{file_path:"/repo/agents/rust-expert.md"}}')
RUN_OUT="$(printf '%s' "$payload" | sh "$SRC_REPO/hooks/posttooluse-agent-edit-hint.sh" 2>&1)"; RUN_RC=$?
assert_rc_zero "hints on agent file edit"
assert_out_contains "emits the reminder" "validate-consistency"
assert_out_contains "advisory shape" "systemMessage"

payload=$(jq -cn '{session_id:"e1", tool_name:"Edit", tool_input:{file_path:"/repo/agents/go-expert.md"}}')
RUN_OUT="$(printf '%s' "$payload" | sh "$SRC_REPO/hooks/posttooluse-agent-edit-hint.sh" 2>&1)"; RUN_RC=$?
assert_rc_zero "second edit same session exits 0"
assert_out_empty "hints at most once per session"

payload=$(jq -cn '{session_id:"e2", tool_name:"Edit", tool_input:{file_path:"/repo/README.md"}}')
RUN_OUT="$(printf '%s' "$payload" | sh "$SRC_REPO/hooks/posttooluse-agent-edit-hint.sh" 2>&1)"; RUN_RC=$?
assert_rc_zero "non-agent file exits 0"
assert_out_empty "silent for non-agent files"

RUN_OUT="$(printf '%s' 'not json' | sh "$SRC_REPO/hooks/posttooluse-agent-edit-hint.sh" 2>&1)"; RUN_RC=$?
assert_rc_zero "fail-open on malformed stdin"
```

Then run both test suites:
```bash
pwsh -NoProfile -File tests/hooks.test.ps1
bash tests/hooks.test.sh
```

And validate:
```bash
bash scripts/validate-hooks.sh
```

The hook is automatically deployed when the agentic-framework plugin is updated or reinstalled — restart Claude Code to load it.

## Completion Checklist

- `.ps1` script in `hooks/` pins PS7, reads stdin JSON, fails open, exits 0 on every path.
- `.sh` script in `hooks/` starts with `#!/bin/sh`, has `set -u`, reads stdin, fails open, identical output to .ps1.
- Hook name added to `hooks/dispatch.sh` case statement allowlist.
- Registered in `hooks/hooks.json` under a valid event with matcher and timeout, using `sh dispatch.sh` invocation (using `${CLAUDE_PLUGIN_ROOT}`).
- Test cases added to BOTH `tests/hooks.test.ps1` AND `tests/hooks.test.sh`; both harnesses pass.
- Equivalence fixture added to `tests/hooks-equivalence.test.sh` if the hook writes state files.
- `bash scripts/validate-hooks.sh` passes (pair parity, dispatch presence + chain reference, events, PS7/sh pin, no deprecated names) — remembering the dispatch.sh name allowlist itself is not validator-checked.
- Plugin reinstalled or updated; live session restarted to load the hook.
