---
name: agent-status
description: Display configuration status and health information for framework agents
---

# Agent Status Command

## Purpose

Check the configuration status and health of all 21 specialized agents in the framework by inspecting actual configuration files.

## Usage

```
/agent-status [agent-name]
```

## Command-line execution
Delegate every shell command this workflow needs — validators, git/gh calls, JSON/YAML
processing, test and build runs — to **bash-expert** (POSIX/Git Bash) or
**powershell-expert** (PowerShell/Windows) instead of running it inline. Executors
return the exact command, its integer exit code, and a distilled result (verbatim
fenced where it will be used literally). Read files with Read/Grep/Glob directly —
never via shell.

## What This Command Does

### 1. Read Agent Configuration

Read `claude.json` and extract all agent entries from the `sub_agents` section. For each agent, report:
- **Name** and **specialization**
- **Model** assignment (opus/sonnet/haiku)
- **Enabled** status
- Whether the agent definition file exists in `agents/`

### 2. Verify Agent Files

For each agent in `claude.json`, check:
- Agent markdown file exists: `agents/{agent-name}.md`
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

Quality enforcement is framework-wide, not per-agent: every agent's committed work passes through the peer-review Stop gate (`hooks/stop-peer-review-gate.ps1`), so there is no per-agent hook to check.

## Expected Agent Count

The roster and its categories are defined in `claude.json` (`.sub_agents` + `.agent_categories`) — counts below reflect the current registry:
- **Language Experts** (7): rust, csharp, go, java, python, typescript, mql-trading-dev
- **Automation Experts** (2): bash, powershell
- **Domain Specialists** (4): database, frontend, security, uiux
- **Infrastructure** (1): devops-orchestrator
- **Architecture & Planning** (2): system-architect, product-owner
- **Quality & Analysis** (4): comprehensive-analyst, code-review-gatekeeper, peer-review-critic, spec-compliance-reviewer
- **Documentation** (1): technical-docs-writer

## Integration

Works with:
- `/list-agents` — Agent catalog with capabilities
- `/validate-hooks` — Hook coverage verification
- `/analyze-framework` — Overall framework health
