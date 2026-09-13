# /log-triage — SARIF mapping and exporter behaviour

All exporters consume the same finalized, canonically ordered group stream (see
[canonical-model.md](canonical-model.md#canonical-ordering)) and the same metadata document, so counts, ids,
severities, attribution and suggestions agree across files. Exporters implement one interface
(`log_triage/exporters/base.py`: `name`, `filenames`, `write(analysis, out_dir) -> [paths]`), write through
`AtomicFile` (temp file + rename, overwriting an existing file of the same name) and never load all groups into
memory; a future exporter (PDF, JUnit XML, …) plugs into `exporters/__init__.py` without touching the engine.

## SARIF 2.1.0 (`analysis.sarif`)

`$schema` = `https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json`,
`version` = `2.1.0`, one `run`.

| SARIF element | Source |
|---|---|
| `tool.driver.name` / `version` / `semanticVersion` / `informationUri` | `log-triage`, engine version, documentation URL |
| `tool.driver.rules[]` — one per reported group | `id` = group id (`LT-…`); `name` = category with dashes; `shortDescription` = template (≤200 chars); `fullDescription` = assessed severity, category, confidence, basis and rationale; `defaultConfiguration.level` = mapped level; `properties.{category, severity, fingerprintVersion, tags[]}` |
| `results[]` — one per reported group, same index as its rule | `ruleId`, `ruleIndex`; `level` (below); `kind` = `informational` for info, `fail` otherwise; `message.text` = `<ExceptionType>: <template> (<count> occurrences, assessed <severity> <category>)`; `occurrenceCount` = exact group count; `rank` = 95/75/50/25/5 |
| `results[].fingerprints` | `logTriage/fingerprint/v1` = full sha256 fingerprint (stable across runs and machines) |
| `results[].partialFingerprints` | `logTriage/template/v1` = first 16 hex chars (for consumers that need a short key) |
| `results[].locations[]` — **log evidence** | one per retained example (≤ `max_examples_per_group` + last seen): `physicalLocation.artifactLocation.uri` = `file://` URI of the input, `index` into `artifacts`; `region.startLine`/`endLine` = physical lines of the record, `region.byteOffset`; `message.text` = example message (redacted, ≤500 chars); `properties.locationKind = "log-evidence"`, `timestamp`, `level` |
| `results[].relatedLocations[]` — **source references** | only when the investigation produced references (≤8): `artifactLocation.uri` = repository-relative path, `uriBaseId` = `REPO_<repo id>`; `region.startLine` = frame line; `message.text` = `verified source reference: …` or `unverified source reference: …`; `properties.locationKind` = `source-verified` / `source-unverified`, `match`, `function`, `repository` |
| `results[].properties` | `severity`, `category`, `confidence`, `basis`, `firstSeen`, `lastSeen`, `untimedCount`, `levels`, `services`, `exceptionChain`, `httpStatus`, `errorCode`, `attribution {status, candidates[≤3]}`, `investigationStatus`, `suggestions[≤3] {kind, summary, confidence}`, `groupingConfidence` |
| `artifacts[]` | one per input file: `location.uri`, `roles: ["analysisTarget"]`, `length`, `properties.{format, detectionConfidence, status, events, encoding, compression}` |
| `originalUriBaseIds` | `REPO_<id>` → repository root `file://` URI with description `name (kind, HEAD sha)` |
| `invocations[0]` | `executionSuccessful` (complete or partial), `exitCode`, `startTimeUtc`, `endTimeUtc`, `toolExecutionNotifications[]` (≤50 diagnostics with `descriptor.id` = diagnostic code and `properties.{input, line, count}`), `properties.{completion, reasons}` |
| `run.properties` | `schemaVersion`, `coverage`, `filtering` (copied from the JSON document) and a note explaining that results are runtime log issue groups |
| `columnKind` | `utf16CodeUnits` |

Level mapping: critical/high → `error`, medium → `warning`, low → `note`, info → `note` with `kind:
informational` (SARIF has no level below `note`; `none` is reserved for suppressed results).

Consumer notes: a `location` points into the **analysed log file**, never into source. Source appears only as
`relatedLocations` and only after the investigation verified the reference in a checkout; a group without verified
references carries no source location at all — nothing is invented for the sake of the schema. Not every SARIF
viewer renders runtime-log results meaningfully (GitHub code scanning, for instance, expects source locations);
the JSON document remains the authoritative form.

## JSON (`analysis.json`)

The authoritative document, validated by `schema/analysis.schema.json`. Top-level order: `schema_version`, `tool`,
`generated_at`, `analysis_started_at`, `duration_seconds`, `status`, `configuration` (effective options and limits),
`inputs` (per-file records, `summary`, `duplicates`, `excluded`, `unmatched`), `coverage` (events parsed / included /
filtered / failed records, redaction counts, time range), `filtering` (severity and output-limit counts),
`diagnostics` (bounded records, exact per-code counts), `timeline`, `repositories` (`discovered`, `skipped`,
`incomplete`, attribution and investigation summaries), `aggregation` (spill statistics), `summary`
(`highest_severity`, `top_findings`, counts by severity/category), `investigation_queue`, and finally `groups[]`,
streamed in canonical order (at most `max_output_groups`). Numbers are exact; `null` means unknown, never zero.

## NDJSON (`groups.ndjson` + `groups.meta.json`)

`groups.ndjson` holds one group object per line in canonical order (same objects as `groups[]`, UTF-8, `\n`
terminated, no envelope). `groups.meta.json` is the JSON document without `groups`, plus an `ndjson` object
(`groups_file`, `groups_written`, `record_kind`), so a consumer can read status, summary, coverage and the
investigation queue without touching the group stream.

## CSV (`groups.csv`)

UTF-8 with BOM (Excel-friendly), CRLF line endings, RFC 4180 quoting, one row per reported group in canonical order.
Columns:

| Column | Content |
|---|---|
| `id`, `severity`, `category`, `confidence`, `basis` | identity and assessment |
| `count`, `first_seen`, `last_seen`, `untimed_count` | occurrence data |
| `level_max`, `services`, `hosts_distinct`, `logger` | producer context (`services` joined with `;`) |
| `exception_type`, `exception_chain`, `http_status`, `http_method`, `error_code` | protected context (`exception_chain` joined with `>`) |
| `template` | message template |
| `attribution_status`, `repositories`, `top_repo_confidence` | attribution (`repositories` joined with `;`) |
| `investigation_status`, `suggestion_kind`, `suggestion_summary` | first suggestion |
| `example_input`, `example_line` | first retained example |
| `fingerprint` | full fingerprint |

Formula-injection protection: any cell whose first character is `=`, `+`, `-`, `@`, tab or carriage return is
prefixed with `'` (so `=HYPERLINK(...)` from a log message cannot execute when the file is opened in a spreadsheet).
Embedded newlines are preserved inside quotes; `NULL`/unknown values are empty cells.

## HTML (`report.html`)

Self-contained (inline CSS and JavaScript, no external resources), offline, with a `Content-Security-Policy` meta tag
(`default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:`). Sections:

1. **Executive summary** — status, counts by severity, top findings, time range, inputs processed.
2. **Prioritized findings** — sortable/filterable table (severity, category, count, first/last seen, services,
   attribution, next action); client-side search, severity/category filters, column sort (`data-col`).
3. **Timeline** — bucketed bars by level class (pure CSS, no canvas).
4. **Issue details** — one expandable section per group (template, exception chain, examples, correlation ids,
   inputs, grouping notes) for the first `max_report_groups` groups.
5. **Root-cause assessment** — observed / inferred / unknown labels, hypotheses with confidence, uncertainty.
6. **Fix plan** — suggestions with kind, references (verified/unverified), regression tests, verification steps.
7. **Coverage and limitations** — inputs table with status/format/confidence/reasons, diagnostics, filters applied,
   omitted groups/rows, redaction counts, repository states.

Every log-derived string passes through HTML escaping (`&`, `<`, `>`, `"`, `'`); no attribute or element is ever
built from log content; example bodies render inside `<pre>`. Accessibility: semantic headings, `<table>` with
`<th scope>`, `<details>/<summary>` for expansion, keyboard-operable controls, `aria-sort` on sorted columns,
sufficient contrast; a print stylesheet expands all details and hides controls. Bounds: `max_report_groups`
detailed groups, `max_findings_rows` rows, `max_report_example_chars` per example; every omission is stated in
section 7 and next to the affected table.

## Markdown (`report.md`)

Sections: 1 Executive summary, 2 Prioritized findings (table), 3 Root-cause assessment, 4 Fix plan, 5 Issue details,
6 Coverage and limitations. Escaping (`md()`): backslash-escapes `\ * _ [ ] < > | ~` and backticks, a leading `#`,
`>`, `+`, `-` or `1.`, so log content cannot create headings, links, images, HTML or list/table structure; templates
in tables are placed in code spans with `|` escaped and backticks replaced; multi-line examples use fences longer
than any backtick run they contain. The same `max_report_groups` / `max_findings_rows` / `max_report_example_chars`
bounds apply and are stated in section 6.

## Consistency contract (tested)

`tests/log-triage/test_exporters.py` checks, on the same run: JSON validates against the schema; SARIF has one rule
per result; ids and counts are identical across JSON, NDJSON, CSV and SARIF; HTML/Markdown mention every group id
they detail and disclose omitted groups/rows; `max_output_groups` produces the same prefix in every machine-readable
file with the omission disclosed; hostile log content (`<script>`, Markdown links, formula prefixes) never becomes
markup or formulas; secrets are absent from every output.
