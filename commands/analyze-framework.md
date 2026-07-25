---
name: analyze-framework
description: Perform comprehensive framework health check and analysis
---

Framework root: `${CLAUDE_PLUGIN_ROOT}` (when running from a development checkout of the framework itself, this may be empty — then use the current directory if it contains `claude.json`). All framework file paths below are relative to that root.

# /agentic-framework:analyze-framework — Framework Health Analysis

## Purpose

Perform a comprehensive analysis of the Claude Code CLI Agentic Framework, checking configuration integrity, agent availability, hook registration, and overall system health.

## Usage

```
/agentic-framework:analyze-framework [--detailed] [--export]
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
FRAMEWORK_ROOT="${CLAUDE_PLUGIN_ROOT:-.}" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/validate-consistency.sh"    # the full check battery (see CONTRIBUTING.md)
FRAMEWORK_ROOT="${CLAUDE_PLUGIN_ROOT:-.}" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/generate-docs.sh" --check   # generated doc blocks are fresh
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT:-.}/tests/hooks.test.ps1"   # hook behavior tests
```

### 1. Configuration Validation

- **${CLAUDE_PLUGIN_ROOT}/claude.json**: registry parses, all registered agents resolve to `${CLAUDE_PLUGIN_ROOT}/agents/*.md` files (and vice versa), categories partition the roster
- **${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json**: valid JSON; its `hooks` block is the canonical hook registration
- **${CLAUDE_PLUGIN_ROOT}/mcp-plugin/.mcp.json**: valid JSON; servers are launchable specs (optional agentic-framework-mcp plugin)

```bash
# Check claude.json structure (expected: matches `ls -1 ${CLAUDE_PLUGIN_ROOT}/agents/*.md | wc -l`)
jq '.sub_agents | length' "${CLAUDE_PLUGIN_ROOT:-.}/claude.json"

# Verify no deprecated agent names are referenced
FRAMEWORK_ROOT="${CLAUDE_PLUGIN_ROOT:-.}" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/validate-consistency.sh"   # check 5 covers this
```

### 2. Agent Availability Assessment

Analyzes every registered agent using the canonical categories from `${CLAUDE_PLUGIN_ROOT}/claude.json .agent_categories`:

- **language_experts** — rust-expert, csharp-expert, go-expert, java-expert, python-expert, typescript-expert, mql-trading-dev
- **automation_experts** — bash-expert, powershell-expert
- **domain_specialists** — database-specialist, frontend-specialist, security-specialist, uiux-specialist
- **infrastructure_operations** — devops-orchestrator
- **architecture_planning** — system-architect, product-owner
- **quality_analysis** — comprehensive-analyst, code-review-gatekeeper, peer-review-critic
- **documentation** — technical-docs-writer

**For each agent:**
- Agent file exists (`${CLAUDE_PLUGIN_ROOT}/agents/{agent}.md`)
- Agent registered in `${CLAUDE_PLUGIN_ROOT}/claude.json`
- YAML frontmatter valid; `model:` tier matches the registry (check 7)
- Agent appears in the prose rosters (README, CLAUDE.md, list-agents — checks 9/10)

### 3. Hook Architecture Analysis

Hooks are real Claude Code hooks: PowerShell scripts in `${CLAUDE_PLUGIN_ROOT}/hooks/` registered in the settings `hooks` block (distributed via `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json`).

- Registration parity: every registered script exists; every script is registered; event names are valid; scripts pin PowerShell 7 (check 3)
- Behavior: `${CLAUDE_PLUGIN_ROOT}/tests/hooks.test.ps1` exercises block/allow paths of the peer-review Stop gate, the run recorder, session context, and the delegation hint
- Design rationale: `${CLAUDE_PLUGIN_ROOT}/docs/design/`

### 4. Skills System Check

Verifies the skills on disk parse and match the documented roster. See README's Skills table for the current list; counts are derived, never hardcoded.

### 5. Directory Structure Verification

```
${CLAUDE_PLUGIN_ROOT}/
├── agents/                  ✓ (one .md per registered agent)
├── commands/                ✓ (10 commands)
├── hooks/                   ✓ (registered hook scripts)
├── skills/                  ✓ (operational skills)
├── scripts/                 ✓ (install + validation + doc generation)
├── tests/                   ✓ (consistency + hook harnesses)
├── docs/design/             ✓ (hook architecture rationale)
├── CLAUDE.md                ✓ (agent execution rules)
├── README.md                ✓ (documentation)
├── claude.json              ✓ (agent registry)
├── hooks/hooks.json         ✓ (hook registration)
├── settings.template.json   ✓ (recommended user settings: permissions)
└── mcp-plugin/.mcp.json     ✓ (MCP servers, optional plugin)
```

### 6. Script Validation

- **${CLAUDE_PLUGIN_ROOT}/scripts/validate-consistency.sh**: the full anti-drift check battery (single source of truth)
- **${CLAUDE_PLUGIN_ROOT}/scripts/validate-framework.sh**: structural checks, then delegates to validate-consistency.sh
- **${CLAUDE_PLUGIN_ROOT}/scripts/validate-hooks.sh**: hook registration parity (shared logic with check 3)
- **${CLAUDE_PLUGIN_ROOT}/scripts/generate-docs.sh**: generated doc blocks (`--check` / `--write`)
- **${CLAUDE_PLUGIN_ROOT}/scripts/install.ps1 / install.sh**: settings + hook installation into `~/.claude` (note: installer is deprecated in favor of the plugin pipeline)

## Output Format

### Quick Summary (Default)

```
Claude Code CLI Framework Health Analysis
================================================

CONFIGURATION
   • claude.json: valid, registry == filesystem
   • hooks/hooks.json: registration parity OK
   • mcp-plugin/.mcp.json: valid server specs

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
/agentic-framework:analyze-framework
```

### 2. Post-Update Validation
```bash
/agentic-framework:analyze-framework --detailed
# After updating agents, hooks, or configuration
```

### 3. Documentation/Reporting
```bash
/agentic-framework:analyze-framework --detailed --export
```

### 4. Troubleshooting
```bash
/agentic-framework:analyze-framework --detailed
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
Remediation: restore the script, or remove its registration from hooks/hooks.json
```

**Stale generated block:**
```
FAIL generate-docs.sh --check reported stale/invalid blocks
Remediation: bash scripts/generate-docs.sh --write
```

## Integration with Other Commands

- Use with `/agentic-framework:validate-hooks` for hook-specific analysis
- Combine with `/agentic-framework:list-agents` to see agent details
- Follow up with `/agentic-framework:agent-status` for configuration status
- Use `/agentic-framework:quality-report` for a quality assessment

## Notes

- Analysis is read-only and doesn't modify any files
- Safe to run at any time
- Requires bash + jq (validators) and PowerShell 7 (hook tests)
