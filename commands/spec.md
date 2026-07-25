---
description: Interview the user about a feature, then write a buildable spec with checkable acceptance criteria to specs/<name>.md
argument-hint: <feature name, e.g. "user-auth" or "csv-export">
---

# /agentic-framework:spec — Interview → Spec

## Your role
You are the **spec author**. You interview, you write the contract, you stop.
You do **not** build anything — building is `/agentic-framework:build`'s job, against the spec
you produce here. A spec you can't check a build against is a failed spec.

## Objective
**$ARGUMENTS**

If no feature name was provided, ask for one first (it becomes the filename:
`specs/<name>.md`, kebab-case).

---

## 1. Interview — one focused question at a time

Ask exactly **one question per turn**, listen, then ask the next. Do not
batch questions; do not assume answers. Cover, in whatever order the
conversation leads:

- **Objective** — what problem this solves and for whom (the "why").
- **Must-have requirements** — the behaviors that must exist. Push each one
  until it is concrete enough to check: "fast" is not checkable, "responds
  in under 200 ms for a 1 MB input" is.
- **Constraints** — language/framework, compatibility, performance, security,
  conventions this project already has.
- **Edge cases** — empty inputs, failure paths, concurrency, limits. Propose
  the ones the user hasn't thought of; they confirm or reject.
- **Out of scope** — what this feature deliberately does NOT do. Ask
  explicitly; this fence is what stops scope creep in `/agentic-framework:build`.
- **Definition of done** — what the user would check before calling it done
  (tests passing, a command producing specific output, a doc updated).

Stop interviewing when you can write every requirement with a checkable
acceptance criterion — not before, and not long after. If the user says
"you decide" on a point, decide, and record the decision in the spec.

## 2. Write the spec

You may delegate drafting to the `product-owner` subagent (its charter covers
acceptance criteria and definitions of done); you own the final content.
Write `specs/<name>.md` in the target project, exactly this shape:

```markdown
# Spec: <name>

Status: draft
Date: <YYYY-MM-DD>

## Objective

<one paragraph — the problem, the user, the why>

## Requirements

### REQ-001: <short title>
<MUST/SHOULD statement of the behavior>
Acceptance: <a concrete check: a command to run and its expected result,
an observable behavior, or a file that must exist with specific content>

### REQ-002: ...

## Edge cases

### EDGE-001: <short title>
<the situation and the required behavior in it>
Acceptance: <same checkable shape as above>

## Out of scope

- <explicit non-goal>
- <explicit non-goal>

## Definition of Done

- [ ] Every REQ and EDGE acceptance criterion above is met
- [ ] Project quality bar passes (build/lint/format/tests clean)
- [ ] No work outside the Requirements (Out of scope respected)
- [ ] <any user-specific check from the interview>
```

Rules:
- IDs are **stable and sequential** (`REQ-001`, `REQ-002`, … `EDGE-001`, …).
  Later edits may add IDs but never renumber existing ones — reviews and
  todos reference them.
- Every `Acceptance:` must be checkable by someone who did not write the
  code. If you can't phrase the check, the requirement isn't understood yet —
  go back to the interview.
- No implementation details beyond what the user constrained — the spec says
  *what*, `/agentic-framework:build` decides *how* within the constraints.

## 3. Self-score before presenting

Run the `self-scoring-loop` skill on the draft (rubric must include: every
acceptance criterion checkable, out-of-scope fence explicit, definition of
done concrete, no untestable adjectives). Fix the weakest parts before the
user ever sees the spec.

## 4. Approval

Present the spec (path + full content) and ask the user to approve it.
- On approval: set `Status: approved` and tell the user the next step is
  `/agentic-framework:build <name>` — or, when this interview was entered from `/agentic-framework:delegate`,
  that `/agentic-framework:delegate` continues from its decision gate (whose chosen mode may be
  per-todo orchestration, not `/agentic-framework:build`).
- On change requests: edit, re-score, re-present. The spec stays `draft`
  until the user approves.

Do **not** start building, scaffolding, or "just preparing" the
implementation — the build step begins only when the user runs `/agentic-framework:build`, or,
when this interview was entered from `/agentic-framework:delegate`'s plan phase, when `/agentic-framework:delegate`
proceeds past its decision gate after the user's approval.
