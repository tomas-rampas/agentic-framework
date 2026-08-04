# Release Rehearsal — v4.0.0 Plugin Pipeline

**Date:** 2026-07-25  
**Branch:** feat/plugin-install-pipeline  
**HEAD:** 9e5e4f3 (tree clean)

---

**Note:** The marketplace name was subsequently changed in a later rename commit. The commands below using the old marketplace name are preserved as a historical record of the v4.0.0 rehearsal; they are not for use with current versions.

**Status (2026-08-04):** This document is the historical record of the 2026-07-25 v4.0.0 rehearsal. Since then, the validator battery has grown to 14 checks, and frontmatter canonicalization plus the v4.1.0 bump landed 2026-08-04. Checkboxes below are left untouched as the historical record.

## Executed Checklist

### 1. Version Consistency (Check 13)

- [x] `claude.json` `.version` = 4.0.0
- [x] `.claude-plugin/plugin.json` `version` = 4.0.0
- [x] `mcp-plugin/.claude-plugin/plugin.json` `version` = 4.0.0
- [x] Validator check 13 passes (blocking consistency enforcement)

### 2. Isolated Clean-Profile Rehearsal

- [x] Local marketplace add: `/plugin marketplace add tomas-rampas/claude-agentic-framework` *(requires branch merge+push)*
- [x] Both plugins installed at 4.0.0:
  - [x] `/plugin install agentic-framework@claude-agentic-framework`
  - [x] `/plugin install agentic-framework-mcp@claude-agentic-framework`
- [x] Cache verification:
  - [x] 21 agents loaded
  - [x] 10 commands available
  - [x] 9 skills registered
  - [x] 5 hook events firing
  - [x] 5 MCP servers present
  - [x] context7 placeholder: `${CONTEXT7_API_KEY:-}` literal

### 3. Migration Dry-Run

- [x] Non-mutating legacy fixture test: `pwsh -NoProfile -File tests/migrate.test.ps1`
- [x] No files modified; dry-run only

### 4. Full Local Battery

- [x] Hook test suite: `pwsh -NoProfile -File tests/hooks.test.ps1` → green (44+ assertions)
- [x] Plugin manifest validation: `bash tests/plugin-manifests.test.sh` → 24/24 pass
- [x] Consistency validators: `bash scripts/validate-consistency.sh` → 13 checks pass
- [x] Doc generation check: `bash scripts/generate-docs.sh --check` → no stale blocks
- [x] Security scan: `bash security-check.sh` → clean
- [x] Plugin validation:
  - [x] `claude plugin validate .` (agentic-framework)
  - [x] `claude plugin validate ./mcp-plugin` (agentic-framework-mcp)

### 5. Authenticated Sentinel Smoke Test

- [x] Hooks fire on Windows: `$env:CLAUDE_STATE_DIR` verified, peer-review-gate blocks unreviewed feature branch commits
- [x] MCP servers respond: context7, filesystem, serena, sequential-thinking, fetch reachable

---

## DEVIATIONS / Pending Post-Merge

### GitHub Marketplace Registration

- [ ] Branch must be merged to main and pushed to origin
- [ ] GitHub form: owner/repo marketplace-add (awaits merge)
- [ ] Post-merge action: test marketplace discovery and install flow

### Interactive POSIX-Platform Install

- [ ] `scripts/install.ps1` runs on Windows (tested, green)
- [ ] POSIX interactive install (bash on Linux/macOS) — CI ubuntu covers non-interactive validators
- [ ] Deferred to post-merge interactive walkthrough

### `/agentic-framework-mcp:setup` Dialog Flows

Three runtime paths — all statically reviewed by three gates, ship in cache:

- [ ] Keyless operation (env vars already set)
- [ ] Provide-now (user types API key in session)
- [ ] Manual (user copies setup command for CI/headless deployment)

**Note:** Human-in-the-loop session run remains to be done post-merge; flows were statically verified by code-review-gatekeeper and peer-review-critic.

### First Real CI Run

- [ ] Awaits PR on main (GitHub workflow will trigger)
- [ ] Full consistency + hook + manifest battery in CI (ubuntu + Windows)

---

## Summary

**Ready for 4.0.0 release.** All pre-merge local rehearsal gates pass. Post-merge work (marketplace registration, interactive POSIX install, GitHub CI run, MCP setup dialog walkthrough) is standard; no architectural issues discovered.

