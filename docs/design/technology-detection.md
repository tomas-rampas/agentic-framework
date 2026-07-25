# Design: technology-detection (advisory delegation hint)

**Status: implemented** — `hooks/pretooluse-delegation-hint.ps1` (PreToolUse, matcher
`Write|Edit`), registered via the plugin's `hooks/hooks.json`.

## Purpose

When the main session writes a file whose extension maps to a specialist subagent
(`.rs` → rust-expert, `.py` → python-expert, `.cs` → csharp-expert, `.go` → go-expert,
`.java` → java-expert, `.ts/.tsx/.js/.jsx` → typescript-expert, `.sh` → bash-expert,
`.ps1` → powershell-expert, `.sql` → database-specialist, `.mq4/.mq5/.mqh` →
mql-trading-dev), surface a gentle reminder that the framework routes implementation
work to specialists.

## Behavior contract

- **Advisory only.** Emits a non-blocking JSON `systemMessage`; never denies the tool call.
- **Once per session per suggested agent.** A marker under
  `~/.claude/.state/delegation-hints/` keys on `<session_id>-<agent>`, so the hint cannot
  become a per-edit nag.
- **Fail-open.** Any error exits 0 silently.

## History

The legacy dispatcher printed this hint (plus several others) as plain stdout on
PreToolUse, which Claude Code does not show to the model on a successful call — so it
never reached anyone. The reimplementation uses the documented `systemMessage` channel
and drops the other advisory strings (zero-tolerance-quality, development-standards,
code-analysis, symbol-operations) as noise: guidance that belongs in CLAUDE.md and agent
prompts, not per-tool-call output.
