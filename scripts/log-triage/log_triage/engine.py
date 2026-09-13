"""Analysis pipeline: inputs -> detection -> parsing -> filtering -> aggregation -> attribution.

Produces an :class:`Analysis` whose ``meta`` dict is the analysis document without its
``groups`` array; exporters stream groups from the shared :class:`GroupStore` so every
output format sees the same counts, identifiers and ordering.
"""
from __future__ import annotations

import os
import platform
import shutil
import sqlite3
import sys
import tempfile
import time
import traceback
from typing import Any, Dict, Iterator, List, Optional

from . import FINGERPRINT_VERSION, SCHEMA_VERSION, TOOL_NAME, TOOL_VERSION
from .aggregate import GroupStore
from .attribute import attribute_all
from .config import SEVERITIES, SEVERITY_RANK, Options
from .inputs import InputFile, InputSet, resolve_inputs
from .investigate import investigate_all
from .model import DiagnosticSink
from .normalize import TEMPLATE_VERSION
from .parsers import detect, get_parser
from .parsers.base import ParseContext
from .reader import LineReader, InputStatus, UnsupportedCompression, read_sample
from .redact import Redactor
from .repos import RepoSet, discover
from .timeline import Timeline
from .timestamps import format_iso


class Analysis:
    def __init__(self, meta: Dict[str, Any], store: Optional[GroupStore], min_rank: int, inputs: InputSet,
                 repos: RepoSet, temp_dir: Optional[str], max_output_groups: Optional[int] = None):
        self.meta = meta
        self.store = store
        self.min_rank = min_rank
        self.inputs = inputs
        self.repos = repos
        self.temp_dir = temp_dir
        self.max_output_groups = max_output_groups
        self._override_groups: Optional[List[Dict[str, Any]]] = None

    def groups(self) -> Iterator[Dict[str, Any]]:
        """Reported groups (assessed severity >= --min-severity), in canonical order.

        At most ``max_output_groups`` are yielded; every exporter therefore writes the same
        prefix of the canonical order and ``filtering.groups_omitted_by_output_limit`` in the
        metadata discloses how many reported groups were left out.
        """
        limit = self.max_output_groups
        n = 0
        if self._override_groups is not None:
            for g in self._override_groups:
                if SEVERITY_RANK.get(g.get("severity", "info"), 0) >= self.min_rank:
                    if limit is not None and n >= limit:
                        return
                    n += 1
                    yield g
            return
        if self.store is None:
            return
        for g in self.store.iter_groups(self.min_rank):
            if limit is not None and n >= limit:
                return
            n += 1
            yield g

    def close(self) -> None:
        if self.store is not None:
            self.store.close()


class Counters:
    def __init__(self) -> None:
        self.events_parsed = 0
        self.events_included = 0
        self.filtered_by_since = 0
        self.untimed_excluded = 0
        self.untimed_included = 0
        self.lines_total = 0
        self.bytes_read = 0
        self.bytes_compressed = 0
        self.parse_failures = 0
        self.truncated_lines = 0
        self.discarded_bytes = 0
        self.replacements = 0
        self.first_ts: Optional[float] = None
        self.last_ts: Optional[float] = None
        self.interrupted = False
        self.disk_full = False
        self.disk_full_detail: Optional[str] = None
        self.reasons: List[str] = []


def _is_disk_full(exc: BaseException) -> bool:
    if isinstance(exc, OSError) and getattr(exc, "errno", None) in (28, 122):   # ENOSPC, EDQUOT
        return True
    if isinstance(exc, sqlite3.OperationalError) and ("disk is full" in str(exc).lower() or "database or disk is full" in str(exc).lower()):
        return True
    return False


def _choose_parser(f: InputFile, sample, options: Options, ctx: ParseContext):
    forced = options.input_format
    if forced:
        layout = None
        name = forced
        if forced.startswith("text:"):
            name, layout = "text", forced.split(":", 1)[1]
        if name == "text":
            from .parsers.text import TextParser
            f.format, f.detection_confidence = forced, 1.0
            return TextParser("text", layout)
        f.format, f.detection_confidence = name, 1.0
        return get_parser(name)
    name, conf, scores = detect(sample, ctx)
    f.format, f.detection_confidence = name, round(conf, 3)
    if conf < 0.3:
        ctx.diag("low-detection-confidence", "warning",
                 "format detection confidence %.2f (best: %s); using the %s fallback" % (conf, name, options.fallback_format))
        name = options.fallback_format
        f.format = name + " (fallback)"
    return get_parser(name)


def process_file(f: InputFile, options: Options, diagnostics: DiagnosticSink, store: GroupStore, counters: Counters,
                 now: float) -> None:
    limits = options.limits
    ctx = ParseContext(limits, options, diagnostics, f, now)
    try:
        sample = read_sample(f.real_path, limits)
    except OSError as exc:
        f.status, f.reason = "failed", "read error: %s" % exc
        ctx.diag("file-read-error", "error", "cannot read %s: %s" % (f.path, exc))
        return
    if sample.compression not in (None, "gzip"):
        hint = UnsupportedCompression(sample.compression).hint()
        f.status, f.reason = "excluded", "unsupported-compression:%s" % sample.compression
        ctx.diag("unsupported-compression", "error", "%s: %s" % (f.path, hint))
        return
    if sample.binary_kind:
        f.status, f.reason = "excluded", "binary-unsupported:%s" % sample.binary_kind
        ctx.diag("binary-input-unsupported", "error", "%s: %s" % (f.path, sample.binary_hint))
        return
    f.encoding = sample.encoding
    f.compressed = sample.compression
    if not sample.raw.strip():
        if sample.stream_error:
            f.status, f.reason = "failed", "corrupt-compressed-input"
            ctx.diag("input-corrupt", "error", "%s: %s; nothing could be decompressed" % (f.path, sample.stream_error))
        elif sample.stream_truncated:
            f.status, f.reason = "partial", "truncated-compressed-input"
            ctx.diag("input-truncated", "error", "%s: compressed stream ends before any data; nothing could be decompressed" % f.path)
        else:
            f.status, f.reason = "processed", "empty"
        return
    parser = _choose_parser(f, sample, options, ctx)
    reader = LineReader(f.real_path, limits, encoding=None)
    since = options.since_epoch
    keep_untimed = options.keep_untimed
    interrupt_after = os.environ.get("LOG_TRIAGE_TEST_INTERRUPT_AFTER")
    interrupt_after_n = int(interrupt_after) if interrupt_after and interrupt_after.isdigit() else None
    try:
        for ev in parser.parse(iter(reader), ctx):
            counters.events_parsed += 1
            f.events += 1
            if since is not None:
                if ev.ts is None:
                    if not keep_untimed:
                        counters.untimed_excluded += 1
                        continue
                    counters.untimed_included += 1
                elif ev.ts < since:
                    counters.filtered_by_since += 1
                    continue
            if ev.ts is not None:
                if counters.first_ts is None or ev.ts < counters.first_ts:
                    counters.first_ts = ev.ts
                if counters.last_ts is None or ev.ts > counters.last_ts:
                    counters.last_ts = ev.ts
            store.add(ev)
            counters.events_included += 1
            if interrupt_after_n is not None and counters.events_included >= interrupt_after_n:
                raise KeyboardInterrupt()
    except KeyboardInterrupt:
        counters.interrupted = True
        f.status, f.reason = "partial", "interrupted"
        ctx.diag("interrupted", "error", "analysis interrupted while processing %s at line %d" % (f.path, reader.lines))
    except BaseException as exc:  # noqa: BLE001 - every failure must be reported, never hidden
        if _is_disk_full(exc):
            counters.disk_full = True
            counters.disk_full_detail = str(exc)
            f.status, f.reason = "partial", "disk-full"
            ctx.diag("disk-full", "error", "temporary storage exhausted while processing %s: %s" % (f.path, exc))
        elif isinstance(exc, MemoryError):
            f.status, f.reason = "failed", "memory-error"
            ctx.diag("parser-error", "error", "%s: MemoryError while parsing (%s)" % (f.path, f.format))
        else:
            f.status, f.reason = "failed", "parser-error: %s: %s" % (type(exc).__name__, str(exc)[:200])
            ctx.diag("parser-error", "error", "%s: %s parser raised %s: %s" % (f.path, f.format, type(exc).__name__, str(exc)[:200]))
            if options.verbose:
                traceback.print_exc(file=sys.stderr)
    finally:
        f.lines = reader.lines
        f.bytes_read = reader.bytes_read
        f.layout = ctx.layout
        f.dialect = ctx.dialect
        counters.lines_total += reader.lines
        counters.bytes_read += reader.bytes_read
        counters.bytes_compressed += reader.bytes_compressed
        counters.parse_failures += ctx.parse_failures
        counters.truncated_lines += reader.truncated_lines
        counters.discarded_bytes += reader.discarded_bytes
        counters.replacements += reader.replacements
        if reader.truncated_lines:
            ctx.diag("oversized-line", "warning", "%d line(s) exceeded max_line_bytes (%d) and were truncated; %d byte(s) discarded"
                     % (reader.truncated_lines, limits.max_line_bytes, reader.discarded_bytes))
        if reader.replacements:
            ctx.diag("encoding-replacement", "warning", "%d invalid byte sequence(s) replaced with U+FFFD (declared/detected encoding: %s)"
                     % (reader.replacements, reader.encoding))
        if reader.unterminated_last_line:
            ctx.diag("unterminated-last-line", "info", "last line has no newline (file may still be written)")
    if f.status == "pending":
        if reader.status == InputStatus.COMPLETE:
            f.status = "processed"
        else:
            f.status, f.reason = "partial", "%s: %s" % (reader.status, reader.error)
            ctx.diag("input-" + reader.status, "error", "%s: %s" % (f.path, reader.error))
    if f.check_changed():
        ctx.diag("input-changed", "warning", "%s changed (size or mtime) during analysis; results reflect the content read" % f.path)
        if f.status == "processed":
            f.status = "partial"
            f.reason = "changed-during-analysis"


def run_analysis(options: Options, stderr=sys.stderr) -> Analysis:
    limits = options.limits
    now = options.now_epoch or time.time()
    started = time.time()
    diagnostics = DiagnosticSink(limits.max_diagnostics)
    inputs = resolve_inputs(options.inputs, limits, options.follow_symlinks)
    for arg in inputs.unmatched:
        diagnostics.add("unmatched-input", "warning", "input argument matched no file: %s" % arg)
    for dup, kept in inputs.duplicates[:200]:
        diagnostics.add("duplicate-input", "info", "%s is the same file as %s; processed once" % (dup, kept))
    for ex in inputs.excluded[:500]:
        diagnostics.add("input-excluded", "info", "%s excluded (%s)" % (ex["path"], ex["reason"]))
    if inputs.limit_hit:
        diagnostics.add("limit-reached", "error", "more than max_files (%d) inputs; the surplus was excluded" % limits.max_files)

    temp_root = tempfile.mkdtemp(prefix="log-triage-", dir=options.temp_dir)
    os.chmod(temp_root, 0o700)
    try:
        return _run_with_temp(options, limits, inputs, diagnostics, now, started, temp_root)
    except BaseException:
        # any failure that escapes (sqlite errors, bugs, interrupts during export) must not leak the
        # private temp directory; cleanup() handles the success path
        shutil.rmtree(temp_root, ignore_errors=True)
        raise


def _run_with_temp(options: Options, limits, inputs, diagnostics, now, started, temp_root: str) -> "Analysis":
    redactor = Redactor(options.redact, options.redact_ips, options.redaction_salt)
    timeline = Timeline(limits.max_timeline_buckets)
    input_paths = {f.id: f.path for f in inputs.files}
    store = GroupStore(limits, temp_root, redactor, timeline, input_paths)
    counters = Counters()
    repos = RepoSet()

    try:
        if options.repo or options.repos_dir:
            repos = discover(options, limits, diagnostics)
            if repos.incomplete:
                counters.reasons.append("repository discovery incomplete: " + "; ".join(repos.incomplete_reasons))
            for r in repos.repos:
                if r.dirty is None:
                    diagnostics.add("repo-state-unknown", "info", "%s: working-tree state unknown (%s)" % (r.name, r.dirty_reason))
        for f in inputs.files:
            if counters.interrupted or counters.disk_full:
                f.status, f.reason = "pending", "not processed (analysis stopped early)"
                continue
            if not options.quiet:
                stderr.write("log-triage: processing %s (%d bytes)\n" % (f.path, f.size))
            process_file(f, options, diagnostics, store, counters, now)
        try:
            store.finalize()
        except BaseException as exc:  # noqa: BLE001
            if _is_disk_full(exc):
                counters.disk_full = True
                counters.disk_full_detail = str(exc)
                diagnostics.add("disk-full", "error", "temporary storage exhausted during aggregation: %s" % exc)
                store.groups.clear()
                store.finalize()
            else:
                raise
        attribution_summary: Dict[str, Any] = {}
        investigation_summary: Dict[str, Any] = {}
        queue: List[Dict[str, Any]] = []
        if repos.repos:
            try:
                attribution_summary = attribute_all(store, repos, limits)
                investigation_summary = investigate_all(store, repos, limits, options)
                queue = investigation_summary.pop("queue", [])
            except KeyboardInterrupt:
                counters.interrupted = True
                diagnostics.add("interrupted", "error", "interrupted during repository investigation; groups keep deterministic results only")
    except KeyboardInterrupt:
        counters.interrupted = True
        diagnostics.add("interrupted", "error", "analysis interrupted")
        store.finalize()
        attribution_summary, investigation_summary, queue = {}, {}, []

    # --- assemble the document ---------------------------------------------------------
    min_rank = SEVERITY_RANK[options.min_severity]
    by_sev = store.by_severity
    groups_total = store.total_groups
    groups_reported = sum(v["groups"] for k, v in by_sev.items() if SEVERITY_RANK[k] >= min_rank)
    events_reported = sum(v["events"] for k, v in by_sev.items() if SEVERITY_RANK[k] >= min_rank)
    completion = "complete"
    reasons = list(counters.reasons)
    if counters.interrupted:
        completion, reasons = "partial", reasons + ["interrupted"]
    if counters.disk_full:
        completion, reasons = "partial", reasons + ["temporary storage exhausted (%s)" % (counters.disk_full_detail or "disk full")]
    if inputs.unmatched:
        completion = "partial"
        reasons.append("%d input argument(s) matched no file" % len(inputs.unmatched))
    for f in inputs.files:
        if f.status in ("failed", "partial", "pending") or (f.status == "excluded"):
            completion = "partial"
            reasons.append("%s: %s (%s)" % (f.path, f.status, f.reason))
    if inputs.limit_hit:
        completion = "partial"
    if repos.incomplete:
        completion = "partial"
    if not inputs.files:
        completion = "failed"
        reasons.append("no input files" if not inputs.excluded else
                       "no input could be processed: every matched file was excluded (%d)" % len(inputs.excluded))
    elif all(f.status in ("failed", "excluded") for f in inputs.files):
        completion = "failed"
        reasons.append("no input could be processed")
    reasons = reasons[:50]

    top: List[Dict[str, Any]] = []
    cat_counts: Dict[str, Dict[str, int]] = {}
    for g in store.iter_groups(min_rank):
        c = cat_counts.setdefault(g["category"], {"groups": 0, "events": 0})
        c["groups"] += 1
        c["events"] += g["count"]
        if len(top) < 10:
            top.append({"id": g["id"], "severity": g["severity"], "category": g["category"], "count": g["count"],
                        "template": g["template"][:200], "services": list(g["services"].keys())[:3]})
    highest = None
    for sev in reversed(SEVERITIES):
        if by_sev.get(sev, {}).get("groups"):
            highest = sev
            break

    meta: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "tool": {"name": TOOL_NAME, "version": TOOL_VERSION, "fingerprint_version": FINGERPRINT_VERSION,
                 "template_version": TEMPLATE_VERSION, "python": platform.python_version(), "platform": platform.platform()},
        "generated_at": format_iso(options.now_epoch or time.time()),
        "analysis_started_at": format_iso(started),
        "duration_seconds": round(time.time() - started, 3),
        "status": {"completion": completion, "reasons": reasons, "interrupted": counters.interrupted,
                   "disk_full": counters.disk_full, "exit_code": None},
        "configuration": options.public_dict(),
        "inputs": {
            "requested": list(inputs.requested),
            "files": [f.to_dict() for f in inputs.files],
            "unmatched": list(inputs.unmatched),
            "excluded": inputs.excluded[:500],
            "excluded_total": len(inputs.excluded),
            "duplicates": [list(d) for d in inputs.duplicates[:200]],
            "skipped_symlinks": inputs.skipped_symlinks[:200],
            "summary": inputs.summary(),
        },
        "coverage": {
            "events_parsed": counters.events_parsed,
            "events_included": counters.events_included,
            "events_filtered_by_since": counters.filtered_by_since,
            "events_untimed_excluded_by_since": counters.untimed_excluded,
            "events_untimed_included": counters.untimed_included,
            "events_with_timestamp": timeline.total - timeline.untimed,
            "events_without_timestamp": timeline.untimed,
            "lines_total": counters.lines_total,
            "bytes_read": counters.bytes_read,
            "bytes_compressed": counters.bytes_compressed,
            "parse_failures": counters.parse_failures,
            "truncated_lines": counters.truncated_lines,
            "discarded_bytes": counters.discarded_bytes,
            "encoding_replacements": counters.replacements,
            "time_range": {"first": format_iso(counters.first_ts), "last": format_iso(counters.last_ts)},
            "redaction": {"enabled": options.redact, "counts": redactor.summary(), "ips_pseudonymized": options.redact_ips},
        },
        "filtering": {
            "since": options.since,
            "since_epoch_utc": options.since_epoch,
            "min_severity": options.min_severity,
            "groups_total": groups_total,
            "groups_reported": groups_reported,
            "groups_filtered_by_severity": groups_total - groups_reported,
            "max_output_groups": limits.max_output_groups,
            "groups_written": min(groups_reported, limits.max_output_groups),
            "groups_omitted_by_output_limit": max(0, groups_reported - limits.max_output_groups),
            "events_in_reported_groups": events_reported,
            "events_in_filtered_groups": store.events - events_reported,
            "by_severity": {sev: by_sev.get(sev, {"groups": 0, "events": 0}) for sev in SEVERITIES},
        },
        "diagnostics": diagnostics.to_dict(),
        "timeline": timeline.to_dict(),
        "repositories": dict(repos.to_dict(), attribution_summary=attribution_summary, investigation_summary=investigation_summary),
        "aggregation": {
            "groups_total": groups_total, "events": store.events, "spilled_to_disk": store.spilled,
            "spill_count": store.spill_count, "temp_bytes_peak": store.temp_bytes_peak, "temp_dir": temp_root if options.keep_temp else None,
            "max_groups_in_memory": limits.max_groups_in_memory, "fingerprint_cache_size": limits.fingerprint_cache_size,
        },
        "summary": {
            "highest_severity": highest, "top_findings": top,
            "counts_by_severity": {sev: by_sev.get(sev, {"groups": 0, "events": 0}) for sev in SEVERITIES},
            "counts_by_category": cat_counts,
        },
        "investigation_queue": queue,
    }
    return Analysis(meta, store, min_rank, inputs, repos, temp_root, limits.max_output_groups)


def cleanup(analysis: Analysis, options: Options) -> None:
    analysis.close()
    if analysis.temp_dir and not options.keep_temp:
        shutil.rmtree(analysis.temp_dir, ignore_errors=True)
