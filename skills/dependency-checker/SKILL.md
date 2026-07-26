---
name: dependency-checker
description: Verify the framework's toolchain (git, bash, jq, gh, yq, PowerShell 7+, Node.js/npx, uv/uvx, shellcheck, Claude Code CLI) is installed and working — use when setting up the framework, after system updates, or when hooks, validators, MCP servers, or the executor agents fail with "command not found".
---

# Dependency Checker

Verify that every external tool this framework actually depends on is installed, on PATH, and at a workable version. Run the probes below, report a concise status table, and give platform-specific remediation for anything missing. Never invent results — run each probe and report exactly what it returns.

## When to Use

- First-time setup of the Claude Code environment (before installing the agentic-framework plugin)
- After OS or package-manager updates
- When a hook, validator script, or MCP server fails with "command not found" or a spawn error
- When onboarding a new machine to the framework
- When `/agentic-framework:validate-hooks` or `/agentic-framework:analyze-framework` report tool-related failures

## What Needs What

| Tool | Required by |
|------|-------------|
| git | Hard requirement; the Stop-gate hook's branch-vs-base checks; all repo workflows |
| bash (Git Bash on Windows) | `scripts/validate-consistency.sh`, `scripts/validate-hooks.sh`, `scripts/validate-framework.sh`, `scripts/generate-docs.sh`, `tests/consistency.test.sh` |
| jq | The bash validators (`validate-consistency.sh` aborts without it); parsing the registry (`claude.json`) and config files |
| gh (GitHub CLI) | The command-line executor agents (bash-expert, powershell-expert): PR/issue/run queries, log grinding, `gh api` reads; must be authenticated |
| yq (mikefarah v4) | The executor agents: YAML processing and agent-frontmatter extraction (`yq --front-matter=extract`) |
| PowerShell 7+ (`pwsh`) | **Windows**: hook chain and installer scripts require pwsh 7 (hooks/dispatch.sh detection runs .ps1 on MINGW/MSYS). **Linux/macOS**: optional — hooks run as POSIX shell; pwsh only needed for the optional .ps1 test suite (`tests/hooks.test.ps1`). |
| Node.js + npx | The `filesystem`, `context7`, and `sequential-thinking` MCP servers (launched via `npx -y`) — only needed if the optional agentic-framework-mcp plugin is installed |
| uv (`uvx`) | The `serena` and `fetch` MCP servers — only needed if the optional agentic-framework-mcp plugin is installed |
| Claude Code CLI | Host runtime that loads the agentic-framework plugin and executes hooks |
| shellcheck (optional) | Linting `scripts/*.sh`; nice-to-have, nothing hard-fails without it |

## Probes

Run each probe and classify the result as OK (with version), MISSING, or WRONG VERSION. On Windows, run PowerShell probes in pwsh and shell probes in Git Bash.

### git
- Probe: `git --version`
- Pass: any modern version (2.30+). Also confirm the repo resolves: `git -C <repo> rev-parse --is-inside-work-tree` prints `true`.

### bash
- Probe: `bash --version` (first line). On Windows, confirm Git Bash specifically: `bash -c 'echo ok'` must print `ok`; Git for Windows installs it at `C:\Program Files\Git\bin\bash.exe`.
- Pass: bash 4+ (Git Bash ships 5.x). WSL bash also works for the validators, but paths must then be WSL-style.

### jq
- Probe: `jq --version`
- Pass: 1.6 or newer. Sanity check: `jq -e '.sub_agents | length > 0' claude.json` from the repo root exits 0.

### gh (GitHub CLI)
- Probe: `gh --version`, then `gh auth status` (exit 0 = authenticated; never pass `--show-token`).
- Pass: 2.0+. Unauthenticated gh means the executor agents' GitHub queries all fail — remediate with `gh auth login`.

### yq
- Probe: `yq --version`
- Pass: must report `https://github.com/mikefarah/yq` v4+. The Python `yq` (a jq wrapper) has incompatible syntax and does NOT satisfy this dependency.

### PowerShell 7+
- Probe: `pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'`
- Pass: 7.0 or newer. `powershell.exe` (Windows PowerShell 5.1) is NOT sufficient — the hook scripts refuse to run under it.
- **Windows: REQUIRED** — hooks need pwsh 7+ (dispatch.sh routes the .ps1 when MINGW*/MSYS*/CYGWIN* is detected, or directly if sh is unavailable).
- **Linux/macOS: OPTIONAL** — hooks run as POSIX shell natively; pwsh is only needed if you want to run the .ps1 test suite for verification (for example, in CI when both interpreters are available for equivalence testing).

### Node.js and npx
- Probes: `node --version` and `npx --version`
- Pass: Node 18+ (LTS recommended). npx must resolve — the MCP servers are launched as `npx -y <package>`.

### uv / uvx
- Probe: `uvx --version` (or `uv --version`)
- Pass: any recent release. Without it the serena MCP server silently fails to start.

### Claude Code CLI
- Probe: `claude --version`
- Pass: any current release. If the optional agentic-framework-mcp plugin is installed, `claude mcp list` should show filesystem, context7, serena, sequential-thinking, and fetch.

### shellcheck (optional)
- Probe: `shellcheck --version`
- If missing, mark OPTIONAL-MISSING, not a failure.

## Functional Smoke Checks

Version probes prove installation, not integration. When the user is troubleshooting (not just installing), also run:

- `pwsh -NoProfile -File tests/hooks.test.ps1` — exercises the .ps1 hook implementations end to end (needs pwsh 7+ and git). Windows: required check. Linux/macOS: optional verification.
- `bash tests/hooks.test.sh` — exercises the .sh hook implementations (needs bash and git). Linux/macOS: verifies POSIX hooks work. Windows: optional if Git Bash is available.
- `bash scripts/validate-consistency.sh` — runs the full consistency battery (needs bash and jq); it validates the registry (`claude.json`), agent frontmatter parity, and hook pair parity against `hooks/hooks.json`.
- `bash scripts/validate-hooks.sh` — focused hook pair-parity and dispatch check.

If a smoke check fails while all version probes pass, the problem is configuration (PATH visible to Claude Code's hook shell, plugin installation state), not a missing tool — verify the agentic-framework plugin is installed and active: `/plugin list` should show it, and the session may need restarting for hooks to load.

## Remediation by Platform

### Windows
- git: `winget install Git.Git` (includes Git Bash)
- jq: `winget install jqlang.jq`
- gh: `winget install GitHub.cli`, then `gh auth login`
- yq: `winget install MikeFarah.yq`
- PowerShell 7: `winget install Microsoft.PowerShell`
- Node.js: `winget install OpenJS.NodeJS.LTS`
- uv: `winget install astral-sh.uv` (or `irm https://astral.sh/uv/install.ps1 | iex`)
- shellcheck: `winget install koalaman.shellcheck`
- Claude Code: `npm install -g @anthropic-ai/claude-code` or the native installer
- After installing, restart the terminal (and Claude Code) so PATH changes are picked up. Verify the tool is visible from BOTH pwsh and Git Bash — hooks run under pwsh, validators under bash.

### macOS
- `brew install git jq gh yq node uv shellcheck`
- `brew install --cask powershell` (provides `pwsh`)
- Claude Code: `npm install -g @anthropic-ai/claude-code` or the native installer

### Linux (Debian/Ubuntu)
- `sudo apt-get install -y git jq shellcheck gh` (gh may need the GitHub CLI apt repo); yq: download the mikefarah binary from GitHub releases (the apt `yq` is the incompatible Python wrapper)
- Node.js: distro package or NodeSource setup script for a current LTS
- PowerShell 7: Microsoft package repository (`packages.microsoft.com`), then `sudo apt-get install -y powershell`
- uv: `curl -LsSf https://astral.sh/uv/install.sh | sh`
- Claude Code: `npm install -g @anthropic-ai/claude-code` or the native installer

## Reporting

Present results as a single table: Tool | Status | Version found | Needed by | Fix (only for failures). Then a one-line verdict:

- All required tools OK → framework is fully operational; install the agentic-framework plugin if not already done.
- Any of git / bash / jq / pwsh missing → validators or hooks WILL fail; list the exact install command for the user's platform.
- node/npx or uvx missing → core framework works, but the optional agentic-framework-mcp plugin's MCP servers will not start; this is non-blocking if the user doesn't need those servers.
- gh or yq missing (or gh unauthenticated, or yq is the Python wrapper) → the command-line executor agents degrade: GitHub queries and YAML processing fail; give the platform install command.
- Only shellcheck missing → note it as optional and move on.

Do not fabricate percentages, scores, or tool inventories beyond the table above, and do not install anything without the user asking — report and recommend.
