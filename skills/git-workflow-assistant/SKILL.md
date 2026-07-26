---
name: git-workflow-assistant
description: Git branching, commit, PR, conflict-resolution, and release guidance integrated with the framework's peer-review final gate — use when planning branches, writing commit messages, preparing or opening PRs, resolving merge conflicts, cutting releases, or when the Stop gate blocks a session over unreviewed committed work.
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

## Review Pipeline (enforced by the framework)

Committed work on a feature branch is not "done" until it has been peer reviewed. Follow this order:

1. Implement and commit on a feature branch (never commit directly to main; branch first).
2. Run `code-review-gatekeeper` (Task tool) for quality validation and testing.
3. Run `peer-review-critic` (Task tool, `subagent_type: peer-review-critic`) — the mandatory final gatekeeper. It performs an independent, diff-scoped critical review of the branch against its base.
4. Resolve every BLOCKER/MAJOR finding (commit the fixes, re-review), or obtain explicit user sign-off.
5. Only then open the PR or declare the task done.

### The Stop gate

The agentic-framework plugin's `hooks/stop-peer-review-gate.ps1` (registered in `hooks/hooks.json` with exec-form PowerShell and `${CLAUDE_PLUGIN_ROOT}`) blocks ending a session when all of these hold:

- The current branch is a feature branch (not main/master, not detached HEAD).
- It has commits ahead of its base (first of `origin/main`, `origin/master`, `main`, `master` that resolves).
- The working tree is clean — the gate only guards committed, "done"-looking states.
- The latest `peer-review-critic` run this session did not record `VERDICT: APPROVED` (the recorder `hooks/record-subagent-run.ps1` parses the review's verdict line into a per-session marker; a marker with no parseable verdict counts as reviewed — fail-open).

What to expect and do:

- The gate blocks a bounded number of times: once when no review ran, up to 3 blocks total while the recorded verdict is `CHANGES_REQUIRED`. It is loop-safe (`stop_hook_active`) and fail-open — errors and non-git contexts never block.
- When blocked, launch `peer-review-critic` to review the branch diff against its base, resolve every BLOCKER/MAJOR finding, and re-run it until the review ends with `VERDICT: APPROVED` — that is what unlocks the next Stop.
- Uncommitted changes do not trigger the gate; committing feature-branch work is what arms it.
- Do not work around the gate by leaving the tree dirty or committing to main — run the review, or ask the user to explicitly waive the gate.

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
3. Run `code-review-gatekeeper`, then `peer-review-critic`; resolve BLOCKER/MAJOR findings and commit the fixes.
4. Open the PR with `gh pr create` using this structure:

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
