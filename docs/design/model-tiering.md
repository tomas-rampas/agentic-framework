# Design: model-tiering

**Status: implemented** — `CLAUDE.md`'s "### 🧠 Model Tiering Policy (token economy)" section,
the re-tiered `agents/{rust,csharp,go,java,python,typescript}-expert.md` and
`agents/mql-trading-dev.md` (now `model: sonnet`), the `hooks/pretooluse-model-guard.ps1` +
`hooks/pretooluse-model-guard.sh` pair registered in `hooks/hooks.json`, and the
`--context claude-code --project-from-cwd` serena launcher in `.mcp.json`.
This document is the design rationale; the files are the source of truth for behavior.

## Purpose

The framework routed work by domain but never by model: every agent carried a fixed
frontmatter tier, the orchestrator never used the Agent tool's per-call `model` override,
and nothing told it that the top-level session (Fable) is the orchestrator only. Built-in
agents (`Explore`, `Plan`, `general-purpose`) inherit the parent model, so delegated
searches ran on the most expensive tier by default. This change states a tiering policy on
every operative surface, lowers the seven language experts' default tier, and adds a hook
that structurally prevents any subagent call from running on Fable.

## How a sub-agent's model is resolved

Measured resolution order (code.claude.com/docs/en/sub-agents, confirmed by this harness's
Agent tool schema): (1) the per-call `model` parameter, (2) the agent's frontmatter
`model:`, (3) the `CLAUDE_CODE_SUBAGENT_MODEL` environment variable, (4) the parent
conversation's model. `fable` is an accepted alias in both frontmatter and the per-call
parameter, which is exactly why it must be blocked structurally rather than by convention
alone. An agent with no `model:` line — every built-in agent — has nothing to fall back on
at step 2, so absent an environment floor at step 3 it inherits the orchestrator's model at
step 4. That is measured, not a bug in this design: `Explore` and `Plan` are documented to
inherit the parent model; for `general-purpose` and `claude` the same follows from the
resolution order (inferred, not separately probed).

The guard's remedy rests on built-in agents honouring step 1, so that was probed rather
than assumed (measured 2026-09-20; each probe agent quoted the model line of its own system
prompt): `Explore` with `model: haiku` ran as `claude-haiku-4-5-20251001`, `Plan` with
`model: sonnet` as `claude-sonnet-5`, `general-purpose` and `claude` with `model: haiku` as
`claude-haiku-4-5-20251001`. A denied built-in call re-issued with the tier the denial
names therefore runs on that tier.

## The three layers

1. **Frontmatter default tier.** Each agent's `model:` line is its default — the value
   `claude.json` `.sub_agents[<a>].model` agrees with (validator check 7). This is a
   default, not a ceiling by itself.
2. **Runtime one-tier moves by the orchestrator.** CLAUDE.md's policy lets the orchestrator
   pass the Agent tool's `model` parameter to move one tier down (mechanical, single-file,
   exact-spec work) or one tier up (concurrency/unsafe code, auth/crypto, cross-file
   refactors, two failed review rounds), stating the reason on an up-move. This layer is
   advisory: nothing stops a mis-typed call from passing `opus` when `sonnet` was meant.
3. **The `pretooluse-model-guard` hook as the ceiling.** A `PreToolUse` hook on
   `Task|Agent` reads `tool_input.model` and `tool_input.subagent_type` (string values
   only, trimmed and lowercased; any other JSON type counts as absent) and denies, in this
   order: (a) every `fork`, because a fork always runs on its parent's model and ignores
   the override; (b) a `model` that contains `fable` — the alias in any case, a full model
   id such as `claude-fable-5-1`, or a suffixed form; (c) a call whose `subagent_type` is
   empty or one of `Explore`/`Plan`/`general-purpose`/`claude` with no `model`, while
   `CLAUDE_CODE_SUBAGENT_MODEL` is unset or itself names the top tier. Otherwise it emits
   nothing. `AF_MODEL_GUARD=off` disables it outright (exit 0, no output), and anything it
   cannot parse — malformed stdin, a `tool_input` that is not a JSON object, a missing
   `jq` — fails open (exit 0, no output): the gate must never trap a session. Condition
   (a), the substring match in (b), the floor-value test in (c) and the type rules were
   added after the security and code-review gates measured each bypass. The
   `CLAUDE_CODE_SUBAGENT_MODEL` environment variable is the user-side floor that closes the
   built-in-agent inheritance gap for a user who sets it (decision C: `sonnet`), independent
   of the hook.

## Tier assignment

Before: opus 12, sonnet 5, haiku 4 (measured, 2026-09-20). After (decision A): opus 5,
sonnet 12, haiku 4. The seven language experts (`rust`, `csharp`, `go`, `java`, `python`,
`typescript`, `mql-trading-dev`) moved from opus to sonnet — routine implementation
against reviewable diffs, not leveraged one-shot decisions. `code-review-gatekeeper`,
`peer-review-critic`, `spec-compliance-reviewer`, `security-specialist` and
`system-architect` stay on opus: a false PASS from a review gate, or a wrong call on
security or system design, costs more than the tokens the lower tier would save.
`effort:` values are unchanged.

## Rejected options

- **Dropping `model:` from frontmatter, letting the orchestrator decide entirely at
  runtime.** Rejected: by the resolution order above, an agent with no `model:` line
  inherits the orchestrator's model, so every delegation where the orchestrator forgets
  the parameter would run on Fable — the exact outcome the policy exists to prevent. The
  frontmatter tier is the one layer that holds without anyone remembering anything, and the
  registry ↔ frontmatter parity check (validator check 7) would lose its anchor.
- **Relying on a global default only** (e.g. `CLAUDE_CODE_SUBAGENT_MODEL` alone, no
  frontmatter tiers). Rejected: it is a single flat tier for all 21 agents, which cannot
  express that reviewers must stay on opus while language experts move to sonnet, and it is
  a user-side setting a plugin cannot ship. It is kept as the optional floor, not the design.
- **Shipping upstream code-review-graph's per-edit `PostToolUse` hook or a `SessionStart`
  graph-refresh hook.** Rejected (decision G) for the graph-freshness problem this spec
  also touches: measured, a `uvx code-review-graph update --skip-flows -q` no-op costs
  1.1 s with a warm cache, so a hook firing on every edit adds constant overhead for a
  freshness check the agent can make in-process via `build_or_update_graph_tool` when
  `_graph.head_matches_build` is false. Out of scope for tiering itself; recorded because
  the same measurement session raised it and decision G governs both.
- **Serena's `serena-hooks`.** Rejected: measured, they require a `uv tool install`, which
  the plugin's `uvx --from git` launch does not provide — shipping them would silently not
  work for plugin users.

## Companion changes

- **Serena launcher**: `.mcp.json`'s serena args become `--context claude-code
  --project-from-cwd` (decision E). Measured: `--project-from-cwd` started from this
  repository activated and auto-registered it into `~/.serena/serena_config.yml` at
  startup; started outside a git repo it warned and started with no project. The plugin's
  prior `--context ide-assistant` logs a deprecation warning — `claude-code` is the current
  name. Security consequence found by the security gate and disclosed in README: activation
  now happens at server launch with no tool call in the transcript, so a repository's own
  `.serena/project.yml` is read — and its `activation_command` executed — before the first
  model turn whenever the path matches `trusted_project_path_patterns`. Upstream ships that
  list empty (measured in the config template), which makes the command inert; a user who
  sets it to `**` turns every clone into startup code execution. Tool-surface consequence,
  measured in the same probes: once a project is found at startup serena runs in
  single-project mode and logs `SingleProjectExclusions excluded 2 tools: activate_project,
  get_current_config` (21 tools exposed instead of 23), so an agent cannot switch project
  roots mid-session; started where no project is found, both tools are present. Validator
  check 15(d) still requires the `activate_project` + `initial_instructions` pair in every
  allowlist that grants a serena tool: the pair is live outside a repository and for a
  user-scope serena launched without the flag, and an allowlisted tool the server does not
  expose is inert.
- **"Code graph first" prompt blocks**: the seven language experts plus
  code-review-gatekeeper, peer-review-critic, spec-compliance-reviewer, security-specialist,
  comprehensive-analyst and system-architect (13 agents) gained a `## Code graph first`
  section instructing them to check the in-band `_graph.head_matches_build` freshness flag
  on any graph result and call `build_or_update_graph_tool` (incremental) when it is false
  or the graph is absent, before falling back to a plain read.

## Limits

- The hook inspects `tool_input` on the `Task`/`Agent` tool call; it cannot see the calling
  agent's own model, so it fires identically whether the caller is the top-level session or
  a sub-agent that itself calls Agent — a sub-agent nesting another sub-agent is checked the
  same way.
- The hook is not a general ceiling. It recognises only what the call itself shows: a
  fork, a `model` naming the top tier, and a built-in agent type. Any other agent type — a
  framework agent, a user-scope agent, another plugin's agent — spawned with no `model` is
  never denied, because the hook cannot read that agent's frontmatter; if its definition
  carries no `model:`, it inherits the caller's tier (measured: `my-custom-agent` with no
  model and no floor passes silently). Denying unknown agents instead would wrongly block
  every custom agent that does declare a tier. `CLAUDE_CODE_SUBAGENT_MODEL` is the cover for
  this case, which is why the policy recommends setting it. Raised by the Copilot review of
  PR #48; the behaviour is pinned by EDGE-016 tests in all three hook suites.
- A `fork` always runs on its parent's model and ignores any `model` override, and the
  hook cannot know the parent's tier, so it denies every fork — including a harmless one
  inside a sonnet sub-agent. That over-blocking is the accepted price of closing the one
  path that silently puts a sub-agent on the top tier.
- Every denial reason ends with `Set AF_MODEL_GUARD=off to disable this guard.`: the hook
  fires for every plugin user, including one whose top-level session is not an expensive
  model, and the denial is the only text a blocked caller sees.
- The byte-equivalence of the two implementations is tested for ASCII payloads. Non-ASCII
  input is not covered: `.Trim()` trims Unicode whitespace where the POSIX `sed` class does
  not, and `[Console]::In` does not decode UTF-8 stdin on Windows (the same pattern as the
  four older hooks), so such payloads are mangled before either rule runs.
- This is a cost control, not a security boundary. A Unicode look-alike of the alias is not
  folded (it is not a valid model name, so the call fails on its own), and built-in agents
  with a fixed model of their own (`statusline-setup`, `claude-code-guide`) are not in the
  list because they never inherit.
- The one-tier-move policy in CLAUDE.md is advisory wherever the hook does not reach: the
  hook enforces only the Fable ban and the built-in-agent floor, not the "move only one
  tier" or "state the reason" rules, which rely on the orchestrator following the policy.
- `.consistency.model_shorthand_map` values are informational: Claude Code resolves the
  alias at runtime. They were stale and now hold the ids measured on 2026-09-20 by the same
  probe method (`opus` → `claude-opus-5`, `sonnet` → `claude-sonnet-5`, `haiku` →
  `claude-haiku-4-5-20251001`); re-measure when a new model generation ships.
