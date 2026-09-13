"""CSV / TSV (RFC 4180 quoting, embedded newlines) and IIS W3C Extended logs."""
from __future__ import annotations

import csv
import re
from typing import Any, Dict, Iterator, List, Optional, Tuple

from ..model import Event, level_from_text
from .base import BaseParser, Lines, ParseContext, set_ts
from .exceptions import parse_exception_block
from .text import _HTTP_STATUS_RE, _promote_attrs

_TS_COLS = ("timestamp", "time", "date", "datetime", "@timestamp", "ts", "timegenerated", "eventtime", "event_time",
            "logged_at", "created", "created_at", "log_time", "log_date", "when", "occurred_at", "timeutc", "utc_time")
_LEVEL_COLS = ("level", "severity", "loglevel", "log_level", "levelname", "priority", "lvl", "type", "eventtype", "severitylevel")
_MSG_COLS = ("message", "msg", "text", "log", "description", "event", "details", "detail", "body", "content", "summary",
             "rendereddescription", "logmessage", "error_message")
_LOGGER_COLS = ("logger", "source", "category", "component", "module", "channel", "class", "origin", "provider")
_SERVICE_COLS = ("service", "app", "application", "appname", "program", "container", "unit", "job", "service_name")
_HOST_COLS = ("host", "hostname", "computer", "machine", "node", "server", "instance")
_EXC_COLS = ("exception", "stack_trace", "stacktrace", "stack", "error", "traceback", "exc_info", "errordetails")
_REQ_COLS = ("request_id", "requestid", "correlation_id", "correlationid", "trace_id", "traceid", "operation_id")
_STATUS_COLS = ("status", "statuscode", "status_code", "sc-status", "http_status", "response_code", "resultcode")
_METHOD_COLS = ("method", "cs-method", "http_method", "verb")
_PATH_COLS = ("path", "url", "uri", "cs-uri-stem", "request", "endpoint", "route")
_LOOKS_TS = re.compile(r"^\s*(?:\d{4}-\d{2}-\d{2}|\d{2}/\d{2}/\d{4}|\d{10,13}\b|[A-Z][a-z]{2} \d{1,2})")


def _norm(name: str) -> str:
    return name.strip().strip('"').lower().replace(" ", "_")


def _looks_like_header(row: List[str]) -> bool:
    if not row or len(row) < 2:
        return False
    for cell in row:
        c = cell.strip()
        if not c or _LOOKS_TS.match(c) or c.isdigit() or len(c) > 64:
            return False
    return True


def _sniff_delimiter(lines: List[str]) -> Tuple[Optional[str], float]:
    """Pick the delimiter whose *logical* rows (quoted newlines respected) have the most consistent
    column count. Requires >= 3 columns so ordinary log lines with a comma (log4j millis) never qualify."""
    import io
    best: Tuple[Optional[str], float] = (None, 0.0)
    text = "\n".join(ln for ln in lines if ln.strip())
    if text.count("\n") < 1:
        return best
    for delim in ("\t", ",", ";", "|"):
        counts: List[int] = []
        try:
            for row in csv.reader(io.StringIO(text), delimiter=delim):
                if row and any(c.strip() for c in row):
                    counts.append(len(row))
                if len(counts) >= 64:
                    break
        except csv.Error:
            continue
        if len(counts) < 2:
            continue
        expected = counts[0]
        if expected < 3:
            continue
        consistent = sum(1 for c in counts if c == expected)
        frac = consistent / float(len(counts))
        if frac > best[1]:
            best = (delim, frac)
    return best


def sniff(name: str, sample, ctx) -> float:
    lines = sample.lines
    if not lines:
        return 0.0
    if name == "iis-w3c":
        head = "\n".join(lines[:8])
        if "#Fields:" in head and ("#Software:" in head or "#Version:" in head or "#Date:" in head):
            return 0.98
        return 0.0
    first = lines[0].lstrip()
    if first[:1] in ("{", "[", "<"):
        return 0.0
    delim, frac = _sniff_delimiter(lines)
    if delim is None or frac < 0.7:
        return 0.0
    try:
        header = next(csv.reader([lines[0]], delimiter=delim))
    except csv.Error:
        return 0.0
    header_ok = _looks_like_header(header)
    known = sum(1 for h in header if _norm(h) in _TS_COLS + _LEVEL_COLS + _MSG_COLS)
    if name == "tsv":
        if delim != "\t":
            return 0.0
        return 0.9 if header_ok and known else (0.6 if header_ok or frac >= 0.9 else 0.0)
    if name == "csv":
        if delim == "\t":
            return 0.0
        if header_ok and known:
            return 0.9
        if header_ok and frac >= 0.9:
            return 0.65
        return 0.0
    return 0.0


class _LineFeed:
    """Adapts the (line_no, offset, text, truncated) stream to what csv.reader expects and
    tracks the physical line where each logical record starts."""

    def __init__(self, lines: Lines):
        self._it = iter(lines)
        self.line_no = 0
        self.offset = 0
        self.truncated = False

    def __iter__(self):
        return self

    def __next__(self):
        line_no, offset, text, truncated = next(self._it)
        self.line_no, self.offset, self.truncated = line_no, offset, truncated or self.truncated
        return text + "\n"


class TabularParser(BaseParser):
    family = "tabular"

    def __init__(self, name: str = "csv"):
        super().__init__(name)

    def _map_columns(self, header: List[str]) -> Dict[str, int]:
        cols = {}
        normalized = [_norm(h) for h in header]
        for group, names in (("ts", _TS_COLS), ("level", _LEVEL_COLS), ("msg", _MSG_COLS), ("logger", _LOGGER_COLS),
                             ("service", _SERVICE_COLS), ("host", _HOST_COLS), ("exc", _EXC_COLS), ("req", _REQ_COLS),
                             ("status", _STATUS_COLS), ("method", _METHOD_COLS), ("path", _PATH_COLS)):
            for i, n in enumerate(normalized):
                if n in names and group not in cols:
                    cols[group] = i
        if "ts" not in cols:
            di = next((i for i, n in enumerate(normalized) if n == "date"), None)
            if di is not None:
                cols["ts"] = di
        ti = next((i for i, n in enumerate(normalized) if n == "time"), None)
        if ti is not None and cols.get("ts") is not None and cols["ts"] != ti and normalized[cols["ts"]] == "date":
            cols["time"] = ti
        return cols

    def parse(self, lines: Lines, ctx: ParseContext) -> Iterator[Event]:
        limits = ctx.limits
        feed = _LineFeed(lines)
        # peek the first line for delimiter/header
        try:
            first = next(feed)
        except StopIteration:
            return
        delim = "\t" if self.name == "tsv" else None
        if delim is None:
            d, _ = _sniff_delimiter([first.rstrip("\n")])
            delim = d if d in (",", ";", "|") else ","
            if d is None:
                delim = ","
        header_row = next(csv.reader([first], delimiter=delim))
        has_header = _looks_like_header(header_row)
        cols = self._map_columns(header_row) if has_header else {}
        header = [_norm(h) for h in header_row] if has_header else []
        ctx.layout = "%s%s" % ("csv" if delim != "\t" else "tsv", " (header)" if has_header else " (no header)")
        ctx.dialect = "delimiter=%r columns=%d" % (delim, len(header_row))
        if not has_header:
            ctx.diag("csv-header-missing", "warning",
                     "first row does not look like a header; columns mapped heuristically (timestamp/level/message by content)")

        def _rows():
            if not has_header:
                yield first
            for ln in feed:
                yield ln

        reader = csv.reader(_rows(), delimiter=delim)
        expected = len(header_row)
        mismatch = 0
        last_end = 1 if has_header else 0
        while True:
            start_line = last_end + 1
            start_offset = feed.offset
            try:
                row = next(reader)
            except StopIteration:
                break
            except csv.Error as exc:
                ctx.failure("malformed-csv-row", "row starting at line %d could not be parsed: %s" % (start_line, exc), start_line)
                last_end = max(feed.line_no, start_line)
                continue
            last_end = max(feed.line_no, start_line)
            if not row or all(not c.strip() for c in row):
                continue
            if expected and len(row) != expected:
                mismatch += 1
                ctx.diag("csv-column-count", "warning", "row at line %d has %d column(s), header has %d" % (start_line, len(row), expected), start_line)
            ev = self._row_event(row, header, cols, ctx, start_line, start_offset, has_header)
            if ev is not None:
                yield ev

    def _row_event(self, row: List[str], header: List[str], cols: Dict[str, int], ctx: ParseContext, line_no: int,
                   offset: int, has_header: bool) -> Optional[Event]:
        limits = ctx.limits
        ev = ctx.new_event(self.name, line_no, offset)
        ev.layout = "csv" if self.name != "tsv" else "tsv"

        def cell(group: str) -> Optional[str]:
            i = cols.get(group)
            if i is None or i >= len(row):
                return None
            v = row[i]
            return v if v != "" else None

        if has_header:
            ts_text = cell("ts")
            if ts_text and cols.get("time") is not None and cols["time"] < len(row):
                ts_text = ts_text + " " + row[cols["time"]]
            if ts_text is not None:
                set_ts(ev, ctx, ts_text)
            lvl = cell("level")
            if lvl and level_from_text(lvl) is not None:
                ev.set_level(lvl)
            elif lvl:
                ev.add_attr("level_text", lvl, limits)
            msg = cell("msg")
            if msg is None and cols.get("msg") is not None and cols["msg"] >= len(row):
                msg = " ".join(c for c in row if c)   # short row: keep its content visible
            ev.logger = cell("logger")
            ev.service = cell("service")
            ev.host = cell("host")
            ev.request_id = cell("req")
            st = cell("status")
            if st and st.isdigit() and 100 <= int(st) <= 599:
                ev.http_status = int(st)
            ev.http_method = cell("method")
            ev.http_path = cell("path")
            exc = cell("exc")
            used = set(cols.values())
            for i, h in enumerate(header):
                if i in used or i >= len(row) or not row[i]:
                    continue
                ev.add_attr(h, row[i], limits)
        else:
            msg = None
            exc = None
            for i, v in enumerate(row):
                if ev.ts is None and not ev.ts_flags and _LOOKS_TS.match(v):
                    set_ts(ev, ctx, v)
                    if ev.ts is not None:
                        continue
                if ev.level_num is None and level_from_text(v) is not None and len(v) <= 12:
                    ev.set_level(v)
                    continue
                if msg is None or len(v) > len(msg):
                    if msg is not None:
                        ev.add_attr("col%d" % i, msg, limits)
                    msg = v
                else:
                    ev.add_attr("col%d" % i, v, limits)
        msg = (msg or "").rstrip()
        if "\n" in msg:
            lines = msg.split("\n")
            excs, hint = parse_exception_block(lines[1:], lines[0], limits.max_frames)
            if excs:
                ev.exceptions = excs
                ev.category_hint = hint
            msg = lines[0]
        if exc:
            elines = exc.split("\n")
            excs, hint = parse_exception_block(elines[1:], elines[0], limits.max_frames)
            if excs:
                ev.exceptions = ev.exceptions or excs
                ev.category_hint = ev.category_hint or hint
            elif not ev.exceptions:
                from ..model import ExceptionInfo
                ev.exceptions = [ExceptionInfo(None, exc[:1000])]
        if not msg and ev.exceptions:
            h = ev.exceptions[0]
            msg = (h.type or "error") + ((": " + h.message) if h.message else "")
        ev.message = msg
        if ev.http_status is None:
            hm = _HTTP_STATUS_RE.search(msg)
            if hm:
                ev.http_status = int(hm.group(1))
        _promote_attrs(ev)
        if ev.level_num is None and ev.exceptions:
            ev.set_level("error")
        ev.bound(limits)
        return ev


_IIS_DIRECTIVE = re.compile(r"^#(?P<directive>Software|Version|Date|Fields|Remark): ?(?P<val>.*)$")


class IisW3cParser(BaseParser):
    family = "tabular"
    name = "iis-w3c"

    def parse(self, lines: Lines, ctx: ParseContext) -> Iterator[Event]:
        limits = ctx.limits
        fields: List[str] = []
        ctx.layout = "iis-w3c"
        for line_no, offset, text, truncated in lines:
            if not text.strip():
                continue
            if text.startswith("#"):
                m = _IIS_DIRECTIVE.match(text.rstrip())
                if m and m.group("directive") == "Fields":
                    fields = m.group("val").split()
                    ctx.dialect = "fields=%d" % len(fields)
                elif m and m.group("directive") == "Software":
                    ctx.dialect = (ctx.dialect or "") + " " + m.group("val").strip()
                continue
            if not fields:
                ctx.failure("iis-fields-missing", "data line %d before any #Fields directive" % line_no, line_no)
                continue
            values = text.rstrip().split(" ")
            if len(values) != len(fields):
                ctx.diag("iis-field-count", "warning", "line %d has %d value(s), #Fields declares %d" % (line_no, len(values), len(fields)), line_no)
            rec = {}
            for i, name in enumerate(fields):
                if i < len(values):
                    rec[name] = values[i] if values[i] != "-" else None
            ev = ctx.new_event(self.name, line_no, offset)
            ev.layout = "iis-w3c"
            date, time_ = rec.get("date"), rec.get("time")
            if date and time_:
                set_ts(ev, ctx, "%sT%sZ" % (date, time_))   # W3C extended logs are UTC by specification
            elif date or time_:
                set_ts(ev, ctx, date or time_)
            status = rec.get("sc-status")
            st = int(status) if status and status.isdigit() else None
            ev.http_status = st
            ev.http_method = rec.get("cs-method")
            ev.http_path = (rec.get("cs-uri-stem") or "")[:300] or None
            ev.host = rec.get("s-computername") or rec.get("s-ip")
            ev.service = rec.get("s-sitename") or rec.get("cs-host")
            ev.message = "%s %s -> %s" % (ev.http_method or "?", ev.http_path or "?", st if st is not None else "?")
            if st is not None:
                ev.set_level("error" if st >= 500 else "warning" if st >= 400 else "info")
                if st >= 500:
                    ev.category_hint = "availability"
            for k in ("sc-substatus", "sc-win32-status", "time-taken", "c-ip", "cs(User-Agent)", "cs-username", "cs-uri-query",
                      "s-port", "cs(Referer)", "sc-bytes", "cs-bytes"):
                if rec.get(k) is not None:
                    ev.add_attr(k, rec[k], limits)
            if truncated:
                ev.truncated = True
            ev.bound(limits)
            yield ev


def make_parser(name: str):
    if name == "iis-w3c":
        return IisW3cParser()
    return TabularParser(name)
