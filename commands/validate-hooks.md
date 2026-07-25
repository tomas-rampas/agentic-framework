---
name: validate-hooks
description: Validate hook registration, consistency, and configuration
---

Framework root: `${CLAUDE_PLUGIN_ROOT}` (when running from a development checkout of the framework itself, this may be empty — then use the current directory if it contains `claude.json`). All framework file paths below are relative to that root.

# /agentic-framework:validate-hooks — Validate Hook Architecture

## Purpose

Validate the framework's hook architecture: registration parity (pair parity of .ps1/.sh implementations), dispatch.sh routing, event-name validity, PowerShell 7 and sh pinning, deprecated-name references, and (optionally) hook behavior.

## Usage

```
/agentic-framework:validate-hooks [--behavior]
```

**Options:**
- (default): run the registration/consistency validation
- `--behavior`: additionally run the hook behavior test harnesses (`tests/hooks.test.ps1` and/or `tests/hooks.test.sh` where available)

## How Hooks Work in This Framework

Claude Code executes only hooks registered in a settings file's `hooks` block. This framework tracks that registration in `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` (the registration source of truth; `settings.template.json` remains the recommended-user-settings artifact) as shell-form chains and implements each hook as both a PowerShell 7 (`.ps1`) and POSIX shell (`.sh`) script in `${CLAUDE_PLUGIN_ROOT}/hooks/`. A dispatcher (`hooks/dispatch.sh`) routes to the appropriate implementation per platform.

| Hook Name | Event | Matcher | Role |
|-----------|-------|---------|------|
| `stop-peer-review-gate` (.ps1/.sh pair) | `Stop` | — | Blocking peer-review final gate |
| `record-subagent-run` (.ps1/.sh pair) | `PostToolUse` + `SubagentStop` | `Task\|Agent` / — | Records peer-review-critic runs and parses the report's `VERDICT:` line into the session marker (`APPROVED` unlocks the gate) |
| `session-start-context` (.ps1/.sh pair) | `SessionStart` | — | Injects branch/review status into context |
| `pretooluse-delegation-hint` (.ps1/.sh pair) | `PreToolUse` | `Write\|Edit` | Advisory specialist-agent hint |

## Command-line execution
Delegate every shell command this workflow needs — validators, git/gh calls, JSON/YAML
processing, test and build runs — to **bash-expert** (POSIX/Git Bash) or
**powershell-expert** (PowerShell/Windows) instead of running it inline. Executors
return the exact command, its integer exit code, and a distilled result (verbatim
fenced where it will be used literally). Read files with Read/Grep/Glob directly —
never via shell.

## Validation Checks

Run the validator (shared logic with `validate-consistency.sh` check 3 — the two cannot drift):

```bash
FRAMEWORK_ROOT="${CLAUDE_PLUGIN_ROOT:-.}" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/validate-hooks.sh"
```

It asserts:

1. **Pair parity** — every hook name registered in `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` has both `.ps1` and `.sh` implementations on disk; every `.ps1` and `.sh` on disk is registered (no orphans on either side).
2. **Dispatch presence** — `${CLAUDE_PLUGIN_ROOT}/hooks/dispatch.sh` exists and is referenced in every registered hook chain. (The name allowlist inside dispatch.sh itself is NOT validator-checked — keep it in sync by hand when adding a hook.)
3. **Event validity** — every event key is a real Claude Code hook event (`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Notification`, `Stop`, `SubagentStop`, `SessionStart`, `SessionEnd`, `PreCompact`).
4. **PowerShell pin** — every `.ps1` script starts with `#Requires -Version 7.0`.
5. **Shell pins** — every `.sh` script starts with `#!/bin/sh` (shebang) and has `set -u` (second line).
6. **No deprecated agent names** referenced by any hook script.

## Behavior Validation (--behavior)

```bash
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT:-.}/tests/hooks.test.ps1"  # PowerShell harness
bash "${CLAUDE_PLUGIN_ROOT:-.}/tests/hooks.test.sh"                    # POSIX harness (where sh is available)
```

Exercises the hook scripts (both implementations) against a throwaway git repo and isolated state directory:
- Stop gate: blocks on a clean feature branch with unreviewed or `CHANGES_REQUIRED`-reviewed commits (once with no marker, up to 3 blocks total on `CHANGES_REQUIRED`); allows on `stop_hook_active`, dirty tree, base branch, non-git cwd, `verdict=APPROVED` or legacy no-verdict markers; fail-open on malformed stdin
- Recorder: writes/ignores markers correctly across `PostToolUse` and `SubagentStop` payload shapes, parses the anchored `VERDICT:` line (last whole-line match wins), and never downgrades a verdict-bearing marker
- Session context and delegation hint: correct output and once-per-session behavior
- Equivalence (where both interpreters exist): `.ps1` and `.sh` versions produce identical state file contents

## Sample Output

```
Hook Architecture Validation
============================

Checking hook registration parity (hooks/hooks.json <-> hooks/*.ps1)...

OK: 4 hook script(s) registered across 5 event(s); no orphans; all events valid; all pin PS7

Checking for deprecated agent references in hooks/...

OK: no deprecated agent references found

================================
Hook validation passed
```

## Common Issues and Remediation

**Registered script missing:**
```
ERROR [missing-hook-script] stop-peer-review-gate.ps1
Remediation: restore ${CLAUDE_PLUGIN_ROOT}/hooks/stop-peer-review-gate.ps1, or remove its registration
             from ${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json
```

**Orphan script (dead code):**
```
ERROR [orphan-hook-script] my-new-hook.ps1
Remediation: register it in ${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json under the right event, or delete it
```

**Unknown event name:**
```
ERROR [invalid-hook-event] OnStop
Remediation: use a real Claude Code event (e.g. Stop)
```

## Adding a New Hook

1. Create `${CLAUDE_PLUGIN_ROOT}/hooks/<name>.ps1` starting with `#Requires -Version 7.0`; read the event JSON from stdin; **fail open** (any error → `exit 0`).
2. Create the POSIX twin `${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh` (`#!/bin/sh` + `set -u`, jq for JSON, fail open) producing byte-identical output.
3. Add the hook name to the case allowlist in `${CLAUDE_PLUGIN_ROOT}/hooks/dispatch.sh` — without this the hook is a silent no-op on POSIX.
4. Register it in `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` under the appropriate event as a shell-form dispatch chain (`sh dispatch.sh <name> || pwsh -NoProfile -File <name>.ps1`), with a `timeout`.
5. Add behavior cases to BOTH `${CLAUDE_PLUGIN_ROOT}/tests/hooks.test.ps1` and `${CLAUDE_PLUGIN_ROOT}/tests/hooks.test.sh`.
6. Run `FRAMEWORK_ROOT="${CLAUDE_PLUGIN_ROOT:-.}" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/validate-hooks.sh"`, `pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT:-.}/tests/hooks.test.ps1"`, and `bash "${CLAUDE_PLUGIN_ROOT:-.}/tests/hooks.test.sh"`.
7. Hooks ship with the plugin via hooks/hooks.json — nothing is written to settings.json; restart the session to load them.

Full guidance (templates, worked example): `skills/hook-config-generator/SKILL.md`.

## Integration

- `${CLAUDE_PLUGIN_ROOT}/scripts/validate-consistency.sh` runs the same parity assertions as its check 3 — CI enforces them on every PR
- See `${CLAUDE_PLUGIN_ROOT}/docs/design/` for the design rationale behind each hook
