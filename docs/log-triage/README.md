# /log-triage — usage, defaults, exit codes, configuration

`/agentic-framework:log-triage` analyses large log files locally and deterministically: it detects the input
format, parses events (multiline exceptions included), groups recurring issues by a stable fingerprint,
assesses severity and impact, optionally attributes issues to Git repositories and suggests fixes, and writes
machine-readable (JSON, SARIF, NDJSON, CSV) and human-readable (HTML, Markdown) reports. The engine is a
stdlib-only Python 3.8+ program shipped with the plugin at `scripts/log-triage/`; the slash command
(`commands/log-triage.md`) runs it and then spends model reasoning only on the compact investigation queue.

Related documents: [format support matrix](support-matrix.md) · [canonical model, grouping and
assessment](canonical-model.md) · [JSON schema](schema/analysis.schema.json) · [SARIF mapping and exporter
behaviour](sarif-mapping.md) · [benchmark](benchmark.md) · [implementation summary and limitations](implementation-summary.md)
· sample outputs under [samples/](samples/).

## Command line

```
/agentic-framework:log-triage <log-path|glob> [--repo <git-root> | --repos-dir <directory>]
    [--format auto|json|sarif|html|markdown|csv|ndjson]... [--out <dir>] [--since <ts>]
    [--min-severity info|low|medium|high|critical] [--input-format <name>] [options]
```

The slash command passes its arguments verbatim to the engine:

```
python3 "${CLAUDE_PLUGIN_ROOT:-.}/scripts/log-triage" <log-path|glob> [options]
```

(`python` on Windows when `python3` is not on PATH. Requires Python 3.8 or newer: the code is checked for 3.8 syntax, and
the test suite is exercised on CPython 3.10–3.13.)

### Inputs

| Argument | Behaviour |
|---|---|
| `<log-path>` (file) | processed as is; compression and format are detected from content, never from the extension alone |
| `<log-path>` (directory) | walked recursively; regular files only; directory symlinks are **not** followed unless `--follow-symlinks`; hidden files are included |
| `<glob>` | expanded with `*`, `?`, `[...]` and `**` (recursive); quote the argument so the shell does not expand it first; matching directories are walked |
| `"path with spaces"` | supported (quote the argument) |
| `--input-list <file>` | one path or glob per line (`#` comments), in addition to positional inputs — handy when the model builds the list |

Expansion, ordering and deduplication:

* All matches are deduplicated by resolved real path (symlinked or repeated files are processed once; duplicates are listed in `inputs.duplicates`).
* Files are processed in **lexicographic order of their resolved absolute path**, independent of argument order, so results are deterministic.
* Obvious non-log media (images, archives other than gzip, executables, office documents, databases; see `EXCLUDED_EXTENSIONS` in `log_triage/inputs.py`) are excluded before parsing and listed in `inputs.excluded`.
* An argument that matches nothing is an **unmatched input**: reported in `inputs.unmatched`, a `unmatched-input` diagnostic, and the run is *partial* (exit 3). When *no* argument matches anything the invocation is invalid (exit 2).
* More than `max_files` (default 10,000) inputs: the surplus is excluded with a `limit-reached` diagnostic (partial).
* Every input ends in exactly one state: `processed`, `partial` (truncated gzip, decompression limit, corrupt, interrupted, changed during analysis), `excluded` (binary/unsupported compression/extension/limit) or `failed` (unreadable, parser error). The counts are in `inputs.summary`.
* If an input's size or modification time changes while it is being analysed, an `input-changed` diagnostic is recorded, the input is marked `partial`, and results reflect the bytes actually read.

### Options

| Option | Default | Meaning |
|---|---|---|
| `--repo <git-root>` | — | investigate one Git repository or worktree (`.git` directory or file) |
| `--repos-dir <directory>` | — | discover repositories beneath a directory (nested organisational folders included); mutually exclusive with `--repo` |
| `--format <f>` (repeatable, or comma-separated) | `auto` | report formats; `auto` = `json,sarif,html,markdown`. `auto` cannot be combined with explicit formats; unknown values are rejected (exit 2). `md` is accepted as an alias of `markdown` |
| `--out <dir>` | `./log-triage-out` | output directory (created if missing). Files are written atomically (`<name>.tmp` then rename) and **overwrite** files of the same name; other files in the directory are left alone |
| `--since <ts>` | — | keep events with a timestamp **at or after** the ISO 8601 value (`2026-09-13T12:00:00Z`, `2026-09-13T14:00:00+02:00`, `2026-09-13`, `2026-09-13 12:00:00`). A value without zone is interpreted with `--assume-tz` |
| `--min-severity <level>` | `info` | report only groups whose *assessed* severity is at or above the level (`info` < `low` < `medium` < `high` < `critical`); applied after classification; filtered counts are disclosed in `filtering` |
| `--input-format <name>` | detected | force a parser (`--list-formats`): a parser name (`ndjson`, `json`, `otlp-json`, `ecs-json`, `docker-json`, `journal-json`, `cloudwatch-json`, `azure-json`, `gcp-json`, `loki-json`, `apple-ips`, `iis-w3c`, `csv`, `tsv`, `cri`, `syslog`, `access-log`, `apple-crash`, `logfmt`, `text`, `xml`, `winevt-xml`) or `text:<layout>` for a specific text layout |
| `--fallback-format <name>` | `text` | parser used when detection confidence is below 0.3 |
| `--assume-tz <tz>` | `UTC` | zone for timestamps that carry none (`UTC`, `local`, `+HH:MM`) — applies to log timestamps and to a naive `--since` |
| `--keep-untimed` | off | with `--since`, keep events that have no usable timestamp instead of excluding them |
| `--no-redact` | redaction on | disable secret redaction (not recommended; see Redaction) |
| `--redact-ips` | off | pseudonymize IPv4 addresses as well |
| `--redaction-salt <salt>` | random per run | stable pseudonyms across runs |
| `--temp-dir <dir>` | system temp | where the private (`0700`) temporary directory for spill files is created |
| `--keep-temp` | off | keep the temporary directory (its path is then recorded in `aggregation.temp_dir`) |
| `--fail-on-severity <level>` | — | exit 4 when any *reported* group is at or above the level (CI policy) |
| `--follow-symlinks` | off | follow directory symlinks during input and repository traversal |
| `--include-nested-repos` | off | with `--repos-dir`, keep searching inside discovered repositories (submodules, vendored repositories) |
| `--config <file.json>` | — | JSON object of limit overrides (same keys as `--limit`) |
| `--limit NAME=VALUE` (repeatable) | — | override one limit; unknown names are rejected (exit 2) |
| `--max-examples N`, `--max-report-groups N`, `--max-groups-in-memory N`, `--max-record-bytes N`, `--max-line-bytes N` | see limits | first-class shortcuts for the most common limits |
| `--render <analysis.json>` | — | regenerate reports from an existing analysis (no log parsing); default formats then `html,markdown` |
| `--suggestions <file.json>` | — | with `--render`: merge model-refined root causes and suggestions (see Model-assisted refinement) |
| `--now <ts>` | wall clock | reference time for missing-year inference and `generated_at` (determinism in tests) |
| `--quiet` / `--verbose` | — | no progress on stderr / parser tracebacks on stderr |
| `--version`, `--list-formats`, `--list-limits`, `--support-matrix` | — | print and exit |

### Output files (deterministic names)

| Format | File(s) | Content |
|---|---|---|
| `json` | `analysis.json` | the authoritative document ([schema](schema/analysis.schema.json)); every reported group |
| `sarif` | `analysis.sarif` | SARIF 2.1.0 ([mapping](sarif-mapping.md)) |
| `html` | `report.html` | offline self-contained report (bounded detail, see below) |
| `markdown` | `report.md` | portable report for issues / PRs (bounded detail) |
| `csv` | `groups.csv` | one row per reported group, UTF-8 with BOM, CRLF, formula-injection safe |
| `ndjson` | `groups.ndjson` + `groups.meta.json` | one group per line + companion metadata (everything except the groups) |

All exporters read the same finalized group stream, so ids, counts, severities, attribution and suggestions are identical
across files. Machine-readable exports contain every reported group up to `max_output_groups` (default 100,000, canonical
order, omission disclosed in `filtering.groups_omitted_by_output_limit`); HTML/Markdown detail the first `max_report_groups`
(default 500) and say so.

### Exit codes

| Code | Meaning | Outputs |
|---|---|---|
| `0` | analysis complete (findings or not) | written |
| `1` | processing failure: no input could be processed (every matched file was excluded, unreadable or unparseable), or no output file could be written | written when possible (`status.completion = "failed"` with the reason) |
| `2` | invalid invocation: bad option/format/limit, `auto` mixed with explicit formats, both repository options, no input, nothing matched | none |
| `3` | partial analysis: outputs written but something is incomplete — an input failed/was excluded as unsupported or changed during analysis, an unmatched argument, a limit was hit, repository discovery was incomplete, temporary storage ran out, or the run was interrupted (Ctrl-C) | written; `status.completion = "partial"` and `status.reasons` list why |
| `4` | `--fail-on-severity` threshold met by a reported group (takes precedence over 3) | written |

The JSON `status.exit_code` mirrors the process exit code, with one exception: when writing a *later* output file fails
after `analysis.json` was already written, the process exits 3 (or 1) while the JSON still carries the code computed before
the export loop; stderr and the process exit code are authoritative in that case.

### Examples

```
# default reports for one file
/agentic-framework:log-triage /var/log/orders/app.log

# a directory plus a glob, quoted path with spaces, JSON + Markdown only, last 24h, warnings and up
/agentic-framework:log-triage "/srv/logs/prod releases" '/srv/logs/*.log.gz' --format json --format markdown --since 2026-09-12T00:00:00Z --min-severity low

# investigate one repository (worktrees allowed)
/agentic-framework:log-triage build/orders-*.ndjson --repo ~/src/orders --out triage/orders

# many services: discover repositories under an organisation folder
/agentic-framework:log-triage exports/cloudwatch.json --repos-dir ~/src/acme --format auto

# CI gate: fail the job when a high or critical group is reported
/agentic-framework:log-triage ci-logs/ --format sarif --format json --fail-on-severity high

# large input, explicit resource limits and a private temp location
/agentic-framework:log-triage /data/2TB-export.log.gz --max-groups-in-memory 50000 --temp-dir /scratch --format json --format ndjson

# force a layout when detection is wrong
/agentic-framework:log-triage weird.log --input-format text:jvm-classic

# re-render reports after the model refined suggestions
/agentic-framework:log-triage --render log-triage-out/analysis.json --suggestions log-triage-out/model-suggestions.json --out log-triage-out
```

## Time handling

* Timestamps with an explicit offset are exact. Naive timestamps (most text layouts) use `--assume-tz` (default UTC) and carry the `naive` flag in examples.
* Layouts without a year (syslog RFC 3164, glog `I0913 ...`) get the most recent year for which the date is not in the future relative to `--now`
  (`year_inferred` flag). Layouts without a date (Logback/log4j2 default `HH:mm:ss.SSS`, Elixir default, Zerolog console, Serilog console `[12:00:00 INF]`)
  produce **no** timestamp (`time_only_timestamp` diagnostic); the event is still counted.
* Events are never re-ordered: first/last seen are min/max; the timeline buckets by timestamp; out-of-order input is fine.
* Envelope timestamps (Docker, CRI, CloudWatch, GCP, Loki, journal) are used when the inner line has none; otherwise the envelope time is recorded as `ts_observed`.
* `--since`: events before the instant are dropped and counted (`coverage.events_filtered_by_since`); events without a timestamp are dropped and
  counted separately (`events_untimed_excluded_by_since`) unless `--keep-untimed`. Multiline continuation lines inherit their record's timestamp.

## Configuration (limits)

Precedence: built-in default < `--config file.json` < `--limit NAME=VALUE` / shortcut flags. `--list-limits` prints the effective defaults.
All values are integers (bytes unless the name says otherwise).

| Limit | Default | Purpose |
|---|---|---|
| `max_line_bytes` | 1,048,576 | physical line cap; longer lines are truncated (event still counted; `oversized-line` diagnostic; discarded bytes counted) |
| `max_record_bytes` | 1,048,576 | retained text per logical (multiline) record and per JSON item (oversized JSON items are skipped with `oversized-record`) |
| `max_multiline_lines` | 500 | continuation lines folded into one event; the rest are dropped and counted (`multiline-limit`) |
| `max_decompressed_bytes` | 17,179,869,184 | per gzip input; beyond it the input is `partial` |
| `max_compression_ratio` | 2000 | decompressed/compressed guard against decompression bombs |
| `max_files` | 10,000 | inputs after expansion |
| `detect_sample_bytes` / `detect_sample_lines` | 65,536 / 256 | bounded sample for format and layout detection |
| `read_chunk_bytes` | 1,048,576 | streaming read size (results do not depend on it) |
| `max_message_chars` / `max_exception_chars` | 2,000 / 4,000 | retained message / exception text per event |
| `max_attributes_per_event` / `max_attribute_value_chars` | 64 / 512 | structured attributes kept per event |
| `max_frames` | 50 | stack frames kept per exception |
| `max_groups_in_memory` | 20,000 | groups held in RAM before spilling to the SQLite temp store |
| `max_examples_per_group` | 3 | representative examples retained per group (plus the last-seen example) |
| `max_correlation_ids_per_group` / `max_levels_per_group` / `max_services_per_group` / `max_inputs_per_group` | 5 / 8 / 10 / 20 | bounded per-group sets (truncation is flagged) |
| `fingerprint_cache_size` | 20,000 | exact-message memo speeding up repetitive logs |
| `max_timeline_buckets` | 200 | timeline buckets (coarsened 1m → 5m → 15m → 1h → 6h → 1d → 7d → 30d) |
| `max_diagnostics` | 1,000 | retained diagnostic records (per-code counts stay exact) |
| `max_report_groups` / `max_findings_rows` | 500 / 500 | groups detailed / listed in HTML and Markdown |
| `max_output_groups` | 100,000 | groups written to JSON/SARIF/CSV/NDJSON (canonical order); `filtering.groups_written` / `groups_omitted_by_output_limit` disclose the cut |
| `max_report_example_chars` | 1,200 | example message characters shown in reports |
| `max_repos` / `max_repo_depth` / `max_repo_dirs_visited` | 200 / 6 / 50,000 | repository discovery bounds |
| `max_repo_files_indexed` / `max_repo_file_bytes` | 50,000 / 524,288 | inventory size per repository / largest source file read |
| `max_attributed_groups` / `max_investigations` | 200 / 50 | top groups receiving attribution / deterministic investigation |
| `max_snippet_lines` | 12 | source snippet lines around a verified reference |
| `max_literal_search_files` / `max_literal_search_hits` | 5,000 / 5 | message-literal search bounds per group |
| `max_model_queue_groups` / `max_model_context_chars` | 20 / 2,000 | investigation queue size and per-group context handed to the model |

## Large files, memory and temporary storage

* Inputs are streamed in `read_chunk_bytes` chunks; gzip is decompressed as a stream; no input is ever loaded whole, and raw files are never sent to the model.
* Memory is bounded by the limits above: per-line/record caps, the multiline buffer, bounded attributes/frames/examples, the in-memory group table
  (`max_groups_in_memory`) and the fingerprint cache. When the group table exceeds its bound, all groups are merged into a SQLite table in the temporary
  directory (exact counts are preserved by the merge) and RAM is released; final ordering and export stream from that table.
* Temporary storage: a private directory (`0700`) under `--temp-dir`; the spill file is roughly 0.5–2.5 KiB per distinct group (examples included).
  `aggregation.temp_bytes_peak` reports the peak. The directory is removed at exit (also after Ctrl-C) unless `--keep-temp`.
* Counts are exact for every parsed event included by the time filter; nothing is sampled. Oversized lines/records are truncated or skipped **and counted**.
* Interruption (Ctrl-C) finishes with the events seen so far: outputs are written, `status.interrupted = true`, unprocessed inputs are `pending`, exit 3.
  Temporary-disk exhaustion is reported (`disk-full` diagnostic, exit 3); output-disk exhaustion aborts remaining formats (exit 1 when nothing could be written).
* Measured figures (256/512 MiB inputs, fixed limits): see [benchmark.md](benchmark.md).

## Redaction

Applied before templating, before examples are retained, before any report is written and before anything is handed to the model.
Patterns: private key blocks, `Authorization`/`Bearer` headers and tokens, JWTs, AWS/GitHub/Slack/Google/Stripe/SendGrid/npm/PyPI/OpenAI-style keys,
Azure `AccountKey`, URL credentials (`scheme://user:pass@` → `scheme://<redacted:credentials>@`), `password=`/`secret=`/`token=`/`api_key=`… key-value
pairs (also when the key is an extracted attribute name), credit-card numbers passing Luhn, and e-mail addresses (pseudonymized as `<email:xxxxxx>` with a
per-run HMAC key, or a stable one with `--redaction-salt`). IPv4 addresses are kept unless `--redact-ips`. Counts per kind are in `coverage.redaction`.
Effect on grouping: redacted values become placeholders, so events that differ only by a secret fall into the same group (desired). Limitations:
pattern-based; secrets in unusual formats, split across lines, or in free prose are not detected — treat reports as sensitive when logs are.

## Repositories, attribution and fix suggestions

See [canonical-model.md](canonical-model.md#repository-attribution) for the evidence weights. In short: `--repo` validates a repository or worktree;
`--repos-dir` discovers repositories with bounded traversal (depth, directories, count), skipping dependency/build directories and never following
directory symlinks by default; nested repositories are not searched unless `--include-nested-repos`. Each repository's HEAD, branch and working-tree
state (via `git status`, when git is available) are recorded because the checkout may not be the version that produced the logs.
A discovered repository's own `.git/config` is treated as untrusted: every git invocation disables `core.fsmonitor` and
`core.hooksPath` so that repository configuration cannot execute a program during discovery, and the engine never writes
into a repository. Attribution uses
path, namespace/symbol and service-name evidence; a basename match alone never resolves. Deterministic investigation verifies frame references
(file exists, line exists, symbol nearby) and searches message literals; suggestions are `source_backed` only when a reference was verified,
otherwise `generic`. No source file is ever modified.

## Model-assisted refinement (what the slash command does after the engine)

`analysis.json` contains `investigation_queue`: up to `max_model_queue_groups` compact entries (template, exception chain, top frames, candidate
repositories, verified references with bounded snippets, the deterministic suggestion and two guiding questions). The command reads only that queue
and the referenced source regions, writes `model-suggestions.json` and re-renders:

```json
{
  "schema_version": "1",
  "groups": {
    "LT-3852f6e44e77": {
      "root_cause": {"observed": ["..."], "hypotheses": [{"hypothesis": "...", "evidence": ["..."], "confidence": 0.7}], "uncertainty": ["..."], "alternatives": ["..."]},
      "suggestions": [{"summary": "...", "rationale": "...", "kind": "source_backed", "confidence": 0.7,
                       "suggested_changes": ["..."], "references": [{"repo": "orders", "path": "src/X.cs", "line": 42, "verified_by_reading": true}],
                       "regression_tests": ["..."], "verification_steps": ["..."], "alternatives": ["..."]}],
      "notes": "free text"
    }
  }
}
```

Merged suggestions are marked `origin: "model"`; `kind: "source_backed"` is only kept when a cited reference was tool-verified or the model flagged it
`verified_by_reading` after actually reading that file region; otherwise it becomes `generic`. Groups the model did not reach keep their deterministic
results and show `model_refinement: "not_investigated_by_model"`. Unknown group ids are reported in `status.model_refinement.unknown_ids`.

## Security posture

Log content is untrusted data: it is parsed, escaped and rendered, never executed or interpreted as instructions. HTML output escapes every log-derived
string and ships a Content-Security-Policy that blocks remote resources; Markdown output neutralises structural characters; CSV output prefixes
formula-looking cells with `'`. XML is parsed with entity expansion disabled and any entity declaration rejects the input. Original inputs are opened
read-only and never modified. No network access is performed by the engine.
