# Design: peer-review-final-gate (Stop hook)

**Status: implemented** — `hooks/stop-peer-review-gate.ps1` + `hooks/record-subagent-run.ps1`,
registered in `settings.json` via `settings.template.json` (see `scripts/install.ps1`).
This document is the design rationale; the scripts are the source of truth for behavior.

## Purpose

Enforce the framework's final quality gate: an independent, diff-scoped review by the
`peer-review-critic` subagent — with an **APPROVED verdict** — before a coding session ends
with committed feature-branch work. It is the last line of defence after
`code-review-gatekeeper`.

## Mechanism

A `Stop` hook. When it decides to block, it emits `{"decision":"block","reason":...}` on
stdout; Claude Code feeds the reason back to the model, which is instructed to launch (or
re-run) the peer-review-critic subagent. The recorder `hooks/record-subagent-run.ps1` runs
on two events — `PostToolUse` (matcher `Task|Agent`) and `SubagentStop` — and writes a
per-session marker file under `~/.claude/.state/peer-review/<session_id>`:

```
<ISO timestamp>                      <- line 1, the pre-verdict format ends here
verdict=APPROVED|CHANGES_REQUIRED    <- line 2, parsed from the report's VERDICT line
```

The verdict comes from the standardized machine-readable line the `peer-review-critic`
agent definition requires as the last line of its report (`VERDICT: APPROVED` or
`VERDICT: CHANGES_REQUIRED`). The **last** occurrence in the report wins, so an earlier
quoted mention cannot spoof it. Each qualifying run overwrites the marker (stale
re-emissions excepted; see Stale-verdict protection below) — the latest review is the one
that counts, which is what a fix → re-review loop needs. The `SubagentStop` source
(`agent_type` + `last_assistant_message`) also covers background subagent launches, whose
`PostToolUse` fires before any report text exists.

## Stale-verdict protection

The mechanism previously allowed any stop of the peer-review-critic agent to overwrite
the session's recorded verdict, risking gate bypass if a stale instance re-emitted an old
outcome. Revised guards now prevent such stale re-recordings:

The recorder deduplicates on the reporting agent's instance ID (when available) across
HEAD changes. Each verdict-bearing write consumes the agent instance, so a repeated stop
of the same instance cannot re-record a verdict while HEAD is unchanged; after new
commits the same instance may record again (the fix → re-review loop). Consumed IDs live
in a per-session `.verdict-sources` file alongside the marker. When an instance ID is
unavailable, the marker's `head=<git sha>` field enables asymmetric contradiction
detection: escalation to CHANGES_REQUIRED always records (fail-safe); a flip to APPROVED
is ignored unless HEAD has provably moved (fail-closed), since a gate unlock without a
review of new code risks bypass. Each suppression is logged to a companion
`.verdict-suppressed` file beside the marker — timestamp, which guard fired, old and new
verdict, and HEAD — so dropped verdicts stay forensically visible. The marker is always
written before the instance ID is consumed, so a failed write cannot burn the instance's
retry ability. All failure paths fail-open to legacy last-write-wins behavior; there is
no cross-process lock, so near-simultaneous hook firings can race, degrading toward
reduced protection, never corruption or silent bypass.

## Gate decision (given committed, clean, ahead-of-base feature-branch work)

| Session marker state | Decision |
|---|---|
| `verdict=APPROVED` | allow |
| marker present, no verdict line (legacy recorder) | allow (fail-open) |
| `verdict=CHANGES_REQUIRED` | **block**, up to 3 blocks/session total |
| no marker (reviewer never ran) | **block**, at most once per session |

The `<session_id>.fired` marker is a **block counter** (absence = 0; an empty file from the
pre-verdict format counts as 1). The no-marker budget of 1 preserves the original
once-per-session semantics; the CHANGES_REQUIRED budget of 3 makes the fix → re-review
loop enforced but bounded — the gate must never trap a session in an endless loop.

## Block conditions (ALL must hold; anything else allows the stop — fail-open)

1. The stop is not a stop-hook continuation (`stop_hook_active` is not true) — loop safety.
2. The block budget for the current marker state (table above) is not exhausted.
3. The latest review this session did not APPROVE (no marker, or `verdict=CHANGES_REQUIRED`;
   a legacy no-verdict marker allows).
4. `cwd` is inside a git work tree.
5. HEAD is a named branch that is not the integration base (not detached, not main/master).
6. There are commits ahead of the integration base — first existing of `origin/main`,
   `origin/master`, `main`, `master`.
7. The working tree is clean (a committed end-of-work milestone, not a mid-edit pause).

## Rationale

The Stop hook fires at the end of every turn, so the trigger is deliberately narrow —
committed work on a feature branch, clean tree, not yet approved — to behave like a
pre-merge review gate, not a per-turn nag. Any error, parse failure, or missing tool exits
0 silently: the gate must never trap a user in an unstoppable session.

The verdict upgrade closes the gap this document previously listed as an accepted
limitation (a session could launch the reviewer, ignore every finding, and still pass the
gate). Resolution of the findings is now code-enforced up to the block budget: a
`CHANGES_REQUIRED` review keeps blocking until a later review records `APPROVED`, the
budget runs out, or the user explicitly waives the gate.

**Remaining accepted limitation:** the marker means "the latest peer-review-critic run this
session produced this verdict", not "the current HEAD was reviewed". A session that gets an
APPROVED review and then commits more work is not re-gated. Tying the marker to the
reviewed commit SHA was considered and rejected as too naggy for iterative fix-review-fix
loops; the per-session semantic matches the documented contract in CLAUDE.md.

## Exit criteria for the review itself

Every BLOCKER and MAJOR finding from peer-review-critic resolved (or explicit user
sign-off) and a `VERDICT: APPROVED` review recorded before the work is declared done — see
CLAUDE.md "Final Quality Gate".
