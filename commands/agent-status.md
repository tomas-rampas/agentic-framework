---
name: agent-status
description: Display configuration status and health information for framework agents
---

Framework root: `${CLAUDE_PLUGIN_ROOT}` (when running from a development checkout of the framework itself, this may be empty — then use the current directory if it contains `claude.json`). All framework file paths below are relative to that root.

# /agentic-framework:agent-status — Agent Configuration Status

## Purpose

Check the configuration status and health of all 21 specialized agents in the framework by inspecting actual configuration files.

## Usage

```
/agentic-framework:agent-status [agent-name]
```

## Command-line execution
Run short shell commands inline — git/gh calls, jq one-liners, quick checks.
Delegate only the long, output-heavy runs this workflow needs — the validator
battery, full test and build runs, log grinding — to **bash-expert**
(POSIX/Git Bash) or **powershell-expert** (PowerShell/Windows), where hundreds of
output lines compress to a verdict. Executors return the exact command, its integer
exit code, and a distilled result (verbatim fenced where it will be used literally).
Read files with Read/Grep/Glob directly — never via shell.

## What This Command Does

### 1. Read Agent Configuration

Read `${CLAUDE_PLUGIN_ROOT}/claude.json` and extract all agent entries from the `sub_agents` section. For each agent, report:
- **Name** and **specialization**
- **Model** assignment (opus/sonnet/haiku)
- **Enabled** status
- Whether the agent definition file exists in `${CLAUDE_PLUGIN_ROOT}/agents/`

### 2. Verify Agent Files

For each agent in `${CLAUDE_PLUGIN_ROOT}/claude.json`, check:
- Agent markdown file exists: `${CLAUDE_PLUGIN_ROOT}/agents/{agent-name}.md`
- Agent frontmatter contains required fields: `name`, `description` (plus optional `model`, `color`)
- Model in frontmatter matches the tier in `claude.json` (validator check 7)

### 3. Report Status

Display a summary table:

```
Agent                    | Model   | File | Status
-------------------------|---------|------|-------
rust-expert              | sonnet  | ✓    | Ready
csharp-expert            | sonnet  | ✓    | Ready
...
```

### 4. Single Agent Detail

When a specific agent name is provided, show detailed information:
- Full configuration from `claude.json`
- Frontmatter fields from the agent `.md` file
- Category membership

## Status Indicators

- **Ready** — Agent file exists, registered in claude.json, model parity OK
- **Limited** — Agent file exists but configuration mismatch (e.g. model divergence)
- **Unavailable** — Agent in claude.json but file missing

Quality enforcement is framework-wide, not per-agent: every agent's committed work passes through the peer-review Stop gate (the `stop-peer-review-gate` hook pair in `${CLAUDE_PLUGIN_ROOT}/hooks/`), so there is no per-agent hook to check.

## Expected Agent Count

The roster and its categories are defined in `${CLAUDE_PLUGIN_ROOT}/claude.json` (`.sub_agents` + `.agent_categories`) — counts below reflect the current registry:
- **Language Experts** (7): rust, csharp, go, java, python, typescript, mql-trading-dev
- **Automation Experts** (2): bash, powershell
- **Domain Specialists** (4): database, frontend, security, uiux
- **Infrastructure** (1): devops-orchestrator
- **Architecture & Planning** (2): system-architect, product-owner
- **Quality & Analysis** (4): comprehensive-analyst, code-review-gatekeeper, peer-review-critic, spec-compliance-reviewer
- **Documentation** (1): technical-docs-writer

## Integration

Works with:
- `/agentic-framework:list-agents` — Agent catalog with capabilities
- `/agentic-framework:validate-hooks` — Hook coverage verification
- `/agentic-framework:analyze-framework` — Overall framework health
