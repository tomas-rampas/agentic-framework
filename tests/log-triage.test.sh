#!/usr/bin/env bash
# log-triage.test.sh — runs the /log-triage automated test suite (stdlib unittest, Python 3.8+).
#
# The Python tests live in tests/log-triage/test_*.py with fixtures under
# tests/log-triage/fixtures (regenerate with `python3 tests/log-triage/make_fixtures.py`).
# Exit 0 = every test passed; the unittest summary is printed verbatim.
#
# Usage: bash tests/log-triage.test.sh [-k pattern]

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_REPO="$(cd "$TEST_DIR/.." && pwd)"

PY=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' >/dev/null 2>&1; then
      PY="$candidate"
      break
    fi
  fi
done
if [ -z "$PY" ]; then
  printf 'log-triage tests: python 3.8+ not found\n' >&2
  exit 2
fi

export PYTHONDONTWRITEBYTECODE=1
export PYTHONPATH="$SRC_REPO/scripts/log-triage${PYTHONPATH:+:$PYTHONPATH}"

printf 'log-triage test suite (%s)\n' "$("$PY" --version 2>&1)"
"$PY" -m unittest discover -s "$SRC_REPO/tests/log-triage" -p 'test_*.py' -t "$SRC_REPO/tests/log-triage" -v "$@" 2>&1
status=$?

# CLI smoke: the tool must run from a fresh interpreter with no PYTHONPATH help
if [ "$status" -eq 0 ]; then
  if env -u PYTHONPATH "$PY" "$SRC_REPO/scripts/log-triage" --version >/dev/null 2>&1; then
    printf 'CLI smoke: OK\n'
  else
    printf 'CLI smoke: FAILED (python3 scripts/log-triage --version)\n' >&2
    status=1
  fi
fi
exit "$status"
