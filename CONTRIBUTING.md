# Contributing to the Claude Code CLI Agent Framework

This guide explains the anti-drift consistency system and how to contribute to the framework while maintaining data integrity.

## Single Source of Truth

`claude.json` is the canonical registry for the entire framework. It contains:

- **`.sub_agents`** — the roster, including each agent's model, specialization, and `focus` field
- **`.agent_categories`** — taxonomy that partitions agents into exactly one category group
- **`.consistency`** — metadata controlling generator and validator behavior:
  - `deprecated_agent_names` — retired agent identifiers (flagged if re-used)
  - `model_shorthand_map` — maps each tier shorthand to its current pinned model id, e.g. `"opus" -> "claude-opus-4-8"`. The shorthand keys (`opus`/`sonnet`/`haiku`) are the single source of truth used in both `.sub_agents[*].model` and each agent's frontmatter; the values are the runtime model ids.
  - `doc_blocks` — registry of machine-generated documentation regions

Do not hand-edit agent counts, rosters, or model assignments in documentation or scripts — they are derived from `claude.json` and the filesystem at validation time.

## Adding or Changing an Agent

Framework agents are part of the agentic-framework plugin and are distributed via the marketplace. This guide covers contribution to the repository. Changes you commit become part of the next plugin release.

One thing to know before you open a session in a clone of this repository: the tracked root `.mcp.json` ships as the plugin's MCP server definitions, but inside the clone it is also a project-scope config, and project scope outranks both your user scope and the installed plugin — so the six servers you get while working here come from the working tree, not from the plugin you have installed.

Follow these steps in order:

### 1. Create the agent prompt file

Add `agents/<name>.md` (in the plugin source) with YAML frontmatter:

```yaml
---
name: <agent-name>
description: <one-paragraph summary + examples>
model: <tier-shorthand>            # opus | sonnet | haiku (must match claude.json, see check 7)
color: <color-name>
effort: <reasoning-effort>         # optional: low | medium | high | xhigh | max
mcpServers: [<server-name>, ...]   # optional: MCP servers available to the agent
tools: <tool1>,<tool2>,...         # optional: comma-separated explicit tool allowlist
disallowedTools: <tool1>,...       # optional: comma-separated tool denylist
---

## Core Expertise
...
```

The `description` must be one physical line. Most agents use a plain (unquoted)
scalar; if the text contains `: ` (colon-space) sequences, wrap the whole value
in double quotes and escape interior quotes as `\"` and literal `\n` markers as
`\\n` — see `agents/bash-expert.md` for the quoted form. Both parse to the same
value; strict YAML parsers only accept the quoted form when colons appear.

`model` must equal the tier shorthand registered for this agent in `claude.json`
(validator check 7) — `opus`, `sonnet`, or `haiku`, never a full model id.
`effort` sets the reasoning effort the agent runs at (`low`/`medium`/`high`/`xhigh`/`max`).
Per Claude Code's documentation, `mcpServers` is not applied to plugin-shipped agents;
treat it as effective only for user-scope agent files. `tools` gives an explicit
comma-separated tool allowlist, overriding the default full tool access for that agent.

**MCP tool names come in twins.** The same server is addressable under two prefixes:
the bare `mcp__<server>__<tool>` form and the plugin-served
`mcp__plugin_agentic-framework_<server>__<tool>` form. A `tools:` allowlist must name
every MCP tool in both forms — validator check 15 rejects an entry whose twin is
missing, because an allowlist carrying only one form silently loses the tool in half
the installs. Dropping the `__<tool>` suffix grants a whole server: `mcp__<server>` and
`mcp__plugin_agentic-framework_<server>` are wildcard entries and also come in pairs.
`disallowedTools:` uses the same syntax to remove tools an agent would otherwise get,
and the validator applies the same twin rules to it.

### 2. Register in `claude.json`

In the `.sub_agents` object, add an entry with `model`, `specialization`, and `focus`:

```json
"your-agent": {
  "enabled": true,
  "model": "sonnet",
  "specialization": "your_domain_area",
  "focus": "Brief focus area (1-2 sentences)"
}
```

Also add the agent to exactly one group in `.agent_categories`.

### 3. Quality enforcement is framework-wide

There is no per-agent hook to create: every agent's committed work passes through the peer-review Stop gate (the `stop-peer-review-gate` hook pair, shipped in the plugin — `.sh` on POSIX, `.ps1` on Windows). If you are adding a **hook** rather than an agent, see `skills/hook-config-generator/SKILL.md` ("Adding a New Hook") — implementation as a `hooks/<name>.ps1` + `hooks/<name>.sh` pair plus a `hooks/dispatch.sh` allowlist entry, registration as a shell-form chain in `hooks/hooks.json`, behavior cases in `tests/hooks.test.ps1` and `tests/hooks.test.sh`.

### 4. Refresh generated documentation

Run the generator to update any `<!-- BEGIN GENERATED: ... -->` marker regions:

```bash
bash scripts/generate-docs.sh --write
```

### 5. Validate the change

Run the full consistency check:

```bash
bash scripts/validate-consistency.sh
```

This runs the full check battery, including:
- Registry ↔ filesystem parity
- Category partition (no duplicates, no gaps)
- Hook registration parity (hooks/hooks.json ↔ hooks/*.ps1: no missing scripts, no orphans, valid event names, PS7 pinned)
- JSON validity (claude.json, settings.template.json, hooks/hooks.json; best-effort YAML)
- No use of deprecated names
- Architecture description count accuracy
- Model parity (agents/<name>.md frontmatter vs claude.json — both tier shorthand) — blocking (see note below)
- Stated-count scan (headline agent/hook/skill/command counts match derived values)
- Roster presence in prose tables (README, CLAUDE.md, list-agents.md)
- README focus-text parity (README Focus cells match claude.json .focus fields)
- Generated blocks are fresh (list-agents summary, README framework-stats footer)

Additional validation and testing:

- `bash tests/plugin-manifests.test.sh` — plugin manifest validation
- `claude plugin validate .` — validate agentic-framework plugin
- `pwsh -NoProfile -File tests/migrate.test.ps1` — legacy migration dry-run validation

All blocking checks must pass (exit 0). **Note:** The consistency and plugin-manifests test harnesses build per-case repository copies from `git ls-files`, so new or renamed files must be staged with `git add` before running these suites — untracked files are invisible to them.

### 5b. Plugin manifest consistency

Releases must maintain version consistency across two manifest files:

- `claude.json` → `.version` field
- `.claude-plugin/plugin.json` → `version` field

The validator enforces this parity with a blocking check (check 13).

User-visible changes to shipped plugin content (agents, commands, skills, hooks, `.mcp.json`, `settings.template.json`) must include version bumps in both manifests. The `claude plugin update` command does not refresh the installed plugin cache when the marketplace version is unchanged, so a content-only release at the same version never reaches installed users. The update follows the marketplace version in both directions: measured 2026-09-18, an installed 5.0.0 was moved down to 4.4.0 once the marketplace advertised 4.4.0.

### 5c. MCP launchers are unpinned

Launchers in the root `.mcp.json` are unpinned as of 2026-09-18. The manifest suite includes an assertion that fails any launcher carrying a version specifier. When an upstream release breaks a launcher, fix it upstream, or add a temporary constraint with a dated note in this subsection and remove it once upstream is fixed. The `fetch` server required `--with mcp<2` at 2026.7.10 (its `McpError` import is gone from the `mcp` 2.x SDK); 2026.8.18 starts without it, measured 2026-09-18 as exit 0 on a fresh `uvx --refresh` resolve, so no launcher carries a constraint today.

### 6. Update prose tables

If the validator reports roster-presence failures in `README.md` or `CLAUDE.md` tables, add the agent row to those hand-written tables. Consult the tables' existing structure for style.

The validator will tell you exactly which tables need updates. Do not hardcode any counts in these tables — omit agent/hook counts and use phrases like "the current roster in claude.json" if needed.

## The Validator

`bash scripts/validate-consistency.sh` is the primary integrity gate. It:

- **Derives all truth at runtime** from `claude.json`, `settings.template.json`, and the filesystem — no hardcoded lists
- **Runs the full check battery** (see summary above) and collects all failures before exiting
- **Distinguishes blocking vs. advisory**: exits non-zero on any blocking check failure
- **Enforces model parity** (check 7, blocking) — each agent's frontmatter `model:` and its claude.json `.sub_agents[*].model` must be the SAME tier shorthand (`opus`/`sonnet`/`haiku`), and every model value on either side must be a declared key in `consistency.model_shorthand_map`. A mismatch or an unknown/typo value fails CI.

Run it during development and before pushing. CI (`.github/workflows/consistency.yml`) runs it on every PR.

## The Generator

`bash scripts/generate-docs.sh` is a documentation-freshness gate. It:

- **Modes:**
  - `--write`: regenerate all `<!-- BEGIN GENERATED: ... -->` marker regions from claude.json + facts
  - `--check`: verify regions are up to date; fails if any are stale
- **Machine-owned regions**: do not hand-edit content between the markers (the validator enforces freshness)
- **Coverage:** currently generates the `commands/list-agents.md` JSON summary block and the README `framework-stats` footer. Prose tables (README "## Agents", CLAUDE.md roster, list-agents.md textual categories) are hand-written and guarded by roster-presence checks instead (better structural flexibility).

Always run `--write` after editing `claude.json`, then validate.

## CI / Continuous Integration

The workflow `.github/workflows/consistency.yml` runs on every PR and push to main:

```bash
bash scripts/validate-consistency.sh       # the full check battery
bash scripts/generate-docs.sh --check      # fails if generated blocks are stale
bash tests/consistency.test.sh             # consistency test harness
```

To reproduce a CI failure locally, run these three commands from the repo root. All must exit 0. Hook behavior is tested separately with `pwsh -NoProfile -File tests/hooks.test.ps1` (`.ps1` implementations) and `bash tests/hooks.test.sh` (`.sh` implementations).

## Quick Reference

| Task | Command |
|------|---------|
| Add/update an agent | Follow the 6-step process above |
| Add a hook | See `commands/validate-hooks.md` ("Adding a New Hook") |
| Test hook behavior | `pwsh -NoProfile -File tests/hooks.test.ps1` + `bash tests/hooks.test.sh` |
| Regenerate docs | `bash scripts/generate-docs.sh --write` |
| Validate everything | `bash scripts/validate-consistency.sh && echo exit=$?` |
| Check freshness (CI mode) | `bash scripts/generate-docs.sh --check && echo exit=$?` |
| Run all tests | `bash tests/consistency.test.sh && echo exit=$?` |

## Notes

- The framework operates on **LF line endings** (configured in `.gitattributes eol=lf`). Do not commit CRLF.
- `FRAMEWORK_ROOT` environment variable overrides git discovery if set; useful for testing against isolated copies.
- Never suppress hooks with `--no-verify` unless troubleshooting a hook failure. Hook violations indicate real inconsistencies.
- Questions? See the validator output — it names every failure precisely.
