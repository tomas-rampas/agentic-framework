---
name: self-scoring-loop
description: Iteratively improve a non-code deliverable (spec, plan, document, design) by writing an explicit rubric, scoring the work 0-100 against it, rewriting the weakest parts, and repeating until the score plateaus. Use when a deliverable has a quality bar but no test suite — e.g. before handing over a spec, proposal, architecture doc, or report.
---

# Self-Scoring Loop

Turn a single-shot draft into a converging loop: score the work against an explicit rubric, fix the weakest parts, and repeat until improvement stalls. Scoring and rewriting are different acts — critiquing the work *before* rewriting turns blind editing into directed search.

This is the quality loop for deliverables that have no test suite. For code, use the `code-scoring-loop` sibling skill — the same loop with the diff scored by the framework's specialist agents, run before (never instead of) the review gates (`code-review-gatekeeper`, `peer-review-critic`).

## When to Apply

- A spec, plan, proposal, or document is "done" but has not been judged against anything.
- The `/agentic-framework:spec` command finishes a draft spec (self-score it before presenting it).
- A deliverable will be consumed by someone else (or another agent) and errors are expensive downstream.
- The user asks to "polish", "tighten", or "make this good" without concrete criteria.

## The Loop

1. **Write the rubric first — before judging.** 5–7 criteria specific to this deliverable, each with a weight (weights sum to 100). Generic criteria produce generic scores; a spec's rubric should weigh things like *testable acceptance criteria* and *explicit out-of-scope fence*, not "clarity" alone. The rubric is fixed for the rest of the loop — do not move the goalposts between iterations.
2. **Score 0–100** against the rubric, with a one-line justification per criterion. Score honestly: an inflated score ends the loop early and defeats it.
3. **Name the 1–2 weakest criteria** and exactly why they lost points.
4. **Rewrite only the weak parts.** Keep what scored well — a full rewrite discards verified quality and restarts convergence.
5. **Rescore and decide:**
   - Improvement **< 3 points**, or **3 iterations** reached → stop. More loops past a plateau produce churn, not quality.
   - Otherwise → back to step 3.
6. **Report** the final version, the final score with per-criterion breakdown, and the score trajectory (e.g. 71 → 84 → 88) so the reader can see the loop worked.

## Rules

- Rubric before judgment, always — scoring without a rubric is vibes.
- The rubric must be *visible* in the report; a hidden rubric is unfalsifiable.
- Never revise the rubric mid-loop to make a score look better.
- If the deliverable scores ≥ 90 on the first pass, say so and stop — the loop is for improvement, not ceremony.
- This loop is single-agent and advisory; it does not replace the framework's review gates for code — code takes the `code-scoring-loop` variant.
