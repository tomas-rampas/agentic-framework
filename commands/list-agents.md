---
name: list-agents
description: Display all available agents with capabilities and status
---

Framework root: `${CLAUDE_PLUGIN_ROOT}` (when running from a development checkout of the framework itself, this may be empty — then use the current directory if it contains `claude.json`). All framework file paths below are relative to that root.

# List Agents Command

## Purpose

Display comprehensive information about all 21 specialized agents in the framework, including their capabilities, specializations, model tier, and current status.

## Usage

```
/list-agents [filter] [--format=<table|json|detailed>]
```

**Filters:**
- `--language`: Show only language expert agents
- `--domain`: Show only domain specialist agents
- `--all`: Show all agents (default)
- `--category=<category>`: Filter by specific category
- `<agent-name>`: Show details for specific agent

**Formats:**
- `table`: Compact table format (default)
- `json`: Machine-readable JSON output
- `detailed`: Full details with descriptions

## Output Formats

### 1. Table Format (Default)

```
┌──────────────────────────┬─────────────────┬───────────┬────────────┐
│ Agent                    │ Category        │ Model     │ Status     │
├──────────────────────────┼─────────────────┼───────────┼────────────┤
│ rust-expert              │ Language        │ Sonnet    │ Ready      │
│ csharp-expert            │ Language        │ Sonnet    │ Ready      │
│ go-expert                │ Language        │ Sonnet    │ Ready      │
│ java-expert              │ Language        │ Sonnet    │ Ready      │
│ python-expert            │ Language        │ Sonnet    │ Ready      │
│ typescript-expert        │ Language        │ Sonnet    │ Ready      │
│ mql-trading-dev          │ Language        │ Opus      │ Ready      │
│ bash-expert              │ Automation      │ Haiku     │ Ready      │
│ powershell-expert        │ Automation      │ Haiku     │ Ready      │
│ database-specialist      │ Domain          │ Sonnet    │ Ready      │
│ frontend-specialist      │ Domain          │ Sonnet    │ Ready      │
│ security-specialist      │ Domain          │ Sonnet    │ Ready      │
│ uiux-specialist          │ Domain          │ Haiku     │ Ready      │
│ devops-orchestrator      │ Infrastructure  │ Sonnet    │ Ready      │
│ system-architect         │ Architecture    │ Opus      │ Ready      │
│ product-owner            │ Planning        │ Sonnet    │ Ready      │
│ comprehensive-analyst    │ Analysis        │ Sonnet    │ Ready      │
│ code-review-gatekeeper   │ Quality         │ Opus      │ Ready      │
│ peer-review-critic       │ Quality         │ Opus      │ Ready      │
│ spec-compliance-reviewer │ Quality         │ Sonnet    │ Ready      │
│ technical-docs-writer    │ Documentation   │ Haiku     │ Ready      │
└──────────────────────────┴─────────────────┴───────────┴────────────┘

Total: 21 agents (21 ready, 0 unavailable)
Quality enforcement is framework-wide: every agent's committed work passes the
peer-review Stop gate (${CLAUDE_PLUGIN_ROOT}/hooks/stop-peer-review-gate.ps1) before a session ends.
```

### 2. Category View (--language)

```
🔧 LANGUAGE EXPERTS (9 agents)

┌───────────────────┬────────────────────────────────────────────────┬────────┐
│ Agent             │ Specialization                                  │ Status │
├───────────────────┼────────────────────────────────────────────────┼────────┤
│ rust-expert       │ Rust systems programming, CLI tools             │ ✅ Ready│
│ csharp-expert     │ C#/.NET, ASP.NET Core, Azure solutions         │ ✅ Ready│
│ go-expert         │ Go microservices, cloud-native applications    │ ✅ Ready│
│ java-expert       │ Java/Spring Boot, enterprise apps, Android     │ ✅ Ready│
│ python-expert     │ Python web, data science, automation           │ ✅ Ready│
│ typescript-expert │ TypeScript/JS, React/Next.js, Node.js          │ ✅ Ready│
│ mql-trading-dev   │ MQL4/MQL5, MetaTrader, trading systems          │ ✅ Ready│
│ bash-expert       │ CLI executor; Bash scripting, Linux automation │ ✅ Ready│
│ powershell-expert │ Windows CLI executor; PowerShell automation    │ ✅ Ready│
└───────────────────┴────────────────────────────────────────────────┴────────┘
```

### 3. Detailed View (--format=detailed <agent-name>)

```
🤖 Agent: rust-expert
═══════════════════════════════════════════════════════════

📋 BASIC INFORMATION
  • Name: rust-expert
  • Category: Language Expert
  • Model: sonnet (resolves to claude-sonnet-4-6)
  • Specialization: rust_development_systems_programming
  • File: ${CLAUDE_PLUGIN_ROOT}/agents/rust-expert.md
  • Configuration: ${CLAUDE_PLUGIN_ROOT}/claude.json ✓

🎯 CAPABILITIES
  • Rust systems programming
  • High-performance applications
  • CLI tool development
  • Memory safety and ownership patterns
  • Async/concurrent programming
  • FFI and unsafe code
  • Cargo ecosystem and crate development

🔧 QUALITY ENFORCEMENT
  • Framework-wide: committed work passes the peer-review Stop gate
    (${CLAUDE_PLUGIN_ROOT}/hooks/stop-peer-review-gate.ps1) before a session can end
  • Review chain: code-review-gatekeeper → peer-review-critic

🔗 RELATED AGENTS
  • Works with: code-review-gatekeeper, security-specialist
  • Alternative for: C/C++ systems programming tasks
  • Delegates to: comprehensive-analyst for debugging

📚 DOCUMENTATION
  • Agent Guide: ${CLAUDE_PLUGIN_ROOT}/agents/rust-expert.md
  • Examples: See delegate.md for routing examples
```

### 4. JSON Format (--format=json)

```json
{
  "agents": [
    {
      "name": "rust-expert",
      "category": "language_expert",
      "model": "sonnet",
      "specialization": "rust_development_systems_programming",
      "file_path": "${CLAUDE_PLUGIN_ROOT}/agents/rust-expert.md",
      "status": "ready",
      "capabilities": [
        "Rust systems programming",
        "CLI tool development",
        "Memory safety patterns"
      ]
    }
  ],
  "summary": {
    <!-- BEGIN GENERATED: list-agents-summary -->
    "total_agents": 21,
    "ready": 21,
    "unavailable": 0,
    "categories": {
      "language_experts": 9,
      "domain_specialists": 4,
      "infrastructure": 1,
      "architecture_planning": 2,
      "quality_analysis": 4,
      "documentation": 1
    }
    <!-- END GENERATED: list-agents-summary -->
  }
}
```

## Agent Categories

### Language Experts (9 agents)
```
rust-expert          → Rust systems programming
csharp-expert        → C#/.NET development
go-expert            → Go microservices
java-expert          → Java/Spring Boot
python-expert        → Python development
typescript-expert    → TypeScript/JavaScript
mql-trading-dev      → MQL4/MQL5 & MetaTrader trading systems
bash-expert          → Command-line execution & shell scripting
powershell-expert    → Windows command-line execution & PowerShell
```

### Domain Specialists (4 agents)
```
database-specialist  → Database design, SQL/NoSQL
frontend-specialist  → Frontend UI, React/Vue/Angular
security-specialist  → Security audits, OWASP compliance
uiux-specialist      → UI/UX design, accessibility
```

### Infrastructure & Planning (3 agents)
```
devops-orchestrator  → Infrastructure, CI/CD, deployment
system-architect     → Architecture design, patterns
product-owner        → Requirements, user stories
```

### Quality & Analysis (4 agents)
```
comprehensive-analyst    → Deep analysis, investigation
code-review-gatekeeper  → Code review, quality enforcement
peer-review-critic      → Independent peer review, final gate
spec-compliance-reviewer → Spec conformance, build vs specs/<name>.md
```

### Documentation (1 agent)
```
technical-docs-writer   → Documentation, guides
```

## Common Use Cases

### 1. Quick Reference
```bash
/list-agents
# See all agents at a glance
```

### 2. Find Agent for Task
```bash
/list-agents --language
# See language experts for code development
```

### 3. Agent Details
```bash
/list-agents rust-expert --format=detailed
# Get full details about Rust expert
```

### 4. Export Agent Catalog
```bash
/list-agents --format=json > agents-catalog.json
# Export for documentation or tooling
```

### 5. Category Filtering
```bash
/list-agents --category=domain
# Show only domain specialists
```

## Agent Selection Guide

**For Code Development:**
- Language-specific → Use appropriate language expert
- Database work → database-specialist
- Frontend UI → frontend-specialist + uiux-specialist
- DevOps/Infrastructure → devops-orchestrator

**For Analysis & Planning:**
- System design → system-architect
- Requirements → product-owner
- Investigation → comprehensive-analyst
- Code review → code-review-gatekeeper

**For Quality & Documentation:**
- Security audit → security-specialist
- Code review → code-review-gatekeeper
- Documentation → technical-docs-writer
- UI/UX design → uiux-specialist

## Status Indicators

- **✅ Ready**: Agent available and fully functional
- **⚠️ Limited**: Agent available but missing some components
- **❌ Unavailable**: Agent configuration missing or broken
- **🔧 Maintenance**: Agent temporarily disabled for updates

## Integration

Works well with:
- `/delegate` - Route tasks to agents
- `/analyze-framework` - Check agent health
- `/agent-status` - Runtime agent information
- `/quality-report` - Framework quality assessment

## Implementation Notes

Agent information sourced from:
1. **${CLAUDE_PLUGIN_ROOT}/agents/*.md** - Agent definitions and capabilities
2. **${CLAUDE_PLUGIN_ROOT}/claude.json** - Agent configuration and models
3. **${CLAUDE_PLUGIN_ROOT}/CLAUDE.md** - Agent execution rules and routing

## Quick Filters

```bash
# By technology
/list-agents rust-expert                    # Specific agent
/list-agents --language                     # All language experts
/list-agents --domain                       # All specialists

# By capability
/list-agents --category=quality             # Quality agents
/list-agents --category=architecture        # Architecture agents

# Export formats
/list-agents --format=json                  # Machine-readable
/list-agents --format=detailed              # Human-readable
/list-agents --format=table                 # Compact view
```

## Notes

- Agent list is derived from `${CLAUDE_PLUGIN_ROOT}/claude.json` and `${CLAUDE_PLUGIN_ROOT}/agents/*.md` (no hardcoded roster)
- Status reflects configuration state (file presence, registry parity, model parity)
- Use `/agent-status` for per-agent configuration detail
- Combine with `/analyze-framework` for comprehensive view
