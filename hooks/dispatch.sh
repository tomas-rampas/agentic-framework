#!/bin/sh
# dispatch.sh — cross-platform hook dispatcher for the agentic-framework plugin.
# Designed to be registered per hook in hooks/hooks.json as the primary arm of:
# (the registration flips to this form in the interlocked registration wave)
#
# Arms:
#   sh "${CLAUDE_PLUGIN_ROOT}/hooks/dispatch.sh" <hook> \
#     || pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/hooks/<hook>.ps1"
# POSIX -> runs hooks/<hook>.sh (pwsh NOT required).
# Windows Git Bash (MSYS/MINGW/CYGWIN) -> runs hooks/<hook>.ps1 via pwsh.
# Windows without Git Bash -> sh not found -> the "|| pwsh" arm is reached instead.
# ALWAYS exits 0 so the "|| pwsh" arm is reached only when sh cannot spawn.
# SECURITY: Chain safety relies on CLAUDE_PLUGIN_ROOT never containing double-quotes, backticks, or $( — guaranteed by CI-enforced kebab-case names, not platform contract.
set -u

hook=${1:-}
case "$hook" in
  stop-peer-review-gate|record-subagent-run|session-start-context|pretooluse-delegation-hint) ;;
  *) exit 0 ;;
esac

case "$0" in
  */*|*\\*) dir=${0%[\\/]*} ;;
  *)        dir=. ;;
esac

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) pwsh -NoProfile -File "$dir/$hook.ps1" ;;
  *)                    sh "$dir/$hook.sh" ;;
esac
exit 0
