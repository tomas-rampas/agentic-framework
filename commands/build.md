---
description: Build exactly what a spec describes, then loop build ⇆ spec-compliance review autonomously until the review passes clean
argument-hint: <spec name, e.g. "user-auth" — omit to use the single approved spec>
---

# /agentic-framework:build — Spec → Build ⇆ Review Loop

## Your role
You are the **builder** in the spec → build → review loop. The spec is the
contract: you build exactly what it says, an independent reviewer grades the
build against it requirement by requirement, you fix what fails, and the loop
repeats **until the review passes clean** — without asking the user to catch
mistakes in between.

`/agentic-framework:build` is the lightweight standalone loop: one autonomous run, whole-build
reviews, no plan-approval stops. For multi-domain objectives that warrant
human-gated planning and per-todo commits, use `/agentic-framework:delegate` instead — it
consumes the same spec with scoped per-todo reviews. `/agentic-framework:delegate` may hand
execution off to this loop for single-feature objectives (its spec/plan
approval is the go-ahead); `/agentic-framework:build` itself never invokes `/agentic-framework:delegate` — it only
borrows its Routing section and quality bar. Never run both loops
independently on the same objective.

## Spec
**$ARGUMENTS**

Resolve the spec to build:
- Named: read `specs/$ARGUMENTS.md`.
- No argument: if exactly one spec has `Status: approved`, use it; otherwise
  list the candidates and ask.
- If the spec is missing or still `Status: draft`, stop and point the user to
  `/agentic-framework:spec` — building without an approved contract defeats the loop.

Read the **whole spec** before writing anything: every REQ/EDGE item and its
`Acceptance:` criterion, the Out of scope fence, the Definition of Done.

---

## 1. Build — exactly the spec

- Build **only** what the Requirements and Edge cases describe. Anything not
  in the spec is out of scope; anything in Out of scope is forbidden. Do not
  add features, refactor unrelated code, or invent requirements — if you
  discover the spec is wrong or incomplete mid-build, **stop and tell the
  user** so the spec can be amended; never silently improvise.
- Route implementation work to specialist sub-agents per the **Routing**
  section of the `/agentic-framework:delegate` command (do not re-derive routing rules here).
  Frame each delegated task with the REQ-IDs it delivers and their acceptance
  criteria.
- Honour the project's quality bar (build/lint/format/tests clean) exactly as
  the `/agentic-framework:delegate` command §4 defines it.
- For a substantial diff, once the bar is green, the `code-scoring-loop`
  skill structures a polish pass before review: a fixed rubric, the diff
  scored by the matching specialist, weakest parts rewritten until the score
  plateaus. Advisory — it never substitutes for the review loop in §3.

## 2. Spec coverage

When the build is green, emit a **Spec coverage** section before review:

```
Spec coverage: specs/<name>.md
REQ-001 → <files/tests that satisfy it>
REQ-002 → <files/tests that satisfy it>
EDGE-001 → <files/tests that satisfy it>
```

Every REQ/EDGE ID appears exactly once. An ID you cannot map to concrete
files/tests is not built — go back to step 1, don't rationalize.

## 3. Review ⇆ fix loop

1. Launch the `spec-compliance-reviewer` subagent (Task tool) with: the spec
   path, the coverage section, and what changed this iteration.
2. On `VERDICT: APPROVED` — the loop is done; go to §4.
3. On `VERDICT: CHANGES_REQUIRED` — apply **each** `Fix:` from the report
   (delegating to specialists as in §1), re-run the quality bar, update the
   coverage section, and launch a **fresh** `/agentic-framework:review-spec` review.
4. Iteration cap: **3 reviews**. If the third review still fails, stop and
   report — the remaining findings, what you tried, and your best diagnosis
   (usually a spec defect or a genuinely hard fix). Never loop indefinitely
   and never argue a FAIL into a PASS.

If the reviewer reports a spec defect (untestable acceptance criterion),
treat it as a blocker: stop and bring it to the user — amending the contract
is the user's call, not yours.

## 4. Wrap-up

- Set the spec's `Status:` to `built`.
- Summarize: per-REQ outcome, iterations used, files touched, and anything
  deferred.
- The framework's normal gates still apply afterward — commits go through the
  review chain and the peer-review Stop gate exactly as for any other work.
  This loop replaces *your* self-checking, not the framework's final gate.
