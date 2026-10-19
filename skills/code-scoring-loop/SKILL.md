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
   `agentic-framework:code-review` skill or the review gates directly.
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
   subagent instance each round and hand it:
   - the diff of that target and the rubric, with the instruction to return
     a 0–100 score and a one-line justification per criterion;
   - the instruction to apply the `agentic-framework:code-review` skill
     (`skills/code-review/SKILL.md` in the agentic-framework plugin; never the
     `code-review` plugin's PR command, which posts comments) to the scored
     tree as the skill's **explicit target**, in the form from step 1, never
     the skill's default Scope resolution: the touched paths or the
     user-named paths, each stated as uncommitted work (a branch may hold a
     committed diff; review the pending edits), or the uncommitted work;
   - the depth budget, stated as the whole diff;
   - the report conventions of step 4 and *The code-review report*: the
     criterion tag on each `[Suggestion]`, the in-scope IDs named in the
     `Problem` answer, the status list after the report;
   - against a spec, the spec path and the in-scope IDs (the caller's list,
     else every `REQ-`/`EDGE-` ID in the spec);
   - from the second round on, the open blockers (`path:line` and claim) to
     mark resolved or still open, and the previous round's Chesterton line,
     reusable for deletions no rewrite touched.
   The scorer returns the score and the code-review report (see *The
   code-review report*). Score honestly — an inflated score ends the loop
   early and defeats it. If the **first** score is **≥ 90** and the report
   holds no open `[Blocker]`, say so and stop — the loop is for improvement,
   not ceremony.
4. **Name the 1–2 weakest criteria** from the scorer's report and exactly why
   they lost points. The scorer tags each `[Suggestion]` with the rubric
   criterion it weakens, at the end of the claim sentence like the moot tag,
   and reflects it in that criterion's score; this step reads the tags. A
   suggestion that fits no criterion is listed in the round's report, not
   scored.
5. **Rewrite only the weak parts** (delegating to the implementing specialist
   where routing says so). Keep what scored well. Rewrites are
   **behavior-preserving**: re-run the quality bar after every rewrite; a
   rewrite that breaks a test has its edits undone, not argued for.
6. **Rescore and decide** — same rubric, fresh scorer instance:
   - Improvement **< 3 points** with no open `[Blocker]`, or **3 scoring
     rounds** (the first included; a resumed round counts, and after the
     third, stop whatever it found) → stop. More loops past a plateau produce
     churn, not quality. The plateau test does not apply to a resumed round,
     which followed a fix and no rewrite: continue at step 4 unless the cap is
     reached or the round scores ≥ 90 with no open `[Blocker]`, which stops as
     a first round does (a behavior-changing blocker found in it stops the
     loop again, see *The code-review report*).
   - Otherwise → back to step 4 (a behavior-changing blocker instead stops the
     loop, see *The code-review report*).
7. **Report** the rubric, the final score with per-criterion breakdown, the
   score trajectory (e.g. 68 → 81 → 86), any blocker still open, the files
   each round's review did not cover in depth, any round whose evaluator was
   not applied, and — against a spec — the
   union across rounds of the "not evidenced in the diff" lists, which the
   caller hands to `spec-compliance-reviewer` together with the coverage
   section (the `/agentic-framework:build` §2 Spec coverage section, where one
   exists) as leads; the reviewer still checks every ID. Then proceed to the
   framework's normal review gates.

## The code-review report

The `code-review` report sharpens the loop's targets; it does not replace the
spec gate (`spec-compliance-reviewer`) and adds no rubric criterion. The loop
reads the report's findings, not its `VERDICT:` line.

- **Open `[Blocker]`**: that round cannot end the loop on score — not on a
  first score ≥ 90, not on a plateau. A blocker stays open until a later
  scorer, given it by name, confirms it resolved; one the next report merely
  omits is still open. Statuses go in a short list after the report, outside
  its template; on a moot suggestion the criterion tag precedes the moot tag.
  By class:
  - *Behavior-changing* (security hole, data loss, broken invariant, lost
    guardrail): not a polish target. Stop the loop, send the change back to
    implementation — with a failing test first where the fix adds behavior —
    and resume at step 3 with the same rubric once gate zero is green again,
    the round count carried over; step 6 then decides as written for a
    resumed round. In a spec-driven run (a build run, or a delegate todo
    against a spec), a fix that needs behavior no `REQ-`/`EDGE-` item covers
    is a spec defect: stop and tell the user rather than implement it.
  - *Out-of-scope change*: one the run made is behavior-changing and handled
    as above; one the run did not make (a pending file outside the change) is
    excluded from the target, reported, and never reverted.
  - *Fixable without a behavior change* (wrong layer, wrong abstraction): the
    next rewrite target (step 5).
  - *Missing provenance*: settled by evidence — hand the next scorer the
    introducing commit, the issue, or the `REQ-` that mandates the removal —
    and reclassified by it.
  - *Still open at the cap*: fixed before the gates with no further rescore —
    a behavior-changing one in implementation, a rewrite target in one last
    rewrite under the quality bar — and listed as unresolved in the final
    report, which is written after that hand-back. Only the cap, or the
    spec-defect stop, ends the loop with a blocker open.
- **Wrong tree or no evaluator**: a code-review stop (no findings, no
  verdict), a `Target:` fallback reading `uncommitted changes present, not
  reviewed`, a report without the skill's `Target:` line, or one whose last
  line is not its `VERDICT:` line, means the target was not stated in its
  step-1 form or the skill was not applied: restate and rerun. A rerun
  replaces the round, does not count toward the cap, and happens at most once
  per round; if it is invalid too, the round counts as "evaluator not
  applied", cannot end the loop on score, and step 7 lists it. Never read
  such a round as a round with no blocker.
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
- **Cost**: a rescoring round reuses the previous round's Chesterton line,
  handed over in step 3, for deletions no rewrite touched; provenance does
  not change between rounds.

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
