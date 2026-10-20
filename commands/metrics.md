---
name: metrics
description: "Report local usage telemetry: sessions, tokens, estimated cost, agent invocations, review outcomes"
---

Framework root: `${CLAUDE_PLUGIN_ROOT}` (when running from a development checkout of the framework itself, this may be empty — then use the current directory if it contains `claude.json`). All framework file paths below are relative to that root.

# /agentic-framework:metrics — Local Usage Telemetry Report

## Purpose

Summarise what the telemetry hooks recorded on this machine: sessions, token use, an estimated cost, agent invocations, and peer-review outcomes. Everything is read from local files; nothing leaves the host.

## Usage

```
/agentic-framework:metrics [last 7 days | last 30 days | all time]
```

Default is `last 7 days`. Sessions are filtered by `started_at`; agent records by their own `started_at`. Any other argument falls back to the default and the report says so.

## Command-line execution
Run short shell commands inline — git/gh calls, jq one-liners, quick checks.
Delegate only the long, output-heavy runs this workflow needs — the validator
battery, full test and build runs, log grinding — to **bash-expert**
(POSIX/Git Bash) or **powershell-expert** (PowerShell/Windows), where hundreds of
output lines compress to a verdict. Executors return the exact command, its integer
exit code, and a distilled result (verbatim fenced where it will be used literally).
Read files with Read/Grep/Glob directly — never via shell.

## What This Command Does

The aggregation below is the one place where shell is the right tool: it folds many small JSON files into a few numbers. Run the pipelines inline (`jq` is a framework dependency; they work in Git Bash on Windows and in any POSIX shell). Each prints one JSON object; render it as the Markdown tables in step 5.

### 1. Resolve the period and the data roots

```bash
S="${CLAUDE_STATE_DIR:-$HOME/.claude/.state}"
T="$S/telemetry/sessions"
PERIOD="last 7 days"   # or "last 30 days" / "all time", from the user's argument
case "$PERIOD" in
  "all time")     CUT="" ;;
  "last 30 days") CUT=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-30d +%Y-%m-%dT%H:%M:%SZ) ;;
  *)              CUT=$(date -u -d '7 days ago'  +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d  +%Y-%m-%dT%H:%M:%SZ) ;;
esac
# GNU date (Git Bash, Linux) takes -d; the || arm covers BSD date on macOS.
[ -d "$T" ] && ls "$T" | head -n1 | grep -q . || echo "NO_TELEMETRY"
```

`CUT` is an ISO-8601 UTC string, so lexicographic comparison with `started_at` is a correct time comparison. An empty `CUT` keeps everything. If `NO_TELEMETRY` prints, skip to "Empty state" (still try the marker fallback in step 4).

### Data sources

| Source | Path under `$S` | Fields used |
|--------|-----------------|-------------|
| Session file | `telemetry/sessions/<session>.json` | `session_id`, `started_at`, `duration_s?`, `model?`, `tokens{input,output,cache_read,cache_creation}` |
| Agent record | `telemetry/sessions/<session>/agents/<tool_use_id>.json` | `agent_name`, `model_tier`, `background`, `started_at`, `duration_s?`, `status?`, `verdict?` |
| Subagent record | `telemetry/sessions/<session>/agents/subagent-<agent_id>.json` | `agent_name`, `model_actual?`, `tokens?`, `verdict?` (not counted as invocations; the pre/post record is) |
| Review marker (fallback) | `peer-review/<session-id>` | line 1 = ISO timestamp; optional `verdict=APPROVED\|CHANGES_REQUIRED`; optional `head=<sha>` |
| Marker sources (fallback) | `peer-review/<session-id>.verdict-sources` | one line per recorded reviewer instance |

### 2. Session summary

```bash
{ find "$T" -maxdepth 1 -name '*.json' -exec cat {} +
  find "$T" -mindepth 3 -maxdepth 3 -name 'subagent-*.json' -exec cat {} + 2>/dev/null; } | jq -s --arg cutoff "$CUT" '
  def R: {"fable-5-1":[10,50,0.25],"fable-5":[10,50,null],
          "opus-5-5":[4,20,0.20],"opus-5":[5,25,null],"opus-4-8":[5,25,null],
          "opus-4-7":[5,25,null],"opus-4-6":[5,25,null],
          "sonnet-5-5":[2,10,0.20],"sonnet-5":[2,10,0.20],"sonnet-4-6":[3,15,null],
          "haiku-5-5":[0.10,0.50,null],"haiku-4-5":[1,5,null]};
  def rate($m): ($m // "" | sub("^claude-";"")) as $id
    | [R | to_entries[] | select(. as $e | $id | startswith($e.key))]
    | max_by(.key | length) | .value;
  def cost($t; $r): ($t.input*$r[0] + $t.output*$r[1]
    + $t.cache_read*($r[2] // $r[0]*0.1) + $t.cache_creation*$r[0]*1.25) / 1e6;
  def tok($x): {input: ($x.input // 0), output: ($x.output // 0),
                cache_read: ($x.cache_read // 0), cache_creation: ($x.cache_creation // 0)};
  [.[] | select(.session_id and ((.started_at // "") >= $cutoff))] as $s
  | [.[] | select(.agent_id and .tokens and ((.ended_at // "") >= $cutoff))] as $sub
  | ([$s[] | {m: (.model // "unknown"), t: tok(.tokens), r: rate(.model), kind: "session"}]
     + [$sub[] | {m: (.model_actual // "unknown"), t: tok(.tokens), r: rate(.model_actual), kind: "subagent"}]) as $p
  | {sessions: ($s | length),
     subagent_runs: ($sub | length),
     total_duration_s: ([$s[].duration_s // 0] | add // 0),
     avg_duration_s: ([$s[] | select(.duration_s != null) | .duration_s] | if length > 0 then add / length else null end),
     tokens: {input: ([$p[].t.input] | add // 0),
              output: ([$p[].t.output] | add // 0),
              cache_read: ([$p[].t.cache_read] | add // 0),
              cache_creation: ([$p[].t.cache_creation] | add // 0)},
     subagent_tokens: ([$p[] | select(.kind == "subagent") | .t.input + .t.output + .t.cache_read + .t.cache_creation] | add // 0),
     est_cost_usd: ([$p[] | select(.r) | cost(.t; .r)] | add // 0),
     subagent_cost_usd: ([$p[] | select(.r and .kind == "subagent") | cost(.t; .r)] | add // 0),
     unpriced: ([$p[] | select(.r == null)] | group_by(.m)
       | map({model: .[0].m, records: length,
              tokens: (map(.t.input + .t.output + .t.cache_read + .t.cache_creation) | add)}))}'
```

Session files carry the main-thread transcript's tokens (priced by `model`); `subagent-*.json` records carry each sub-agent's own transcript tokens (priced by `model_actual`). Both are summed into `tokens` and `est_cost_usd`; `subagent_tokens` and `subagent_cost_usd` show the sub-agent share. The rates table is embedded in `def R` (per million tokens: `[input, output, cache_read or null]`). A model that matches no key is **unpriced**: it is listed under `unpriced` with its record count and token total and excluded from the cost, never counted as zero. Report the cost as "priced records only" whenever `unpriced` is non-empty.

### Rates table (snapshot 2026-10-06, USD per million tokens)

| Model id (longest prefix match) | Input | Output | Cache read |
|---------------------------------|-------|--------|------------|
| fable-5-1 | 10 | 50 | 0.25 |
| fable-5 | 10 | 50 | 1.00 (10% of input) |
| opus-5-5 | 4 | 20 | 0.20 |
| opus-5, opus-4-8, opus-4-7, opus-4-6 | 5 | 25 | 0.50 (10% of input) |
| sonnet-5-5, sonnet-5 | 2 | 10 | 0.20 |
| sonnet-4-6 | 3 | 15 | 0.30 (10% of input) |
| haiku-5-5 | 0.10 | 0.50 | 0.01 (10% of input) |
| haiku-4-5 | 1 | 5 | 0.10 (10% of input) |

Cache creation is billed at 1.25 x input. The model id has its leading `claude-` removed and is matched by the longest listed prefix, so `claude-opus-5-5-<date>` prices as `opus-5-5`, not `opus-5`. The snapshot is static and editable (edit `def R` and this table together). **The cost is an estimate** from this table, not a bill.

### 3. Agent usage

```bash
find "$T" -mindepth 3 -maxdepth 3 -path '*/agents/*.json' -exec cat {} + | jq -s --arg cutoff "$CUT" '
  [.[] | select(.tool_use_id and ((.started_at // .ended_at // "") >= $cutoff))] as $a
  | {invocations: ($a | length),
     pending: ([$a[] | select(.status == null)] | length),
     tiers: ($a | group_by(.model_tier // "unknown")
       | map({tier: (.[0].model_tier // "unknown"), n: length}) | sort_by(-.n)),
     agents: ($a | group_by(.agent_name // "general-purpose")
       | map(([.[] | select(.status == "completed" and .duration_s != null) | .duration_s]) as $d
         | {agent: (.[0].agent_name // "general-purpose"), n: length,
            background: ([.[] | select(.background)] | length),
            completed: ($d | length),
            avg_s: (if ($d | length) > 0 then ($d | add / length) else null end)})
       | sort_by(-.n) | .[:10])}'
```

Only records with a `tool_use_id` count as invocations; a record created by PostToolUse alone (hook installed mid-session) has no `started_at` and is placed by its `ended_at`; a call with no `subagent_type` is reported as `general-purpose`. `pending` counts records with no `status`: launches that never completed because the model guard denied them, the user rejected them, or they are still running (the PreToolUse hook cannot see a later denial or the guard's model rewrite, so such a record may also carry a null tier). Duration averages use completed records only; an agent with `completed: 0` shows `-`. A non-zero `background` count is flagged in the table, because background launches may never complete.

### 4. Review metrics

Primary source is the agent records. Reviewers are `peer-review-critic` and `spec-compliance-reviewer`; a session's outcome is the verdict of its last reviewer record that carries one.

```bash
find "$T" -mindepth 3 -maxdepth 3 -path '*/agents/*.json' -exec jq -c '. + {file: input_filename}' {} + \
 | jq -s --arg cutoff "$CUT" '
  [.[] | select(.tool_use_id
        and (.agent_name == "peer-review-critic" or .agent_name == "spec-compliance-reviewer")
        and ((.started_at // .ended_at // "") >= $cutoff))
      | . + {session: (.file | split("/") | .[-3])}] as $r
  | ($r | group_by(.session)
      | map({session: .[0].session, cycles: length,
             last: ([.[] | select(.verdict)] | sort_by(.started_at) | last | .verdict)})) as $s
  | {source: "agent-records", sessions: ($s | length),
     approved: ([$s[] | select(.last == "APPROVED")] | length),
     approval_rate: (if ($s | length) > 0
       then ([$s[] | select(.last == "APPROVED")] | length) / ($s | length) else null end),
     avg_cycles: (if ($s | length) > 0 then ([$s[].cycles] | add) / ($s | length) else null end)}'
```

If this reports `sessions: 0` (no agent records, for example telemetry not installed yet), run the marker fallback. A session counts when line 1 of its marker is a timestamp inside the period; cycles are the line count of `<session-id>.verdict-sources`, and a marker with no sources file counts as 1 cycle:

```bash
for m in "$S"/peer-review/*; do
  [ -f "$m" ] || continue
  case "$m" in *.*) continue ;; esac   # session ids carry no dot; skips .verdict-sources, .verdict-suppressed, .fired
  ts=$(head -n1 "$m")
  case "$ts" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) ;; *) continue ;; esac
  v=$(sed -n 's/^verdict=//p' "$m" | tail -n1)
  n=0; [ -f "$m.verdict-sources" ] && n=$(grep -c . "$m.verdict-sources")
  printf '%s\t%s\t%s\n' "$ts" "$v" "$n"
done | jq -R -s --arg cutoff "$CUT" '
  [split("\n")[] | select(length > 0) | split("\t")
   | {ts: .[0], v: .[1], n: ((.[2] | tonumber) | if . < 1 then 1 else . end)}
   | select(.ts >= $cutoff)] as $m
  | {source: "markers", sessions: ($m | length),
     approved: ([$m[] | select(.v == "APPROVED")] | length),
     approval_rate: (if ($m | length) > 0
       then ([$m[] | select(.v == "APPROVED")] | length) / ($m | length) else null end),
     avg_cycles: (if ($m | length) > 0 then ([$m[].n] | add) / ($m | length) else null end)}'
```

Markers are written by the review-gate recorder and predate the telemetry hooks, so the fallback also covers sessions from before 5.0.0. State which source produced the numbers.

### 5. Render the report

Print the period and the date range first, then three Markdown tables from the JSON above. Round durations to whole seconds (or `1h 02m` above an hour), tokens with thousands separators, cost to 2 decimals, rates to a whole percent.

```
# Metrics — last 7 days (since 2026-10-13T14:02:11Z)

## Session summary
| Metric                    | Value               |
|---------------------------|---------------------|
| Sessions / sub-agent runs | 12 / 49             |
| Total / average duration  | 4h 10m / 21m        |
| Input tokens              | 1,204,331           |
| Output tokens             | 310,022             |
| Cache read tokens         | 18,440,900          |
| Cache creation tokens     | 902,114             |
| Sub-agent share of tokens | 6,120,400           |
| Estimated cost (USD)      | ~$23.41 (priced; ~$9.80 from sub-agents) |
| Unpriced                  | 1 record, mystery-model, 52,310 tokens |

## Agent usage  (49 invocations, 2 pending)
| Agent               | Invocations | Avg duration | Notes            |
|---------------------|-------------|--------------|------------------|
| peer-review-critic  | 6           | 142 s        |                  |
| rust-expert         | 4           | 96 s         | 1 background     |
Tier distribution: opus 8, sonnet 31, haiku 9, unknown 1

## Review metrics  (source: agent-records)
| Metric                 | Value |
|------------------------|-------|
| Sessions with a review | 5     |
| Approval rate          | 80%   |
| Average review cycles  | 1.6   |
```

Cost is always printed with a leading `~` and the footer line `Cost is an estimate from a static rates table (snapshot 2026-10-06), not a bill.`

### Empty state

If no session files exist for the period, say so plainly instead of printing zero tables: telemetry is collected by hooks that arrive with 5.0.0 and records only start accumulating after they first fire. After updating the plugin, restart Claude Code so the new hooks register; sessions started before the restart are not recorded. If the period is `last 7 days` and older files exist, suggest `all time`. Review metrics may still be available from the marker fallback.

## Notes

- Session and agent files that are malformed JSON make the pipeline fail; name the offending file (`jq empty <file>`) and report it rather than guessing.
- Telemetry older than 30 days is pruned by the session-start hook, so `all time` means "all retained".
- Session token totals come from the main-thread transcript (as of the session's last Stop event); sub-agent tokens come from the SubagentStop records (`subagent-*.json`) and are included in the totals and the cost. A background agent that never reaches SubagentStop contributes no tokens.

## Integration

Works with:
- `/agentic-framework:validate-hooks` — Confirms the telemetry hooks are registered
- `/agentic-framework:agent-status` — Agent roster and tier configuration
- `/agentic-framework:quality-report` — Configuration-side quality view; metrics is the usage-side view
