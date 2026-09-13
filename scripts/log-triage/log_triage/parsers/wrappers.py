"""Line-oriented wrapper formats: Kubernetes CRI, logfmt, Apple crash reports; plus the
``syslog`` and ``access-log`` parser names (text-engine layout families)."""
from __future__ import annotations

import re
from typing import Any, Dict, Iterator, List, Optional, Tuple

from ..model import Event, ExceptionInfo
from .base import BaseParser, Lines, ParseContext, set_ts
from .exceptions import parse_exception_block
from .nested import NestedSink, make_base
from .text import family_sniff, make_parser as make_text_parser

_CRI_RE = re.compile(r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})) (?P<stream>stdout|stderr) (?P<tag>[PF]) (?P<msg>.*)$")
_LOGFMT_LINE = re.compile(r'^(?:[A-Za-z_][\w.\-/]*=(?:"(?:[^"\\]|\\.)*"|\S*)\s*)+$')
_LOGFMT_PAIR = re.compile(r'([A-Za-z_][\w.\-/]*)=("(?:[^"\\]|\\.)*"|\S*)')
_APPLE_START = re.compile(r"^(?:Incident Identifier|Process):\s+")
_APPLE_KV = re.compile(r"^(?P<key>[A-Za-z][A-Za-z /-]{1,30}):\s+(?P<val>.*)$")


def sniff(name: str, sample, ctx) -> float:
    lines = [ln for ln in sample.lines if ln.strip()]
    if not lines:
        return 0.0
    if name == "cri":
        hits = sum(1 for ln in lines if _CRI_RE.match(ln))
        frac = hits / float(len(lines))
        return 0.97 * frac if frac >= 0.6 else 0.0
    if name == "logfmt":
        hits = sum(1 for ln in lines if _LOGFMT_LINE.match(ln) and "=" in ln)
        frac = hits / float(len(lines))
        return 0.92 * frac if frac >= 0.6 else 0.0
    if name == "apple-crash":
        head = "\n".join(lines[:40])
        score = 0.0
        for marker in ("Incident Identifier:", "Exception Type:", "Thread 0 Crashed", "Crashed Thread:", "Hardware Model:",
                       "OS Version:", "Report Version:", "Code Type:"):
            if marker in head:
                score += 0.2
        return min(0.97, score) if score >= 0.4 else 0.0
    if name in ("syslog", "access-log"):
        return family_sniff(name, sample)
    return 0.0


class CriParser(BaseParser):
    """Kubernetes CRI log format with partial (P) / full (F) record reconstruction."""

    family = "wrapper"
    name = "cri"

    def parse(self, lines: Lines, ctx: ParseContext) -> Iterator[Event]:
        from .structured import StructuredParser
        mapper_parser = StructuredParser("cri")
        sink = NestedSink(ctx, "cri", lambda obj, c, ln, off, base: mapper_parser._record_event(obj, c, ln, off, None, base_meta=base))
        ctx.layout = "cri"
        partial: List[str] = []
        partial_start: Optional[Tuple[int, int, str, str]] = None   # (line, offset, ts, stream)
        partial_bytes = 0
        dropped = 0
        for line_no, offset, text, truncated in lines:
            m = _CRI_RE.match(text)
            if not m:
                if not text.strip():
                    continue
                ctx.failure("cri-malformed-line", "line %d does not match the CRI format; parsed as text" % line_no, line_no)
                for ev in sink.feed_text(text, make_base(None, (), {}), line_no, offset):
                    yield ev
                continue
            ts, flags = ctx.ts(m.group("ts"))
            stream, tag, msg = m.group("stream"), m.group("tag"), m.group("msg")
            if tag == "P":
                if partial_start is None:
                    partial_start = (line_no, offset, m.group("ts"), stream)
                    partial = []
                    partial_bytes = 0
                if partial_bytes + len(msg) <= ctx.limits.max_record_bytes:
                    partial.append(msg)
                    partial_bytes += len(msg)
                else:
                    dropped += 1
                continue
            # F: full line (possibly completing a partial sequence)
            if partial_start is not None:
                partial.append(msg)
                full = "".join(partial)
                start_line, start_offset, ts_text, stream0 = partial_start
                ts0, flags0 = ctx.ts(ts_text)
                partial_start = None
                partial = []
                if dropped:
                    ctx.diag("cri-partial-oversized", "warning", "partial record starting at line %d exceeded max_record_bytes; %d fragment(s) dropped" % (start_line, dropped), start_line)
                    dropped = 0
                base = make_base(ts0, flags0, {"stream": stream0})
                for ev in sink.feed_text(full, base, start_line, start_offset):
                    yield ev
                continue
            base = make_base(ts, flags, {"stream": stream})
            for ev in sink.feed_text(msg, base, line_no, offset):
                yield ev
        if partial_start is not None:
            start_line, start_offset, ts_text, stream0 = partial_start
            ctx.diag("cri-partial-unterminated", "warning", "partial (P) record starting at line %d was never completed by an F line; emitted as-is" % start_line, start_line)
            ts0, flags0 = ctx.ts(ts_text)
            for ev in sink.feed_text("".join(partial), make_base(ts0, flags0, {"stream": stream0, "cri.unterminated": True}), start_line, start_offset):
                yield ev
        for ev in sink.flush():
            yield ev


class LogfmtParser(BaseParser):
    family = "wrapper"
    name = "logfmt"

    def parse(self, lines: Lines, ctx: ParseContext) -> Iterator[Event]:
        from .structured import StructuredParser
        mapper = StructuredParser("logfmt")
        sink = NestedSink(ctx, "logfmt", None)
        ctx.layout = "logfmt"
        for line_no, offset, text, truncated in lines:
            st = text.strip()
            if not st:
                continue
            if not _LOGFMT_LINE.match(st) or "=" not in st:
                ctx.failure("logfmt-malformed-line", "line %d is not logfmt; parsed as text" % line_no, line_no)
                for ev in sink.feed_text(text, make_base(None, (), {}), line_no, offset):
                    yield ev
                continue
            for ev in sink.flush():
                yield ev
            rec: Dict[str, Any] = {}
            for k, v in _LOGFMT_PAIR.findall(st):
                if v.startswith('"') and v.endswith('"') and len(v) >= 2:
                    v = re.sub(r'\\(.)', r'\1', v[1:-1])
                if len(rec) < ctx.limits.max_attributes_per_event + 16:
                    rec[k] = v
            ev = mapper._record_event(rec, ctx, line_no, offset, None, "generic-json")
            if ev is not None:
                ev.parser = "logfmt"
                ev.layout = "logfmt"
                if truncated:
                    ev.truncated = True
                yield ev
        for ev in sink.flush():
            yield ev


class AppleCrashParser(BaseParser):
    """Apple text crash reports (.crash and translated .ips): one event per report."""

    family = "wrapper"
    name = "apple-crash"

    def parse(self, lines: Lines, ctx: ParseContext) -> Iterator[Event]:
        ctx.layout = "apple-crash"
        block: List[str] = []
        block_bytes = 0
        start: Optional[Tuple[int, int]] = None
        seen_exception = False
        for line_no, offset, text, truncated in lines:
            starts = _APPLE_START.match(text) is not None
            if starts and (start is None or (seen_exception and text.startswith("Process:")) or text.startswith("Incident Identifier:")):
                if start is not None and block:
                    ev = self._report(block, start, ctx)
                    if ev is not None:
                        yield ev
                block = []
                block_bytes = 0
                start = (line_no, offset)
                seen_exception = False
            if start is None:
                start = (line_no, offset)
            if len(block) < ctx.limits.max_multiline_lines and block_bytes < ctx.limits.max_record_bytes:
                block.append(text)
                block_bytes += len(text)
            if text.startswith("Exception Type:") or text.startswith("Crashed Thread:"):
                seen_exception = True
        if start is not None and block:
            ev = self._report(block, start, ctx)
            if ev is not None:
                yield ev

    def _report(self, block: List[str], start: Tuple[int, int], ctx: ParseContext) -> Optional[Event]:
        limits = ctx.limits
        ev = ctx.new_event(self.name, start[0], start[1])
        ev.layout = "apple-crash"
        ev.line_end = start[0] + len(block) - 1
        meta: Dict[str, str] = {}
        for ln in block[:40]:
            m = _APPLE_KV.match(ln)
            if m:
                meta.setdefault(m.group("key").strip(), m.group("val").strip())
        ts_text = meta.get("Date/Time")
        if ts_text:
            # "2026-09-13 12:00:00.123 +0200" -> normalise the space before the offset
            set_ts(ev, ctx, re.sub(r" ([+-]\d{4})$", r"\1", ts_text))
        proc = meta.get("Process", "")
        ev.process = re.sub(r"\s*\[\d+\]$", "", proc) or None
        ev.app = meta.get("Identifier") or ev.process
        for k in ("Version", "OS Version", "Hardware Model", "Code Type", "Role", "Incident Identifier", "Crashed Thread"):
            if meta.get(k):
                ev.add_attr(k.lower().replace(" ", "_"), meta[k], limits)
        excs, hint = parse_exception_block(block, None, limits.max_frames)
        excs = [e for e in excs if e.type and (e.type.startswith("EXC_") or "SIG" in e.type or e.frames)] or excs
        ev.exceptions = excs[:3]
        ev.category_hint = "application_crash"
        ev.set_level("fatal")
        head = excs[0] if excs else None
        typ = head.type if head else meta.get("Exception Type", "crash")
        ev.message = "%s crashed: %s" % (ev.process or "process", typ)
        if head is None:
            ev.exceptions = [ExceptionInfo(meta.get("Exception Type"), meta.get("Exception Codes"))]
        ev.bound(limits)
        return ev


def make_parser(name: str):
    if name == "cri":
        return CriParser()
    if name == "logfmt":
        return LogfmtParser()
    if name == "apple-crash":
        return AppleCrashParser()
    return make_text_parser(name)
