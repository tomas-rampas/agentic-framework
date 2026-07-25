# Claude Code CLI - Agent Execution Framework

A configuration framework for [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) that adds 21 specialized agents, a real peer-review enforcement gate, an anti-drift consistency system, and intelligent task routing.

**This is NOT a standalone tool** — it requires Claude Code CLI as the underlying platform.

---

## Overview

This framework extends Claude Code CLI with:

- **21 Specialized Agents** covering the full development lifecycle
- **Real Enforcement Hooks** — a blocking peer-review Stop gate plus session-context and delegation-hint hooks, registered via `settings.template.json` and covered by tests
- **Anti-Drift Consistency System** — dynamic validator, doc generator, and CI gate that keep the registry, docs, and filesystem in lockstep
- **MCP Integration** — 5 MCP servers for code intelligence, file operations, documentation lookup, structured reasoning, and web fetching

---

## Prerequisites

| Requirement | Purpose |
|-------------|---------|
| **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)** | Agent execution platform (required) |
| **Git** | Version control |
| **PowerShell 7.3+ (`pwsh`)** | Runs the hook scripts (`hooks/*.ps1`, 7.0+) and the installer (`scripts/install.ps1`, 7.3+ for order-preserving case-sensitive JSON parsing) — required on every platform |
| **bash + jq** | Validation and doc-generation tooling (Git Bash works on Windows) |
| **gh + yq** | Command-line executor agents (bash-expert / powershell-expert): GitHub CLI queries and YAML processing; run `gh auth login` once. yq is mikefarah v4 |
| **Node.js/npm** | filesystem, context7, sequential-thinking MCP servers via `npx` |
| **uv (`uvx`)** | serena + fetch MCP servers |
| **shellcheck** | Shell-script linting (optional, used by CI) |

### Install Claude Code CLI

```bash
# macOS
brew install --cask claude-code

# Linux / WSL
curl -fsSL https://anthropic.com/install-claude.sh | sh

# Verify
claude --version
```

### Configure MCP Servers

This repo ships a project-level `.mcp.json` with five servers:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem",
               "${MCP_FS_ROOT:-D:/src/github/claude-agentic-framework}"]
    },
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp"],
      "env": { "CONTEXT7_API_KEY": "${CONTEXT7_API_KEY:-}" }
    },
    "serena": {
      "command": "uvx",
      "args": ["--from", "git+https://github.com/oraios/serena",
               "serena", "start-mcp-server", "--context", "ide-assistant"]
    },
    "sequential-thinking": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-sequential-thinking"]
    },
    "fetch": {
      "command": "uvx",
      "args": ["mcp-server-fetch"]
    }
  }
}
```

Set `MCP_FS_ROOT` (and optionally `CONTEXT7_API_KEY`) in your environment or `.env` — see `.env.example`. Note that a project-level `.mcp.json` only applies to sessions started inside this directory; to make a server available in every project, register it with `claude mcp add --scope user` instead.

| MCP Server | Purpose | Runtime |
|------------|---------|---------|
| **filesystem** | Enhanced file operations for large files and atomic updates | Node.js (`npx`) |
| **context7** | External documentation and best practices lookup | Node.js (`npx`) |
| **serena** | Semantic code intelligence and symbol operations | Python (`uvx`) |
| **sequential-thinking** | Structured step-by-step reasoning for complex problem decomposition | Node.js (`npx`) |
| **fetch** | Web content fetching and conversion for efficient page consumption | Python (`uvx`) |

---

## Installation

```bash
# 1. Clone into the Claude Code CLI config directory (or anywhere you like)
git clone <your-framework-repo> ~/.claude
cd ~/.claude

# 2. Install the runtime surface (settings.json from the template, hook
#    registration, session-state directory). Refuses to clobber an existing
#    hooks block unless -Force is passed.
pwsh -NoProfile -File scripts/install.ps1        # Windows / any OS with pwsh
# or: bash scripts/install.sh                    # Linux / macOS / WSL

# 3. Validate framework integrity
bash scripts/validate-consistency.sh
```

Notes:
- `settings.json` is **not** tracked — it is created from `settings.template.json` by the installer, so your local permission tweaks never end up in git.
- The installer prints a per-item report (hooks new/updated/unchanged, settings action, MCP merge results, framework-surface sync state) and ends with a summary.
- **MCP merge is non-destructive**: the framework's MCP servers are merged into the user-scope `~/.claude.json` — missing servers are added (with `${VAR:-default}` placeholders expanded from your environment), existing definitions are **never overwritten**, and a timestamped backup is written before any change. Skip the step with `-SkipMcp`.
- If `~/.claude` is a git clone of this framework, the installer reports when its checkout (commands/agents/skills) is behind this repo — sync it with `git -C ~/.claude pull`; the installer deliberately does not touch those surfaces.
- Secrets/paths for MCP servers come from your environment or `.env` (copy `.env.example`); if `.claude/settings.local.json` lists servers under `disabledMcpjsonServers`, remove the ones you want active.
- Restart any running Claude Code session after installing so the hooks load.

---

## Quick Start

```bash
# Start Claude Code CLI
claude

# Or start with a specific task
claude "Create a REST API in Rust with JWT authentication"
```

Tasks are automatically routed to the appropriate agent. Examples:

```
"Create user stories for authentication feature"        → product-owner
"Design microservices architecture"                      → system-architect
"Implement JWT authentication in Rust"                   → rust-expert
"Create ASP.NET Core REST API with Entity Framework"     → csharp-expert
"Build gRPC microservice in Go"                          → go-expert
"Build a Fisher Transform indicator for MetaTrader 5"    → mql-trading-dev
"Review pull request for code quality"                   → code-review-gatekeeper
"Set up Kubernetes deployment with Helm"                 → devops-orchestrator
"Write API documentation for REST endpoints"             → technical-docs-writer
"Analyze codebase security vulnerabilities"              → comprehensive-analyst
```

---

## Pipeline at a Glance

How the commands, self-scoring loop, review chain, and Stop gate fit together:

![The /spec → /build → /delegate pipeline](docs/pipeline-infographic.png)

---

## Agents

### Planning & Requirements
| Agent | Focus |
|-------|-------|
| **product-owner** | User stories, backlog management, acceptance criteria |

### Architecture & Analysis
| Agent | Focus |
|-------|-------|
| **system-architect** | System design, technology selection, SOLID principles |
| **comprehensive-analyst** | Security audits, performance profiling, investigation |
| **code-review-gatekeeper** | Code review, quality gates, standards compliance |
| **peer-review-critic** | Final independent peer review — diff-scoped gatekeeper (branch vs base) |
| **spec-compliance-reviewer** | Requirement-by-requirement spec conformance review (specs/<name>.md) |

### Language Experts
| Agent | Focus |
|-------|-------|
| **rust-expert** | Systems programming, memory safety, async/await |
| **csharp-expert** | ASP.NET Core, Entity Framework, Azure |
| **go-expert** | Microservices, gRPC, Kubernetes operators |
| **java-expert** | Spring Boot, Maven/Gradle, enterprise apps |
| **python-expert** | Django/Flask, data science, automation |
| **typescript-expert** | React/Next.js, Node.js, frontend/backend |
| **mql-trading-dev** | MQL4/MQL5, C/C++ DLLs, MetaTrader trading systems |

### Scripting & Automation
| Agent | Focus |
|-------|-------|
| **bash-expert** | Command-line executor; shell scripting, Linux/CI automation |
| **powershell-expert** | Windows command-line executor; PowerShell automation |

### Specialized Domains
| Agent | Focus |
|-------|-------|
| **database-specialist** | Schema design, query optimization, SQL/NoSQL |
| **frontend-specialist** | React/Vue/Angular, responsive design, accessibility |
| **security-specialist** | Vulnerability assessment, compliance, auth |
| **uiux-specialist** | User flows, design systems, wireframing |

### Infrastructure & Documentation
| Agent | Focus |
|-------|-------|
| **devops-orchestrator** | CI/CD, containers, cloud deployment, monitoring |
| **technical-docs-writer** | API docs, user guides, architecture docs |

---

## Project Structure

```
~/.claude/
├── CLAUDE.md                # Agent execution rules and task routing
├── claude.json              # Agent registry (single source of truth for the tooling)
├── .mcp.json                # MCP server definitions (filesystem, context7, serena, sequential-thinking, fetch)
├── settings.template.json   # Tracked settings template: permissions + hook registration
├── agents/                  # 21 agent definitions (.md with YAML frontmatter)
├── commands/                # 9 commands (delegate, spec, build, review-spec, etc.)
├── hooks/                   # Real hook scripts (peer-review Stop gate, recorder, session context, delegation hint)
├── skills/                  # Operational skills
├── scripts/                 # Install, validation, anti-drift consistency, and doc-generation scripts
├── tests/                   # Consistency + hook test harnesses
├── docs/design/             # Design rationale for the hook architecture
├── .github/workflows/       # CI (anti-drift consistency gate)
└── security-check.sh        # Security validation
```

---

## Management Commands

| Command | Purpose |
|---------|---------|
| `/delegate` | End-to-end orchestration: auto-runs the `/spec` interview when no source of truth exists, then hands off to `/build` (single feature) or per-todo orchestration (multi-domain) |
| `/analyze-framework` | Framework health checking and validation |
| `/list-agents` | Agent catalog with filtering and multiple output formats |
| `/validate-hooks` | Hook coverage and consistency verification |
| `/agent-status` | Agent configuration status and health assessment |
| `/quality-report` | Quality metrics, trend analysis, and reporting |

## Spec Loop Commands

The self-correcting spec → build → review loop: the system, not the user, catches the gaps.

| Command | Purpose |
|---------|---------|
| `/spec` | Interview the user one question at a time, then write `specs/<name>.md` with checkable acceptance criteria and a definition of done |
| `/build` | Build exactly what the spec says, then loop build ⇆ `spec-compliance-reviewer` until `VERDICT: APPROVED` (max 3 iterations) |
| `/review-spec` | Manual conformance check: per-requirement PASS/FAIL of the current build against the spec, without entering the loop |

---

## Skills

The framework ships operational skills in `skills/<name>/SKILL.md` (the layout Claude Code loads):

| Skill | Purpose |
|-------|---------|
| **agent-debugger** | Diagnose agent routing, loading, and configuration issues |
| **agent-routing-advisor** | Recommend the right specialist agent for a task |
| **code-scaffolder** | Generate idiomatic project scaffolding for supported languages |
| **code-scoring-loop** | Rubric-based score → rewrite → rescore loop for code diffs, scored by the specialist agents before the review gates |
| **dependency-checker** | Verify the toolchain the framework needs (git, jq, pwsh 7, node, uv) |
| **git-workflow-assistant** | Guide branching, commit conventions, and PR workflows (incl. the peer-review gate) |
| **hook-config-generator** | Guide for adding a new real hook (script + registration + tests) |
| **refactoring-advisor** | Identify refactoring opportunities and improvement patterns |
| **self-scoring-loop** | Rubric-based score → rewrite → rescore loop for non-code deliverables |

---

## Enforcement Hooks

The framework registers real Claude Code hooks via the **agentic-framework plugin** (`hooks/hooks.json`). The deprecated legacy installer (`scripts/install.ps1`) no longer registers hooks — it skips that step with a notice — and `settings.template.json` now carries only the recommended user settings (permissions, `alwaysThinkingEnabled`):

| Hook | Event | Behavior |
|------|-------|----------|
| `stop-peer-review-gate.ps1` | `Stop` | **Blocking.** Refuses to end a session while a feature branch has committed work ahead of its base and the latest `peer-review-critic` run did not record `VERDICT: APPROVED` — one block if no review ran, up to 3 while the verdict is `CHANGES_REQUIRED`. Loop-safe, fail-open (legacy no-verdict markers unlock). |
| `record-subagent-run.ps1` | `PostToolUse` + `SubagentStop` | Records each `peer-review-critic` run as a per-session marker, parsing the report's machine-readable `VERDICT:` line into it (the verdict the Stop gate enforces). |
| `session-start-context.ps1` | `SessionStart` | Injects branch/review status into the session context at startup. |
| `pretooluse-delegation-hint.ps1` | `PreToolUse` | Advisory: suggests the matching specialist subagent when a technology-specific file is written (once per session per agent). |

Design rationale (including why the legacy TDD hard block was retired) lives in `docs/design/`. The hook scripts are tested by `tests/hooks.test.ps1`, and `scripts/validate-consistency.sh` asserts registration parity: every registered script exists, every script is registered, all event names are valid.

---

## Troubleshooting

**Claude Code CLI not found:**
```bash
which claude  # If missing, reinstall per the Prerequisites section
```

**MCP servers not available:**
```bash
cat .mcp.json                                            # Check configuration
npx -y @modelcontextprotocol/server-filesystem --help    # Test filesystem server
npx -y @upstash/context7-mcp --help                      # Test context7 server
uvx --from git+https://github.com/oraios/serena serena --help  # Test serena
npx -y @modelcontextprotocol/server-sequential-thinking --help # Test sequential-thinking
uvx mcp-server-fetch --help                              # Test fetch server
claude mcp list                                          # What Claude Code sees
```
Also check `.claude/settings.local.json` — servers listed under `disabledMcpjsonServers` are switched off locally.

**Agents not found:**
```bash
ls -1 agents/*.md | wc -l  # Should show 21
./scripts/validate-consistency.sh
```

**Delegation not working:**
```bash
cat commands/delegate.md | head -20  # Verify command exists
```

---

## Contributing

To add or modify agents, manage framework consistency, or understand the anti-drift validation system, see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Resources

- [Claude Code CLI Documentation](https://docs.claude.com/en/docs/claude-code)
- [Getting Started Guide](https://docs.claude.com/en/docs/claude-code/getting-started)
- [Configuration Reference](https://docs.claude.com/en/docs/claude-code/configuration)
- [MCP Integration Guide](https://docs.claude.com/en/docs/claude-code/mcp)

---

<!-- BEGIN GENERATED: framework-stats -->
**Built for Claude Code CLI • 21 Specialized Agents • 4 Hook Scripts • 9 Skills • 9 Commands • v3.1.0**
<!-- END GENERATED: framework-stats -->
