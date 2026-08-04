---
name: agent-debugger
description: Diagnose and fix agent routing, loading, and configuration issues by inspecting agents/*.md frontmatter, the claude.json registry, hook registration, and validator output — use when an agent is "not found", tasks route to the wrong specialist, models mismatch, hooks do not fire, or validate-consistency.sh fails.
---

# Agent Debugger

Systematic diagnosis of agent configuration problems in this framework. Every check below is grounded in real files — inspect configuration, run the validators, fix the source of truth, then re-verify. Do not invent runtime logs or metrics; this framework has none.

## Ground Truth: Where Configuration Lives

Configuration lives in the **agentic-framework plugin** (typically at `~/.claude/plugins/cache/agentic-framework/agentic-framework/*/`) and is overridden by user-scope copies in `~/.claude/agents/`, `~/.claude/commands/`, and `~/.claude/skills/`:

- `agents/<name>.md` — agent definition. YAML frontmatter carries `name` (must equal the filename), `description` (the routing trigger text Claude Code matches tasks against), `model` (tier shorthand, e.g. `sonnet`), `color`, and the optional `effort` (reasoning effort: low|medium|high|xhigh|max), `mcpServers` (list of MCP servers available to the agent; ignored by Claude Code for plugin-shipped agents), and `tools` (comma-separated explicit tool allowlist). The body is the agent's system prompt.
  - **Plugin location**: `~/.claude/plugins/cache/agentic-framework/agentic-framework/*/agents/<name>.md`
  - **Override location** (if present): `~/.claude/agents/<name>.md` (takes priority)
- `claude.json` — the registry. `.sub_agents` maps each agent to its config (including `model` shorthand and `focus`); `.agent_categories` partitions the roster into the canonical categories; `.consistency.model_shorthand_map` defines the only legal model values; `.consistency.deprecated_agent_names` lists dead names that must never be referenced.
  - **Plugin location**: `~/.claude/plugins/cache/agentic-framework/agentic-framework/*/claude.json`
- `hooks/hooks.json` — hook registration as shell-form dispatch chains (`sh dispatch.sh <name> || pwsh -NoProfile -File <name>.ps1`) with `${CLAUDE_PLUGIN_ROOT}` substitution; each hook is a `.ps1`/`.sh` pair routed by `hooks/dispatch.sh`. Hooks are loaded automatically by Claude Code.
  - **Plugin location**: `~/.claude/plugins/cache/agentic-framework/agentic-framework/*/hooks/hooks.json`
- `settings.template.json` — recommended permissions and `alwaysThinkingEnabled` for merging into user settings.
  - **Plugin location**: `~/.claude/plugins/cache/agentic-framework/agentic-framework/*/settings.template.json`
- Validators: `scripts/validate-consistency.sh` (the full anti-drift battery), `scripts/validate-hooks.sh` (hook pair parity + dispatch), `scripts/validate-framework.sh`, `scripts/generate-docs.sh --check`. Tests: `tests/hooks.test.ps1` (PowerShell), `tests/hooks.test.sh` (POSIX shell), `tests/hooks-equivalence.test.sh` (cross-platform byte-equality).
- Namespaced slash commands for quick inspection: `/agentic-framework:list-agents`, `/agentic-framework:agent-status`, `/agentic-framework:analyze-framework`, `/agentic-framework:validate-hooks`, `/agentic-framework:quality-report`.

**Note:** The cache path format is `{marketplace}/{plugin}/{version}/`; the repeated `agentic-framework/agentic-framework` segment is correct and intentional.

## Debug Workflow

1. **Classify the symptom**: not found / wrong routing / model error / hook not firing / validator failure.
2. **Run the battery first** — it localizes most problems for you:
   ```bash
   bash scripts/validate-consistency.sh   # numbered checks, PASS/FAIL per check, aggregates all failures
   ```
3. **Apply the matching playbook below.**
4. **Verify** (see Verify the Fix).

## Playbook: Agent Not Found or Not Loading

```bash
# Check plugin location first (default)
ls ~/.claude/plugins/cache/agentic-framework/agentic-framework/*/agents/<name>.md        # file exists, exactly matching name?
# Or check override location (if applicable)
ls ~/.claude/agents/<name>.md                                  # override present?

# Check registry
jq '.sub_agents["<name>"]' ~/.claude/plugins/cache/agentic-framework/agentic-framework/*/claude.json    # registered?

# Check frontmatter (from plugin or override)
head -10 ~/.claude/plugins/cache/agentic-framework/agentic-framework/*/agents/<name>.md   # frontmatter sane?
# or: head -10 ~/.claude/agents/<name>.md

# Check for deprecated names
jq -r '.consistency.deprecated_agent_names[]' ~/.claude/plugins/cache/agentic-framework/agentic-framework/*/claude.json   # is the name dead/legacy?
```

Check 1 of `validate-consistency.sh` reports both failure directions: `missing-md` (registered in `claude.json` but no `agents/<name>.md`) and `orphan-md` (file exists but not registered). Fix by adding the missing side, never by deleting the working side.

Frontmatter requirements: opens and closes with `---`; `name:` equals the filename stem; `description:` is a single line with concrete trigger phrasing; `model:` is a key of `.consistency.model_shorthand_map`; `color:` present. A malformed frontmatter block silently prevents loading — validate YAML before anything else.

Also confirm the agent appears in exactly one `.agent_categories` category (check 2 fails on missing or duplicated membership).

## Playbook: Task Routed to the Wrong Agent

Routing is driven by the `description` frontmatter of each agent (Claude Code matches the task against it) plus the routing tables in `CLAUDE.md` and the `/agentic-framework:delegate` command logic in `commands/delegate.md`.

1. Read the `description` of both the expected agent and the one that won. Overlapping trigger phrasing is the usual cause.
2. Sharpen the losing agent's description with concrete technologies, file types, and example triggers; remove ambiguous claims from the winner.
3. Check `CLAUDE.md`'s routing table lists the agent under the right domain, and that `.agent_categories` places it in the correct category.
4. For a one-off, add an explicit routing hint in the task itself ("use rust-expert").

Remember the review chain: `code-review-gatekeeper` reviews first; `peer-review-critic` is the mandatory final reviewer of branch-vs-base before work is declared done. Routing review work anywhere else is a routing bug.

## Playbook: Model Mismatch (Parity Check 7)

Both sides must hold the SAME tier shorthand, and each value must be a declared key of `.consistency.model_shorthand_map`:

```bash
grep -m1 '^model:' agents/<name>.md
jq -r '.sub_agents["<name>"].model' claude.json
jq -r '.consistency.model_shorthand_map | keys[]' claude.json
```

Check 7 fails on: missing frontmatter `model:`, empty registry model, a value not in the map (typos like `sonnett`), or any md-vs-registry divergence. Fix by editing BOTH files to the same shorthand — never introduce full model IDs in either place; the shorthand map is the single source of truth.

## Playbook: Hook Not Firing or Stop Gate Misbehaving

Hooks are real Claude Code hooks — PowerShell 7 (.ps1) and POSIX shell (.sh) script pairs, routed by dispatch.sh, registered in `hooks/hooks.json` of the agentic-framework plugin.

```bash
# Check plugin hook registration
jq '.hooks.Stop' ~/.claude/plugins/cache/agentic-framework/agentic-framework/*/hooks/hooks.json    # hook registration for Stop event

# Verify plugin is installed
/plugin list | grep agentic-framework

# Check hook scripts exist (each hook is a .ps1/.sh pair plus dispatch.sh)
ls ~/.claude/plugins/cache/agentic-framework/agentic-framework/*/hooks/*.ps1 \
   ~/.claude/plugins/cache/agentic-framework/agentic-framework/*/hooks/*.sh

# Validate hook registration parity
/agentic-framework:validate-hooks

# Verify pwsh 7+ is available
pwsh -NoProfile -Command '$PSVersionTable.PSVersion'

# Verify jq is available (required for POSIX hook implementations)
command -v jq && jq --version
```

Common causes, in order of likelihood:
- Plugin not installed or not enabled: run `/plugin install agentic-framework@agentic-framework` and verify with `/plugin list`.
- The session predates the plugin install: hooks load at session start, so restart Claude Code after installing.
- On Linux/macOS, `jq` missing from PATH — hooks load and fire (visible in transcript), but enforcement is disarmed. The `SessionStart` hook prints a `[session-context]` warning when jq is absent, confirming the symptom. Fix: install jq (`apt-get install jq` on Debian/Ubuntu; `brew install jq` on macOS), then restart Claude Code.
- Matcher mismatch: `record-subagent-run` fires on PostToolUse `Task|Agent` and on SubagentStop; `pretooluse-delegation-hint` on PreToolUse `Write|Edit` (each name = its `.ps1`/`.sh` pair). An event without a matching tool never fires.
- Plugin cache stale: try `/plugin uninstall agentic-framework` and then `/plugin install agentic-framework@agentic-framework`.

Check 3 of `validate-consistency.sh` asserts pair parity: every hook name in `hooks/hooks.json` has both .ps1 and .sh implementations; `dispatch.sh` is present and referenced in every registered chain; no orphans on either side. (The name allowlist inside dispatch.sh itself is not validator-checked — keep it in sync by hand.) Behavior is covered by `tests/hooks.test.ps1` (PowerShell) and `tests/hooks.test.sh` (POSIX).

Stop-gate specifics: `stop-peer-review-gate.ps1` blocks session end only when a feature branch has committed work ahead of its base and the latest `peer-review-critic` run this session did not record `VERDICT: APPROVED` (verdicts are parsed into the session marker by `record-subagent-run.ps1`; blocks are bounded — once with no review, up to 3 on `CHANGES_REQUIRED`). It is loop-safe and fail-open — if it appears to "block forever", verify the recorder hook is registered and firing, since the gate clears based on its records. Design rationale lives in `docs/design/`.

## Playbook: Consistency Validator Failures

`validate-consistency.sh` derives all truth at runtime from `claude.json` plus the filesystem — nothing is hardcoded. Read each FAIL line; it names the check and the offending items. Frequent ones:

- Check 5 (deprecated names): a doc or config still references a dead agent name. Replace with the current name from the registry.
- Check 8 (stated-count scan): a doc states a headline count that no longer matches derived reality. Do not hand-edit numbers into docs — remove the count or let the generator own it.
- Check 11 (stale generated blocks): run `bash scripts/generate-docs.sh --write` to regenerate, then re-check.
- Checks 9/10 (prose tables / README focus text): update the table cell to match `.sub_agents[<agent>].focus` or the roster exactly.

## Verify the Fix

```bash
bash scripts/validate-consistency.sh && echo OK   # must exit 0
bash scripts/validate-hooks.sh
bash scripts/generate-docs.sh --check
pwsh -NoProfile -File tests/hooks.test.ps1        # after any hook change
```

Then confirm the original symptom is gone (e.g. re-issue the task and watch it route correctly, or restart a session and confirm the hook fires).

## Prevention

- Edit `agents/<name>.md` and `claude.json` together, in the same commit; the validators treat divergence as a blocking failure.
- Never hardcode rosters, counts, or model IDs into docs — reference the registry (`claude.json`) and let `generate-docs.sh` produce derived content.
- Run the validator battery before every commit touching `agents/`, `hooks/`, `claude.json`, or `hooks/hooks.json`.
- After changing hook scripts or registration in `hooks/hooks.json`, reinstall or update the plugin and restart Claude Code.
- Beware leftover legacy clones in `~/.claude/` that shadow the plugin agents — run `/agentic-framework:migrate-legacy` to resolve.
