# An Agent Execution Framework for Claude Code CLI

A configuration framework for [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) that adds 21 specialized agents, a real peer-review enforcement gate, an anti-drift consistency system, and intelligent task routing.

**This is NOT a standalone tool** — it requires Claude Code CLI as the underlying platform.

---

## Overview

This framework extends Claude Code CLI with:

- **21 Specialized Agents** covering the full development lifecycle
- **Real Enforcement Hooks** — a blocking peer-review Stop gate plus session-context and delegation-hint hooks, registered via the plugin's `hooks/hooks.json` and covered by tests
- **Anti-Drift Consistency System** — dynamic validator, doc generator, and CI gate that keep the registry, docs, and filesystem in lockstep
- **MCP Integration** — 6 MCP servers ship with the plugin, covering code intelligence, file operations, documentation lookup, structured reasoning, web fetching, and a persistent code-review knowledge graph

---

## Prerequisites

| Requirement | Purpose |
|-------------|---------|
| **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)** | Agent execution platform (required) |
| **Git** | Version control |
| **PowerShell 7+ (`pwsh`)** | Windows: runs hooks and installer scripts (7.0+ for hooks, 7.3+ for installer); Linux/macOS: optional (hooks run as POSIX shell; pwsh needed only for the optional .ps1 test suites) |
| **bash + jq** | Validation and doc-generation tooling (Git Bash works on Windows). On Linux/macOS, `sh` + `jq` + `git` are the complete hook runtime — nothing else needed. If `jq` is missing on POSIX hosts, enforcement is disarmed — hooks fire without enforcing anything, including the peer-review Stop gate |
| **gh + yq** | Command-line executor agents (bash-expert / powershell-expert): GitHub CLI queries and YAML processing; run `gh auth login` once. yq is mikefarah v4 |
| **Node.js/npm** | Required: the plugin starts the filesystem, context7 and sequential-thinking MCP servers via `npx` |
| **uv (`uvx`)** | Required: the plugin starts the serena, fetch and code-review-graph MCP servers via `uvx` |
| **shellcheck** | Shell-script linting (optional, used by CI) |

### Install Claude Code CLI

```bash
# macOS
brew install --cask claude-code

# Linux / WSL
curl -fsSL https://anthropic.com/install-claude.sh | sh

# Windows / Powershell
irm https://claude.ai/install.ps1 | iex

# Verify
claude --version
```

### MCP Servers

Six MCP servers are included in the plugin. They connect automatically at session start once the plugin is enabled, with no approval prompt, and register as `plugin:agentic-framework:<server>`. Run `claude mcp list` to see them. To switch one off, use the `/mcp` panel or add its scoped name — `plugin:agentic-framework:code-review-graph`, for example — to `disabledMcpServers` in `~/.claude.json`. The bare server name does not match a plugin-shipped server.

Both runtime environment variables below are optional; `/agentic-framework:setup` configures them for you. Set them globally via shell profile or system settings, or copy `.env.example` for placeholders:

| Env Var | Purpose |
|---------|---------|
| `CONTEXT7_API_KEY` | API key for the context7 MCP server (optional) |
| `MCP_FS_ROOT` | Root directory for the filesystem MCP server (defaults to the current project directory) |

**Servers included in the plugin:**

| MCP Server | Purpose | Runtime |
|------------|---------|---------|
| **filesystem** | Enhanced file operations for large files and atomic updates | Node.js (`npx`) |
| **context7** | External documentation and best practices lookup | Node.js (`npx`) |
| **serena** | Semantic code intelligence and symbol operations | Python (`uvx`) |
| **sequential-thinking** | Structured step-by-step reasoning for complex problem decomposition | Node.js (`npx`) |
| **fetch** | Web content fetching and conversion for efficient page consumption | Python (`uvx`) |
| **code-review-graph** | Persistent incremental code knowledge graph for reviews: change impact, dead code, execution flows, semantic search (after an initial graph build — see the note below) | Python (`uvx`) |

All six launchers are version-pinned (serena by commit SHA, matching its v1.6.1 release; code-review-graph to 2.3.8), so `npx`/`uvx` resolve from local cache instead of hitting the network at every session start — an unpinned serena re-resolved its git repository on each launch. The cache helps only after the first resolution: a fresh install or a cleared `uv`/`npm` cache downloads each pinned launcher, plus its unpinned dependency closure, from PyPI/npm and executes it with your user privileges. Cost note: serena is the bundle's session-start heavyweight (it boots language servers for the project) and code-review-graph is its per-request heavyweight (30 tools, about 37 KB of tool schema advertised to every session); if you don't use one of them, switch it off in the `/mcp` panel or add its scoped name (`plugin:agentic-framework:<server>`) to `disabledMcpServers` in `~/.claude.json`. Do not edit the plugin cache's `.mcp.json` — `claude plugin update` overwrites it.

**About code-review-graph — read this before your first session.** Installing the framework connects this server automatically, with no approval prompt, and it ships with its full tool set, which is not read-only. `apply_refactor_tool` writes source files into whatever directory the model passes as `repo_root` — every tool that targets a single repository accepts that parameter (28 of the 30), an explicit value overrides the `--repo` launch flag, and the package's only guard on that root is that the target contains a `.git`, `.svn`, or `.code-review-graph` directory, so any checkout on your machine is reachable. `cross_repo_search_tool` / `list_repos_tool` read any other repositories registered with the tool. It is also a solo-maintained community package (MIT, no PyPI attestations as of 2.3.8). If that is not acceptable on your machine, switch it off before first use: add `plugin:agentic-framework:code-review-graph` to `disabledMcpServers` in `~/.claude.json` before you start a session. Use that scoped spelling — the bare name does not match a plugin-shipped server. The `/mcp` panel disables a server too, but it is only reachable from inside a session, by which point the server has already connected, so `disabledMcpServers` is the true before-first-use switch. To keep the server but drop its write reach, set `CRG_TOOLS` in your environment to a comma-separated list of the tools you want — unlisted tools are removed. Those two knobs are the durable ones; editing the plugin cache's `.mcp.json` does not survive `claude plugin update`. The recommended settings template also adds an `ask` rule for `apply_refactor_tool` (see Installation step 3), so that one tool prompts before it writes — in the default permission mode; `bypassPermissions` and `auto` never consult the rule, so on those modes narrow with `CRG_TOOLS` or disable the server instead.

Its tools return nothing until a graph exists — call `build_or_update_graph_tool` once, or run `uvx code-review-graph==2.3.8 build` in the repo (same pin as the manifest, so the CLI and the server share one database schema). The graph is written to `<repo>/.code-review-graph/` in every repository you point it at (the package gitignores that directory); `CRG_DATA_DIR` relocates it.

---

## Installation

The framework is distributed as a single **Claude Code plugin** via the marketplace (no local cloning).

Installing it does more than add agents. The plugin ships six MCP servers, and they connect automatically at session start with no approval prompt — including code-review-graph, whose `apply_refactor_tool` can write source files (read **About code-review-graph** above before you install). On the first run after a fresh install or a cleared `npm`/`uv` cache, six pinned launchers plus their unpinned dependency closures download from npm and PyPI and execute with your user privileges. You can switch any server off in the `/mcp` panel, or before the first session via `disabledMcpServers` in `~/.claude.json` using the scoped name (`plugin:agentic-framework:code-review-graph`).

### 1. Install the Plugin

Using the Claude Code GUI:
```
/plugin marketplace add tomas-rampas/agentic-framework
/plugin install agentic-framework@agentic-framework
```

Or via the CLI:
```bash
claude plugin marketplace add tomas-rampas/agentic-framework
claude plugin install agentic-framework@agentic-framework
```

### 2. (Optional) Configure MCP Environment Variables

The six MCP servers are already installed. Neither environment variable is required — the servers start without them. Inside a Claude Code session, run:

```
/agentic-framework:setup
```

It writes the two optional variables (see `.env.example` for placeholders):
- `CONTEXT7_API_KEY` — optional, for the context7 MCP server; it runs keyless by default and a key only raises its rate limits
- `MCP_FS_ROOT` — optional, filesystem server root (defaults to the current project directory)

### 3. Merge User Settings

The plugin ships `settings.template.json` with recommended permissions and `alwaysThinkingEnabled`. Merge these into your `~/.claude/settings.json`:

```bash
# Inspect the template (use the versioned cache path)
cat ~/.claude/plugins/cache/agentic-framework/agentic-framework/*/settings.template.json
# (or open the plugin folder via /plugin)

# Copy permissions and alwaysThinkingEnabled into your ~/.claude/settings.json
# (do not overwrite hooks — they are registered via hooks/hooks.json in the plugin)
```

The template's `permissions.ask` list includes `mcp__plugin_agentic-framework_code-review-graph__apply_refactor_tool` and `mcp__code-review-graph__apply_refactor_tool` — both name forms of the one graph tool that writes source files. `ask` outranks `allow`, so even if you later allow the whole server, that tool still prompts before it edits anything — in the default permission mode. `bypassPermissions` and `auto` do not consult permission rules at all; on those modes, narrow the server with `CRG_TOOLS` or disable it instead.

### 4. Restart Claude Code

Hooks load and the six MCP servers connect at session start:
```bash
# Restart any running Claude Code session
claude
```

### 5. Validate Framework Integrity

```bash
/agentic-framework:validate-hooks
/agentic-framework:analyze-framework
```

---

### Migration: Existing Local Clones

If you have this framework cloned into `~/.claude`, migrate to the plugin distribution:

```bash
# Dry-run (the default — reports what would change, makes no changes)
/agentic-framework:migrate-legacy

# Perform the migration (backs up settings.json + .claude.json, de-registers the
# framework hooks, deletes the 4 copied hook scripts, and cleans a legacy ~/.claude
# clone; add -RemoveMcp to also remove framework-shaped MCP servers)
/agentic-framework:migrate-legacy -Apply
```

**Note**: Do not run the migration on dirty working trees or unpushed commits — it will refuse to proceed. Exit codes: 0 = migration complete (or dry-run), 2 = checkout cleanup aborted (genuine uncommitted changes or unpushed commits); hook/MCP removals from the earlier steps have already been applied by then.

---

### Updating the Plugin

**Upgrading from 4.x:** the six MCP servers used to live in a second, optional plugin. They are now part of `agentic-framework` itself, and the separate plugin is retired. If you installed it, uninstall it:

```
/plugin uninstall agentic-framework-mcp@agentic-framework
```

The same command works from the CLI, prefixed with `claude` instead of `/`. Leaving the retired plugin installed runs the same six servers twice, under two names.

Check your own MCP configuration too. Scope precedence is local > project > user > plugin: when the same server name is defined in more than one place, Claude Code connects to it once, using the definition from the highest-precedence source. This cuts both ways.

- A user-scope server in `~/.claude.json` with a name like `serena` or `context7` **shadows** the plugin's copy. Delete those entries to get the version-pinned servers the plugin ships.
- A cloned repository's project `.mcp.json` outranks the plugin, so a familiar name like `serena` in a project file can be an arbitrary command. Read a project's `.mcp.json` before approving it. This repository's own tracked root `.mcp.json` is exactly such a project-scope config inside a clone.

<!-- intentional: pre-rename marketplace name; do not rename -->
**Upgrading from a pre-rename install:** the marketplace name changed from `claude-agentic-framework` to `agentic-framework`. If you have an older registration, remove it first, then re-add and re-install:

In Claude Code:
```
/plugin marketplace remove claude-agentic-framework
/plugin marketplace add tomas-rampas/agentic-framework
/plugin install agentic-framework@agentic-framework
/reload-plugins
```

Restarting Claude Code has the same effect as `/reload-plugins`.

To check for updates (whether or not you migrated):
```bash
claude plugin marketplace update agentic-framework
claude plugin update agentic-framework@agentic-framework
```

---

### Uninstalling

```bash
/plugin uninstall agentic-framework@agentic-framework
/plugin marketplace remove agentic-framework

# Clean up environment variables (optional)
# Windows PowerShell:
[Environment]::SetEnvironmentVariable('CONTEXT7_API_KEY', $null, 'User')
[Environment]::SetEnvironmentVariable('MCP_FS_ROOT', $null, 'User')

# macOS/Linux: remove the export lines from ~/.zshrc, ~/.bashrc, or ~/.bash_profile
# (see the setup command's "To undo" section for the exact lines to remove)
```

---

### Troubleshooting Installation

**Plugin marketplace add fails:** ensure you use the exact owner/repo form (`tomas-rampas/agentic-framework`), a git clone URL, or a local checkout path. Note that adding the marketplace directly via a URL to marketplace.json itself is unsupported (its relative plugin source `./` cannot resolve without repo context).

**MCP servers not available:** restart Claude Code; the servers connect at session start. Run `claude mcp list` to verify they are registered, and `/plugin list` to verify agentic-framework is installed. A server you disabled in `/mcp` stays disabled for that project until you re-enable it there.

**Hooks not firing after restart:** verify the agentic-framework plugin is installed: `/plugin list`. If missing, re-run `/plugin install agentic-framework@agentic-framework`.

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

The framework distributes as one plugin:

```
<plugin root>*                      # ~/.claude/plugins/cache/agentic-framework/agentic-framework/<version>/
├── CLAUDE.md                # Agent execution rules and task routing
├── claude.json              # Agent registry (single source of truth for the tooling)
├── settings.template.json   # Recommended permissions + alwaysThinkingEnabled
├── .mcp.json                # MCP server definitions (filesystem, context7, serena, sequential-thinking, fetch, code-review-graph)
├── agents/                  # 21 agent definitions (.md with YAML frontmatter)
├── commands/                # 12 namespaced commands (delegate, spec, build, review-spec, log-triage, etc.)
│   └── setup.md             # Configures the two MCP environment variables (both optional)
├── hooks/                   # Real hook scripts + hooks/hooks.json registration (peer-review Stop gate, recorder, session context, delegation hint)
├── skills/                  # Operational skills
├── scripts/                 # Validation, anti-drift consistency, and doc-generation scripts
├── tests/                   # Consistency + hook test harnesses
├── docs/design/             # Design rationale for the hook architecture
├── .github/workflows/       # CI (anti-drift consistency gate)
└── security-check.sh        # Security validation
```
*<plugin root> is the plugin cache path: `~/.claude/plugins/cache/agentic-framework/agentic-framework/<version>/`

---

## Management Commands

**Note:** Commands are namespaced as `/agentic-framework:<name>`. For example, `/agentic-framework:spec` instead of `/spec`.

| Command | Purpose |
|---------|---------|
| `/agentic-framework:delegate` | End-to-end orchestration: auto-runs the spec interview when no source of truth exists, then hands off to build (single feature) or per-todo orchestration (multi-domain) |
| `/agentic-framework:analyze-framework` | Framework health checking and validation |
| `/agentic-framework:list-agents` | Agent catalog with filtering and multiple output formats |
| `/agentic-framework:validate-hooks` | Hook coverage and consistency verification |
| `/agentic-framework:agent-status` | Agent configuration status and health assessment |
| `/agentic-framework:quality-report` | Quality metrics, trend analysis, and reporting |
| `/agentic-framework:setup` | Configure the two MCP environment variables, `CONTEXT7_API_KEY` and `MCP_FS_ROOT` (both optional) |

## Analysis Commands

| Command | Purpose |
|---------|---------|
| `/agentic-framework:log-triage` | Local, deterministic log triage: streams large log files (text, JSON/NDJSON, CSV, XML, syslog, access logs, container/cloud exports), groups recurring issues by stable fingerprint, assesses severity with observed/inferred/unknown labels, attributes issues to Git repositories, and exports JSON, SARIF 2.1.0, HTML, Markdown, CSV and NDJSON reports — see [docs/log-triage/README.md](docs/log-triage/README.md) |

## Spec Loop Commands

The self-correcting spec → build → review loop: the system, not the user, catches the gaps.

| Command | Purpose |
|---------|---------|
| `/agentic-framework:spec` | Interview the user one question at a time, then write `specs/<name>.md` with checkable acceptance criteria and a definition of done |
| `/agentic-framework:build` | Build exactly what the spec says, then loop build ⇆ `spec-compliance-reviewer` until `VERDICT: APPROVED` (max 3 iterations) |
| `/agentic-framework:review-spec` | Manual conformance check: per-requirement PASS/FAIL of the current build against the spec, without entering the loop |

For legacy clones being migrated to plugins, there is also:
| `/agentic-framework:migrate-legacy` | Migrate a local ~/.claude clone to the plugin distribution |

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

The framework ships real Claude Code hooks via the **agentic-framework plugin** in `hooks/hooks.json`. Each hook is registered as a shell-form fallback chain: `sh "${CLAUDE_PLUGIN_ROOT}/hooks/dispatch.sh" <name> || pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.ps1"`. On Linux/macOS, the dispatcher runs the POSIX shell script; on Windows, it runs the PowerShell script. Each hook exists as both a `.ps1` (PowerShell 7) and `.sh` (POSIX shell) pair.

| Hook | Event | Behavior |
|------|-------|----------|
| `stop-peer-review-gate` (.ps1/.sh pair) | `Stop` | **Blocking.** Refuses to end a session while a feature branch has committed work ahead of its base and the latest `peer-review-critic` run did not record `VERDICT: APPROVED` — one block if no review ran, up to 3 while the verdict is `CHANGES_REQUIRED`. Loop-safe, fail-open (legacy no-verdict markers unlock). Accepts bare and plugin-scoped reviewer names. |
| `record-subagent-run` (.ps1/.sh pair) | `PostToolUse` + `SubagentStop` | Records each `peer-review-critic` run as a per-session marker, parsing the report's machine-readable `VERDICT:` line into it (the verdict the Stop gate enforces). |
| `session-start-context` (.ps1/.sh pair) | `SessionStart` | Injects branch/review status into the session context at startup. |
| `pretooluse-delegation-hint` (.ps1/.sh pair) | `PreToolUse` | Advisory: suggests the matching specialist subagent when a technology-specific file is written (once per session per agent). |

Design rationale (including why the legacy TDD hard block was retired) lives in `docs/design/`. The hook scripts are tested by `tests/hooks.test.ps1` (PowerShell) and `tests/hooks.test.sh` (POSIX), and `/agentic-framework:validate-hooks` asserts pair parity: every registered hook has both .ps1 and .sh implementations, every registered script exists and is paired, all event names are valid. An equivalence test `tests/hooks-equivalence.test.sh` verifies the two implementations produce identical output on systems where both interpreters are present (primarily CI).

---

## Troubleshooting

**Claude Code CLI not found:**
```bash
which claude  # If missing, reinstall per the Prerequisites section
```

**MCP servers not available:**
```bash
claude mcp list                                          # What Claude Code sees
# If empty: restart Claude Code, or run /plugin list to verify agentic-framework is installed
# A server you disabled in /mcp stays disabled per project until re-enabled there
```

**Agents not found or not loading:**
```bash
/agentic-framework:list-agents                          # Verify agents are available
/agentic-framework:analyze-framework                    # Framework health check
```

**Hooks not firing or Stop gate misbehaving:**
```bash
/agentic-framework:validate-hooks                       # Hook pair parity and dispatch check
# If hooks are not firing after setup, restart Claude Code (hooks load at session start)
```

**Hooks fire but nothing is enforced (peer-review gate not blocking):**
On Linux/macOS, if `jq` is missing from PATH, the hook scripts load and fire (visible in the transcript), but enforcement is disarmed — nothing gets enforced, including the peer-review Stop gate. **Cause:** the POSIX hook implementations depend on `jq` to validate the hook JSON payload; without it, hooks skip enforcement. **Fix:** install `jq` with your system package manager (`apt-get install jq` on Debian/Ubuntu; `brew install jq` on macOS), then restart Claude Code. When `jq` is absent, the `SessionStart` hook prints a `[session-context]` warning line at session start — this confirms the symptom is active.

**Harmless "sh: not found" stderr on Windows without Git Bash:**
When Git Bash is not installed, the hook chain's `sh` command fails with a "not found" error line in the transcript. This is harmless — the `||` arm runs the PowerShell `.ps1` script directly. (Installing Git Bash removes the noise and speeds hooks up: `sh` then exists and `dispatch.sh` detects MINGW*/MSYS*/CYGWIN*, running the POSIX `.sh` implementation directly when `jq` is on PATH — which skips a pwsh cold start of roughly 1–2 seconds on every hook fire — and routing to the same PowerShell script otherwise.)

**Hooks feel slow, or fire twice:**
Two known causes. First, on Windows without `jq` in Git Bash, every hook fire pays a pwsh cold start — install `jq` (`winget install jqlang.jq`) so the dispatcher can take the POSIX fast path described above. Second, if you migrated from a pre-v4 (pre-plugin) install, the legacy hook entries may still sit in `~/.claude/settings.json` alongside the plugin's `hooks/hooks.json` registration, making every hook fire twice. Run `/agentic-framework:validate-hooks` — it warns on exactly this — and remove the legacy entries (`/agentic-framework:migrate-legacy` automates the cleanup).

**Plugin installation failed:**

See **Upgrading from a pre-rename install** under [Updating the Plugin](#updating-the-plugin) if you have a pre-rename registration — you must remove the old registration first.

```bash
/plugin list                                            # Check installed plugins
/plugin marketplace add tomas-rampas/agentic-framework  # Re-add to marketplace
/plugin install agentic-framework@agentic-framework     # Re-install
```

**Marketplace name suffix vs. GitHub path:**
When installing a plugin, use the full `<name>@<marketplace>` form where `<marketplace>` is the marketplace's **registered name** (the `"name"` field in `.claude-plugin/marketplace.json`) — here, `agentic-framework`. The repo segment of the GitHub path now matches that name, but the two remain distinct values: `/plugin marketplace add` takes the `owner/repo` path, while the `@` suffix — and `marketplace update` and `marketplace remove` — take the registered marketplace name.
```
/plugin install agentic-framework@agentic-framework
```
Alternatively, once the marketplace is added, the bare plugin name also works: `/plugin install agentic-framework`. The CLI reference documents `<plugin>` as "plugin name or `plugin-name@marketplace-name`", so the bare form is supported — but prefer the qualified form: it's unambiguous if another registered marketplace ever ships a plugin with the same name.

**Windows MAX_PATH limit during marketplace clone:**
On deeply nested Windows paths, marketplace clone fails with "Filename too long" at the 260-character limit. **Remediation:** enable Windows 10+ long paths in two steps (both required). First, run this PowerShell command as Administrator:
```powershell
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' LongPathsEnabled 1 -Type DWord
```
Then configure Git for long paths:
```bash
git config --global core.longpaths true
```
Restart Claude Code, then re-run the marketplace add and install from *Plugin installation failed* above. Without both steps, the "Filename too long" error will recur.

**Running the shell test suites or validators manually on Windows:**
If you are running the test suites manually on Windows, use the Git Bash bash.exe directly (not WSL's bash, which may be on PATH by default): `C:\Program Files\Git\bin\bash.exe -c 'bash tests/hooks.test.sh'`. Bare `bash` without a full path may resolve to WSL bash, which will fail or behave incorrectly.

**Migrating from a legacy local clone:**
```bash
/agentic-framework:migrate-legacy                        # Dry-run (default; no changes)
/agentic-framework:migrate-legacy -Apply                 # Perform migration
/agentic-framework:analyze-framework                     # Verify success
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

## License

This project is licensed under the [Apache License 2.0](LICENSE).

---

<!-- BEGIN GENERATED: framework-stats -->
**Built for Claude Code CLI • 21 Specialized Agents • 4 Hook Scripts • 9 Skills • 12 Commands • v4.3.0**
<!-- END GENERATED: framework-stats -->
