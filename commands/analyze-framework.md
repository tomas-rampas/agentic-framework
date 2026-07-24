---
name: analyze-framework
description: Perform comprehensive framework health check and analysis
---

# Framework Health Analysis Command

## Purpose

Perform a comprehensive analysis of the Claude Code CLI Agentic Framework, checking configuration integrity, agent availability, hook registration, and overall system health.

## Usage

```
/analyze-framework [--detailed] [--export]
```

**Options:**
- `--detailed`: Include detailed analysis of each component
- `--export`: Export results to `framework-health-report.md`

## Command-line execution
Delegate every shell command this workflow needs — validators, git/gh calls, JSON/YAML
processing, test and build runs — to **bash-expert** (POSIX/Git Bash) or
**powershell-expert** (PowerShell/Windows) instead of running it inline. Executors
return the exact command, its integer exit code, and a distilled result (verbatim
fenced where it will be used literally). Read files with Read/Grep/Glob directly —
never via shell.

## What This Command Does

The authoritative implementation is the anti-drift tooling — this command runs it and interprets the results:

```bash
bash scripts/validate-consistency.sh    # the full check battery (see CONTRIBUTING.md)
bash scripts/generate-docs.sh --check   # generated doc blocks are fresh
pwsh -NoProfile -File tests/hooks.test.ps1   # hook behavior tests
```

### 1. Configuration Validation

- **claude.json**: registry parses, all registered agents resolve to `agents/*.md` files (and vice versa), categories partition the roster
- **settings.template.json**: valid JSON; its `hooks` block is the canonical hook registration
- **.mcp.json**: valid JSON; servers are launchable specs

```bash
# Check claude.json structure (expected: matches `ls -1 agents/*.md | wc -l`)
jq '.sub_agents | length' claude.json

# Verify no deprecated agent names are referenced
bash scripts/validate-consistency.sh   # check 5 covers this
```

### 2. Agent Availability Assessment

Analyzes every registered agent using the canonical categories from `claude.json .agent_categories`:

- **language_experts** — rust-expert, csharp-expert, go-expert, java-expert, python-expert, typescript-expert, mql-trading-dev
- **automation_experts** — bash-expert, powershell-expert
- **domain_specialists** — database-specialist, frontend-specialist, security-specialist, uiux-specialist
- **infrastructure_operations** — devops-orchestrator
- **architecture_planning** — system-architect, product-owner
- **quality_analysis** — comprehensive-analyst, code-review-gatekeeper, peer-review-critic
- **documentation** — technical-docs-writer

**For each agent:**
- Agent file exists (`agents/{agent}.md`)
- Agent registered in `claude.json`
- YAML frontmatter valid; `model:` tier matches the registry (check 7)
- Agent appears in the prose rosters (README, CLAUDE.md, list-agents — checks 9/10)

### 3. Hook Architecture Analysis

Hooks are real Claude Code hooks: PowerShell scripts in `hooks/` registered in the settings `hooks` block (distributed via `settings.template.json`).

- Registration parity: every registered script exists; every script is registered; event names are valid; scripts pin PowerShell 7 (check 3)
- Behavior: `tests/hooks.test.ps1` exercises block/allow paths of the peer-review Stop gate, the run recorder, session context, and the delegation hint
- Design rationale: `docs/design/`

### 4. Skills System Check

Verifies the skills on disk parse and match the documented roster. See README's Skills table for the current list; counts are derived, never hardcoded.

### 5. Directory Structure Verification

```
claude-agentic-framework/
├── agents/                  ✓ (one .md per registered agent)
├── commands/                ✓ (9 commands)
├── hooks/                   ✓ (registered hook scripts)
├── skills/                  ✓ (operational skills)
├── scripts/                 ✓ (install + validation + doc generation)
├── tests/                   ✓ (consistency + hook harnesses)
├── docs/design/             ✓ (hook architecture rationale)
├── CLAUDE.md                ✓ (agent execution rules)
├── README.md                ✓ (documentation)
├── claude.json              ✓ (agent registry)
├── settings.template.json   ✓ (permissions + hook registration)
└── .mcp.json                ✓ (MCP servers)
```

### 6. Script Validation

- **validate-consistency.sh**: the full anti-drift check battery (single source of truth)
- **validate-framework.sh**: structural checks, then delegates to validate-consistency.sh
- **validate-hooks.sh**: hook registration parity (shared logic with check 3)
- **generate-docs.sh**: generated doc blocks (`--check` / `--write`)
- **install.ps1 / install.sh**: settings + hook installation into `~/.claude`

## Output Format

### Quick Summary (Default)

```
Claude Code CLI Framework Health Analysis
================================================

CONFIGURATION
   • claude.json: valid, registry == filesystem
   • settings.template.json: hooks registered, parity OK
   • .mcp.json: valid server specs

AGENTS
   • Registry == filesystem; all categories partition the roster; model parity OK

HOOKS
   • Registration parity OK (no missing, no orphans, events valid)
   • hooks.test.ps1: all assertions pass

DOCS
   • Generated blocks fresh; stated counts match derived values

OVERALL HEALTH: EXCELLENT
```

### Detailed Analysis (--detailed)

Includes:
- Individual agent status and configuration details
- Per-check validator output
- Hook test results
- Detected issues with remediation steps

### Export Report (--export)

Generates `framework-health-report.md` with executive summary, findings, remediation recommendations, and timestamp.

## Use Cases

### 1. Daily Health Check
```bash
/analyze-framework
```

### 2. Post-Update Validation
```bash
/analyze-framework --detailed
# After updating agents, hooks, or configuration
```

### 3. Documentation/Reporting
```bash
/analyze-framework --detailed --export
```

### 4. Troubleshooting
```bash
/analyze-framework --detailed
```

## Expected Issues and Remediation

**Missing agent file:**
```
FAIL Agents registered in claude.json with NO agents/<name>.md file
Remediation: create the agent file or remove the registry entry
```

**Hook parity break:**
```
FAIL registered hook script missing on disk: hooks/<name>.ps1
Remediation: restore the script, or remove its registration from settings.template.json
```

**Stale generated block:**
```
FAIL generate-docs.sh --check reported stale/invalid blocks
Remediation: bash scripts/generate-docs.sh --write
```

## Integration with Other Commands

- Use with `/validate-hooks` for hook-specific analysis
- Combine with `/list-agents` to see agent details
- Follow up with `/agent-status` for configuration status
- Use `/quality-report` for a quality assessment

## Notes

- Analysis is read-only and doesn't modify any files
- Safe to run at any time
- Requires bash + jq (validators) and PowerShell 7 (hook tests)
