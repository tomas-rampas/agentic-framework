#!/usr/bin/env bash
# install.sh — thin POSIX installer for Linux / macOS / WSL.
# Mirrors the CORE of scripts/install.ps1: copies hook scripts, wires the
# "hooks" block into ~/.claude/settings.json, and creates the session-state
# directory. The full-featured installer is install.ps1 (per-item reporting,
# non-destructive MCP merge into user-scope ~/.claude.json, stale-checkout
# detection) — pwsh runs on Linux/macOS too, so prefer it when available:
#   pwsh -NoProfile -File scripts/install.ps1
#
# The hook implementations are PowerShell 7 scripts, so pwsh is required at
# runtime even on Unix (https://learn.microsoft.com/powershell).
#
# NOTE: On Windows use scripts/install.ps1 instead. This script leaves the
# literal $HOME in hook commands (expanded by the POSIX shell at hook time);
# Windows hook invocation cannot expand it, so hooks would be silently inert.
#
# Usage: bash scripts/install.sh [--force]

set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "ERROR: on Windows use scripts/install.ps1 - hooks installed by this" >&2
    echo "       script keep a literal \$HOME that Windows cannot expand at hook" >&2
    echo "       time, leaving them silently inert." >&2
    exit 1
    ;;
esac

echo ""
echo "DEPRECATED: scripts/install.sh will be removed in the next release."
echo "Plugin pipeline commands are now recommended:"
echo "  /plugin marketplace add tomas-rampas/claude-agentic-framework"
echo "  /plugin install agentic-framework@claude-agentic-framework"
echo "  (optional) /agentic-framework-mcp:setup"
echo "See README.md migration section for details."
echo ""

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CLAUDE_HOME="${HOME}/.claude"

echo "Framework repo : $REPO_ROOT"
echo "Claude home    : $CLAUDE_HOME"

command -v git >/dev/null 2>&1 || { echo "ERROR: git is required" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "ERROR: jq is required for settings merging" >&2; exit 1; }
command -v pwsh >/dev/null 2>&1 || echo "WARNING: pwsh (PowerShell 7+) not found - the hook scripts will not run without it." >&2
command -v npx >/dev/null 2>&1 || echo "WARNING: npx not found - the filesystem/context7/sequential-thinking MCP servers need Node.js." >&2
command -v uvx >/dev/null 2>&1 || echo "WARNING: uvx (uv) not found - the serena/fetch MCP servers need it." >&2

# ── Hooks ──────────────────────────────────────────────────────────────────────
mkdir -p "$CLAUDE_HOME/hooks"
if [[ "$(cd "$REPO_ROOT" && pwd)" != "$(cd "$CLAUDE_HOME" 2>/dev/null && pwd || echo "$CLAUDE_HOME")" ]]; then
  cp "$REPO_ROOT"/hooks/*.ps1 "$CLAUDE_HOME/hooks/"
  echo "Copied hook scripts to $CLAUDE_HOME/hooks/"
else
  echo "Repo is ~/.claude itself - hook scripts already in place."
fi

# ── settings.json ──────────────────────────────────────────────────────────────
TEMPLATE="$REPO_ROOT/settings.template.json"
SETTINGS="$CLAUDE_HOME/settings.json"

if [[ ! -f "$SETTINGS" ]]; then
  mkdir -p "$CLAUDE_HOME"
  cp "$TEMPLATE" "$SETTINGS"
  echo "Created $SETTINGS from template."
elif ! jq -e '.hooks' "$TEMPLATE" >/dev/null 2>&1; then
  echo "Hook registration now ships with the agentic-framework plugin (hooks/hooks.json);"
  echo "settings.json hooks merge skipped."
elif jq -e '.hooks' "$SETTINGS" >/dev/null 2>&1 && [[ "$FORCE" -ne 1 ]]; then
  echo "WARNING: a 'hooks' block already exists in $SETTINGS - settings NOT modified." >&2
  echo "         Re-run with --force to replace it with the framework version." >&2
else
  tmp="$(mktemp)"
  jq --slurpfile tpl "$TEMPLATE" '.hooks = $tpl[0].hooks' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  echo "Merged framework hooks block into $SETTINGS."
fi

# ── Session-state directory ────────────────────────────────────────────────────
mkdir -p "$CLAUDE_HOME/.state/peer-review"

echo ""
echo "Done. Reminders:"
echo "  - MCP: project-level .mcp.json applies to sessions started in the repo directory."
echo "    Remove servers you want active from disabledMcpjsonServers in .claude/settings.local.json."
echo "    Set CONTEXT7_API_KEY / MCP_FS_ROOT per .env.example."
echo "  - Restart any running Claude Code session to pick up the new hooks."
