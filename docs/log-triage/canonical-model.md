# /log-triage — canonical model, normalization, grouping and assessment

This document is the reference for the data produced by the `/agentic-framework:log-triage` engine
(`scripts/log-triage/`). The machine-readable contract is `schema/analysis.schema.json` (`schema_version` `1.0.0`).
Every exporter (JSON, SARIF, NDJSON, CSV, HTML, Markdown) is rendered from the same finalized group stream described
here, so a group has the same id, count, severity, attribution and suggestions in every file.

Versioned identifiers:

| Identifier | Value | Changes when |
|---|---|---|
| `schema_version` | `1.0.0` | the shape of `analysis.json` changes (semver: additive = minor) |
| `fingerprint_version` | `1` | the fingerprint components or the templating rules change in a way that would move events between groups |
| `template_version` | `1` | placeholder rules change (always bumps `fingerprint_version` too) |

## 1. Canonical event

Every parsed record — a text line with its continuation lines, a JSON/NDJSON object, a CSV row, an XML element, a
Kubernetes CRI line reassembled from partial chunks, an envelope item — becomes one canonical event. Events are
transient (they are aggregated into groups immediately); the fields below are what parsers may fill and what
grouping, classification and examples are built from.

| Field | Type | Meaning / normalization |
|---|---|---|
| `ts` | float or null | event time as UTC epoch seconds. Naive timestamps are interpreted in `--assume-tz` (default UTC) |
| `ts_observed` | float or null | envelope/ingestion time (CloudWatch `ingestionTime`, Docker/CRI wrapper time, journal `__REALTIME_TIMESTAMP`) when it differs from `ts` |
| `ts_flags` | tuple of strings | `naive` (no zone in the source), `year_inferred` (syslog/glog without year), `time_only` (no date at all → `ts` is null), `from_envelope` (time taken from the wrapper), `missing`, `unparsed`, `invalid` |
| `level_text` / `level_num` | string / int | the producer's level text and its number on the OTLP scale (below). Unknown texts keep `level_text` with `level_num` null |
| `message` | string | the human message, whitespace-normalized, bounded by `max_message_chars`; for request logs a synthetic `METHOD path -> status` |
| `attrs` | ordered map | structured attributes (JSON fields, logfmt/`key=value` pairs, syslog structured data, access-log fields), bounded by `max_attributes_per_event` / `max_attribute_value_chars`; nested objects are flattened with dots |
| `exceptions` | list of ExceptionInfo | exception chain, **outermost first** (`type`, `message`, `frames[]` with `function`, `file`, `line`, `in_app`), bounded by `max_frames` per exception, `max_exception_chars` of text |
| `service`, `app`, `env`, `host`, `process`, `thread`, `logger` | string or null | identity fields taken from structured keys, layout groups or envelope labels |
| `trace_id`, `span_id`, `request_id`, `correlation_id` | string or null | correlation identifiers (`traceId`, `trace_id`, `dd.trace_id`, `X-Request-ID`, Rails request tags, structured-data ids, …) |
| `http_status`, `http_method`, `http_path` | int / string / string | from access logs, request logs and structured HTTP fields; the path is truncated to 300 chars |
| `error_code` | string or null | protected error/exit codes found in the message (`E1234`, `ORA-00942`, `HRESULT 0x8007…`, `SQLSTATE`, `errno 111`) |
| `category_hint` | string or null | a parser-supplied observed category (sanitizer reports, panics, access-log 5xx, Erlang crash reports) |
| `input_id`, `line`, `line_end`, `byte_offset` | ints | provenance: which input, first and last physical line of the record, byte offset of the first line (uncompressed offsets for gzip) |
| `parser`, `layout`, `confidence` | string, string, float | the parser (`text`, `ndjson`, `syslog`, …), the text layout or JSON dialect that produced the event, and the record-level confidence |
| `truncated` | bool | the record hit `max_line_bytes`, `max_record_bytes` or `max_multiline_lines` |
| `raw_excerpt` | string | bounded raw continuation text kept for examples when no exception was parsed |

### Level scale

Levels are mapped onto the OpenTelemetry severity-number scale so that producers can be compared:

| Number | Class | Producer texts (case-insensitive) |
|---|---|---|
| 1 | trace | `TRACE`, `trce`, `VRB`/`verbose`, syslog debug, Pino 10 |
| 5 | debug | `DEBUG`, `dbug`, `DBG`, `FINE/FINER/FINEST`, Pino 20, Python 10, Monolog 100 |
| 9 | info | `INFO`, `INF`, `Information`, `NOTICE`→10, `Default` (Apple), Pino 30, Monolog 200 |
| 13 | warn | `WARN`, `WARNING`, `WRN`, `Warning` (PHP), Pino 40, Monolog 300 |
| 17 | error | `ERROR`, `ERR`, `fail`, `SEVERE`, `Error`, `EXCEPTION`, PHP `Fatal error`, Pino 50, Monolog 400 |
| 21 | fatal | `FATAL`, `CRITICAL`, `crit`, `CRIT`, `Fault`, `PANIC`→23, `ALERT`→22, `EMERGENCY`→24, Pino 60, Monolog 500–600 |

Syslog priorities, Pino/Bunyan numbers, Python numeric levels, Monolog numbers, Windows Event Log `Level`
(1 critical … 5 verbose) and Azure `SeverityLevel` (0–4) have dedicated converters. Producers whose text is not in
the table keep their text and are treated as *unknown level* by the assessment.

## 2. Normalization rules (message templating, `template_version` 1)

`normalize.template()` turns a message into a template whose instance-specific values are typed placeholders. The
same function is applied to exception messages (bounded to 300 chars for the fingerprint). Rules run in this order;
earlier matches are protected from later ones with sentinels:

| # | Protected / replaced | Placeholder | Note |
|---|---|---|---|
| 0 | existing placeholders `<...>`, redaction pseudonyms `<email:hash>` / `<ip:hash>` | kept; pseudonyms collapse to `<email>` / `<ip>` | redaction runs before templating |
| 1 | HTTP status in context (`status 502`, `HTTP/1.1" 503`), error codes (`ORA-00942`, `E1234`, `WSAE10054`), HRESULTs, `SQLSTATE[...]`, `errno`/`exit code`/`signal` numbers, technical tokens (`utf-8`, `sha256`, `http2`, `x509`, `api/v1`, `arm64`, …) | **kept verbatim** | these change the meaning of a failure and must not be generalized |
| 2 | Kubernetes pod suffixes `name-7d9f8b6c5-x2k9q` | `name-<pod>` | |
| 3 | UUIDs | `<uuid>` | |
| 4 | timestamps (ISO, CLF, syslog, JUL, `HH:MM:SS`) | `<ts>` | |
| 5 | URLs | scheme and host kept, digit/hex/uuid path segments → `<n>`, query string → `?<qs>` | |
| 6 | IPv4 (optionally `:port`) / IPv6 | `<ip>` / `<ip>:<n>` / `<ip6>` | |
| 7 | temp names (`tmpAbc123`) | `<tmp>` | |
| 8 | Windows and Unix paths | path kept; all-digit, hex or uuid segments → `<n>`; digit runs inside segments → `<n>` | `C:\Users\<n>\...` |
| 9 | `0x…` hex, long hex strings (≥8 chars containing letters and digits) | `<hex>` | |
| 10 | long base64/token-like strings (≥24 chars, letters and digits) | `<token>` | |
| 11 | long quoted strings (≥40 chars) | `"<str>"` | |
| 12 | durations (`12ms`, `3.5 s`, `2 hours`) / sizes (`512 MiB`, `4k`) / percentages | `<dur>` / `<size>` / `<pct>` | |
| 13 | identifiers after `-`, `=`, `:`, `#` that contain a digit (`req-11667`, `id=ab12`) | `<id>` | |
| 14 | remaining numbers, digits glued to words (`worker7`, `retry3`) | `<n>` | |
| 15 | whitespace runs | single space | |

Information loss: templates are one-way — the original values only survive in the bounded per-group examples.
Everything that identifies an *instance* (ids, counters, addresses, sizes, durations, timestamps) is removed;
everything that identifies a *kind of failure* (error codes, HTTP statuses in context, exception types, frames,
protected technical tokens) is kept. Two events whose messages differ only in instance values share a template.

## 3. Fingerprint (version 1)

The fingerprint is `sha256` over the following components joined with `\x1f`; the group id is `LT-` plus the first
12 hex characters of the fingerprint:

| Component | Value | Why |
|---|---|---|
| `v1` | fingerprint version | fingerprints from different versions never collide silently |
| `svc=` | lower-cased service | the same error in two services is two operational issues |
| `log=` | logger / category name | separates `Acme.Orders.OrderService` from `Acme.Billing.Worker` |
| `exc=` | exception type chain, outermost first (≤5 types) | preserves `IOException > SocketException` |
| `excmsg=` | templated message of the outermost exception (300 chars) | keeps `Table 'orders' not found` distinct from `Table 'users' not found` while collapsing ids |
| `frames=` | signatures of the first 3 in-app frames (or the first 2 frames when no frame is in-app) of the first exception with frames: `function|file-basename` with numbers normalized | the same exception thrown from two code paths is two groups |
| `msg=` | the message template | |
| `http=` | HTTP status | 502 and 504 from the same handler are different issues |
| `code=` | protected error code | |

Deliberately **not** part of the fingerprint: timestamps, hosts, threads, process ids, input file, line numbers,
correlation ids, non-in-app frame line numbers, attribute values. Those are retained as bounded per-group data.

Stability guarantees: within a `fingerprint_version` the fingerprint of an event depends only on the event's own
content and the rules above — not on other events, input order, chunk size or limits — so ids are stable across
runs and across machines. Any rule change that could move an event to a different group bumps
`fingerprint_version`; consumers that track issues over time must key on `(fingerprint_version, fingerprint)`.
`grouping.confidence` (0.9 for groups keyed by an exception chain, 0.8 for message templates that contain
placeholders, 0.7 for literal templates, reduced when the group's raw messages are heterogeneous, floor 0.3) and
`grouping.notes` state how much evidence the group key carries.

## 4. Group object

`groups[]` in `analysis.json` (one object per line in `groups.ndjson`):

| Field | Content |
|---|---|
| `id`, `fingerprint`, `fingerprint_version`, `template` | identity (see §3) |
| `severity`, `category`, `assessment` | assessed severity/category; `assessment` = `{severity, category, confidence, basis, rationale[], impact_signals[]}` (§5) |
| `count`, `first_seen`, `last_seen`, `untimed_count` | exact occurrence count; ISO UTC min/max of timed occurrences; occurrences without timestamp |
| `levels`, `level_max` | producer level texts seen with their counts (`{LEVEL: count}`, bounded by `max_levels_per_group`; overflow is folded into `_other`) and the highest level number |
| `services`, `hosts` | bounded distinct sets (`truncated` flag when the bound was hit; `hosts.distinct` is an exact count) |
| `logger`, `parser`, `layouts` | provenance |
| `exception` | `{type, message_template, chain[], frames[]}` — the outermost type, its message template, the type chain (≤8) and the bounded in-app/first frames collected across the chain |
| `http` (`status`, `method`, `path_template`), `error_code` | protected context |
| `examples[]` | up to `max_examples_per_group` first occurrences plus the last-seen one: `{input, input_id, line, line_end, byte_offset, timestamp, level, message, exception_text, body (raw excerpt when no exception), is_last_seen}` — redacted, bounded by `max_report_example_chars` in reports |
| `correlation` | bounded `trace_ids[]`, `request_ids[]` (`truncated` flag) |
| `inputs[]`, `inputs_truncated` | input files the group occurred in (bounded by `max_inputs_per_group`) |
| `grouping` | `confidence`, `notes[]`, `key_components[]` (the fingerprint parts, for auditing) |
| `attribution` | `{status, candidates[]}` or `{status: "not_attempted"}` (§7) |
| `investigation` | `{status, root_cause, suggestions[], source_references[], model_refinement}` (§8) |

### Canonical ordering

Groups are ordered by assessed severity (critical first), then occurrence count (descending), then `first_seen`
(ascending, untimed last), then fingerprint. The order is total and deterministic; every exporter uses it. The
`max_output_groups` limit (default 100,000) cuts this ordered stream for the machine-readable exports and the
omission is disclosed in `filtering.groups_omitted_by_output_limit`.

## 5. Assessment: categories, severity, basis and confidence

### Categories

| Category | Observed evidence (examples) |
|---|---|
| `availability` | HTTP 502/503/5xx from a server, `service unavailable`, health-check failures, upstream down |
| `application_crash` | panics, unhandled exceptions, segfaults/sanitizer reports, Erlang crash reports, `Aborted (core dumped)` |
| `dependency_failure` | connection refused/reset to a dependency, SQL/driver exceptions, gRPC/HTTP client failures |
| `timeout` | `timed out`, `deadline exceeded`, HTTP 408/504, `TimeoutException`, `context deadline exceeded`; .NET `OperationCanceledException`/`TaskCanceledException` count here too because HttpClient and ADO.NET surface timeouts through them — a user-initiated cancellation is therefore reported as a timeout (limitation) |
| `auth` | HTTP 401/403, authentication/authorization exceptions, expired tokens |
| `configuration` | missing/invalid settings, unknown options, `FileNotFound` for config, environment variables unset |
| `resource_exhaustion` | out-of-memory, disk full, HTTP 429, thread/connection pool exhausted, too many open files |
| `data_integrity` | corruption, checksum mismatch, constraint/duplicate-key violations, serialization errors |
| `network` | DNS failures, unreachable hosts, TLS handshake errors, broken pipes |
| `security` | failed logins, blocked requests, injection attempts, permission denied on protected resources |
| `performance` | slow queries, latency warnings, GC pauses |
| `client_error` | HTTP 4xx other than 401/403/408/429 |
| `operational` | start/stop/reload/deploy notices |
| `unknown` | nothing recognized |

Evidence precedence (highest first): a parser-supplied observed category (sanitizer/panic/crash report) →
exception type → HTTP status → message rules. When observed evidence exists, message rules are consulted only for
`performance`/`security` refinements; the category is then `basis: "observed"`. When only message wording matched,
`basis: "inferred"`; when nothing matched, `category: "unknown"`, `basis: "unknown"`. Confidence is 0.85
(observed), 0.6 (inferred) or 0.35 (unknown). `assessment.rationale[]` names the evidence used (exception type,
HTTP status, matched rule) and explains each severity decision; `assessment.impact_signals[]` lists the impact
labels derived from that evidence (termination, data loss, resource exhaustion, …).

### Severity policy

Base severity by category: `application_crash`, `resource_exhaustion`, `data_integrity`, `security`,
`availability`, `dependency_failure` → **high**; `timeout`, `network`, `configuration`, `unknown` → **medium**;
`auth`, `client_error`, `performance` → **low**; `operational` → **info**. Then:

* **critical** requires explicit evidence: termination (`panic`, `SIGSEGV`, `core dumped`, `fatal error`, crash
  report) at error level or above; out-of-memory / disk-full; data loss or corruption wording.
* `data_integrity` without loss evidence (duplicate key, constraint, optimistic-lock conflict) → medium.
* `security` that is ordinary authentication noise (`failed password`, `invalid user`, `blocked`) → medium.
* `availability`/`dependency_failure` logged below ERROR → medium.
* `unknown` follows the producer level only: FATAL/CRITICAL → high, ERROR → medium, WARN → low, INFO → info, no
  level → low (`rationale` says "severity from producer level only").
* Producer-level caps: a message logged below WARN is at most **low** (info for `operational`/`unknown`) unless
  termination, OOM/disk-full or data-loss evidence is explicit. A WARN-level message is at most medium unless the
  same strong evidence exists.

What severity does **not** do: it is never derived from the occurrence count (frequency is reported separately and
must not be read as impact), never from the word "error" alone (an ERROR-level line with unknown content is
medium, not high), and the assessment never claims an incident happened — it labels what was *observed*, what was
*inferred* from wording, and what is *unknown*. Grouping is not causal correlation: two groups with overlapping
time ranges or shared correlation ids are shown side by side, never merged or declared cause and effect.

### Severity mappings

| Assessed severity | SARIF `level` | SARIF `rank` | SARIF `kind` | CSV `severity` | HTML class |
|---|---|---|---|---|---|
| critical | `error` | 95 | `fail` | `critical` | `sev-critical` |
| high | `error` | 75 | `fail` | `high` | `sev-high` |
| medium | `warning` | 50 | `fail` | `medium` | `sev-medium` |
| low | `note` | 25 | `fail` | `low` | `sev-low` |
| info | `note` (SARIF has no lower level) | 5 | `informational` | `info` | `sev-info` |

## 6. Timeline

`timeline` holds at most `max_timeline_buckets` (default 200) buckets over `[start, end]` of timed events. The bucket
width adapts (60 s → 5 min → 15 min → 1 h → 6 h → 1 d → 7 d → 30 d) so the bound is never exceeded; each bucket
counts events by level class (`fatal`, `error`, `warn`, `info`, `debug`, `unknown`). `events_without_timestamp` is
reported alongside. Counts are exact; coarsening merges buckets, it does not sample.

## 7. Repository attribution

Attribution runs for the top `max_attributed_groups` groups when `--repo`/`--repos-dir` is given. Evidence and
weights (per candidate repository every distinct piece of evidence — a `(kind, value)` pair — adds its weight; the
sum is capped at 1.0):

| Evidence | Weight | Source |
|---|---|---|
| frame path: full match of ≥2 trailing components / ≥3 trailing components / 2 trailing components | 0.6 / 0.5 / 0.4 | in-app frames of the group's exception, matched against the repository inventory (`git ls-files` + bounded walk) |
| frame path: basename only (unique / not unique) | 0.15 / 0.1 | **never sufficient alone** — confidence is capped at 0.3 |
| namespace / package / module from exception type or logger (dotted / single segment) | 0.5 / 0.3 | JVM package layout, `csproj` RootNamespace, Python packages, Go module dirs, Ruby/Elixir `lib` |
| path or namespace found *in the message* | 0.8 × the above | |
| service name equals repository name | 0.5 | |
| repository name mentioned in the message | 0.1 | |

Status: `resolved` when the top candidate scores ≥ 0.6 with a margin ≥ 0.2 over the runner-up (≥ 0.4 with the
same margin also resolves, flagged "moderate evidence; verify against the deployed version"), `ambiguous` when
≥ 0.4 without a clear margin, `unresolved` otherwise (a `reason` string explains each non-resolved status; two
candidates at the same commit — a repository and its worktree — are attributed to the first with a note). Candidates
list `{repo, repo_id, confidence, evidence[] {kind, value, matched, weight}}`. Each discovered repository records
`kind` (repository / worktree / submodule), `head`, `branch` and `working_tree_dirty`, because the checkout may not
be the revision that produced the logs; source references are repository-relative paths.

## 8. Investigation, root cause and suggestions

Deterministic investigation runs for the top `max_investigations` attributed groups:

* every in-app frame reference is checked against the checkout: file exists, line exists (`beyond end of file`
  otherwise), the function/symbol appears within ±6 lines → `verified: true`; a bounded snippet
  (`max_snippet_lines`) is captured for the model queue;
* the message template's literal words are searched in the repository (bounded by `max_literal_search_files` /
  `max_literal_search_hits`) to locate the logging call;
* `root_cause` = `{observed[], hypotheses[] {hypothesis, evidence[], confidence}, uncertainty[], alternatives[]}`;
  observed facts come from the assessment rationale, hypotheses are category-based and cite verified locations,
  uncertainty states what could not be verified (inferred basis, dirty or mismatched checkout);
* `suggestions[]` = `{summary, rationale, kind, confidence, suggested_changes[], references[] {repo, path, line,
  verified, function, note}, regression_tests[], verification_steps[], alternatives[], origin}` where `kind` is
  `source_backed` only when a reference was verified in the checkout and `generic` otherwise (category-based
  guidance clearly labelled as such);
* `status`: `deterministic` (references verified), `insufficient_evidence` (nothing verifiable — the suggestion
  says so instead of guessing), `not_investigated` (beyond `max_investigations`), `not_attempted` (no repository
  given, or the group was not attributed);
* `investigation_queue[]` (≤ `max_model_queue_groups`, each ≤ `max_model_context_chars` of context) hands the model
  compact entries: `{id, severity, category, count, template, exception {chain, message_template}, top_frames[],
  candidates[], references[] {repo, path, line, verified, function, snippet, note}, deterministic_suggestion,
  questions[]}`; `investigation.model_refinement` is `pending` until `--render --suggestions` merges the model's
  answer (`origin: "model"`), after which unreached groups read `not_investigated_by_model`.

No suggestion modifies source: the engine only reads repositories, and the slash command is instructed to propose
changes as text.
