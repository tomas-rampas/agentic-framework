# /log-triage — benchmark (reproducible, measured)

The benchmark answers the questions the specification asks: does the engine handle inputs of hundreds of MB with
bounded memory, are counts exact, and what does a run cost. Everything below was produced by
`scripts/log-triage/bench/benchmark.py`; the raw results are committed as
[benchmark-results.json](benchmark-results.json) and the table is rendered from them with
`python3 scripts/log-triage/bench/benchmark.py --report docs/log-triage/benchmark-results.json`.

## Reproduce

```bash
# two modes x two sizes (about 45 minutes on the host below; needs ~4 GB scratch space)
python3 scripts/log-triage/bench/benchmark.py --sizes-mib 256,512 --modes normal,high-cardinality \
    --work /path/to/scratch --out /path/to/scratch/results.json
python3 scripts/log-triage/bench/benchmark.py --report /path/to/scratch/results.json
```

* **Inputs are generated, not shipped** (deterministic seed `20260913`): Spring Boot style text logs.
  `normal` draws from 200 message templates with random ids/sizes/durations (61 distinct issue groups; one in
  four ERROR templates carries a 10-line Java stack trace). `high-cardinality` gives 25 % of the events a unique
  alphabetic token that survives templating and the rest one of 51,000 repeating tokens, so nearly every event is
  its own group — this is the case that forces the SQLite spill.
* **The generator knows the answer**: it counts the events it wrote and the distinct message templates it emitted,
  and the runner compares them with `coverage.events_included` and `filtering.groups_total` from
  `analysis.json` (`Counts exact` below). Nothing is sampled or estimated.
* **Measurement** (all per run, in a fresh parent process): elapsed = wall clock of the analyzer subprocess;
  peak memory = `resource.getrusage(RUSAGE_CHILDREN).ru_maxrss` of the analyzer; temp disk =
  `aggregation.temp_bytes_peak` (peak size of the spill database); the analyzer runs with default limits,
  `--format json --quiet --no-redact` (redaction is pattern work proportional to input size; it is measured
  separately below).

## Results

Host: 4 vCPU Intel Xeon @ 2.10 GHz, 15 GiB RAM, Linux 6.18, Python 3.11.15 (CPython), ext4 scratch disk.
Runs were executed sequentially, one analyzer process at a time (the engine is single-threaded).

| Run | Input | Events | Groups (expected) | Counts exact | Elapsed | Throughput | Peak RSS | Spilled (spills) | Temp disk peak | Exit |
|---|---|---|---|---|---|---|---|---|---|---|
| normal-256mib | 256 MiB (268,435,552 bytes) | 1,477,017 | 61 (61) | yes | 223.4 s | 1.15 MiB/s | 51.2 MiB | no (0) | 0 | 0 |
| normal-512mib | 512 MiB (536,871,013 bytes) | 2,952,588 | 61 (61) | yes | 442.6 s | 1.16 MiB/s | 51.5 MiB | no (0) | 0 | 0 |
| high-cardinality-256mib | 256 MiB (268,435,474 bytes) | 1,791,393 | 498,784 (498,784) | yes | 596.0 s | 0.43 MiB/s | 137.4 MiB | yes (90) | 1.29 GiB | 0 |
| high-cardinality-512mib | 512 MiB (536,871,045 bytes) | 3,580,408 | 947,519 (947,519) | yes | 1224.7 s | 0.42 MiB/s | 136.6 MiB | yes (180) | 2.34 GiB | 0 |

Measurement: elapsed = wall-clock of the analyzer subprocess; peak_memory = resource.getrusage(RUSAGE_CHILDREN).ru_maxrss of the analyzer (KiB on Linux), measured in a fresh parent process per run; temp_disk = aggregation.temp_bytes_peak from analysis.json (peak SQLite spill file size); counts = coverage.events_included and filtering.groups_total compared with the generator's totals

### What the numbers show

* **Memory does not scale with input size.** Doubling the input (256 → 512 MiB) leaves peak RSS unchanged in both
  modes: ~51 MiB when the group table stays in memory, ~137 MiB when 0.5–0.95 million distinct groups are
  spilled to SQLite (the in-memory table is bounded by `max_groups_in_memory` = 20,000 groups; the rest lives on
  disk). Elapsed time scales linearly with input size (1.15 MiB/s normal, 0.42 MiB/s high-cardinality).
* **Counts are exact under spill.** 947,519 groups were merged across 180 spills and the final count equals the
  generator's distinct-template count; every event is accounted for (`events_included` = events generated).
* **Temp disk grows with the number of distinct groups**, not with input size: ~2.5 KiB per spilled group
  including its bounded examples (1.29 GiB for 499 k groups, 2.34 GiB for 948 k groups). The directory is private
  (`0700`) and removed at exit. `aggregation.temp_bytes_peak` in every run reports the actual peak.
* **Throughput** is CPU-bound pure Python: ~1.15 MiB/s for typical logs with redaction off (≈ 6,600 events/s;
  ~0.87 MiB/s with the default redaction on, see below), ~0.42 MiB/s when
  almost every event creates a new group (classification and fingerprinting cannot use the exact-message cache).
  A 1 GiB typical log therefore takes ~15 minutes; multi-GB inputs work but should be delegated as a long run.
* **Output size** for the high-cardinality runs is bounded by `max_output_groups` (default 100,000 groups in
  `analysis.json`/`groups.ndjson`/`groups.csv`/`analysis.sarif`, omission disclosed in `filtering`); HTML and
  Markdown are bounded by `max_report_groups`/`max_findings_rows` independently.

### Redaction cost (measured separately)

Redaction is enabled by default and is pattern work proportional to the input; the runs above use `--no-redact`
so that the table isolates parsing, grouping and spill behaviour. Measured on a 16 MiB `normal` input on the same
host (three runs, wall clock of the analyzer process, `resource.getrusage` peak RSS):

| Options | Elapsed | Throughput | Peak RSS |
|---|---|---|---|
| `--no-redact` | 11.7 s | 1.37 MiB/s | 50.1 MiB |
| default (redaction on) | 18.4 s | 0.87 MiB/s | 50.1 MiB |
| `--redact-ips` (redaction on + IPv4 pseudonyms) | 18.0 s | 0.89 MiB/s | 50.0 MiB |

Redaction costs roughly 55–60 % more wall time on this synthetic input (every event is scanned by the secret
patterns); memory is unaffected. Keep it on for logs of unknown content; `--no-redact` is for logs already known
to be free of secrets.

## Limits used

Default `Limits` (see `docs/log-triage/README.md` → Configuration): `max_groups_in_memory` 20,000,
`fingerprint_cache_size` 20,000, `max_examples_per_group` 3, `max_line_bytes`/`max_record_bytes` 1 MiB,
`read_chunk_bytes` 1 MiB. `--limit KEY=VALUE` on the benchmark command line passes overrides to every run.
