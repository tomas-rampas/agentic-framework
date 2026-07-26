---
description: Manually run a spec conformance review — check the current build against specs/<name>.md requirement by requirement
argument-hint: <spec name, e.g. "user-auth" — omit to use the single approved/built spec>
---

# /agentic-framework:review-spec — Manual Spec Conformance Check

## Your role
Entry point only: you resolve the spec, launch the independent
`spec-compliance-reviewer` subagent, and relay its report faithfully. You do
not review yourself, soften findings, or fix anything in this command.

## Spec
**$ARGUMENTS**

- Named: use `specs/$ARGUMENTS.md`.
- No argument: if exactly one spec has `Status: approved` or `Status: built`,
  use it; otherwise list candidates and ask.
- No spec found: stop and point the user to `/agentic-framework:spec`.

## Run

Launch the `spec-compliance-reviewer` subagent (Task tool) with:
- the spec path,
- the scope to judge: the branch diff against its base if on a feature
  branch, otherwise the working tree,
- any Spec coverage section a previous `/agentic-framework:build` produced (as a claim to
  verify, not to trust).

## Relay

Report back to the user, unedited in substance:

1. The per-requirement lines (`REQ-001: PASS/FAIL — …`, `EDGE-…`, `SCOPE:`)
   exactly as the reviewer classified them.
2. The reviewer's fix list, if any.
3. The final `VERDICT:` line.

If the verdict is `CHANGES_REQUIRED`, offer the natural next step — apply the
fixes via `/agentic-framework:build <name>` (which re-enters the build ⇆ review loop) — but do
not start it without the user's go-ahead: this command is a read-only check.

The review runs on the reviewer's own evidence (commands it ran, files it
read); if it reports the spec itself is untestable as written, surface that
prominently — the fix belongs in `specs/<name>.md`, via `/agentic-framework:spec`.
