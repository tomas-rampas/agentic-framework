---
name: git-workflow-assistant
description: Git branching, commit, PR, conflict-resolution, and release guidance integrated with the framework's review gates — use when planning branches, writing commit messages, preparing or opening PRs, resolving merge conflicts, cutting releases, when the Stop gate blocks a session over unreviewed committed work, or when the push/PR gate denies a PR, MR or push to main/master.
---

# Git Workflow Assistant

Structured guidance for git operations in this framework: branching strategy, commit conventions, PR preparation, conflict resolution, and releases — plus how committed work interacts with the enforced peer-review final gate.

## When to Use

- Choosing or applying a branching strategy
- Writing commit messages and PR descriptions
- Preparing a feature branch for review and merge
- Resolving merge conflicts or cleaning up history
- Planning a versioned release
- Responding when the peer-review Stop gate blocks the end of a session
- Responding when the push/PR gate denies a PR, MR or push to main/master

## Review Pipeline (enforced by the framework)

Committed work on a feature branch is not "done" until it has been peer reviewed. Follow this order:

1. Implement and commit on a feature branch (never commit directly to main; branch first).
2. Run `code-review-gatekeeper` (Task tool) for quality validation and testing.
3. Run `peer-review-critic` (Task tool, `subagent_type: peer-review-critic`) — the mandatory final gatekeeper. It performs an independent, diff-scoped critical review of the branch against its base.
4. Resolve every BLOCKER/MAJOR finding (commit the fixes, re-review), or obtain explicit user sign-off.
5. Only then open the PR or declare the task done.

Any commit made after the gatekeeper review stales its push/PR-gate marker, including the `peer-review-critic` fix commits from step 4, because the gate matches the HEAD. Run `code-review-gatekeeper` last, after the final commit, before `gh pr create`.

### The Stop gate

The agentic-framework plugin's `stop-peer-review-gate` hook (.ps1/.sh pair, registered in `hooks/hooks.json` as a shell-form chain) blocks ending a session when all of these hold. On Linux/macOS the .sh runs; on Windows the .ps1 runs (either via dispatch if Git Bash is present, or directly).

- The current branch is a feature branch (not main/master, not detached HEAD).
- It has commits ahead of its base (first of `origin/main`, `origin/master`, `main`, `master` that resolves).
- The working tree is clean — the gate only guards committed, "done"-looking states.
- The latest `peer-review-critic` run this session did not record `VERDICT: APPROVED` (the recorder `hooks/record-subagent-run.ps1` parses the review's verdict line into a per-session marker; a marker with no parseable verdict counts as reviewed — fail-open).

What to expect and do:

- The gate blocks a bounded number of times: once when no review ran, up to 3 blocks total while the recorded verdict is `CHANGES_REQUIRED`. It is loop-safe (`stop_hook_active`) and fail-open — errors and non-git contexts never block.
- When blocked, launch `peer-review-critic` to review the branch diff against its base, resolve every BLOCKER/MAJOR finding, and re-run it until the review ends with `VERDICT: APPROVED` — that is what unlocks the next Stop.
- Uncommitted changes do not trigger the gate; committing feature-branch work is what arms it.
- Do not work around the gate by leaving the tree dirty. Committing to main is not an exit either: a push to main or master is itself gated by the push/PR gate, so the review still applies before that commit leaves the machine. Run the review, or ask the user to explicitly waive the gate.

### The push/PR gate

- Hook: `pretooluse-code-review-gate` (`.ps1`/`.sh` pair), `PreToolUse` on the shell tools (`Bash|PowerShell`).
- Allows a push or a PR/MR creation only as a plain single command with literal names: `git push [options] [<remote> [<refspec>]]`, `gh pr create` (alias `gh pr new`), `glab mr create` (alias `glab mr new`), optionally after one location form: `cd <dir> &&`, `cd <dir>;`, or (PowerShell) `Set-Location <dir>;`; the push may also be written `git -C <dir> push ...`. Every other command that mentions one is denied, chains included, and the deny asks for it to be split into plain commands.
- A PR/MR body with newlines, `$`, backticks or the `--body "$(cat <<'EOF' ...)"` idiom is not a plain command and is denied. Write the body to a file and pass `--body-file <path>`, or use `--fill`. A plain push's destination is resolved the way git resolves it (explicit refspec, `remote.<r>.push`, `push.default`, upstream); a push whose destination is `main` or `master` (force included), and every PR/MR creation, is gated.
- Unlocked by a `code-review-gatekeeper` sub-agent run that applies `agentic-framework:code-review` and ends with `VERDICT: APPROVED`. `record-subagent-run` stores the verdict and the review's `Target:` line in `code-review/<session>`; the gate matches it against the current HEAD and the destination base. A per-todo review of uncommitted work, a `peer-review-critic` approval, or a review of another base does not unlock it. The approval is bound to the reviewed range: the marker's `head=` must equal the current HEAD, and the `Target:` range `(<merge-base>..<head-sha>)` must end at the current HEAD and start at a merge-base that is an ancestor of the destination. A commit after the review stales the record, and so does a review that finished after a later commit. Re-run the gatekeeper after any commit, before `gh pr create`.
- The gate stacks on the Stop gate with no cross-unlock.
- `git add && git commit && git push` chains are denied by the gate; push as a separate command.
- It is a best-effort guardrail over direct Bash and PowerShell commands, not a sandbox. Its limitations are: scripts, aliases, `gh api`, shell-capable tools outside the matcher, forged local state (a remote-tracking ref or the marker file), hosts slower than the 8 s budget, git older than 2.31, SHA-256 repositories, and a host without `jq` on the POSIX path. The executor agents' no-push rule and the Stop gate remain the other layers.
- Threat model: the gate guards against a review that was skipped or forgotten in an ordinary session, not against a model that deliberately evades it by forging the local state it reads (a remote-tracking ref or the marker file), which is outside its model exactly as it is for the Stop gate.
- The only sanctioned bypass: `AF_CODE_REVIEW_GATE=off` in the environment Claude Code was launched with. An inline assignment on the command does nothing, and the variable takes effect after a restart.

If the gate is not firing after installing the agentic-framework plugin, verify: (1) the plugin is installed with `/plugin list`, (2) Claude Code has been restarted (hooks load at session start), (3) you have committed work on a non-main branch with `/agentic-framework:validate-hooks` showing no errors.

## Branching Strategies

**Trunk-based development** (recommended for CI/CD): short-lived feature branches (1–3 days), merge to main via reviewed PR, feature flags for incomplete work. Best for small teams and continuous deployment.

**GitHub Flow**: branch from main, PR back to main, deploy from main after merge. Best for SaaS and web applications.

**GitFlow** (scheduled releases): `develop` as integration branch, `release/*` for release prep, `hotfix/*` branching from main. Best for products with versioned releases.

Whichever strategy applies, keep branches focused on one change and rebase onto the base before requesting review so the peer-review diff is clean.

## Commit Message Conventions

Use Conventional Commits:

```
<type>(<scope>): <subject>

<body>

<footer>
```

Types: `feat` (minor bump), `fix` (patch bump), `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `ci`.

Example:

```
fix(api): prevent SQL injection in user search endpoint

Parameterize the search query instead of string interpolation.
Added input validation for search terms.

Fixes #287
BREAKING CHANGE: search API now rejects special characters
```

Note breaking changes in the footer with `BREAKING CHANGE:` and reference issues (`Closes #N`, `Fixes #N`).

## PR Workflow

Pre-PR checklist:

1. Update the branch: `git fetch origin main && git rebase origin/main`.
2. Run the full test suite locally.
3. Run `code-review-gatekeeper` as a sub-agent on the branch against its base. The push/PR gate (`pretooluse-code-review-gate`) denies `gh pr create` until that review's `VERDICT: APPROVED` is recorded at the current HEAD. Then run `peer-review-critic`; resolve BLOCKER/MAJOR findings and commit the fixes. Those fix commits stale the marker, so run `code-review-gatekeeper` again after the last commit; it must run last before `gh pr create`, which runs as its own plain command.
4. Open the PR with `gh pr create --body-file <path>`, writing the body to a file first (a multi-line `--body` is denied by the push/PR gate; `--fill` is the alternative). Use this structure for the body file:

```markdown
## Summary
Brief description of what this PR does and why.

## Changes
- Change 1: description
- Change 2: description

## Testing
- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Manual testing completed

## Notes for Reviewers
Context that helps reviewers understand the changes.
```

## Merge Conflict Resolution

1. **Understand both sides** — read the conflicting changes to understand intent before resolving.
2. **Choose the right strategy**: `theirs` for upstream dependency updates, `ours` for intentional divergence, manual merge for logic conflicts.
3. **Test after resolution** — always run the test suite after resolving conflicts.
4. **Commit with context** — explain the resolution in the merge commit message.

Useful commands:

```bash
# Update branch before PR
git fetch origin main
git rebase origin/main

# Abort a bad rebase
git rebase --abort

# Squash merge for clean history
git merge --squash feature-branch
```

Avoid interactive rebase (`git rebase -i`) in this environment — it opens an editor and is not supported. To squash history, use `git merge --squash` or `git reset --soft <base>` followed by a fresh commit.

## Release Workflow

Semantic versioning: `MAJOR.MINOR.PATCH` — breaking changes / new backward-compatible features / backward-compatible fixes.

Release checklist:

1. Create a release branch (`release/v1.2.0`).
2. Update version numbers in config files and CHANGELOG.md.
3. Run the full test suite; run the review pipeline (code-review-gatekeeper, then peer-review-critic) on the release diff.
4. Tag: `git tag -a v1.2.0 -m "Release v1.2.0"`, then `git push origin v1.2.0`.
5. Merge the release branch back to main (and develop, under GitFlow).

## Agent Coordination

- **Language experts** (see the registry, `claude.json`) for language-specific build/test tooling around commits.
- **devops-orchestrator** for CI/CD pipeline integration and release automation.
- **code-review-gatekeeper** for the first-pass quality review before the final gate.
- **peer-review-critic** for the final, independent branch-vs-base review — the last step before work is declared done.
