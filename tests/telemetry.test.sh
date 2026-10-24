#!/usr/bin/env bash
# telemetry.test.sh — SubagentStop records of hooks/telemetry-agent-run.sh:
# final output tokens per message.id, output_final, verdict, duration_s.
# Fixture transcripts are created here; state goes to a throwaway CLAUDE_STATE_DIR.
# Usage: bash tests/telemetry.test.sh   (exit 0 = all pass)

set -u

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_REPO="$(cd "$TEST_DIR/.." && pwd)"
HOOK="$SRC_REPO/hooks/telemetry-agent-run.sh"

TESTS_RUN=0
TESTS_PASS=0
TESTS_FAIL=0

HARNESS_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/telemetry-test.XXXXXXXX") || exit 1
trap 'cd / 2>/dev/null || true; rm -rf "$HARNESS_ROOT"' EXIT INT TERM

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

export CLAUDE_STATE_DIR="$HARNESS_ROOT/state"
mkdir -p "$CLAUDE_STATE_DIR"

assert_eq() { # name expected actual
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" = "$3" ]; then
    TESTS_PASS=$((TESTS_PASS + 1)); printf 'PASS %s\n' "$1"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1)); printf 'FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3"
  fi
}

# line <ts> <msgid> <stop_reason|null> <output_tokens> [text]  -> one assistant transcript line
line() {
  jq -c -n --arg ts "$1" --arg id "$2" --arg sr "$3" --argjson out "$4" --arg text "${5:-hi}" '
    {type: "assistant", timestamp: $ts, isSidechain: true,
     message: {id: $id, model: "claude-sonnet-5-5", stop_reason: (if $sr == "null" then null else $sr end),
               content: [{type: "text", text: $text}],
               usage: {input_tokens: 10, output_tokens: $out,
                       cache_read_input_tokens: 0, cache_creation_input_tokens: 0}}}'
}

handback() { # ts id message
  jq -c -n --arg ts "$1" --arg id "$2" --arg msg "$3" '
    {type: "assistant", timestamp: $ts, isSidechain: true,
     message: {id: $id, model: "claude-sonnet-5-5", stop_reason: "tool_use",
               content: [{type: "tool_use", id: "tu1", name: "SubagentHandback", input: {message: $msg}}],
               usage: {input_tokens: 1, output_tokens: 50, cache_read_input_tokens: 0, cache_creation_input_tokens: 0}}}'
}

# run_stop <session> <agent_id> <agent_type> <transcript> -> record path in $REC
run_stop() {
  jq -c -n --arg s "$1" --arg a "$2" --arg t "$3" --arg p "$4" \
    '{session_id: $s, hook_event_name: "SubagentStop", agent_id: $a, agent_type: $t, agent_transcript_path: $p}' \
    | sh "$HOOK" >/dev/null 2>&1
  REC="$CLAUDE_STATE_DIR/telemetry/sessions/$1/agents/subagent-$2.json"
}
field() { jq -r "$1" "$REC" 2>/dev/null | tr -d '\r'; }

T1="$HARNESS_ROOT/t1.jsonl"; T2="$HARNESS_ROOT/t2.jsonl"; T3="$HARNESS_ROOT/t3.jsonl"; T4="$HARNESS_ROOT/t4.jsonl"

# 1. placeholders (8) then the final line (1,234): the record holds 1,234, output_final true
{
  line 2026-10-24T10:00:00Z msg_A null 8
  line 2026-10-24T10:00:01Z msg_A null 8
  line 2026-10-24T10:00:02Z msg_A end_turn 1234
} > "$T1"
run_stop s1 a1 rust-expert "$T1"
assert_eq "final line wins over placeholders: tokens.output" 1234 "$(field .tokens.output)"
assert_eq "final line present: output_final true" true "$(field .output_final)"

# 2. no final line: maximum output, output_final false
{
  line 2026-10-24T10:00:00Z msg_B null 8
  line 2026-10-24T10:00:01Z msg_B null 300
  line 2026-10-24T10:00:02Z msg_B null 9
} > "$T2"
run_stop s2 a2 rust-expert "$T2"
assert_eq "no final line: maximum output" 300 "$(field .tokens.output)"
assert_eq "no final line: output_final false" false "$(field .output_final)"

# 3. hand-back with CHANGES_REQUIRED, duration from the timestamp span
{
  line 2026-10-24T10:00:00Z msg_C end_turn 100
  handback 2026-10-24T10:01:30Z msg_D "Findings below.
VERDICT: CHANGES_REQUIRED"
} > "$T3"
run_stop s3 a3 peer-review-critic "$T3"
assert_eq "hand-back verdict recorded" CHANGES_REQUIRED "$(field .verdict)"
assert_eq "duration_s is the first-to-last span" 90 "$(field .duration_s)"
assert_eq "duration_s greater than 0" true "$(field '.duration_s > 0')"
assert_eq "tokens sum over messages (100 + 50)" 150 "$(field .tokens.output)"

# 4. reviewer transcript without a hand-back and without a VERDICT line: verdict null
{
  line 2026-10-24T10:00:00Z msg_E end_turn 40 "no verdict here"
} > "$T4"
run_stop s4 a4 peer-review-critic "$T4"
assert_eq "no hand-back: verdict null" null "$(field .verdict)"
assert_eq "no hand-back: record still written with tokens" 40 "$(field .tokens.output)"

printf '\n%s run, %s passed, %s failed\n' "$TESTS_RUN" "$TESTS_PASS" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ]
