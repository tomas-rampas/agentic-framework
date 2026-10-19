---
name: code-scoring-loop
description: Iteratively improve a code change by having the matching specialist agent score the diff 0-100 against an explicit rubric, rewriting the weakest parts, and repeating until the score plateaus. Use after the quality bar is green (build/lint/format/tests clean) but before the review gates — e.g. polishing an implementation or refactor, or when asked to "clean up" code without concrete criteria. Code-side sibling of self-scoring-loop.
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
- The user asks to "polish", "clean up", or "tighten" code without concrete
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
follows the refactor.) Correctness is binary and comes first; scoring a red build is
meaningless. If the bar fails, fix that — this loop is not for broken code.

## The Loop

1. **Scope the diff.** The unit being scored is the *change* (branch vs base,
   or the todo's touched files) — not the whole repository. Pre-existing debt
   outside the diff is out of scope.
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
   subagent instance each round and hand it: the diff; the rubric; the
   instruction to return a 0–100 score with a one-line justification per
   criterion; the instruction to apply the `code-review` skill
   (`skills/code-review/SKILL.md`) to the unit from step 1 as the skill's
   **explicit target** — uncommitted work, or the todo's touched paths,
   inside a `/agentic-framework:delegate` todo or a `/agentic-framework:build`
   run, the branch against its base otherwise, never the skill's default
   Scope resolution — with the depth budget stated as the whole diff;
   against a spec, the spec path and the in-scope IDs (the caller's list,
   else every `REQ-`/`EDGE-` ID in the spec); and, from the second round on,
   the open blockers (`path:line` and claim) to mark resolved or still open.
   The scorer returns the score and the code-review report (see *The
   code-review report*). Score honestly — an inflated score ends the loop
   early and defeats it. If the **first** score is **≥ 90** and the report
   holds no open `[Blocker]`, say so and stop — the loop is for improvement,
   not ceremony.
4. **Name the 1–2 weakest criteria** from the scorer's report and exactly why
   they lost points. The scorer tags each `[Suggestion]` with the rubric
   criterion it weakens and reflects it in that criterion's score; this step
   reads the tags. A suggestion that fits no criterion is listed in the
   round's report, not scored.
5. **Rewrite only the weak parts** (delegating to the implementing specialist
   where routing says so). Keep what scored well. Rewrites are
   **behavior-preserving**: re-run the quality bar after every rewrite; a
   rewrite that breaks a test is reverted, not argued for.
6. **Rescore and decide** — same rubric, fresh scorer instance:
   - Improvement **< 3 points** with no open `[Blocker]`, or **3 scoring
     rounds** (the first included) → stop. More loops past a plateau produce
     churn, not quality.
   - Otherwise → back to step 4.
7. **Report** the rubric, the final score with per-criterion breakdown, the
   score trajectory (e.g. 68 → 81 → 86), any blocker still open, and —
   against a spec — the union across rounds of the "not evidenced in the
   diff" lists, which the caller hands to `spec-compliance-reviewer` together
   with the coverage section as leads (the reviewer still checks every ID) —
   then proceed to the framework's normal review gates.

## The code-review report

The `code-review` report sharpens the loop's targets; it does not replace the
spec gate (`spec-compliance-reviewer`) and adds no rubric criterion. The loop
reads the report's findings, not its `VERDICT:` line.

- **Open `[Blocker]`**: that round cannot end the loop on score — not on a
  first score ≥ 90, not on a plateau. A blocker whose fix changes behavior
  (security hole, data loss, broken invariant, lost guardrail, out-of-scope
  change) is not a polish target: stop the loop, send the change back to
  implementation — first a test that fails without the fix, then the fix —
  and re-enter at step 3 with the same rubric, the round count carried over.
  A blocker fixable without a behavior change (wrong layer, wrong
  abstraction) is the next rewrite target (step 5). A blocker stays open
  until a later scorer, given it by name, confirms it resolved; one the next
  report merely omits is still open. Only the round cap ends the loop with a
  blocker open, and the final report then lists it as unresolved.
- **Against a spec**: the report's `Problem` answer must name the in-scope
  `REQ-`/`EDGE-` IDs the diff delivers. Every in-scope ID the answer does not
  cover, or that a `[Question]` marks as unclear, goes in the round's report
  under the words "not evidenced in the diff" — leads for the
  `spec-compliance-reviewer` gate, which still checks every ID and decides
  conformance.
- **Partial coverage**: if the scorer still reports partial coverage despite
  the whole-diff budget, treat it as a scoring limitation, not a defect of
  the change. Name the files not covered in the round's report; do not cap the
  score for it, and do not rewrite to cure it.
- **Cost**: a rescoring round may reuse the previous round's Chesterton line
  for deletions no rewrite touched; provenance does not change between rounds.

## Rules

- The bar before the rubric — never score a build that isn't green.
- Scorer ≠ author, always: every score comes from a delegated fresh
  specialist run, never from the agent that wrote the code.
- Rubric before judgment, visible in the report, never revised mid-loop.
- Behavior-preserving only: never trade a passing test for a rubric point.
  Spec conformance is a gate (`spec-compliance-reviewer`), not a rubric
  criterion — requirement changes do not belong in a polish loop. The
  `code-review` report feeds targets and the "not evidenced in the diff" list
  into that gate; it never substitutes for it.
- Advisory, and strictly *before* the gates: `code-review-gatekeeper`,
  `peer-review-critic`, and the peer-review Stop gate apply unchanged. A 95
  here skips nothing.
