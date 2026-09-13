# /log-triage — implementation summary, status and known limitations

## What was built

| Deliverable | Location |
|---|---|
| Slash command definition | `commands/log-triage.md` (`/agentic-framework:log-triage`) |
| Engine (stdlib-only Python ≥ 3.8, no third-party packages) | `scripts/log-triage/` (`python3 scripts/log-triage …`) |
| Usage documentation (CLI contract, defaults, exit codes, limits, time handling, redaction) | `docs/log-triage/README.md` |
| Tested support matrix (generated from the code: `--support-matrix`) | `docs/log-triage/support-matrix.md` |
| Canonical model, normalization rules, fingerprint v1, assessment policy, attribution weights | `docs/log-triage/canonical-model.md` |
| JSON Schema for `analysis.json` | `docs/log-triage/schema/analysis.schema.json` |
| SARIF mapping and exporter behaviour (JSON, NDJSON, CSV, HTML, Markdown) | `docs/log-triage/sarif-mapping.md` |
| Fixtures (106 files, 13 ecosystems, every input format) and tests | `tests/log-triage/` (`bash tests/log-triage.test.sh`, also run in CI) |
| Sample outputs in all six formats | `docs/log-triage/samples/` |
| Benchmark tooling and measured results | `scripts/log-triage/bench/benchmark.py`, `docs/log-triage/benchmark.md` |

## Architecture (module map)

```
scripts/log-triage/
├── __main__.py                 entry point → log_triage.cli.main
├── bench/benchmark.py          reproducible generator + runner (size, elapsed, peak RSS, temp disk, exact counts)
└── log_triage/
    ├── cli.py                  argument parsing (exit 2 on misuse), exit-code policy, output loop, summary
    ├── config.py               Limits (every bound, overridable) and Options
    ├── engine.py               per-input pipeline, run orchestration, status/partial logic, temp dir lifecycle
    ├── inputs.py               path/glob/directory expansion, dedupe, ordering, exclusions, change detection
    ├── reader.py               chunked streaming reader, gzip (multi-member, salvage), encodings, binary detection
    ├── timestamps.py           ISO/CLF/syslog/JUL/glog/epoch parsing, zone/year inference, --since
    ├── model.py                canonical Event/Frame/ExceptionInfo, level scale, DiagnosticSink
    ├── parsers/                registry + bounded-sample detection
    │   ├── text.py             layout engine (38 producer layouts + 2 generic fallbacks, mixed layouts, multiline records)
    │   ├── exceptions.py       exception/crash/backtrace parsing for every ecosystem
    │   ├── structured.py       JSON/NDJSON dialects, envelopes, platform exports (CloudWatch, Azure, GCP, Loki, ES)
    │   ├── jsonstream.py       incremental JSON item scanner (documents, arrays, envelopes) without loading files
    │   ├── nested.py           nested text/JSON sink for Docker, CRI, CloudWatch, GCP, Loki, journal payloads
    │   ├── tabular.py          CSV/TSV (quoted, embedded newlines), IIS W3C (#Fields)
    │   ├── xml_log.py          expat-based XML (Windows Event Log, log4j/log4net/JUL XML); entities rejected
    │   └── wrappers.py         Kubernetes CRI, logfmt, Apple crash reports
    ├── redact.py               secret/credential/email redaction with HMAC pseudonyms
    ├── normalize.py            message templating (template v1)
    ├── fingerprint.py          fingerprint v1 (sha256) and group ids
    ├── aggregate.py            bounded in-memory groups, SQLite spill, exact merges, canonical ordering
    ├── classify.py             category/severity assessment with observed/inferred/unknown basis
    ├── timeline.py             adaptive bounded timeline
    ├── repos.py                repository/worktree discovery (bounded), inventory, revision state
    ├── attribute.py            evidence-weighted attribution
    ├── investigate.py          reference verification, literal search, root-cause assessment, suggestions, model queue
    ├── render.py               --render / --suggestions merge
    ├── schema_check.py         minimal JSON-Schema validator used by the tests
    ├── supportmatrix.py        generates docs/log-triage/support-matrix.md
    └── exporters/              json, ndjson (+meta), csv, sarif, html, markdown (common Exporter interface)
```

Data flow: inputs → sample-based detection → streaming parser → canonical events → redaction → templating →
fingerprint → bounded group store (spilling to SQLite) → classification → timeline → (repositories → attribution →
investigation) → canonical ordering → exporters. Everything before the exporters is deterministic for a given input
set and configuration; the model is only involved after `analysis.json` exists (`investigation_queue` →
`model-suggestions.json` → `--render`).

## Status by requirement area

Legend: **tested** = automated tests in `tests/log-triage/` exercise it with fixtures; **best effort** = implemented,
exercised manually or partially, listed limitations apply; **future** = not implemented, documented only.

| Area | Status | Notes |
|---|---|---|
| CLI contract, globs, quoting, ordering, dedupe, unmatched inputs, mutually exclusive repo options, format handling, deterministic filenames, exit codes 0/1/2/3/4 | tested | `test_cli.py`, `test_partial.py` |
| Ecosystem text layouts (C#/.NET, Java/Kotlin/Scala, Python, TS/JS, Go, Rust, C/C++, PHP, Ruby, Swift/ObjC, Erlang/Elixir, PowerShell, AWS Lambda) | tested | one fixture per layout, event counts and fields asserted (`test_formats.py`); the support matrix is generated from the same layout table |
| Structured dialects (Serilog, log4j2, Logstash/Logback, python-json-logger, structlog, Loguru, Pino, Bunyan, Winston, slog, Zap, Zerolog, tracing, Monolog, ECS, OTLP, journal, Docker json-file, CloudWatch, Azure, GCP, Loki, Apple .ips) | tested | exact exported shapes in `tests/log-triage/fixtures/…`; no live cloud connections |
| Plain text, JSON documents/arrays/envelopes, NDJSON, CSV/TSV, logfmt, XML, syslog 3164/5424, Apache/Nginx access + error, IIS W3C, CRI, journal JSON, Windows Event Log XML, gzip (multi-member, truncated, ratio/size limits) | tested | |
| Binary inputs (EVTX, ETL, journal, ELF/PE/PDF/PNG/SQLite/PCAP, random bytes) refused with actionable diagnostics | tested | never parsed as text; legacy single-byte text encodings are kept |
| Mixed formats in one file, malformed records, encoding problems (UTF-8/16, BOMs, Latin-1 replacement counts), truncated files, oversized lines/records, unknown layout fallback | tested | |
| Missing timestamps/years/zones, out-of-order events, `--since` semantics | tested | `test_timestamps.py`, `test_ingestion.py` |
| Bounded memory, streaming, SQLite spill with exact counts, temp cleanup, interruption, disk exhaustion, input change detection | tested (unit) + measured (benchmark) | `test_partial.py`, `benchmark.md` |
| Redaction (keys, tokens, JWTs, private keys, URL credentials, cards, emails) and pseudonyms | tested | `test_security.py` |
| Templating, fingerprint stability (pinned digest), grouping equivalence, deterministic ordering | tested | `test_grouping.py` |
| Categories, severity policy, observed/inferred/unknown basis, level caps, "frequency ≠ impact" | tested | `test_classify.py` |
| Repository discovery (repos, worktrees, `.git` files, bounded traversal, skips, symlinks), inventory, attribution, verified references, suggestions | tested | `test_repos.py` with generated Git repositories |
| Exporters: JSON (schema-validated), SARIF 2.1.0, HTML (offline, CSP, escaping, bounded), Markdown (escaped, bounded), CSV (formula-safe), NDJSON + meta; cross-exporter consistency; output-group limit | tested | `test_exporters.py`, `test_security.py` |
| Model-assisted refinement (`--render --suggestions`, kind downgrade rules) | tested | `test_cli.py` |
| Benchmark ≥ 500 MiB, high-cardinality spill, memory not scaling with size | measured | `docs/log-triage/benchmark.md` (reproduce with `bench/benchmark.py`) |
| PDF and JUnit exporters | future | the `Exporter` interface (`exporters/base.py`) is the extension point |
| Live cloud log APIs (CloudWatch, Azure Monitor, Google Cloud Logging, Loki queries) | future by design | only exported files are read; no network access |
| EVTX / ETL / systemd journal *binary* parsing | future | detected and refused with instructions to export (`wevtutil`, `tracerpt`, `journalctl -o json`) |

## Known limitations

* **Detection is sample-based.** The parser and layout are chosen from the first `detect_sample_bytes`/`detect_sample_lines`;
  a file whose first 64 KiB is unrepresentative may be parsed with the wrong layout (mixed layouts are supported up
  to three per file; a `layout-mismatch` diagnostic reports when most records did not match). Use `--input-format`.
* **Multiline assembly is heuristic.** Continuation detection covers stack traces, tracebacks, backtraces, crash
  reports, sanitizer output and PowerShell records; a producer that prints free-text continuation lines without
  indentation under a headerless layout will be split into separate events.
* **Templating cannot know intent.** A number that is semantically a *kind* (queue id 3 vs queue id 4) is still
  generalized to `<n>` unless it appears in a protected context (error code, HTTP status, errno). Conversely, long
  free-text messages with several variable words may form several groups. The fingerprint version guards
  consumers against silent changes.
* **Severity is a policy, not a measurement.** Categories come from explicit evidence or message rules; without
  service-level context the engine cannot know user impact, so severities are labelled observed/inferred/unknown
  and the report says so.
* **Attribution needs evidence.** Without in-app frames, namespaces or service names in the logs, attribution is
  `unresolved`; a basename match alone never resolves. The checkout may not be the revision that produced the
  logs — HEAD/branch/dirty state are recorded, but drift is not detected.
* **Redaction is pattern-based.** Secrets in unusual formats or split across lines are not detected; treat reports
  as sensitive when the logs are.
* **Throughput** is that of pure Python: about 1 MiB/s on one core for typical text logs, lower for high-cardinality
  logs (see benchmark). Multi-GB inputs are supported but take proportionally long; the reports and memory stay
  bounded.
* **Large machine-readable outputs.** A run with hundreds of thousands of distinct groups produces a large
  `analysis.json`/`groups.ndjson` (≈2 KiB per group). `max_output_groups` (default 100,000) bounds this and the
  omission is disclosed; HTML/Markdown are bounded separately.
* **XML** is parsed with entity expansion disabled; documents that rely on entities (DOCTYPE with entity
  declarations) are rejected rather than partially parsed.
* **Windows**: the engine is pure Python and path handling is cross-platform, but the automated suite runs on the
  Linux and macOS CI jobs only (the Windows job runs the PowerShell harnesses); PowerShell transcript/error-record
  fixtures are exercised on the POSIX jobs.
* **Hostile input is data, not a crash.** Tokens with thousands of digits, NUL bytes in text, and secrets inside
  multi-line continuation text are handled and tested; a parser bug on an unforeseen input is reported as a
  `parser-error` diagnostic for that input (status `failed`), never as a traceback, and never silently.

## Measured performance

See [benchmark.md](benchmark.md) for the reproducible numbers (input size, events, elapsed, peak RSS, temp disk,
method) including the high-cardinality run that exercises the SQLite spill.
