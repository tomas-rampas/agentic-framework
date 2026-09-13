"""Command-line contract (docs/log-triage/README.md).

Exit codes:
  0  analysis complete (with or without findings)
  1  processing failure: no usable analysis or outputs could not be written
  2  invalid invocation (arguments, unknown formats/limits, nothing to analyse)
  3  partial analysis: outputs were written but some input failed, a limit was hit,
     the run was interrupted, or temporary storage ran out
  4  findings at or above --fail-on-severity (only when that option is given)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any, Dict, List, Optional

from . import FINGERPRINT_VERSION, SCHEMA_VERSION, TOOL_NAME, TOOL_VERSION
from .config import AUTO_FORMATS, Limits, Options, REPORT_FORMATS, SEVERITIES, SEVERITY_RANK, load_config_file
from .timestamps import parse_offset_spec, parse_timestamp

EXIT_OK, EXIT_FAILURE, EXIT_USAGE, EXIT_PARTIAL, EXIT_FINDINGS = 0, 1, 2, 3, 4


class UsageError(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:  # type: ignore[override]
        raise UsageError(message)


def build_parser() -> argparse.ArgumentParser:
    p = _Parser(prog="log-triage", add_help=True,
                description="Analyse large log files: group recurring issues, assess severity/impact, and write JSON/SARIF/HTML/Markdown/CSV/NDJSON reports.",
                epilog="Exit codes: 0 complete, 1 processing failure, 2 invalid invocation, 3 partial analysis, 4 findings at/above --fail-on-severity.")
    p.add_argument("inputs", nargs="*", metavar="<log-path|glob>", help="log file, directory, or glob (quote paths containing spaces)")
    r = p.add_mutually_exclusive_group()
    r.add_argument("--repo", metavar="<git-root>", help="investigate one Git repository or worktree")
    r.add_argument("--repos-dir", metavar="<directory>", help="discover and investigate Git repositories beneath a directory (nested organisational folders included)")
    p.add_argument("--format", action="append", metavar="auto|json|sarif|html|markdown|csv|ndjson", dest="formats",
                   help="report format; repeatable. Default auto = json, sarif, html, markdown")
    p.add_argument("--out", default="log-triage-out", metavar="<dir>", help="output directory (default: ./log-triage-out; files are overwritten)")
    p.add_argument("--since", metavar="<ts>", help="include events at or after this ISO 8601 timestamp (naive values use --assume-tz)")
    p.add_argument("--min-severity", default="info", choices=SEVERITIES, help="report groups at or above this assessed severity (default: info)")
    p.add_argument("--input-format", metavar="<name>", help="override input format detection (parser name, or text:<layout>); see --list-formats")
    p.add_argument("--fallback-format", default="text", metavar="<name>", help="parser used when detection confidence is low (default: text)")
    p.add_argument("--assume-tz", default="UTC", metavar="<tz>", help="time zone for naive timestamps: UTC, local, or +HH:MM (default: UTC)")
    p.add_argument("--keep-untimed", action="store_true", help="with --since, keep events that have no timestamp instead of excluding them")
    p.add_argument("--no-redact", action="store_true", help="disable secret redaction (not recommended)")
    p.add_argument("--redact-ips", action="store_true", help="pseudonymize IPv4 addresses too")
    p.add_argument("--redaction-salt", metavar="<salt>", help="salt for stable pseudonyms across runs (default: random per run)")
    p.add_argument("--temp-dir", metavar="<dir>", help="directory for temporary spill files (default: system temp)")
    p.add_argument("--keep-temp", action="store_true", help="keep the temporary directory after the run")
    p.add_argument("--fail-on-severity", choices=SEVERITIES, help="exit 4 when any reported group is at or above this severity")
    p.add_argument("--follow-symlinks", action="store_true", help="follow directory symlinks during input and repository traversal")
    p.add_argument("--include-nested-repos", action="store_true", help="with --repos-dir, also discover repositories nested inside repositories (submodules)")
    p.add_argument("--config", metavar="<file.json>", help="JSON object of limit overrides (keys as in --limit)")
    p.add_argument("--limit", action="append", default=[], metavar="NAME=VALUE", help="override a resource/report limit, for example max_examples_per_group=5 (repeatable); see --list-limits")
    p.add_argument("--max-examples", type=int, metavar="N", help="examples retained per group (limit max_examples_per_group)")
    p.add_argument("--max-report-groups", type=int, metavar="N", help="groups detailed in HTML/Markdown (limit max_report_groups)")
    p.add_argument("--max-groups-in-memory", type=int, metavar="N", help="spill threshold (limit max_groups_in_memory)")
    p.add_argument("--max-record-bytes", type=int, metavar="N", help="retained bytes per logical record (limit max_record_bytes)")
    p.add_argument("--max-line-bytes", type=int, metavar="N", help="physical line cap (limit max_line_bytes)")
    p.add_argument("--input-list", metavar="<file>", help="file with one input path/glob per line (in addition to positional inputs)")
    p.add_argument("--render", metavar="<analysis.json>", help="render reports from an existing analysis document instead of analysing logs")
    p.add_argument("--suggestions", metavar="<file.json>", help="with --render: merge model-refined suggestions/root causes into the reports")
    p.add_argument("--now", metavar="<ts>", help="reference time for year inference and generated_at (tests/determinism)")
    p.add_argument("--quiet", action="store_true", help="no progress output on stderr")
    p.add_argument("--verbose", action="store_true", help="print parser tracebacks on stderr")
    p.add_argument("--version", action="store_true", help="print version information and exit")
    p.add_argument("--list-formats", action="store_true", help="list input parsers, text layouts and report formats, then exit")
    p.add_argument("--list-limits", action="store_true", help="list configurable limits with their defaults, then exit")
    p.add_argument("--support-matrix", action="store_true", help="print the format support matrix (Markdown) derived from the implementation, then exit")
    return p


def _parse_formats(values: Optional[List[str]]) -> List[str]:
    if not values:
        return list(AUTO_FORMATS)
    chosen: List[str] = []
    for v in values:
        for item in v.split(","):
            item = item.strip().lower()
            if not item:
                continue
            if item == "md":
                item = "markdown"
            if item != "auto" and item not in REPORT_FORMATS:
                raise UsageError("unsupported --format %r (supported: auto, %s)" % (item, ", ".join(REPORT_FORMATS)))
            chosen.append(item)
    if "auto" in chosen:
        if len(chosen) > 1:
            raise UsageError("--format auto cannot be combined with explicit formats (%s)" % ", ".join(c for c in chosen if c != "auto"))
        return list(AUTO_FORMATS)
    out: List[str] = []
    for c in chosen:
        if c not in out:
            out.append(c)
    return out


def build_options(ns: argparse.Namespace) -> Options:
    limits = Limits()
    if ns.config:
        try:
            limits.apply(load_config_file(ns.config), "--config %s" % ns.config)
        except (OSError, ValueError) as exc:
            raise UsageError("cannot load --config: %s" % exc)
    overrides: Dict[str, Any] = {}
    for item in ns.limit:
        if "=" not in item:
            raise UsageError("--limit expects KEY=VALUE, got %r" % item)
        k, v = item.split("=", 1)
        overrides[k.strip()] = v.strip()
    for key, val in (("max_examples_per_group", ns.max_examples), ("max_report_groups", ns.max_report_groups),
                     ("max_groups_in_memory", ns.max_groups_in_memory), ("max_record_bytes", ns.max_record_bytes),
                     ("max_line_bytes", ns.max_line_bytes)):
        if val is not None:
            overrides[key] = val
    try:
        limits.apply(overrides, "--limit")
    except ValueError as exc:
        raise UsageError(str(exc))
    opts = Options(limits=limits)
    inputs = list(ns.inputs or [])
    if ns.input_list:
        try:
            with open(ns.input_list, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        inputs.append(line)
        except OSError as exc:
            raise UsageError("cannot read --input-list: %s" % exc)
    opts.inputs = inputs
    opts.repo = ns.repo
    opts.repos_dir = ns.repos_dir
    opts.formats = _parse_formats(ns.formats)
    opts.formats_explicit = bool(ns.formats)
    opts.out_dir = ns.out
    opts.min_severity = ns.min_severity
    opts.input_format = ns.input_format
    opts.fallback_format = ns.fallback_format
    opts.keep_untimed = ns.keep_untimed
    opts.redact = not ns.no_redact
    opts.redact_ips = ns.redact_ips
    opts.redaction_salt = ns.redaction_salt
    opts.temp_dir = ns.temp_dir
    opts.keep_temp = ns.keep_temp
    opts.fail_on_severity = ns.fail_on_severity
    opts.follow_symlinks = ns.follow_symlinks
    opts.include_nested_repos = ns.include_nested_repos
    opts.quiet = ns.quiet
    opts.verbose = ns.verbose
    opts.render_from = ns.render
    opts.suggestions_file = ns.suggestions
    try:
        opts.assume_tz = ns.assume_tz
        opts.assume_tz_offset_seconds = parse_offset_spec(ns.assume_tz)
    except ValueError as exc:
        raise UsageError(str(exc))
    if ns.now:
        ts, flags = parse_timestamp(ns.now, 0)
        if ts is None:
            raise UsageError("--now is not an ISO 8601 timestamp: %r" % ns.now)
        opts.now_epoch = ts
    if ns.since:
        ts, flags = parse_timestamp(ns.since, opts.assume_tz_offset_seconds, opts.now_epoch)
        if ts is None or "year_inferred" in flags:
            raise UsageError("--since must be an ISO 8601 timestamp (e.g. 2026-09-13T12:00:00Z or 2026-09-13), got %r" % ns.since)
        opts.since = ns.since
        opts.since_epoch = ts
    if ns.input_format:
        from .parsers import parser_names
        from .parsers.text import layout_ids
        name = ns.input_format
        if name.startswith("text:"):
            if name.split(":", 1)[1] not in layout_ids():
                raise UsageError("unknown text layout %r (see --list-formats)" % name.split(":", 1)[1])
        elif name not in parser_names():
            raise UsageError("unknown --input-format %r (see --list-formats)" % name)
    if ns.fallback_format != "text":
        from .parsers import parser_names
        if ns.fallback_format not in parser_names():
            raise UsageError("unknown --fallback-format %r" % ns.fallback_format)
    if opts.render_from:
        if not os.path.isfile(opts.render_from):
            raise UsageError("--render file not found: %s" % opts.render_from)
        if opts.suggestions_file and not os.path.isfile(opts.suggestions_file):
            raise UsageError("--suggestions file not found: %s" % opts.suggestions_file)
        if opts.inputs:
            raise UsageError("--render does not take log inputs")
        if not ns.formats:
            opts.formats = ["html", "markdown"]
    else:
        if opts.suggestions_file:
            raise UsageError("--suggestions requires --render")
        if not opts.inputs:
            raise UsageError("no input given: pass a log file, directory or glob (or --render <analysis.json>)")
    return opts


def _list_formats() -> str:
    from .parsers import parser_names
    from .parsers.text import LAYOUTS
    lines = ["Input parsers (--input-format):"]
    for n in parser_names():
        lines.append("  " + n)
    lines.append("Text layouts (--input-format text:<layout>):")
    for l in LAYOUTS:
        lines.append("  %-22s %s (%s)" % (l.id, l.family, l.ecosystem))
    lines.append("Report formats (--format): auto, " + ", ".join(REPORT_FORMATS))
    return "\n".join(lines) + "\n"


def _list_limits() -> str:
    lim = Limits()
    return "\n".join("%-32s %d" % (k, v) for k, v in lim.as_dict().items()) + "\n"


def compute_exit_code(analysis, options: Options, export_failures: int, exports_written: int) -> int:
    status = analysis.meta.get("status", {})
    completion = status.get("completion")
    if completion == "failed" or (export_failures and not exports_written):
        return EXIT_FAILURE
    if options.fail_on_severity:
        threshold = SEVERITY_RANK[options.fail_on_severity]
        by = analysis.meta.get("filtering", {}).get("by_severity", {})
        hit = any(v.get("groups", 0) for k, v in by.items() if SEVERITY_RANK.get(k, 0) >= threshold and SEVERITY_RANK.get(k, 0) >= analysis.min_rank)
        if analysis._override_groups is not None:
            hit = any(SEVERITY_RANK.get(g.get("severity", "info"), 0) >= threshold for g in analysis.groups())
        if hit:
            return EXIT_FINDINGS
    if completion == "partial" or export_failures:
        return EXIT_PARTIAL
    return EXIT_OK


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    try:
        ns = parser.parse_args(argv)
    except UsageError as exc:
        sys.stderr.write("log-triage: error: %s\n" % exc)
        sys.stderr.write("Run with --help for usage.\n")
        return EXIT_USAGE
    if ns.version:
        sys.stdout.write("%s %s (schema %s, fingerprint v%s)\n" % (TOOL_NAME, TOOL_VERSION, SCHEMA_VERSION, FINGERPRINT_VERSION))
        return EXIT_OK
    if ns.list_formats:
        sys.stdout.write(_list_formats())
        return EXIT_OK
    if ns.list_limits:
        sys.stdout.write(_list_limits())
        return EXIT_OK
    if ns.support_matrix:
        from .supportmatrix import render
        sys.stdout.write(render())
        return EXIT_OK
    try:
        options = build_options(ns)
    except UsageError as exc:
        sys.stderr.write("log-triage: error: %s\n" % exc)
        return EXIT_USAGE

    from .engine import cleanup, run_analysis
    from .exporters import registry
    started = time.time()
    if options.render_from:
        from .render import build_render_analysis
        try:
            analysis = build_render_analysis(options, options.render_from, options.suggestions_file)
        except (OSError, ValueError) as exc:
            sys.stderr.write("log-triage: error: cannot render: %s\n" % exc)
            return EXIT_FAILURE
    else:
        try:
            analysis = run_analysis(options)
        except (OSError, ValueError) as exc:
            sys.stderr.write("log-triage: error: %s\n" % exc)
            return EXIT_FAILURE
    try:
        if not analysis.inputs.files and not options.render_from and analysis.inputs.unmatched and not analysis.inputs.excluded:
            sys.stderr.write("log-triage: error: no input file matched: %s\n" % ", ".join(analysis.inputs.unmatched))
            return EXIT_USAGE
        try:
            os.makedirs(options.out_dir, exist_ok=True)
        except OSError as exc:
            sys.stderr.write("log-triage: error: cannot create output directory %s: %s\n" % (options.out_dir, exc))
            return EXIT_FAILURE
        # exit code is embedded in the JSON status; compute the provisional code first (without export failures)
        provisional = compute_exit_code(analysis, options, 0, 1)
        analysis.meta["status"]["exit_code"] = provisional
        written: List[str] = []
        failures: List[str] = []
        exporters = registry()
        for fmt in options.formats:
            exp = exporters[fmt](options)
            try:
                written.extend(exp.write(analysis, options.out_dir))
            except OSError as exc:
                failures.append("%s: %s" % (fmt, exc))
                sys.stderr.write("log-triage: error: writing %s output failed: %s\n" % (fmt, exc))
                if getattr(exc, "errno", None) in (28, 122):
                    sys.stderr.write("log-triage: output disk is full; remaining formats skipped\n")
                    break
        code = compute_exit_code(analysis, options, len(failures), len(written))
        if failures and code == EXIT_OK:
            code = EXIT_PARTIAL
        analysis.meta["status"]["exit_code"] = code
        if failures:
            analysis.meta["status"]["reasons"] = analysis.meta["status"].get("reasons", []) + ["output write failed: " + "; ".join(failures)]
        _print_summary(analysis, options, written, failures, code, time.time() - started)
        return code
    finally:
        if not options.render_from:
            cleanup(analysis, options)


def _print_summary(analysis, options: Options, written: List[str], failures: List[str], code: int, elapsed: float) -> None:
    meta = analysis.meta
    status = meta.get("status", {})
    cov = meta.get("coverage", {})
    filt = meta.get("filtering", {})
    summ = meta.get("summary", {})
    out = sys.stdout
    out.write("log-triage %s: %s (exit %d) in %.1fs\n" % (TOOL_VERSION, status.get("completion"), code, elapsed))
    if not options.render_from:
        out.write("  inputs: %s files, %s bytes; events: %s parsed, %s included; groups: %s total, %s reported (>= %s)\n" % (
            len(meta.get("inputs", {}).get("files", [])), cov.get("bytes_read", 0), cov.get("events_parsed", 0), cov.get("events_included", 0),
            filt.get("groups_total", 0), filt.get("groups_reported", 0), filt.get("min_severity")))
        by = summ.get("counts_by_severity", {})
        out.write("  by severity: %s\n" % ", ".join("%s=%s" % (s, by.get(s, {}).get("groups", 0)) for s in reversed(SEVERITIES)))
        for t in summ.get("top_findings", [])[:5]:
            out.write("  %s %-8s %-20s x%-6d %s\n" % (t["id"], t["severity"], t["category"], t["count"], t["template"][:80]))
        if status.get("reasons"):
            out.write("  partial/limitations:\n")
            for r in status["reasons"][:10]:
                out.write("    - %s\n" % r)
        q = meta.get("investigation_queue") or []
        if q:
            out.write("  investigation queue: %d group(s) with source references ready for model refinement (analysis.json: investigation_queue)\n" % len(q))
    else:
        mr = status.get("model_refinement")
        if mr:
            out.write("  model suggestions applied to %s group(s); unknown ids: %s\n" % (mr.get("applied"), mr.get("unknown_ids")))
    out.write("  outputs: %s\n" % ", ".join(written) if written else "  outputs: none\n")
    if failures:
        out.write("  failed outputs: %s\n" % "; ".join(failures))
