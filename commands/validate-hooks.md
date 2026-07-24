---
name: validate-hooks
description: Validate hook registration, consistency, and configuration
---

# Validate Hooks Command

## Purpose

Validate the framework's hook architecture: registration parity between `settings.template.json` and the hook scripts in `hooks/`, event-name validity, PowerShell 7 pinning, deprecated-name references, and (optionally) hook behavior.

## Usage

```
/validate-hooks [--behavior]
```

**Options:**
- (default): run the registration/consistency validation
- `--behavior`: additionally run the hook behavior test harness (`tests/hooks.test.ps1`)

## How Hooks Work in This Framework

Claude Code executes only hooks registered in a settings file's `hooks` block. This framework tracks that registration in `settings.template.json` (installed into `~/.claude/settings.json` by `scripts/install.ps1`) and implements each hook as a PowerShell 7 script in `hooks/`:

| Script | Event | Matcher | Role |
|--------|-------|---------|------|
| `stop-peer-review-gate.ps1` | `Stop` | — | Blocking peer-review final gate |
| `record-subagent-run.ps1` | `PostToolUse` + `SubagentStop` | `Task\|Agent` / — | Records peer-review-critic runs and parses the report's `VERDICT:` line into the session marker (`APPROVED` unlocks the gate) |
| `session-start-context.ps1` | `SessionStart` | — | Injects branch/review status into context |
| `pretooluse-delegation-hint.ps1` | `PreToolUse` | `Write\|Edit` | Advisory specialist-agent hint |

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
bash scripts/validate-hooks.sh
```

It asserts:

1. **Registration parity** — every script referenced in the settings template's `hooks` block exists in `hooks/`; every `hooks/*.ps1` on disk is registered (no dead scripts).
2. **Event validity** — every event key is a real Claude Code hook event (`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Notification`, `Stop`, `SubagentStop`, `SessionStart`, `SessionEnd`, `PreCompact`).
3. **PowerShell pin** — every hook script starts with `#Requires -Version 7.0`.
4. **No deprecated agent names** referenced by any hook script.

## Behavior Validation (--behavior)

```bash
pwsh -NoProfile -File tests/hooks.test.ps1
```

Exercises the hook scripts against a throwaway git repo and isolated state directory:
- Stop gate: blocks on a clean feature branch with unreviewed or `CHANGES_REQUIRED`-reviewed commits (once with no marker, up to 3 blocks total on `CHANGES_REQUIRED`); allows on `stop_hook_active`, dirty tree, base branch, non-git cwd, `verdict=APPROVED` or legacy no-verdict markers; fail-open on malformed stdin
- Recorder: writes/ignores markers correctly across `PostToolUse` and `SubagentStop` payload shapes, parses the anchored `VERDICT:` line (last whole-line match wins), and never downgrades a verdict-bearing marker
- Session context and delegation hint: correct output and once-per-session behavior

## Sample Output

```
Hook Architecture Validation
============================

Checking hook registration parity (settings.template.json <-> hooks/*.ps1)...

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
Remediation: restore hooks/stop-peer-review-gate.ps1, or remove its registration
             from settings.template.json (and re-run scripts/install.ps1)
```

**Orphan script (dead code):**
```
ERROR [orphan-hook-script] my-new-hook.ps1
Remediation: register it in settings.template.json under the right event, or delete it
```

**Unknown event name:**
```
ERROR [invalid-hook-event] OnStop
Remediation: use a real Claude Code event (e.g. Stop)
```

## Adding a New Hook

1. Create `hooks/<name>.ps1` starting with `#Requires -Version 7.0`; read the event JSON from stdin; **fail open** (any error → `exit 0`).
2. Register it in `settings.template.json` under the appropriate event, with a `timeout`.
3. Add behavior cases to `tests/hooks.test.ps1`.
4. Run `bash scripts/validate-hooks.sh` and `pwsh -NoProfile -File tests/hooks.test.ps1`.
5. Re-run `pwsh scripts/install.ps1 -Force` to update your live `~/.claude/settings.json`.

## Integration

- `validate-consistency.sh` runs the same parity assertions as its check 3 — CI enforces them on every PR
- See `docs/design/` for the design rationale behind each hook
