#!/usr/bin/env bash
# Focused documentation policy regression; --equivalence also runs the PS twin.
set -euo pipefail
src=$(cd "$(dirname "$0")/.." && pwd)
hooks=${HOOK_ROOT:-$src}
wd=$(mktemp -d "${TMPDIR:-/tmp}/docs-gate.XXXXXXXX")
trap 'rm -rf -- "$wd"' EXIT
unset AF_CODE_REVIEW_GATE
passed=0; failed=0; skipped=0
while IFS= read -r row; do
  name=$(printf '%s' "$row" | jq -r .name)
  if [ -n "${CASE_FILTER:-}" ] && [ "$name" != "$CASE_FILTER" ]; then continue; fi
  unset GH_REPO GH_HOST GLAB_REPO GITLAB_REPO GITLAB_HOST
  action=$(printf '%s' "$row" | jq -r .action)
  path=$(printf '%s' "$row" | jq -r '.path // ""')
  expected=$(printf '%s' "$row" | jq -r .allow)
  repo="$wd/case-$((passed + failed + skipped))"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name test
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config commit.gpgsign false
  printf 'base\n' > "$repo/README.md"; printf 'base\n' > "$repo/app.cs"
  git -C "$repo" add -A; git -C "$repo" commit -qm fixture
  base=$(git -C "$repo" rev-parse HEAD)
  if [ "$action" = gitlink ]; then
    git -C "$repo" update-index --add --cacheinfo "160000,$base,module"
    git -C "$repo" commit -qm 'base gitlink'
    base=$(git -C "$repo" rev-parse HEAD)
    mkdir -p "$repo/module"
  fi
  git -C "$repo" remote add origin "$repo.nowhere"
  git -C "$repo" update-ref refs/remotes/origin/main "$base"
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$repo" checkout -qb feature/docs
  case $action in
    add) mkdir -p "$(dirname "$repo/$path")"; printf 'prose\n' > "$repo/$path" ;;
    mixed) printf 'new\n' > "$repo/README.md"; printf 'new\n' > "$repo/app.cs" ;;
    nested-relative) mkdir -p "$repo/docs"; printf 'new\n' > "$repo/docs/guide.md"; printf 'new\n' > "$repo/app.cs" ;;
    gitlink) printf 'new\n' > "$repo/README.md"; git -C "$repo" update-index --cacheinfo "160000,$base,module" ;;
    history) printf 'new\n' > "$repo/app.cs"; git -C "$repo" add -A; git -C "$repo" commit -qm code; printf 'new\n' > "$repo/README.md" ;;
    rename-code-doc) git -C "$repo" mv -- app.cs renamed.md ;;
    rename-doc-code) git -C "$repo" mv -- README.md renamed.py ;;
    rename-doc-doc) git -C "$repo" mv -- README.md renamed.md ;;
    delete-doc) git -C "$repo" rm -q -- README.md ;;
    control-name)
      case $(uname -s) in MINGW*|MSYS*|CYGWIN*) skipped=$((skipped + 1)); continue ;; esac
      printf 'prose\n' > "$repo/$(printf 'app.cs\nnotes.md')" ;;
    *) printf 'new\n' > "$repo/README.md" ;;
  esac
  git -C "$repo" add -A; git -C "$repo" commit -qm fixture
  if [ "$action" = executable ]; then
    git -C "$repo" update-index --chmod=+x README.md; git -C "$repo" commit -qm mode
  fi
  headsha=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-ref refs/remotes/origin/feature/docs "$headsha"
  case $action in
    nested-relative) git -C "$repo" config diff.relative true ;;
    multiple-remotes) git -C "$repo" remote add another "$repo.another" ;;
    gitlink) git -C "$repo" config diff.ignoreSubmodules all ;;
    dirty) printf dirty > "$repo/app.cs" ;;
    staged) printf dirty > "$repo/app.cs"; git -C "$repo" add -- app.cs ;;
    untracked) printf code > "$repo/new.py" ;;
    dirty-doc) printf dirty > "$repo/README.md" ;;
    unknown-base) git -C "$repo" update-ref -d refs/remotes/origin/main ;;
    diff-failed) git -C "$repo" config diff.orderFile "$wd/missing-order-file" ;;
    unknown-head) git -C "$repo" update-ref -d refs/remotes/origin/feature/docs ;;
    remote-mismatch) git -C "$repo" update-ref refs/remotes/origin/feature/docs "$base" ;;
    diverged)
      git -C "$repo" checkout -q main; printf destination > "$repo/app.cs"
      git -C "$repo" add -A; git -C "$repo" commit -qm destination
      git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse HEAD)"
      git -C "$repo" checkout -q feature/docs ;;
  esac
  command='gh pr create --base main'
  case $(printf '%s' "$row" | jq -r '.command // "pr"') in
    push) command='git push origin HEAD:main' ;;
    mr) command='glab mr create --target-branch main' ;;
  esac
  options=$(printf '%s' "$row" | jq -r '.options // [] | join(" ")')
  [ -z "$options" ] || command="$command $options"
  env_name=$(printf '%s' "$row" | jq -r '.envName // ""')
  if [ -n "$env_name" ]; then export "$env_name=foreign/project"; fi
  cwd=$repo; [ "$action" != nested-relative ] || cwd="$repo/docs"
  payload=$(jq -cn --arg cwd "$cwd" --arg command "$command" '{session_id:"docs-only",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command}}')
  output=$(printf '%s' "$payload" | CLAUDE_STATE_DIR="$wd/state" sh "$hooks/hooks/pretooluse-code-review-gate.sh")
  allow=false; [ -z "$output" ] && allow=true
  ok=true
  if [ "$allow" != "$expected" ]; then ok=false; fi
  if [ -n "$output" ] && ! printf '%s' "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null; then ok=false; fi
  if [ "${1:-}" = --equivalence ] && command -v pwsh >/dev/null 2>&1; then
    win_repo=$(cygpath -w "$cwd" 2>/dev/null || printf '%s' "$cwd")
    win_state=$(cygpath -w "$wd/state" 2>/dev/null || printf '%s' "$wd/state")
    ps_payload=$(jq -cn --arg cwd "$win_repo" --arg command "$command" '{session_id:"docs-only",cwd:$cwd,tool_name:"Bash",tool_input:{command:$command}}')
    ps_output=$(printf '%s' "$ps_payload" | CLAUDE_STATE_DIR="$win_state" pwsh -NoProfile -File "$hooks/hooks/pretooluse-code-review-gate.ps1" | tr -d '\r')
    # Deny targets contain platform paths only when location resolution fails;
    # these fixtures resolve, so the complete JSON bytes must match.
    [ "$ps_output" = "$output" ] || ok=false
  fi
  if [ "$ok" = true ]; then passed=$((passed + 1)); printf 'PASS %s\n' "$name"
  else failed=$((failed + 1)); printf 'FAIL %s\n' "$name"; fi
done < <(jq -c '.[]' "$src/tests/docs-only-cases.json")
printf 'RESULT: %s passed, %s skipped, %s failed\n' "$passed" "$skipped" "$failed"
[ "$failed" -eq 0 ]
