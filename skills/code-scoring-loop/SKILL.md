---
name: code-scoring-loop
description: Iteratively improve a pending (uncommitted) code change by having the matching specialist agent score the diff 0-100 against an explicit rubric, rewriting the weakest parts, and repeating until the score plateaus. Use after the quality bar is green (build/lint/format/tests clean) but before the review gates — e.g. polishing an implementation or refactor, or when asked to "clean up" uncommitted code without concrete criteria. Code-side sibling of self-scoring-loop.
---

# Code-Scoring Loop

The same converging loop as `self-scoring-loop` — rubric first, score, rewrite
the weakest parts, rescore until improvement stalls — adapted for code. Three
things change when the deliverable is a diff:

1. **Objective checks come first.** The toolchain already judges correctness;
   the rubric only covers what build/lint/tests *cannot* check.
2. **The author never grades their own work.** Scoring is delegated to the
   framework's specialist agents, so the score is an independent read, not a
   self-assessment.
3. **The loop feeds the gates, it does not replace them.** A polished diff
   still goes through `code-review-gatekeeper` and `peer-review-critic`
   unchanged — this loop just means it arrives pre-polished.

## When to Apply

- An implementation or refactor is green but has not been judged on the
  dimensions tests can't check (readability, error-handling completeness,
  test quality, idiomatic fit).
- Before handing a substantial diff to `code-review-gatekeeper` — fewer gate
  iterations when the obvious weaknesses are already fixed.
- The user asks to "polish", "clean up", or "tighten" pending (uncommitted) code without concrete
  criteria.
- After the refactor step of a `/agentic-framework:delegate` todo, or the first time a `/agentic-framework:build`
  run goes green before its spec-compliance review (once per run — fix
  iterations of the review loop don't re-enter the polish pass), when the
  change is large enough that a structured polish pass beats ad-hoc tidying.

## Gate zero — the quality bar

Before iteration 1, the mechanical checks of the `/agentic-framework:delegate` command (§4)'s
quality bar must be clean: build 0 errors / 0 warnings, linter clean,
formatter no diffs, full unit-test suite green. (The docs bullet is not part
of gate zero — in the `/agentic-framework:delegate` flow it lands in the per-todo doc step that
follows the mechanical bar.) Correctness is binary and comes first; scoring a red build is
meaningless. If the bar fails, fix that — this loop is not for broken code.

## The Loop

1. **Scope the diff.** The unit being scored is the *change* as it sits
   uncommitted in the working tree, in one of two forms. (a) The touched paths
   of a `/agentic-framework:delegate` todo or a `/agentic-framework:build` run,
   recomputed each round: the paths `git status --porcelain` lists now that a
   snapshot taken at the todo's or run's start did not list. With no
   snapshot, or none found, the paths the todo's or run's delegations reported
   changing that `git status` lists now (a path only one source names is
   reported, not targeted). Still none: ask the user to name the paths (a build
   run skips the polish); never default to the whole tree. (b) For standalone
   polish of pending changes, the paths the user names or confirms, or the
   uncommitted work as a whole when every uncommitted path belongs to the
   change — not the whole repository. Committed branch work is outside this
   loop: polish happens before the commit, and committed changes go to the
   review gates (`code-review-gatekeeper`, then `peer-review-critic`) directly.
   Pre-existing debt outside the diff is out of scope.
2. **Write the rubric first — before judging.** 5–7 criteria specific to this
   change, each with a weight (weights sum to 100), drawn from what tooling
   cannot verify: naming and readability, error-handling completeness at
   boundaries, test quality (assertion strength and edge coverage — not just
   line coverage), consistency with the codebase's existing idioms, API and
   interface design, duplication and complexity, security hygiene of touched
   surfaces. Never spend rubric weight on what gate zero already enforces
   (compiles, lint-clean, formatted, tests pass) — those are preconditions,
   not criteria. The rubric is fixed for the rest of the loop.
3. **Delegate scoring to the matching specialist.** Route by the diff's
   domain per the framework routing table (`rust-expert` for a Rust diff,
   `typescript-expert` for TypeScript, …); use `comprehensive-analyst` when
   the change spans languages or no language expert fits — not
   `code-review-gatekeeper`, which must stay outside the polish loop so the
   gate's judgment remains independent of the rubric. Launch a **fresh**
   subagent instance each round and hand it the diff of the step-1 paths
   (`git diff HEAD -- <paths>`, plus each untracked path in full), the rubric,
   and the instruction to return a 0–100 score with a one-line justification
   per criterion. Score honestly — an inflated score ends the loop early and
   defeats it. If the **first** score is **≥ 90**, say so and stop — the loop
   is for improvement, not ceremony.
4. **Name the 1–2 weakest criteria** from the scorer's report and exactly why
   they lost points.
5. **Rewrite only the weak parts** (delegating to the implementing specialist
   where routing says so). Keep what scored well. Rewrites are
   **behavior-preserving**: re-run the quality bar after every rewrite; a
   rewrite that breaks a test has its edits undone, not argued for.
6. **Rescore and decide** — same rubric, fresh scorer instance:
   - Improvement **< 3 points**, or **3 scoring rounds** reached (the first
     included) → stop. More loops past a plateau produce churn, not quality.
   - Otherwise → back to step 4.
7. **Report** the rubric, the final score with per-criterion breakdown, and
   the score trajectory (e.g. 68 → 81 → 86) — then proceed to the framework's
   normal review gates.

## Rules

- The bar before the rubric — never score a build that isn't green.
- Scorer ≠ author, always: every score comes from a delegated fresh
  specialist run, never from the agent that wrote the code.
- Rubric before judgment, visible in the report, never revised mid-loop.
- Behavior-preserving only: never trade a passing test for a rubric point.
  Spec conformance is a gate (`spec-compliance-reviewer`), not a rubric
  criterion — requirement changes do not belong in a polish loop.
- Advisory, and strictly *before* the gates: `code-review-gatekeeper`,
  `peer-review-critic`, the peer-review Stop gate and the push/PR gate apply
  unchanged. A 95 here skips nothing.
