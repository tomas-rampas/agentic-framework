---
name: quality-report
description: Generate a framework quality assessment based on actual configuration state
---

Framework root: `${CLAUDE_PLUGIN_ROOT}` (when running from a development checkout of the framework itself, this may be empty — then use the current directory if it contains `claude.json`). All framework file paths below are relative to that root.

# /agentic-framework:quality-report — Framework Quality Assessment

## Purpose

Generate a quality assessment of the framework by inspecting actual configuration files, agent definitions, hook coverage, and structural integrity.

## Usage

```
/agentic-framework:quality-report [--detailed]
```

## Command-line execution
Delegate every shell command this workflow needs — validators, git/gh calls, JSON/YAML
processing, test and build runs — to **bash-expert** (POSIX/Git Bash) or
**powershell-expert** (PowerShell/Windows) instead of running it inline. Executors
return the exact command, its integer exit code, and a distilled result (verbatim
fenced where it will be used literally). Read files with Read/Grep/Glob directly —
never via shell.

## What This Command Does

### 1. Configuration Integrity

Validate core configuration files:
- `${CLAUDE_PLUGIN_ROOT}/claude.json` — Parse JSON, verify the registry matches `${CLAUDE_PLUGIN_ROOT}/agents/`, check required fields
- `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` — Parse JSON, verify the hook registration block
- `${CLAUDE_PLUGIN_ROOT}/settings.template.json` — Parse JSON, verify the recommended user settings (permissions block, `alwaysThinkingEnabled`)
- `${CLAUDE_PLUGIN_ROOT}/mcp-plugin/.mcp.json` — Parse JSON, verify MCP server definitions (ships in the optional agentic-framework-mcp plugin)

### 2. Agent Coverage

Check agent ecosystem completeness:
- All 21 agents have definition files in `${CLAUDE_PLUGIN_ROOT}/agents/`
- All agent files have valid YAML frontmatter (name, description, model, color)
- Agent model fields match `${CLAUDE_PLUGIN_ROOT}/claude.json` assignments
- No orphaned agent files (files without `${CLAUDE_PLUGIN_ROOT}/claude.json` entries)

### 3. Hook Architecture

Assess the real hook system:
- Registration parity: every script in `${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json` exists in `${CLAUDE_PLUGIN_ROOT}/hooks/`, and vice versa (no dead scripts)
- All event names are valid Claude Code hook events; all scripts pin PowerShell 7
- Hook behavior tests pass (`${CLAUDE_PLUGIN_ROOT}/tests/hooks.test.ps1`)
- No references to deprecated agent names

### 4. Structural Integrity

Verify directory structure:
- `${CLAUDE_PLUGIN_ROOT}/agents/` — one definition file per registered agent
- `${CLAUDE_PLUGIN_ROOT}/commands/` — Slash command definitions
- `${CLAUDE_PLUGIN_ROOT}/hooks/` — Registered hook scripts
- `${CLAUDE_PLUGIN_ROOT}/skills/` — Skill definitions
- `${CLAUDE_PLUGIN_ROOT}/scripts/` — Install + validation scripts
- `${CLAUDE_PLUGIN_ROOT}/tests/` — Consistency + hook harnesses

### 5. Quality Score

Calculate a quality score based on:

```
Quality Score = (
  Config Integrity     × 0.20 +
  Agent Coverage       × 0.25 +
  Hook Architecture    × 0.25 +
  Frontmatter Quality  × 0.15 +
  Structural Integrity × 0.15
) × 100
```

### Rating Scale

- **90-100**: Excellent — Framework fully configured and consistent
- **80-89**: Good — Minor gaps, fully functional
- **70-79**: Acceptable — Some missing hooks or configuration issues
- **60-69**: Needs Improvement — Significant gaps affecting quality
- **Below 60**: Critical — Structural issues require immediate attention

## Output Format

```
FRAMEWORK QUALITY REPORT
========================

Configuration Integrity:  ✓ claude.json valid (registry == filesystem)
                         ✓ hooks/hooks.json valid (registration parity OK)
                         ✓ mcp-plugin/.mcp.json valid

Agent Coverage:          all registered agents have definition files
                         all agent frontmatter valid (model parity OK)
                         0 orphaned files

Hook Architecture:       registration parity OK (no missing, no orphans)
                         all events valid; all scripts pin PS7
                         hooks.test.ps1: all assertions pass
                         0 deprecated agent references

Structural Integrity:    ✓ All required directories present
                         ✓ Validation scripts present

Quality Score: 95/100 (Excellent)
```

## Detailed Mode (--detailed)

When `--detailed` is specified, additionally:
- List each agent with its configuration status
- List each hook file with validation result
- Show any mismatches between agent frontmatter and claude.json
- Report specific issues with remediation suggestions

## Integration

Works with:
- `/agentic-framework:agent-status` — Individual agent health
- `/agentic-framework:validate-hooks` — Deep hook validation
- `/agentic-framework:analyze-framework` — Comprehensive framework analysis
