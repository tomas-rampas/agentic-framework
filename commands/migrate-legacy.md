---
description: Migrate legacy framework installs to the plugin pipeline
argument-hint: "<optional: any arguments to pass to the migration script>"
---

Framework root: `${CLAUDE_PLUGIN_ROOT}` (when running from a development checkout of the framework itself, this may be empty — then use the current directory if it contains `claude.json`). All framework file paths below are relative to that root.

# /agentic-framework:migrate-legacy — Migrate Legacy Framework Installs

This command helps you transition from manual script installs (`scripts/install.ps1`) to the modern plugin pipeline.

## Invocation

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT:-.}/scripts/migrate-legacy.ps1"
```

(Dry-run by default; add `-Apply` to perform the migration.)

## What it does

The migration script:

1. **De-registers framework hooks** from `settings.json` (framework hook registrations only; your custom hooks are preserved)
2. **Removes framework hook script files** from `~/.claude/hooks/`
3. **Optionally removes framework MCP servers** from user-scope `.claude.json` (requires explicit `-RemoveMcp` consent)
4. **Cleans up git-tracked files** if `~/.claude` is this repo clone (protected runtime paths like `.state`, `settings.local.json`, `projects`, `todos`, `memory`, `plugins` are always preserved)
5. **Reports next steps** for plugin installation

## Recommended workflow

### Step 1: Dry-run first

Review what will be changed without making any changes:

```
/agentic-framework:migrate-legacy
```

The output shows:
- Hook entries that will be removed
- Files that will be deleted
- MCP servers that would be removed (if you were to use `-RemoveMcp`)

### Step 2: Apply changes

Once you're satisfied with the dry-run report, apply the changes:

```
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT:-.}/scripts/migrate-legacy.ps1" -Apply
```

This:
- Creates timestamped backups of `settings.json` and `.claude.json`
- Removes framework hook registrations
- Deletes the 4 framework hook script files
- **Optional**: removes framework MCP servers only with explicit `-RemoveMcp` AND `-Apply` together

### Step 3: Install the plugin

After migration completes, follow the on-screen instructions:

```
/plugin marketplace add tomas-rampas/agentic-framework
/plugin install agentic-framework@agentic-framework
(optional) /plugin install agentic-framework-mcp@agentic-framework
(optional) /agentic-framework-mcp:setup
```

Then restart Claude Code.

## Consent gates

- **Hook removal**: automatic (these are fully managed by the plugin)
- **MCP removal**: requires explicit `-RemoveMcp` flag
  - Framework-shaped servers (with no customization) are removed
  - Customized servers (extra args, altered flags) are kept
  - Non-framework servers are always kept

## Checkout cleanup safety

When `-Apply` is used and `~/.claude` is detected as a git clone, the migration will:
- **Refuse to proceed** if there are uncommitted changes or unpushed commits
- **Require manual push/stash** before cleanup of tracked files and `.git` directory

This ensures you don't lose work accidentally. Commit and push any pending changes, then run migration again.

## Protected paths

These paths are NEVER deleted, even if they're git-tracked in `~/.claude`:

```
.state, settings.local.json, .credentials.json, settings.json, .claude.json,
projects, todos, memory, statsig, ide, shell-snapshots, plugins, backup
```

## Examples

Dry-run (report only, no changes):
```
/agentic-framework:migrate-legacy
```

Apply all changes, remove framework-shaped MCP servers:
```
/agentic-framework:migrate-legacy -Apply -RemoveMcp
```

Test against a different Claude home directory (e.g., for validation):
```
/agentic-framework:migrate-legacy -Apply -ClaudeHome C:\test\.claude
```
