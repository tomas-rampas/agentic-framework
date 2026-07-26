---
description: Route and orchestrate a development objective end-to-end through specialist sub-agents
argument-hint: <objective, e.g. "implement Sprint 3" or "add SCIM provisioning">
---

# /agentic-framework:delegate — Orchestrate & Route

## Your role
You are the **orchestrator**. You plan, route work to specialist sub-agents,
review their output, integrate results, and own commits and documentation. You
do **not** write implementation code yourself — that is delegated to specialists.

## Objective
**$ARGUMENTS**

If no objective was provided (`$ARGUMENTS` is empty), stop and ask me what to
implement before doing anything else.

---

## Routing
Don't follow a keyword table. Read the task, match it to the sub-agent whose
description fits, and delegate. Keep a task on a single agent unless it genuinely
spans domains. Available specialists:

- **Implementation:** `rust-expert`, `csharp-expert`, `go-expert`, `java-expert`,
  `python-expert`, `typescript-expert`, `mql-trading-dev`, `bash-expert`, `powershell-expert`
- **Specialists:** `database-specialist`, `security-specialist`,
  `devops-orchestrator`, `frontend-specialist`, `uiux-specialist`
- **Plan / analyze:** `system-architect`, `product-owner`, `comprehensive-analyst`
- **Quality / docs:** `code-review-gatekeeper`, `peer-review-critic`, `technical-docs-writer`

## Command-line execution
This overrides the don't-follow-a-keyword-table guidance above for shell work
specifically: delegate every shell command this workflow needs — validators,
git/gh calls, JSON/YAML processing, test and build runs — to
**bash-expert** (POSIX/Git Bash) or
**powershell-expert** (PowerShell/Windows) instead of running it inline. Executors
return the exact command, its integer exit code, and a distilled result (verbatim
fenced where it will be used literally). Read files with Read/Grep/Glob directly —
never via shell.

## How to frame a delegated task
Always hand an agent a **concrete** task, never a vague one. Specify: the exact
file path(s), the behavior / acceptance criteria, the test location, and what
"done" means. Turn *"implement auth"* into *"create `src/Auth/AuthService.cs`
with JWT issuing/validation + ASP.NET Core identity integration, tests in
`tests/Auth.Tests/AuthServiceTests.cs`"*. Vague tasks produce vague output.

---

## 1. Plan
- Locate and read the source of truth for the objective (sprint plan, ticket, or
  spec — e.g. under `<DOCS_OR_JIRA_BASE>`).
- **If `specs/<name>.md` exists for this objective** (written by `/agentic-framework:spec`), it
  **is** the source of truth: derive the todo list from its `REQ-`/`EDGE-` items
  and tag each todo with the IDs it delivers. Its Out of scope list is binding.
- **If NO source of truth exists**, do not infer the scope and do not stop dead:
  **run the `/agentic-framework:spec` workflow automatically** — follow the spec command exactly
  (interview one focused question at a time, write `specs/<name>.md`, self-score
  via the `self-scoring-loop` skill, set `Status: approved` only on my
  confirmation). The approved spec then becomes the source of truth above. Never
  skip the interview and write a spec from the objective line alone — an
  unasked-about spec launders ambiguity into requirements.
- Use sequential thinking to break the objective into an ordered todo list. For
  each todo capture: behavior / acceptance criteria, files likely touched,
  dependencies, and the owning agent.
- For non-trivial design, route architecture to `system-architect` first and
  fold its output into the plan.
- Present the plan + todo list, then **stop and wait for my approval before
  executing.**

## 2. Decision gate
- After I approve: if there are no blocking ambiguities or unmet dependencies,
  proceed.
- If blockers exist, list them explicitly and stop for my input. Do not proceed
  past an unresolved blocker.

### Execution mode — spec-backed objectives
When the source of truth is a `specs/<name>.md`, choose the mode and **state it
in the plan**:
- **Hand off to `/agentic-framework:build`** when the objective is a single cohesive feature one
  autonomous run can deliver (single domain, no cross-team sequencing): execute
  `/agentic-framework:build`'s build ⇆ review loop against the spec. **Always surface
  the hand-off decision for approval** — a single combined confirmation
  ("approve the spec and run `/agentic-framework:build`") satisfies both, but never proceed on spec
  approval alone without having stated the hand-off. Then skip §3–§6. On loop
  completion, **commit the delivered work** (meaningful message per behavior —
  you still own commits on this path) and rejoin §8 **for the documentation
  drift-audit, checkbox tick, and summary only**: `/agentic-framework:build`'s loop already ran the
  full-spec review to APPROVED and set `Status: built` — do not re-run them.
- **Orchestrate here** (default for multi-domain or multi-todo objectives):
  continue with §3's per-todo BDD loop consuming the spec.

## 3. Execute — per todo, BDD loop
(Skip §3–§6 entirely if §2 chose hand-off to `/agentic-framework:build`.)

For each todo, in dependency order:
1. Write a failing test for the acceptance criteria (**red**).
2. Delegate implementation to the right specialist until the test passes (**green**).
3. Refactor while keeping tests green. For a substantial change, the
   `code-scoring-loop` skill structures this step: a fixed rubric, the diff
   scored by the matching specialist, weakest parts rewritten until the score
   plateaus.
4. **Update the docs this todo touches, in the same change.** If the todo adds,
   removes, or changes a public type, a DSL/config field, an event type, a CLI
   flag, a verdict, a schema, or any user-visible behavior, it has doc impact —
   locate and update that surface now (via `technical-docs-writer`). A todo with
   stale docs is **not** green. (Scope = §7.)
5. Run the **full unit-test suite**. Do **not** run integration tests.
6. Confirm the quality bar (§4).
7. Run review gates (§5).
8. Commit (§6).

**Parallelism:** parallelize sub-agents only for todos that are independent and
touch disjoint files/state. Serialize anything that shares files or state.
**Tooling:** use the appropriate MCP servers (symbol-aware edits, library docs,
structured reasoning) where they help.

## 4. Quality bar — zero tolerance
Before any commit, all must pass clean:
- **Build:** 0 errors, 0 warnings.
- **Linter:** 0 errors, 0 warnings.
- **Formatter:** no diffs.
- **Unit tests:** full suite green.
- **Docs:** every doc surface the change touches is current (README, spec, plan,
  schema, CHANGELOG — see §7). Stale user-facing docs fail the bar, exactly like
  a failing test.

If the bar cannot be met: retry up to **2** times, then **stop and report** with
diagnostics. Never loop indefinitely, suppress warnings, skip/disable tests, or
report a clean state that isn't real.

## 5. Review gates
- Route each green + clean todo through `code-review-gatekeeper` and
  `security-specialist`. Address findings before committing. If a finding is a
  blocker you can't resolve, stop and report.
- **When building against a spec**, also route the todo through
  `spec-compliance-reviewer` as a **scoped review** naming exactly the
  REQ-/EDGE-IDs the todo delivers (the agent verifies only those; other spec
  items report as out-of-scope, not FAIL). A `CHANGES_REQUIRED` verdict on the
  todo's own IDs blocks the commit like any other finding.

## 6. Commit
- Commit **per completed todo** (after red → green → refactor → quality bar →
  review pass), not once at the end. Meaningful message describing the behavior
  delivered.

## 7. Documentation
- **Documentation scope.** "Docs" means every surface a reader or author trusts:
  `README.md`; the authoritative spec under `docs/`; the delivery plan (`plan/`
  sprint files, roadmap, **checkboxes**); any `CHANGELOG`; and machine-facing
  contracts (JSON Schema, OpenAPI, public API / XML-doc comments). A change is not
  done until every surface it *touches* is current.
- Keep docs current **as you go** via `technical-docs-writer` (the per-todo doc
  step, §3.4). Don't batch all doc updates to the end.

## 8. Wrap-up
- Confirm every todo is complete and all acceptance criteria are met.
- **When building against a spec via §3 orchestration**: run a final
  **full-spec** `spec-compliance-reviewer` review over the whole diff (per-todo
  runs were scoped, so this is the completeness check) and confirm every
  `REQ-`/`EDGE-` item is PASS, then set the spec's `Status:` to `built`. (On
  the `/agentic-framework:build` hand-off path both already happened inside `/agentic-framework:build` — skip this
  bullet.)
- **Documentation drift-audit (blocking).** Before declaring done, delegate to a
  *fresh* sub-agent (`Explore` or `technical-docs-writer`) an audit of README,
  `docs/`, `plan/`, `CHANGELOG`, and any schema **against what actually shipped
  (the diff)** — classifying each surface MUST-UPDATE / nice-to-have / no-change.
  **Do not assume the spec already matches — verify it** (a fresh agent re-derives
  doc impact from the diff without the orchestrator's bias). Fix every MUST-UPDATE
  before summarizing.
- Tick all completed checkboxes in the plan.
- Summarize: what shipped, what didn't (and why), and any follow-ups.

---

## Multi-agent coordination — for cross-domain objectives
Default sequence: `system-architect` -> language-expert / specialist(s) ->
`code-review-gatekeeper` -> `comprehensive-analyst` (gaps & risks) ->
`technical-docs-writer`.

Example — *"auth with DB persistence and UI"*:
`security-specialist` (flow + threat model) -> `database-specialist` (schema) ->
`{language}-expert` (API) -> `frontend-specialist` (UI) ->
`code-review-gatekeeper` -> `technical-docs-writer`.

## Failure handling — applies throughout
- If a sub-agent returns unusable output: retry once with clarified
  instructions, then stop and report.
- Always prefer stopping and surfacing a problem over guessing or fabricating
  success.
