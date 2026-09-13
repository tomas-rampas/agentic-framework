"""Canonical analysis model (see docs/log-triage/canonical-model.md).

Every parser normalizes its input into :class:`Event`. Fields are ``None`` /
empty when the source does not carry them. All text fields are bounded by the
configured limits *before* an event leaves the parser.
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

# OpenTelemetry-style severity numbers (1..24) used as the canonical numeric level.
LEVEL_TRACE = 1
LEVEL_DEBUG = 5
LEVEL_INFO = 9
LEVEL_NOTICE = 10
LEVEL_WARN = 13
LEVEL_ERROR = 17
LEVEL_CRITICAL = 21
LEVEL_FATAL = 21
LEVEL_ALERT = 22
LEVEL_PANIC = 23
LEVEL_EMERGENCY = 24

_LEVEL_TEXT = {
    # generic / .NET / Java / Python / Node / Go / Rust / PHP / Ruby / Elixir
    "trace": LEVEL_TRACE, "trc": LEVEL_TRACE, "verbose": LEVEL_TRACE, "vrb": LEVEL_TRACE,
    "finest": LEVEL_TRACE, "finer": LEVEL_TRACE, "fine": LEVEL_DEBUG, "config": LEVEL_DEBUG,
    "debug": LEVEL_DEBUG, "dbg": LEVEL_DEBUG, "dbug": LEVEL_DEBUG, "d": LEVEL_DEBUG,
    "info": LEVEL_INFO, "inf": LEVEL_INFO, "information": LEVEL_INFO, "informational": LEVEL_INFO,
    "i": LEVEL_INFO, "success": LEVEL_INFO, "default": LEVEL_INFO, "log": LEVEL_INFO,
    "notice": LEVEL_NOTICE, "important": LEVEL_NOTICE,
    "warn": LEVEL_WARN, "warning": LEVEL_WARN, "wrn": LEVEL_WARN, "w": LEVEL_WARN,
    "error": LEVEL_ERROR, "err": LEVEL_ERROR, "e": LEVEL_ERROR, "severe": LEVEL_ERROR,
    "fail": LEVEL_ERROR, "failure": LEVEL_ERROR, "exception": LEVEL_ERROR, "dpanic": LEVEL_ERROR,
    "critical": LEVEL_CRITICAL, "crit": LEVEL_CRITICAL, "fatal": LEVEL_FATAL, "ftl": LEVEL_FATAL,
    "f": LEVEL_FATAL, "fault": LEVEL_CRITICAL, "any": LEVEL_FATAL,
    "alert": LEVEL_ALERT, "panic": LEVEL_PANIC, "pnc": LEVEL_PANIC,
    "emergency": LEVEL_EMERGENCY, "emerg": LEVEL_EMERGENCY,
    # PHP error_log kinds
    "fatal error": LEVEL_FATAL, "parse error": LEVEL_FATAL, "deprecated": LEVEL_NOTICE,
    # Windows / Azure textual levels
    "informational": LEVEL_INFO, "logalways": LEVEL_INFO,
}

_SYSLOG_SEVERITY = {7: LEVEL_DEBUG, 6: LEVEL_INFO, 5: LEVEL_NOTICE, 4: LEVEL_WARN,
                    3: LEVEL_ERROR, 2: LEVEL_CRITICAL, 1: LEVEL_ALERT, 0: LEVEL_EMERGENCY}
_SYSLOG_TEXT = {7: "debug", 6: "info", 5: "notice", 4: "warning", 3: "err", 2: "crit",
                1: "alert", 0: "emerg"}


def level_from_text(text: Optional[str]) -> Optional[int]:
    if not text:
        return None
    key = str(text).strip().strip("[]<>:").lower()
    if key in _LEVEL_TEXT:
        return _LEVEL_TEXT[key]
    return None


def level_from_syslog(sev: int) -> Tuple[Optional[int], Optional[str]]:
    return _SYSLOG_SEVERITY.get(sev), _SYSLOG_TEXT.get(sev)


def level_from_pino(num: int) -> Optional[int]:
    # 10 trace, 20 debug, 30 info, 40 warn, 50 error, 60 fatal
    if num >= 60:
        return LEVEL_FATAL
    return {10: LEVEL_TRACE, 20: LEVEL_DEBUG, 30: LEVEL_INFO, 40: LEVEL_WARN, 50: LEVEL_ERROR}.get(
        (num // 10) * 10, LEVEL_INFO
    )


def level_from_monolog(num: int) -> Optional[int]:
    if num >= 600:
        return LEVEL_EMERGENCY
    if num >= 550:
        return LEVEL_ALERT
    if num >= 500:
        return LEVEL_CRITICAL
    if num >= 400:
        return LEVEL_ERROR
    if num >= 300:
        return LEVEL_WARN
    if num >= 250:
        return LEVEL_NOTICE
    if num >= 200:
        return LEVEL_INFO
    return LEVEL_DEBUG


def level_from_python(num: int) -> Optional[int]:
    if num >= 50:
        return LEVEL_CRITICAL
    if num >= 40:
        return LEVEL_ERROR
    if num >= 30:
        return LEVEL_WARN
    if num >= 20:
        return LEVEL_INFO
    if num >= 10:
        return LEVEL_DEBUG
    return LEVEL_TRACE


def level_from_winevt(num: int) -> Tuple[Optional[int], Optional[str]]:
    table = {1: (LEVEL_CRITICAL, "Critical"), 2: (LEVEL_ERROR, "Error"), 3: (LEVEL_WARN, "Warning"),
             4: (LEVEL_INFO, "Information"), 5: (LEVEL_TRACE, "Verbose"), 0: (LEVEL_INFO, "LogAlways")}
    return table.get(num, (None, None))


def level_from_azure_severity(num: int) -> Tuple[Optional[int], Optional[str]]:
    table = {0: (LEVEL_TRACE, "Verbose"), 1: (LEVEL_INFO, "Information"), 2: (LEVEL_WARN, "Warning"),
             3: (LEVEL_ERROR, "Error"), 4: (LEVEL_CRITICAL, "Critical")}
    return table.get(num, (None, None))


def level_class(level_num: Optional[int]) -> str:
    """Coarse class used by the timeline: fatal/error/warn/info/debug/unknown."""
    if level_num is None:
        return "unknown"
    if level_num >= LEVEL_CRITICAL:
        return "fatal"
    if level_num >= LEVEL_ERROR:
        return "error"
    if level_num >= LEVEL_WARN:
        return "warn"
    if level_num >= LEVEL_INFO:
        return "info"
    return "debug"


class Frame:
    """One stack frame. ``in_app`` is a heuristic (not framework/runtime code)."""

    __slots__ = ("function", "file", "line", "in_app", "raw")

    def __init__(self, function: Optional[str], file: Optional[str], line: Optional[int],
                 in_app: bool = True, raw: Optional[str] = None):
        self.function = function
        self.file = file
        self.line = line
        self.in_app = in_app
        self.raw = raw

    def to_dict(self) -> Dict[str, Any]:
        return {"function": self.function, "file": self.file, "line": self.line, "in_app": self.in_app}


class ExceptionInfo:
    """One exception in a cause chain (outermost first in ``Event.exceptions``)."""

    __slots__ = ("type", "message", "frames", "raw")

    def __init__(self, type_: Optional[str], message: Optional[str], frames: Optional[List[Frame]] = None,
                 raw: Optional[str] = None):
        self.type = type_
        self.message = message
        self.frames = frames or []
        self.raw = raw

    def to_dict(self) -> Dict[str, Any]:
        return {"type": self.type, "message": self.message, "frames": [f.to_dict() for f in self.frames]}


class Event:
    """Canonical log event. See docs/log-triage/canonical-model.md for field semantics."""

    __slots__ = (
        "ts", "ts_observed", "ts_flags",
        "level_text", "level_num",
        "message", "attrs",
        "exceptions",
        "service", "app", "env", "host", "process", "thread", "logger",
        "trace_id", "span_id", "request_id", "correlation_id",
        "input_id", "line", "line_end", "byte_offset",
        "parser", "layout", "confidence", "diagnostics",
        "http_status", "http_method", "http_path", "error_code",
        "category_hint", "truncated", "raw_excerpt",
    )

    def __init__(self) -> None:
        self.ts: Optional[float] = None          # event timestamp, epoch seconds UTC
        self.ts_observed: Optional[float] = None  # observed/ingestion timestamp when distinct
        self.ts_flags: Tuple[str, ...] = ()       # e.g. ("naive", "year_inferred", "time_only")
        self.level_text: Optional[str] = None
        self.level_num: Optional[int] = None
        self.message: str = ""
        self.attrs: Dict[str, Any] = {}
        self.exceptions: List[ExceptionInfo] = []
        self.service: Optional[str] = None
        self.app: Optional[str] = None
        self.env: Optional[str] = None
        self.host: Optional[str] = None
        self.process: Optional[str] = None
        self.thread: Optional[str] = None
        self.logger: Optional[str] = None
        self.trace_id: Optional[str] = None
        self.span_id: Optional[str] = None
        self.request_id: Optional[str] = None
        self.correlation_id: Optional[str] = None
        self.input_id: int = 0
        self.line: int = 0
        self.line_end: int = 0
        self.byte_offset: Optional[int] = None
        self.parser: str = ""
        self.layout: Optional[str] = None
        self.confidence: float = 1.0
        self.diagnostics: List[str] = []
        self.http_status: Optional[int] = None
        self.http_method: Optional[str] = None
        self.http_path: Optional[str] = None
        self.error_code: Optional[str] = None
        self.category_hint: Optional[str] = None
        self.truncated: bool = False
        self.raw_excerpt: Optional[str] = None

    # convenience -----------------------------------------------------------
    def set_level(self, text: Optional[str], num: Optional[int] = None) -> None:
        if text is not None:
            self.level_text = str(text)
        if num is None and text is not None:
            num = level_from_text(text)
        if num is not None:
            self.level_num = num

    def add_attr(self, key: str, value: Any, limits) -> None:
        if len(self.attrs) >= limits.max_attributes_per_event and key not in self.attrs:
            self.attrs["_attrs_truncated"] = True
            return
        if isinstance(value, (dict, list)):
            try:
                import json
                value = json.dumps(value, ensure_ascii=False, sort_keys=True, default=str)
            except Exception:  # pragma: no cover - defensive
                value = str(value)
        if isinstance(value, str) and len(value) > limits.max_attribute_value_chars:
            value = value[: limits.max_attribute_value_chars] + "…"
        self.attrs[key] = value

    def bound(self, limits) -> None:
        if len(self.message) > limits.max_message_chars:
            self.message = self.message[: limits.max_message_chars]
            self.truncated = True
        if len(self.exceptions) > 8:
            self.exceptions = self.exceptions[:8]
        for exc in self.exceptions:
            if exc.message and len(exc.message) > limits.max_message_chars:
                exc.message = exc.message[: limits.max_message_chars]
            if len(exc.frames) > limits.max_frames:
                exc.frames = exc.frames[: limits.max_frames]

    @property
    def primary_exception(self) -> Optional[ExceptionInfo]:
        return self.exceptions[0] if self.exceptions else None

    def exception_text(self, limits) -> Optional[str]:
        """Rendered exception chain (bounded), used for examples."""
        if not self.exceptions:
            return None
        parts: List[str] = []
        for i, exc in enumerate(self.exceptions):
            head = (exc.type or "Exception")
            if exc.message:
                head += ": " + exc.message
            if i > 0:
                head = "Caused by: " + head
            parts.append(head)
            for fr in exc.frames[:12]:
                loc = ""
                if fr.file:
                    loc = " (%s%s)" % (fr.file, ":%d" % fr.line if fr.line else "")
                parts.append("    at %s%s" % (fr.function or "?", loc))
            if len(exc.frames) > 12:
                parts.append("    ... %d more frame(s)" % (len(exc.frames) - 12))
        text = "\n".join(parts)
        if len(text) > limits.max_exception_chars:
            text = text[: limits.max_exception_chars] + "\n… [truncated]"
        return text


class Diagnostic:
    """A parsing/processing diagnostic. Counts are exact even when instances are bounded."""

    __slots__ = ("code", "severity", "message", "input", "line", "count")

    def __init__(self, code: str, severity: str, message: str, input_path: Optional[str] = None,
                 line: Optional[int] = None, count: int = 1):
        self.code = code
        self.severity = severity  # "info" | "warning" | "error"
        self.message = message
        self.input = input_path
        self.line = line
        self.count = count

    def to_dict(self) -> Dict[str, Any]:
        return {"code": self.code, "severity": self.severity, "message": self.message,
                "input": self.input, "line": self.line, "count": self.count}


def safe_int(value: Any, max_digits: int = 18) -> Optional[int]:
    """Convert log-derived text to int without ever raising.

    Python (3.11+, and the security backports of 3.8-3.10) refuses ``int()`` on strings longer
    than 4300 digits; a hostile or corrupt token must not turn into a parser error that loses the
    whole input. Values longer than ``max_digits`` digits are not integers a log can mean.
    """
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if -10 ** max_digits < value < 10 ** max_digits else None
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")) or abs(value) >= 10 ** max_digits:
            return None
        return int(value)
    if isinstance(value, str):
        s = value.strip()
        body = s[1:] if s[:1] in "+-" else s
        if body.isdigit() and body.isascii() and len(body) <= max_digits:
            return int(s)
    return None


class DiagnosticSink:
    """Bounded diagnostics store: keeps up to ``max_diagnostics`` records and exact per-code counts."""

    def __init__(self, max_records: int):
        self.max_records = max_records
        self.records: List[Diagnostic] = []
        self.counts: Dict[str, int] = {}
        self.dropped = 0
        self._index: Dict[Tuple[str, Optional[str], Optional[int]], Diagnostic] = {}

    def add(self, code: str, severity: str, message: str, input_path: Optional[str] = None,
            line: Optional[int] = None, dedupe: bool = True) -> None:
        self.counts[code] = self.counts.get(code, 0) + 1
        key = (code, input_path, line if not dedupe else None)
        if dedupe and key in self._index:
            self._index[key].count += 1
            return
        if len(self.records) >= self.max_records:
            self.dropped += 1
            return
        diag = Diagnostic(code, severity, message, input_path, line)
        self.records.append(diag)
        if dedupe:
            self._index[key] = diag

    def to_dict(self) -> Dict[str, Any]:
        return {
            "records": [d.to_dict() for d in self.records],
            "counts_by_code": dict(sorted(self.counts.items())),
            "records_dropped": self.dropped,
            "total": sum(self.counts.values()),
        }
