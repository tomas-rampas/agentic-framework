"""JSON-based inputs: NDJSON, JSON documents/envelopes, and platform export adapters.

Parser names (registry): ``ndjson``, ``json`` (generic), ``otlp-json``, ``ecs-json``,
``docker-json``, ``journal-json``, ``cloudwatch-json``, ``azure-json``, ``gcp-json``,
``loki-json``, ``apple-ips``. All share one implementation; the name only pins the
expected envelope/dialect when given via ``--input-format``.

Dialects (per-record key signatures) are listed in ``DIALECTS``; each entry names the
producing library, the signature keys and the fixture that covers it (see
docs/log-triage/support-matrix.md).
"""
from __future__ import annotations

import json
import re
from typing import Any, Dict, Iterator, List, Optional, Sequence, Tuple

from ..model import (Event, ExceptionInfo, Frame, level_from_azure_severity, level_from_monolog, level_from_pino,
                     level_from_python, level_from_syslog, level_from_text)
from .base import BaseParser, Lines, ParseContext, set_ts
from .exceptions import parse_exception_block, parse_frame
from .jsonstream import ROOT, JsonItemScanner
from .nested import NestedSink
from .text import LazyTextEngine, _promote_attrs

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
_TS_KEYS = ("@timestamp", "timestamp", "time", "ts", "Timestamp", "eventTime", "event_time", "datetime", "date",
            "asctime", "t", "@t", "created", "logged_at", "_ts", "TimeGenerated", "time_local", "Time", "TIMESTAMP",
            "@timestamp", "timeMillis", "epoch", "unix_time", "ingestionTime")
_LEVEL_KEYS = ("level", "severity", "lvl", "levelname", "level_name", "Level", "loglevel", "log_level", "severity_text",
               "severityText", "@l", "priority", "PRIORITY", "SeverityLevel", "severityLevel", "log.level", "LEVEL",
               "type")
_MSG_KEYS = ("message", "msg", "@m", "@mt", "event", "text", "log", "body", "Message", "RenderedMessage",
             "MessageTemplate", "description", "short_message", "MESSAGE", "textPayload", "line", "full_message",
             "Msg", "MSG")
_EXC_KEYS = ("exception", "stack_trace", "stacktrace", "stackTrace", "stack", "exc_info", "err", "error", "@x",
             "Exception", "thrown", "error.stack_trace", "traceback", "exceptions", "errors", "StackTrace",
             "exception_message", "error_message", "err_msg")
_LOGGER_KEYS = ("logger", "logger_name", "loggerName", "SourceContext", "channel", "target", "log.logger", "name",
                "category", "source", "component", "module", "caller", "class", "Logger", "log_name")
_SERVICE_KEYS = ("service", "service.name", "service_name", "serviceName", "app", "application", "appname", "app_name",
                 "Application", "program", "SYSLOG_IDENTIFIER", "_SYSTEMD_UNIT", "cloud_RoleName", "AppRoleName",
                 "container_name", "kubernetes.container_name", "k8s.container.name", "job", "dd.service")
_HOST_KEYS = ("host", "hostname", "host.name", "MachineName", "_HOSTNAME", "computer", "Computer", "hostName",
              "instance", "node", "kubernetes.host", "host_name")
_ENV_KEYS = ("env", "environment", "Environment", "deployment.environment", "stage", "dd.env")
_TRACE_KEYS = ("trace_id", "traceId", "trace.id", "traceID", "@tr", "dd.trace_id", "TraceId", "trace", "logging.googleapis.com/trace")
_SPAN_KEYS = ("span_id", "spanId", "span.id", "spanID", "@sp", "SpanId", "logging.googleapis.com/spanId")
_REQ_KEYS = ("request_id", "requestId", "req_id", "reqId", "RequestId", "x-request-id", "request.id", "http.request.id",
             "OperationId", "operation_Id", "operationId", "aws_request_id", "correlation_id", "correlationId",
             "CorrelationId", "ConnectionId")
_STATUS_KEYS = ("status", "statusCode", "status_code", "http.response.status_code", "res.statusCode", "response.status",
                "StatusCode", "ResultCode", "resultCode", "sc-status", "http_status", "httpRequest.status", "code")
_METHOD_KEYS = ("method", "http.request.method", "req.method", "httpRequest.requestMethod", "request_method", "verb", "cs-method")
_PATH_KEYS = ("path", "url.path", "req.url", "url", "httpRequest.requestUrl", "request_uri", "uri", "cs-uri-stem", "RequestPath")
_PID_KEYS = ("pid", "process.pid", "processId", "process_id", "_PID", "ProcessId")
_THREAD_KEYS = ("thread", "thread_name", "threadName", "thread.name", "tid", "ThreadId", "threadId")

_LEVEL_WORD = re.compile(r"^[A-Za-z]{1,12}$")


def _get(rec: Dict[str, Any], keys: Sequence[str]) -> Tuple[Optional[str], Any]:
    for k in keys:
        if k in rec:
            v = rec[k]
            if v is None or v == "":
                continue
            return k, v
        if "." in k:
            cur: Any = rec
            ok = True
            for part in k.split("."):
                if isinstance(cur, dict) and part in cur:
                    cur = cur[part]
                else:
                    ok = False
                    break
            if ok and cur not in (None, ""):
                return k, cur
    return None, None


def _s(v: Any, limit: int = 512) -> Optional[str]:
    if v is None:
        return None
    if isinstance(v, str):
        return v if len(v) <= limit else v[:limit]
    if isinstance(v, bool):
        return str(v).lower()
    if isinstance(v, (int, float)):
        return str(v)
    try:
        t = json.dumps(v, ensure_ascii=False, sort_keys=True, default=str)
    except Exception:
        t = str(v)
    return t if len(t) <= limit else t[:limit]


def _frames_from_list(items: List[Any], max_frames: int) -> List[Frame]:
    frames: List[Frame] = []
    for it in items[:max_frames]:
        if isinstance(it, str):
            fr = parse_frame(it)
            if fr:
                frames.append(fr)
            continue
        if not isinstance(it, dict):
            continue
        func = _s(_get(it, ("function", "method", "func", "symbol", "name", "methodName"))[1], 200)
        cls = _s(_get(it, ("class", "className", "module", "type"))[1], 200)
        if cls and func and "." not in func and "::" not in func:
            func = cls + "." + func
        elif cls and not func:
            func = cls
        file = _s(_get(it, ("file", "filename", "fileName", "path", "abs_path", "sourceFile", "source"))[1], 300)
        line = _get(it, ("line", "lineno", "lineNumber", "line_number", "sourceLine"))[1]
        try:
            line_i = int(line) if line is not None else None
        except (TypeError, ValueError):
            line_i = None
        from .exceptions import _in_app  # local import to reuse the heuristic
        frames.append(Frame(func, file, line_i, _in_app(func, file)))
    return frames


def extract_exception(value: Any, max_frames: int, depth: int = 0) -> List[ExceptionInfo]:
    """Normalize a structured exception field (string, object, or list) into ExceptionInfo chain."""
    if value is None or depth > 8:
        return []
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return []
        lines = text.split("\n")
        excs, _ = parse_exception_block(lines[1:], lines[0], max_frames)
        if excs:
            return excs
        return [ExceptionInfo(None, text[:1000] if len(lines) == 1 else lines[0][:1000])]
    if isinstance(value, list):
        out: List[ExceptionInfo] = []
        for v in value[:8]:
            out.extend(extract_exception(v, max_frames, depth + 1))
        return out
    if isinstance(value, dict):
        typ = _s(_get(value, ("type", "name", "class", "kind", "exception_type", "exceptionType", "ExceptionType",
                              "error_type", "errorType", "className", "@type", "Type", "OuterType"))[1], 300)
        msg = _s(_get(value, ("message", "msg", "value", "detail", "Message", "description", "reason", "OuterMessage",
                              "error_message", "text"))[1], 2000)
        stack_key, stack = _get(value, ("stack", "stacktrace", "stack_trace", "trace", "traceback", "stackTrace",
                                        "StackTrace", "extendedStackTrace", "frames", "backtrace", "parsedStack"))
        frames: List[Frame] = []
        chain: List[ExceptionInfo] = []
        if isinstance(stack, str):
            lines = stack.strip().split("\n")
            excs, _ = parse_exception_block(lines[1:], lines[0], max_frames)
            if excs:
                if not typ and excs[0].type:
                    typ = excs[0].type
                if not msg and excs[0].message:
                    msg = excs[0].message
                frames = excs[0].frames
                chain = excs[1:]
        elif isinstance(stack, list):
            frames = _frames_from_list(stack, max_frames)
        if typ is None and msg is None and not frames:
            # maybe a wrapper like {"error": {...}} or a Sentry-ish {"values":[...]}
            inner = _get(value, ("error", "exception", "err", "values", "innerException"))[1]
            if inner is not None and inner is not value:
                return extract_exception(inner, max_frames, depth + 1)
            return []
        if not frames and isinstance(value.get("file"), str) and value.get("line") is not None:
            try:
                from .exceptions import _in_app
                frames = [Frame(None, value["file"], int(value["line"]), _in_app(None, value["file"]))]
            except (TypeError, ValueError):
                pass
        head = ExceptionInfo(typ, msg, frames)
        out = [head]
        cause = _get(value, ("cause", "inner", "innerException", "InnerException", "innerExceptions", "InnerExceptions",
                             "cause_chain", "causes", "previous", "__cause__", "__context__", "suppressed"))[1]
        if cause is not None and cause is not value:
            out.extend(extract_exception(cause, max_frames, depth + 1))
        out.extend(chain)
        return out
    return []


# ---------------------------------------------------------------------------
# dialects
# ---------------------------------------------------------------------------
class Dialect:
    __slots__ = ("id", "library", "ecosystem", "signature", "normalize", "fixture", "notes")

    def __init__(self, id_: str, library: str, ecosystem: str, signature, normalize, fixture: str, notes: str = ""):
        self.id = id_
        self.library = library
        self.ecosystem = ecosystem
        self.signature = signature      # fn(rec) -> score 0..1
        self.normalize = normalize      # fn(rec, ev, ctx, consumed:set) -> None
        self.fixture = fixture
        self.notes = notes


def _has(rec: Dict[str, Any], *keys: str) -> bool:
    return all(k in rec for k in keys)


def _any(rec: Dict[str, Any], *keys: str) -> bool:
    return any(k in rec for k in keys)


# --- normalizers ------------------------------------------------------------
def _n_generic(rec, ev, ctx, consumed) -> None:
    pass


def _n_serilog_compact(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("@t"))
    lvl = rec.get("@l", "Information")
    ev.set_level(lvl)
    ev.message = _s(rec.get("@m") or rec.get("@mt"), ctx.limits.max_message_chars) or ""
    if "@x" in rec:
        ev.exceptions = extract_exception(rec["@x"], ctx.limits.max_frames)
    ev.logger = _s(rec.get("SourceContext"), 200)
    ev.trace_id = _s(rec.get("@tr"), 64)
    ev.span_id = _s(rec.get("@sp"), 64)
    ev.request_id = _s(rec.get("RequestId"), 128)
    ev.app = _s(rec.get("Application"), 128)
    ev.host = _s(rec.get("MachineName"), 128)
    consumed.update({"@t", "@l", "@m", "@mt", "@x", "@i", "@r", "@tr", "@sp", "SourceContext", "RequestId", "Application",
                     "MachineName"})


def _n_serilog_json(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("Timestamp"))
    ev.set_level(rec.get("Level"))
    ev.message = _s(rec.get("RenderedMessage") or rec.get("MessageTemplate"), ctx.limits.max_message_chars) or ""
    if rec.get("Exception"):
        ev.exceptions = extract_exception(rec["Exception"], ctx.limits.max_frames)
    props = rec.get("Properties") or {}
    if isinstance(props, dict):
        ev.logger = _s(props.get("SourceContext"), 200)
        ev.request_id = _s(props.get("RequestId"), 128)
        ev.app = _s(props.get("Application"), 128)
        ev.host = _s(props.get("MachineName"), 128)
        for k, v in list(props.items())[:32]:
            ev.add_attr(k, v, ctx.limits)
    consumed.update({"Timestamp", "Level", "RenderedMessage", "MessageTemplate", "Exception", "Properties"})


def _n_log4j2(rec, ev, ctx, consumed) -> None:
    inst = rec.get("instant")
    if isinstance(inst, dict) and "epochSecond" in inst:
        ts = float(inst.get("epochSecond") or 0) + float(inst.get("nanoOfSecond") or 0) / 1e9
        set_ts(ev, ctx, ts)
    elif "timeMillis" in rec:
        set_ts(ev, ctx, rec["timeMillis"])
    ev.set_level(rec.get("level"))
    ev.logger = _s(rec.get("loggerName"), 200)
    ev.thread = _s(rec.get("thread"), 100)
    msg = rec.get("message")
    if isinstance(msg, dict):
        msg = msg.get("formattedMessage") or msg.get("message") or _s(msg)
    ev.message = _s(msg, ctx.limits.max_message_chars) or ""
    if rec.get("thrown"):
        ev.exceptions = extract_exception(rec["thrown"], ctx.limits.max_frames)
    cm = rec.get("contextMap")
    if isinstance(cm, dict):
        for k, v in list(cm.items())[:32]:
            ev.add_attr(k, v, ctx.limits)
    consumed.update({"instant", "timeMillis", "level", "loggerName", "thread", "message", "thrown", "contextMap",
                     "endOfBatch", "loggerFqcn", "threadId", "threadPriority"})


def _n_logstash(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("@timestamp"))
    ev.set_level(rec.get("level"))
    ev.logger = _s(rec.get("logger_name"), 200)
    ev.thread = _s(rec.get("thread_name"), 100)
    ev.message = _s(rec.get("message"), ctx.limits.max_message_chars) or ""
    if rec.get("stack_trace"):
        ev.exceptions = extract_exception(rec["stack_trace"], ctx.limits.max_frames)
    consumed.update({"@timestamp", "@version", "level", "level_value", "logger_name", "thread_name", "message", "stack_trace"})


def _n_python_json(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("asctime") or rec.get("timestamp") or rec.get("created"))
    ev.set_level(rec.get("levelname"), level_from_python(int(rec["levelno"])) if isinstance(rec.get("levelno"), int) else None)
    ev.logger = _s(rec.get("name"), 200)
    ev.message = _s(rec.get("message"), ctx.limits.max_message_chars) or ""
    if rec.get("exc_info"):
        ev.exceptions = extract_exception(rec["exc_info"], ctx.limits.max_frames)
    if rec.get("process"):
        ev.process = _s(rec.get("process"), 32)
    if rec.get("threadName") or rec.get("thread"):
        ev.thread = _s(rec.get("threadName") or rec.get("thread"), 64)
    consumed.update({"asctime", "timestamp", "created", "levelname", "levelno", "name", "message", "exc_info", "exc_text",
                     "process", "processName", "thread", "threadName", "msecs", "relativeCreated", "args", "taskName"})


def _n_structlog(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("timestamp"))
    ev.set_level(rec.get("level"))
    ev.logger = _s(rec.get("logger"), 200)
    ev.message = _s(rec.get("event"), ctx.limits.max_message_chars) or ""
    exc = rec.get("exception") or rec.get("exc_info")
    if exc:
        ev.exceptions = extract_exception(exc, ctx.limits.max_frames)
    consumed.update({"timestamp", "level", "logger", "event", "exception", "exc_info"})


def _n_loguru(rec, ev, ctx, consumed) -> None:
    r = rec.get("record") or {}
    t = r.get("time") or {}
    set_ts(ev, ctx, t.get("timestamp") if isinstance(t, dict) else t)
    lvl = r.get("level") or {}
    ev.set_level(lvl.get("name") if isinstance(lvl, dict) else lvl)
    ev.logger = _s(r.get("name"), 200)
    ev.message = _s(r.get("message"), ctx.limits.max_message_chars) or ""
    exc = r.get("exception")
    if exc:
        if isinstance(exc, dict):
            info = ExceptionInfo(_s(exc.get("type"), 200), _s(exc.get("value"), 1000))
            tb = exc.get("traceback")
            if isinstance(tb, str):
                inner = extract_exception(tb, ctx.limits.max_frames)
                if inner:
                    info.frames = inner[0].frames
            elif isinstance(rec.get("text"), str) and "Traceback" in rec["text"]:
                txt = rec["text"]
                inner = extract_exception(txt[txt.index("Traceback"):], ctx.limits.max_frames)
                if inner:
                    info.frames = inner[0].frames
            ev.exceptions = [info]
        else:
            ev.exceptions = extract_exception(exc, ctx.limits.max_frames)
    proc = r.get("process")
    if isinstance(proc, dict):
        ev.process = _s(proc.get("id"), 32)
    if r.get("function") and r.get("line"):
        ev.add_attr("source", "%s:%s:%s" % (r.get("file", {}).get("name") if isinstance(r.get("file"), dict) else r.get("file"),
                                            r.get("function"), r.get("line")), ctx.limits)
    extra = r.get("extra")
    if isinstance(extra, dict):
        for k, v in list(extra.items())[:32]:
            ev.add_attr(k, v, ctx.limits)
    consumed.update({"record", "text"})


def _n_pino(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("time"))
    lvl = rec.get("level")
    if isinstance(lvl, int):
        ev.set_level({10: "trace", 20: "debug", 30: "info", 40: "warn", 50: "error", 60: "fatal"}.get(lvl, str(lvl)),
                     level_from_pino(lvl))
    else:
        ev.set_level(lvl)
    ev.message = _s(rec.get("msg"), ctx.limits.max_message_chars) or ""
    ev.host = _s(rec.get("hostname"), 128)
    ev.process = _s(rec.get("pid"), 32)
    ev.logger = _s(rec.get("name"), 200)
    err = rec.get("err") or rec.get("error")
    if err:
        ev.exceptions = extract_exception(err, ctx.limits.max_frames)
    res = rec.get("res")
    if isinstance(res, dict) and isinstance(res.get("statusCode"), int):
        ev.http_status = res["statusCode"]
    req = rec.get("req")
    if isinstance(req, dict):
        ev.http_method = _s(req.get("method"), 16)
        ev.http_path = _s(req.get("url"), 300)
        if req.get("id"):
            ev.request_id = _s(req.get("id"), 128)
    ev.request_id = ev.request_id or _s(rec.get("reqId"), 128)
    consumed.update({"time", "level", "msg", "hostname", "pid", "name", "err", "error", "res", "req", "reqId", "v"})


def _n_bunyan(rec, ev, ctx, consumed) -> None:
    _n_pino(rec, ev, ctx, consumed)


def _n_winston(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("timestamp"))
    ev.set_level(rec.get("level"))
    ev.message = _s(rec.get("message"), ctx.limits.max_message_chars) or ""
    if rec.get("stack"):
        ev.exceptions = extract_exception(rec["stack"], ctx.limits.max_frames)
    ev.service = _s(rec.get("service"), 128)
    ev.logger = _s(rec.get("label"), 200)
    consumed.update({"timestamp", "level", "message", "stack", "service", "label"})


def _n_slog(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("time"))
    ev.set_level(rec.get("level"))
    ev.message = _s(rec.get("msg"), ctx.limits.max_message_chars) or ""
    src = rec.get("source")
    if isinstance(src, dict):
        ev.add_attr("source", "%s:%s (%s)" % (src.get("file"), src.get("line"), src.get("function")), ctx.limits)
    for k in ("err", "error"):
        if rec.get(k):
            ev.exceptions = extract_exception(rec[k], ctx.limits.max_frames)
            consumed.add(k)
            break
    consumed.update({"time", "level", "msg", "source"})


def _n_zap(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("ts") or rec.get("time") or rec.get("timestamp"))
    ev.set_level(rec.get("level"))
    ev.message = _s(rec.get("msg"), ctx.limits.max_message_chars) or ""
    ev.logger = _s(rec.get("logger") or rec.get("caller"), 200)
    if rec.get("stacktrace") or rec.get("error"):
        excs = extract_exception(rec.get("error"), ctx.limits.max_frames) if rec.get("error") else []
        if rec.get("stacktrace"):
            st = extract_exception(rec["stacktrace"], ctx.limits.max_frames)
            if st:
                if excs:
                    excs[0].frames = excs[0].frames or st[0].frames
                else:
                    excs = st
        ev.exceptions = excs
    consumed.update({"ts", "time", "timestamp", "level", "msg", "logger", "caller", "stacktrace", "error", "errorVerbose"})


def _n_zerolog(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("time"))
    ev.set_level(rec.get("level"))
    ev.message = _s(rec.get("message"), ctx.limits.max_message_chars) or ""
    if rec.get("error"):
        ev.exceptions = extract_exception(rec["error"], ctx.limits.max_frames)
    ev.logger = _s(rec.get("caller"), 200)
    consumed.update({"time", "level", "message", "error", "caller"})


def _n_tracing(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("timestamp"))
    ev.set_level(rec.get("level"))
    ev.logger = _s(rec.get("target"), 200)
    fields = rec.get("fields") or {}
    if isinstance(fields, dict):
        ev.message = _s(fields.get("message"), ctx.limits.max_message_chars) or ""
        for k, v in list(fields.items())[:32]:
            if k != "message":
                ev.add_attr(k, v, ctx.limits)
        if fields.get("error") or fields.get("err"):
            ev.exceptions = extract_exception(fields.get("error") or fields.get("err"), ctx.limits.max_frames)
    span = rec.get("span")
    if isinstance(span, dict) and span.get("name"):
        ev.add_attr("span", span.get("name"), ctx.limits)
    consumed.update({"timestamp", "level", "target", "fields", "span", "spans", "threadId", "threadName", "filename",
                     "line_number"})


def _n_monolog(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("datetime"))
    lvl = rec.get("level")
    ev.set_level(rec.get("level_name") or (str(lvl) if lvl is not None else None),
                 level_from_monolog(int(lvl)) if isinstance(lvl, int) else None)
    ev.logger = _s(rec.get("channel"), 200)
    ev.message = _s(rec.get("message"), ctx.limits.max_message_chars) or ""
    context = rec.get("context") or {}
    if isinstance(context, dict):
        if context.get("exception"):
            ev.exceptions = extract_exception(context["exception"], ctx.limits.max_frames)
        for k, v in list(context.items())[:32]:
            if k != "exception":
                ev.add_attr(k, v, ctx.limits)
    consumed.update({"datetime", "level", "level_name", "channel", "message", "context", "extra"})


def _n_ecs(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, _get(rec, ("@timestamp",))[1])
    ev.set_level(_s(_get(rec, ("log.level",))[1], 32))
    ev.logger = _s(_get(rec, ("log.logger",))[1], 200)
    ev.message = _s(_get(rec, ("message",))[1], ctx.limits.max_message_chars) or ""
    etype = _s(_get(rec, ("error.type",))[1], 300)
    emsg = _s(_get(rec, ("error.message",))[1], 2000)
    estack = _get(rec, ("error.stack_trace",))[1]
    if etype or emsg or estack:
        excs = extract_exception(estack, ctx.limits.max_frames) if estack else []
        if excs:
            if etype:
                excs[0].type = etype
            if emsg and not excs[0].message:
                excs[0].message = emsg
        else:
            excs = [ExceptionInfo(etype, emsg)]
        ev.exceptions = excs
    ev.service = _s(_get(rec, ("service.name",))[1], 128)
    ev.env = _s(_get(rec, ("service.environment",))[1], 64)
    ev.host = _s(_get(rec, ("host.name", "host.hostname"))[1], 128)
    ev.trace_id = _s(_get(rec, ("trace.id",))[1], 64)
    ev.span_id = _s(_get(rec, ("span.id",))[1], 64)
    ev.request_id = _s(_get(rec, ("transaction.id", "http.request.id"))[1], 128)
    st = _get(rec, ("http.response.status_code",))[1]
    if isinstance(st, int):
        ev.http_status = st
    ev.http_method = _s(_get(rec, ("http.request.method",))[1], 16)
    ev.http_path = _s(_get(rec, ("url.path",))[1], 300)
    pid = _get(rec, ("process.pid",))[1]
    if pid is not None:
        ev.process = _s(pid, 32)
    consumed.update({"@timestamp", "log", "message", "error", "service", "host", "trace", "span", "transaction", "http",
                     "url", "process", "ecs", "event", "log.level", "log.logger", "error.type", "error.message",
                     "error.stack_trace", "service.name", "host.name", "trace.id", "span.id"})


def _otlp_value(v: Any) -> Any:
    if not isinstance(v, dict):
        return v
    for k in ("stringValue", "intValue", "doubleValue", "boolValue", "bytesValue"):
        if k in v:
            return v[k]
    if "arrayValue" in v:
        return [_otlp_value(x) for x in (v["arrayValue"].get("values") or [])]
    if "kvlistValue" in v:
        return {kv.get("key"): _otlp_value(kv.get("value")) for kv in (v["kvlistValue"].get("values") or [])}
    return v


def _otlp_attrs(lst: Any) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    if isinstance(lst, list):
        for kv in lst[:128]:
            if isinstance(kv, dict) and "key" in kv:
                out[str(kv["key"])] = _otlp_value(kv.get("value"))
    elif isinstance(lst, dict):
        out.update(lst)
    return out


_OTLP_SEV_TEXT = {1: "TRACE", 5: "DEBUG", 9: "INFO", 13: "WARN", 17: "ERROR", 21: "FATAL"}


def _n_otlp(rec, ev, ctx, consumed, context: Optional[Dict] = None) -> None:
    set_ts(ev, ctx, rec.get("timeUnixNano") or rec.get("observedTimeUnixNano"))
    if rec.get("observedTimeUnixNano") and rec.get("timeUnixNano"):
        ts2, _ = ctx.ts(rec.get("observedTimeUnixNano"))
        ev.ts_observed = ts2
    sev_num = rec.get("severityNumber")
    sev_text = rec.get("severityText")
    num = None
    if isinstance(sev_num, int) and 1 <= sev_num <= 24:
        num = sev_num
    elif isinstance(sev_num, str) and sev_num.startswith("SEVERITY_NUMBER_"):
        num = level_from_text(sev_num.split("_")[-1].rstrip("234"))
    if sev_text or num:
        ev.set_level(sev_text or _OTLP_SEV_TEXT.get(((num or 9) - 1) // 4 * 4 + 1, str(num)), num)
    body = _otlp_value(rec.get("body"))
    ev.message = _s(body, ctx.limits.max_message_chars) or ""
    attrs = _otlp_attrs(rec.get("attributes"))
    res_attrs: Dict[str, Any] = {}
    if context:
        res = context.get("resource")
        if isinstance(res, dict):
            res_attrs = _otlp_attrs(res.get("attributes"))
        scope = context.get("scope")
        if isinstance(scope, dict) and scope.get("name"):
            ev.logger = _s(scope.get("name"), 200)
    ev.service = _s(res_attrs.get("service.name"), 128)
    ev.env = _s(res_attrs.get("deployment.environment") or res_attrs.get("deployment.environment.name"), 64)
    ev.host = _s(res_attrs.get("host.name"), 128)
    if res_attrs.get("process.pid") is not None:
        ev.process = _s(res_attrs.get("process.pid"), 32)
    ev.trace_id = _s(rec.get("traceId"), 64)
    ev.span_id = _s(rec.get("spanId"), 64)
    etype = attrs.get("exception.type")
    emsg = attrs.get("exception.message")
    estack = attrs.get("exception.stacktrace")
    if etype or emsg or estack:
        excs = extract_exception(estack, ctx.limits.max_frames) if estack else []
        if excs:
            if etype:
                excs[0].type = _s(etype, 300)
            if emsg and not excs[0].message:
                excs[0].message = _s(emsg, 2000)
        else:
            excs = [ExceptionInfo(_s(etype, 300), _s(emsg, 2000))]
        ev.exceptions = excs
    if attrs.get("http.response.status_code") or attrs.get("http.status_code"):
        try:
            ev.http_status = int(attrs.get("http.response.status_code") or attrs.get("http.status_code"))
        except (TypeError, ValueError):
            pass
    ev.http_method = _s(attrs.get("http.request.method") or attrs.get("http.method"), 16)
    ev.http_path = _s(attrs.get("url.path") or attrs.get("http.target"), 300)
    for k, v in list(attrs.items())[:48]:
        if not k.startswith("exception."):
            ev.add_attr(k, v, ctx.limits)
    for k in ("service.namespace", "service.version", "k8s.pod.name", "k8s.namespace.name", "container.name"):
        if res_attrs.get(k) is not None:
            ev.add_attr(k, res_attrs[k], ctx.limits)
    consumed.update(rec.keys())


def _n_journal(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("__REALTIME_TIMESTAMP") or rec.get("_SOURCE_REALTIME_TIMESTAMP"))
    pri = rec.get("PRIORITY")
    try:
        pri_i = int(pri) if pri is not None else None
    except (TypeError, ValueError):
        pri_i = None
    if pri_i is not None:
        num, text = level_from_syslog(pri_i)
        ev.set_level(text, num)
    msg = rec.get("MESSAGE")
    if isinstance(msg, list):
        try:
            msg = bytes(int(b) & 0xFF for b in msg).decode("utf-8", "replace")
        except Exception:
            msg = _s(msg)
    ev.message = _s(msg, ctx.limits.max_message_chars) or ""
    ev.service = _s(rec.get("_SYSTEMD_UNIT") or rec.get("SYSLOG_IDENTIFIER") or rec.get("_COMM"), 128)
    ev.host = _s(rec.get("_HOSTNAME"), 128)
    ev.process = _s(rec.get("_PID"), 32)
    if rec.get("CODE_FILE"):
        ev.add_attr("source", "%s:%s (%s)" % (rec.get("CODE_FILE"), rec.get("CODE_LINE"), rec.get("CODE_FUNC")), ctx.limits)
    if rec.get("ERRNO"):
        ev.add_attr("errno", rec.get("ERRNO"), ctx.limits)
    consumed.update({"__REALTIME_TIMESTAMP", "_SOURCE_REALTIME_TIMESTAMP", "__MONOTONIC_TIMESTAMP", "__CURSOR",
                     "PRIORITY", "MESSAGE", "_SYSTEMD_UNIT", "SYSLOG_IDENTIFIER", "_COMM", "_HOSTNAME", "_PID",
                     "CODE_FILE", "CODE_LINE", "CODE_FUNC", "_BOOT_ID", "_MACHINE_ID", "_TRANSPORT", "SYSLOG_FACILITY",
                     "_EXE", "_CMDLINE", "_CAP_EFFECTIVE", "_SYSTEMD_CGROUP", "_SYSTEMD_SLICE", "_UID", "_GID",
                     "_SELINUX_CONTEXT", "_SYSTEMD_INVOCATION_ID", "_STREAM_ID", "__SEQNUM", "__SEQNUM_ID", "_RUNTIME_SCOPE"})
    if ev.message and "\n" in ev.message:
        lines = ev.message.split("\n")
        excs, hint = parse_exception_block(lines[1:], lines[0], ctx.limits.max_frames)
        if excs:
            ev.exceptions = excs
            ev.category_hint = hint
        ev.message = lines[0]


def _n_azure_record(rec, ev, ctx, consumed) -> None:
    """Azure Monitor diagnostic-settings export record ({"time","resourceId","category","operationName",...})."""
    set_ts(ev, ctx, rec.get("time") or rec.get("timestamp") or rec.get("TimeGenerated"))
    lvl = rec.get("level") or rec.get("Level") or rec.get("severityLevel") or rec.get("SeverityLevel")
    if isinstance(lvl, int):
        num, text = level_from_azure_severity(lvl)
        ev.set_level(text, num)
    else:
        ev.set_level(_s(lvl, 32))
    props = rec.get("properties") if isinstance(rec.get("properties"), dict) else {}
    msg = (props.get("message") or props.get("Message") or props.get("outerMessage") or props.get("innermostMessage")
           or rec.get("message") or rec.get("Message") or rec.get("resultDescription") or rec.get("operationName"))
    ev.message = _s(msg, ctx.limits.max_message_chars) or ""
    ev.service = _s(props.get("appRoleName") or props.get("cloud_RoleName") or rec.get("AppRoleName"), 128)
    ev.request_id = _s(props.get("operation_Id") or props.get("operationId") or rec.get("correlationId") or rec.get("OperationId"), 128)
    ev.logger = _s(rec.get("category") or rec.get("Category"), 200)
    ev.add_attr("resourceId", rec.get("resourceId"), ctx.limits)
    ev.add_attr("operationName", rec.get("operationName"), ctx.limits)
    if rec.get("resultType"):
        ev.add_attr("resultType", rec.get("resultType"), ctx.limits)
    for k in ("outerType", "innermostType", "ExceptionType"):
        if props.get(k) or rec.get(k):
            ev.exceptions = [ExceptionInfo(_s(props.get(k) or rec.get(k), 300),
                                           _s(props.get("outerMessage") or props.get("innermostMessage") or rec.get("OuterMessage"), 2000))]
            break
    details = props.get("details") or rec.get("Details")
    if details and not ev.exceptions:
        ev.exceptions = extract_exception(details if not isinstance(details, str) else _try_json(details), ctx.limits.max_frames)
    for k, v in list(props.items())[:32]:
        if k not in ("message", "Message", "details"):
            ev.add_attr(k, v, ctx.limits)
    consumed.update({"time", "timestamp", "TimeGenerated", "level", "Level", "severityLevel", "SeverityLevel", "properties",
                     "message", "Message", "resourceId", "operationName", "category", "Category", "resultType",
                     "correlationId", "resultDescription", "durationMs", "callerIpAddress", "identity", "location"})


def _try_json(text: str) -> Any:
    try:
        return json.loads(text)
    except Exception:
        return text


def _n_azure_row(rec, ev, ctx, consumed) -> None:
    """A row from the Log Analytics / Application Insights query API (mapped by column names)."""
    set_ts(ev, ctx, rec.get("TimeGenerated") or rec.get("timestamp") or rec.get("TIMESTAMP"))
    lvl = rec.get("SeverityLevel") if "SeverityLevel" in rec else rec.get("severityLevel", rec.get("Level"))
    if isinstance(lvl, int):
        num, text = level_from_azure_severity(lvl)
        ev.set_level(text, num)
    elif lvl is not None:
        ev.set_level(_s(lvl, 32))
    msg = (rec.get("Message") or rec.get("message") or rec.get("OuterMessage") or rec.get("InnermostMessage") or rec.get("outerMessage")
           or rec.get("innermostMessage") or rec.get("Name") or rec.get("name") or rec.get("RenderedDescription"))
    ev.message = _s(msg, ctx.limits.max_message_chars) or ""
    etype = rec.get("ExceptionType") or rec.get("OuterType") or rec.get("type") or rec.get("InnermostType")
    if etype and any(k in rec for k in ("OuterMessage", "InnermostMessage", "ExceptionType", "Details", "details", "outerMessage")):
        excs: List[ExceptionInfo] = []
        det = rec.get("Details") or rec.get("details")
        if det:
            excs = extract_exception(_try_json(det) if isinstance(det, str) else det, ctx.limits.max_frames)
        if not excs:
            excs = [ExceptionInfo(_s(etype, 300), _s(rec.get("OuterMessage") or rec.get("outerMessage") or rec.get("InnermostMessage"), 2000))]
        ev.exceptions = excs
        if ev.level_num is None:
            ev.set_level("error")
    ev.service = _s(rec.get("AppRoleName") or rec.get("cloud_RoleName") or rec.get("Computer") and None, 128)
    ev.host = _s(rec.get("Computer") or rec.get("AppRoleInstance") or rec.get("cloud_RoleInstance"), 128)
    ev.request_id = _s(rec.get("OperationId") or rec.get("operation_Id") or rec.get("ParentId"), 128)
    ev.logger = _s(rec.get("OperationName") or rec.get("operation_Name") or rec.get("Type") or rec.get("Category"), 200)
    rc = rec.get("ResultCode") or rec.get("resultCode")
    if rc is not None:
        try:
            ev.http_status = int(rc)
        except (TypeError, ValueError):
            pass
    if rec.get("Url") or rec.get("url"):
        ev.http_path = _s(rec.get("Url") or rec.get("url"), 300)
    consumed.update({"TimeGenerated", "timestamp", "TIMESTAMP", "SeverityLevel", "severityLevel", "Level", "Message",
                     "message", "OuterMessage", "InnermostMessage", "outerMessage", "innermostMessage", "ExceptionType",
                     "OuterType", "InnermostType", "Details", "details", "AppRoleName", "cloud_RoleName", "Computer",
                     "AppRoleInstance", "cloud_RoleInstance", "OperationId", "operation_Id", "ParentId", "OperationName",
                     "operation_Name", "ResultCode", "resultCode", "Url", "url", "Name", "name", "RenderedDescription"})


def _n_gcp(rec, ev, ctx, consumed, nested_text=None) -> None:
    set_ts(ev, ctx, rec.get("timestamp"))
    if rec.get("receiveTimestamp"):
        ev.ts_observed, _ = ctx.ts(rec.get("receiveTimestamp"))
    ev.set_level(rec.get("severity"))
    res = rec.get("resource") or {}
    labels = res.get("labels") if isinstance(res, dict) else {}
    labels = labels if isinstance(labels, dict) else {}
    ev.service = _s(labels.get("service_name") or labels.get("container_name") or labels.get("module_id")
                    or labels.get("function_name") or labels.get("job_id"), 128)
    ev.host = _s(labels.get("instance_id") or labels.get("pod_name") or labels.get("node_name"), 128)
    if isinstance(res, dict) and res.get("type"):
        ev.add_attr("resource.type", res.get("type"), ctx.limits)
    for k in ("project_id", "namespace_name", "cluster_name", "location", "revision_name"):
        if labels.get(k):
            ev.add_attr("resource." + k, labels[k], ctx.limits)
    tr = rec.get("trace")
    if isinstance(tr, str):
        ev.trace_id = tr.rsplit("/", 1)[-1][:64]
    ev.span_id = _s(rec.get("spanId"), 64)
    ev.logger = _s((rec.get("logName") or "").rsplit("/", 1)[-1] or None, 200)
    hr = rec.get("httpRequest")
    if isinstance(hr, dict):
        if isinstance(hr.get("status"), int):
            ev.http_status = hr["status"]
        ev.http_method = _s(hr.get("requestMethod"), 16)
        ev.http_path = _s(hr.get("requestUrl"), 300)
    src = rec.get("sourceLocation")
    if isinstance(src, dict):
        ev.add_attr("source", "%s:%s (%s)" % (src.get("file"), src.get("line"), src.get("function")), ctx.limits)
    op = rec.get("operation")
    if isinstance(op, dict) and op.get("id"):
        ev.request_id = _s(op.get("id"), 128)
    lbl = rec.get("labels")
    if isinstance(lbl, dict):
        for k, v in list(lbl.items())[:16]:
            ev.add_attr("labels." + k, v, ctx.limits)
    if "jsonPayload" in rec and isinstance(rec["jsonPayload"], dict):
        jp = rec["jsonPayload"]
        ev.message = _s(jp.get("message") or jp.get("msg") or jp.get("event") or jp.get("textPayload") or jp.get("log"),
                        ctx.limits.max_message_chars) or ""
        exc = jp.get("exception") or jp.get("stack_trace") or jp.get("stackTrace") or jp.get("error")
        if exc:
            ev.exceptions = extract_exception(exc, ctx.limits.max_frames)
        elif "@type" in jp and "ReportedErrorEvent" in str(jp.get("@type")) and jp.get("message"):
            ev.exceptions = extract_exception(jp.get("message"), ctx.limits.max_frames)
        if jp.get("serviceContext") and isinstance(jp["serviceContext"], dict):
            ev.service = ev.service or _s(jp["serviceContext"].get("service"), 128)
        for k, v in list(jp.items())[:32]:
            if k not in ("message", "msg", "exception", "stack_trace", "stackTrace", "error"):
                ev.add_attr(k, v, ctx.limits)
        if ev.message and "\n" in ev.message and not ev.exceptions:
            lines = ev.message.split("\n")
            excs, hint = parse_exception_block(lines[1:], lines[0], ctx.limits.max_frames)
            if excs:
                ev.exceptions = excs
                ev.category_hint = hint
            ev.message = lines[0]
    elif "protoPayload" in rec and isinstance(rec["protoPayload"], dict):
        pp = rec["protoPayload"]
        ev.message = _s(pp.get("methodName") or pp.get("@type"), ctx.limits.max_message_chars) or ""
        st = pp.get("status")
        if isinstance(st, dict) and st.get("message"):
            ev.exceptions = [ExceptionInfo(_s(st.get("code"), 32), _s(st.get("message"), 1000))]
        ev.add_attr("protoPayload.methodName", pp.get("methodName"), ctx.limits)
        ev.add_attr("protoPayload.resourceName", pp.get("resourceName"), ctx.limits)
    else:
        ev.message = _s(rec.get("textPayload"), ctx.limits.max_message_chars) or ""
    consumed.update({"timestamp", "receiveTimestamp", "severity", "resource", "trace", "spanId", "logName", "httpRequest",
                     "sourceLocation", "operation", "labels", "jsonPayload", "protoPayload", "textPayload", "insertId",
                     "traceSampled", "logging.googleapis.com/trace", "logging.googleapis.com/spanId"})


def _n_cloudwatch_event(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("timestamp"))
    if rec.get("ingestionTime"):
        ev.ts_observed, _ = ctx.ts(rec.get("ingestionTime"))
    ev.message = _s(rec.get("message"), ctx.limits.max_message_chars) or ""
    if rec.get("logStreamName"):
        ev.add_attr("logStreamName", rec.get("logStreamName"), ctx.limits)
    consumed.update({"timestamp", "ingestionTime", "message", "logStreamName", "eventId", "id"})


def _n_cloudwatch_insights(rec, ev, ctx, consumed) -> None:
    fields = rec.get("_fields") or {}
    set_ts(ev, ctx, fields.get("@timestamp") or fields.get("timestamp"))
    ev.message = _s(fields.get("@message") or fields.get("message"), ctx.limits.max_message_chars) or ""
    if fields.get("@logStream"):
        ev.add_attr("logStreamName", fields.get("@logStream"), ctx.limits)
    if fields.get("@log"):
        ev.add_attr("logGroup", fields.get("@log"), ctx.limits)
    for k, v in fields.items():
        if not k.startswith("@") and k not in ("message", "timestamp"):
            ev.add_attr(k, v, ctx.limits)
    consumed.update({"_fields"})


def _n_loki_line(rec, ev, ctx, consumed) -> None:
    set_ts(ev, ctx, rec.get("timestamp"))
    ev.message = _s(rec.get("line"), ctx.limits.max_message_chars) or ""
    labels = rec.get("labels") or {}
    if isinstance(labels, dict):
        ev.service = _s(labels.get("app") or labels.get("service") or labels.get("service_name") or labels.get("job")
                        or labels.get("container"), 128)
        ev.host = _s(labels.get("host") or labels.get("instance") or labels.get("pod") or labels.get("node_name"), 128)
        ev.env = _s(labels.get("env") or labels.get("environment"), 64)
        lvl = labels.get("level") or labels.get("severity") or labels.get("detected_level")
        if lvl:
            ev.set_level(_s(lvl, 32))
        for k, v in list(labels.items())[:24]:
            ev.add_attr("label." + k, v, ctx.limits)
    consumed.update({"timestamp", "line", "labels"})


def _n_apple_ips(rec, ev, ctx, consumed) -> None:
    hdr = rec.get("_header") or {}
    set_ts(ev, ctx, rec.get("captureTime") or hdr.get("timestamp"))
    ev.set_level("fatal")
    ev.process = _s(rec.get("procName") or hdr.get("app_name") or hdr.get("name"), 128)
    ev.app = _s(hdr.get("app_name") or rec.get("coalitionName"), 128)
    exc = rec.get("exception") or {}
    typ = None
    if isinstance(exc, dict):
        typ = _s(exc.get("type"), 100)
        sig = exc.get("signal")
        if sig:
            typ = "%s (%s)" % (typ, sig) if typ else str(sig)
        msg = _s(exc.get("codes") or exc.get("subtype"), 500)
    else:
        msg = None
    term = rec.get("termination")
    if isinstance(term, dict) and term.get("indicator"):
        msg = ((msg + "; ") if msg else "") + _s(term.get("indicator"), 300)
    frames: List[Frame] = []
    threads = rec.get("threads") or []
    ft = rec.get("faultingThread", 0)
    images = rec.get("usedImages") or []
    if isinstance(threads, list) and isinstance(ft, int) and ft < len(threads) and isinstance(threads[ft], dict):
        for fr in (threads[ft].get("frames") or [])[: ctx.limits.max_frames]:
            if not isinstance(fr, dict):
                continue
            idx = fr.get("imageIndex")
            image = images[idx].get("name") if isinstance(idx, int) and idx < len(images) and isinstance(images[idx], dict) else None
            func = _s(fr.get("symbol"), 200) or ("%s+0x%x" % (image, fr.get("imageOffset")) if image and isinstance(fr.get("imageOffset"), int) else None)
            file = _s(fr.get("sourceFile"), 300) or image
            line = fr.get("sourceLine") if isinstance(fr.get("sourceLine"), int) else None
            from .exceptions import _in_app
            frames.append(Frame(func, file, line, _in_app(func, file)))
    ev.exceptions = [ExceptionInfo(typ or "crash", msg, frames)]
    ev.message = "%s crashed: %s" % (ev.process or "process", typ or "unknown exception")
    ev.category_hint = "application_crash"
    for k in ("bundleID", "version", "osVersion", "incident", "bug_type"):
        v = rec.get(k) if k in rec else hdr.get(k)
        if v is not None:
            ev.add_attr(k, v, ctx.limits)
    consumed.update(rec.keys())


DIALECTS: List[Dialect] = [
    Dialect("otlp", "OpenTelemetry OTLP/JSON log record", "any",
            lambda r: 1.0 if _any(r, "timeUnixNano", "observedTimeUnixNano") and _any(r, "body", "severityText", "severityNumber") else 0.0,
            _n_otlp, "otlp/otlp-logs.json", "ExportLogsServiceRequest envelope (resourceLogs/scopeLogs/logRecords) or bare records"),
    Dialect("serilog-compact", "Serilog CompactJsonFormatter", "C#/.NET",
            lambda r: 1.0 if "@t" in r and _any(r, "@m", "@mt") else 0.0, _n_serilog_compact, "dotnet/serilog-compact.ndjson"),
    Dialect("serilog-json", "Serilog JsonFormatter", "C#/.NET",
            lambda r: 1.0 if _has(r, "Timestamp", "Level") and _any(r, "RenderedMessage", "MessageTemplate") else 0.0,
            _n_serilog_json, "dotnet/serilog-json.ndjson"),
    Dialect("log4j2-json", "log4j2 JsonLayout", "Java/Kotlin/Scala",
            lambda r: 1.0 if (isinstance(r.get("instant"), dict) or "timeMillis" in r) and "loggerName" in r else 0.0,
            _n_log4j2, "jvm/log4j2-json.ndjson", "JsonTemplateLayout with EcsLayout is handled by the ECS dialect"),
    Dialect("logstash-logback", "Logback logstash-logback-encoder", "Java/Kotlin/Scala",
            lambda r: 1.0 if "@timestamp" in r and "logger_name" in r and "level" in r else 0.0,
            _n_logstash, "jvm/logstash-logback.ndjson"),
    Dialect("python-json-logger", "python-json-logger", "Python",
            lambda r: 1.0 if "levelname" in r and _any(r, "asctime", "message", "name") else 0.0,
            _n_python_json, "python/python-json-logger.ndjson"),
    Dialect("structlog-json", "structlog JSONRenderer", "Python",
            lambda r: 1.0 if "event" in r and "level" in r and "timestamp" in r and "msg" not in r else 0.0,
            _n_structlog, "python/structlog.ndjson"),
    Dialect("loguru-serialized", "Loguru serialize=True", "Python",
            lambda r: 1.0 if isinstance(r.get("record"), dict) and "text" in r else 0.0, _n_loguru, "python/loguru.ndjson"),
    Dialect("pino", "Pino", "JavaScript/TypeScript",
            lambda r: 1.0 if isinstance(r.get("level"), int) and "time" in r and "msg" in r and "v" not in r else 0.0,
            _n_pino, "node/pino.ndjson", "numeric levels 10..60"),
    Dialect("bunyan", "Bunyan", "JavaScript/TypeScript",
            lambda r: 1.0 if isinstance(r.get("level"), int) and "v" in r and "msg" in r and "hostname" in r else 0.0,
            _n_bunyan, "node/bunyan.ndjson"),
    Dialect("winston-json", "Winston format.json", "JavaScript/TypeScript",
            lambda r: 0.8 if isinstance(r.get("level"), str) and "message" in r and _any(r, "timestamp", "service", "stack", "label") else 0.0,
            _n_winston, "node/winston.ndjson"),
    Dialect("slog-json", "Go log/slog JSONHandler", "Go",
            lambda r: 0.9 if _has(r, "time", "level", "msg") and isinstance(r.get("level"), str) and r.get("level", "").isupper() else 0.0,
            _n_slog, "go/slog.ndjson"),
    Dialect("zap-json", "Zap JSON encoder", "Go",
            lambda r: 1.0 if "msg" in r and "level" in r and ("ts" in r or "caller" in r) and isinstance(r.get("level"), str) else 0.0,
            _n_zap, "go/zap.ndjson"),
    Dialect("zerolog", "Zerolog", "Go",
            lambda r: 0.9 if _has(r, "level", "time", "message") and isinstance(r.get("level"), str) else 0.0,
            _n_zerolog, "go/zerolog.ndjson"),
    Dialect("tracing-json", "tracing-subscriber JSON", "Rust",
            lambda r: 1.0 if isinstance(r.get("fields"), dict) and "target" in r and "level" in r else 0.0,
            _n_tracing, "rust/tracing-json.ndjson"),
    Dialect("monolog-json", "Monolog JsonFormatter", "PHP",
            lambda r: 1.0 if _has(r, "message", "channel", "level_name") else 0.0, _n_monolog, "php/monolog-json.ndjson"),
    Dialect("ecs", "Elastic Common Schema", "any",
            lambda r: 1.0 if "@timestamp" in r and (_get(r, ("log.level",))[0] or _get(r, ("ecs.version",))[0]) else 0.0,
            _n_ecs, "ecs/ecs.ndjson", "nested or dotted keys"),
    Dialect("journal-json", "systemd journal (journalctl -o json)", "any",
            lambda r: 1.0 if "__REALTIME_TIMESTAMP" in r or (_has(r, "MESSAGE", "PRIORITY")) else 0.0,
            _n_journal, "journal/journal.json"),
    Dialect("docker-json-file", "Docker json-file logging driver", "any",
            lambda r: 1.0 if _has(r, "log", "stream", "time") else 0.0, None, "docker/docker-json-file.log",
            "inner text reassembled across records"),
    Dialect("cri", "Kubernetes CRI (nested, via cri parser)", "any", lambda r: 0.0, None, "cri/cri.log"),
    Dialect("cloudwatch-event", "AWS CloudWatch Logs event (GetLogEvents/FilterLogEvents/subscription)", "any",
            lambda r: 1.0 if "message" in r and isinstance(r.get("timestamp"), int) and _any(r, "ingestionTime", "logStreamName", "eventId", "id") else 0.0,
            None, "cloudwatch/get-log-events.json", "inner message parsed as text/JSON"),
    Dialect("cloudwatch-insights", "AWS CloudWatch Logs Insights GetQueryResults row", "any",
            lambda r: 0.0, _n_cloudwatch_insights, "cloudwatch/insights-results.json"),
    Dialect("azure-record", "Azure Monitor diagnostic settings export record", "any",
            lambda r: 1.0 if _has(r, "time", "resourceId") and _any(r, "category", "operationName") else 0.0,
            _n_azure_record, "azure/diagnostic-export.json"),
    Dialect("azure-row", "Azure Log Analytics / Application Insights query API row", "any",
            lambda r: 0.0, _n_azure_row, "azure/query-tables.json"),
    Dialect("gcp-logentry", "Google Cloud Logging LogEntry", "any",
            lambda r: 1.0 if ("logName" in r or "insertId" in r) and _any(r, "textPayload", "jsonPayload", "protoPayload") else 0.0,
            None, "gcp/logentries.json", "textPayload parsed as text; jsonPayload fields mapped"),
    Dialect("loki-logcli", "Grafana Loki logcli --output=jsonl", "any",
            lambda r: 1.0 if _has(r, "labels", "line", "timestamp") else 0.0, None, "loki/logcli.jsonl",
            "line parsed as text/JSON"),
    Dialect("loki-stream", "Grafana Loki query_range streams result", "any", lambda r: 0.0, None, "loki/query-range.json"),
    Dialect("apple-ips", "Apple .ips crash report (JSON)", "Swift/Objective-C",
            lambda r: 1.0 if "faultingThread" in r and "threads" in r else 0.0, _n_apple_ips, "apple/crash.ips"),
    Dialect("generic-json", "generic JSON object (common key names)", "any", lambda r: 0.2, _n_generic, "json/generic.ndjson",
            "timestamp/level/message/exception located by common key names"),
]
_DIALECT_BY_ID = {d.id: d for d in DIALECTS}
_NESTED_TEXT_DIALECTS = {"docker-json-file", "cloudwatch-event", "gcp-logentry", "loki-logcli", "loki-stream"}


def detect_dialect(records: List[Dict[str, Any]]) -> Tuple[str, float]:
    if not records:
        return "generic-json", 0.0
    totals: Dict[str, float] = {}
    for rec in records:
        if not isinstance(rec, dict):
            continue
        for d in DIALECTS:
            try:
                sc = d.signature(rec)
            except Exception:
                sc = 0.0
            if sc:
                totals[d.id] = totals.get(d.id, 0.0) + sc
    if not totals:
        return "generic-json", 0.2
    best = max(totals.items(), key=lambda kv: (kv[1], -DIALECTS.index(_DIALECT_BY_ID[kv[0]])))
    n = float(len(records))
    return best[0], min(1.0, best[1] / n)


# ---------------------------------------------------------------------------
# envelopes (document shapes)
# ---------------------------------------------------------------------------
class Envelope:
    __slots__ = ("id", "detect", "item_paths", "capture_paths", "dialect", "label")

    def __init__(self, id_: str, detect, item_paths, capture_paths, dialect: Optional[str], label: str):
        self.id = id_
        self.detect = detect
        self.item_paths = item_paths
        self.capture_paths = capture_paths
        self.dialect = dialect
        self.label = label


ENVELOPES: List[Envelope] = [
    Envelope("otlp", lambda h: '"resourceLogs"' in h, [("resourceLogs", "*", "scopeLogs", "*", "logRecords")],
             [("resourceLogs", "*", "resource"), ("resourceLogs", "*", "scopeLogs", "*", "scope")], "otlp",
             "OTLP ExportLogsServiceRequest"),
    Envelope("cloudwatch-subscription", lambda h: '"logEvents"' in h and '"messageType"' in h, [("logEvents",)],
             [("logGroup",), ("logStream",), ("owner",)], "cloudwatch-event", "CloudWatch Logs subscription filter (DATA_MESSAGE)"),
    Envelope("cloudwatch-events", lambda h: '"events"' in h and ('"nextForwardToken"' in h or '"ingestionTime"' in h
                                                              or '"searchedLogStreams"' in h or '"logStreamName"' in h),
             [("events",)], [], "cloudwatch-event", "CloudWatch GetLogEvents / FilterLogEvents response"),
    Envelope("cloudwatch-insights", lambda h: '"results"' in h and '"field"' in h and '"value"' in h, [("results",)], [],
             "cloudwatch-insights", "CloudWatch Logs Insights GetQueryResults response"),
    Envelope("azure-tables", lambda h: '"tables"' in h and '"columns"' in h, [("tables", "*", "rows")],
             [("tables", "*", "columns"), ("tables", "*", "name")], "azure-row", "Azure Log Analytics / App Insights query API"),
    Envelope("loki-streams", lambda h: '"resultType"' in h and ('"streams"' in h or '"values"' in h),
             [("data", "result", "*", "values")], [("data", "result", "*", "stream")], "loki-stream", "Loki query_range streams"),
    Envelope("elasticsearch-hits", lambda h: '"hits"' in h and '"_source"' in h, [("hits", "hits")], [], None,
             "Elasticsearch search response (_source unwrapped)"),
    Envelope("records", lambda h: h.lstrip().startswith("{") and '"records"' in h[:200], [("records",)], [], None, "{\"records\": [...]}"),
    Envelope("events", lambda h: h.lstrip().startswith("{") and '"events"' in h[:200], [("events",)], [], None, "{\"events\": [...]}"),
    Envelope("entries", lambda h: h.lstrip().startswith("{") and '"entries"' in h[:200], [("entries",)], [], None, "{\"entries\": [...]}"),
    Envelope("logs", lambda h: h.lstrip().startswith("{") and '"logs"' in h[:200], [("logs",)], [], None, "{\"logs\": [...]}"),
    Envelope("items", lambda h: h.lstrip().startswith("{") and '"items"' in h[:200], [("items",)], [], None, "{\"items\": [...]}"),
    Envelope("messages", lambda h: h.lstrip().startswith("{") and '"messages"' in h[:200], [("messages",)], [], None, "{\"messages\": [...]}"),
    Envelope("Records", lambda h: h.lstrip().startswith("{") and '"Records"' in h[:200], [("Records",)], [], None, "{\"Records\": [...]}"),
    Envelope("data-array", lambda h: h.lstrip().startswith("{") and re.match(r'\s*\{\s*"data"\s*:\s*\[', h) is not None,
             [("data",)], [], None, "{\"data\": [...]}"),
]


class _Shape:
    __slots__ = ("kind", "envelope", "dialect", "confidence", "records")

    def __init__(self, kind: Optional[str], envelope: Optional[Envelope], dialect: str, confidence: float, records: list):
        self.kind = kind              # ndjson | array | envelope | root-objects | None
        self.envelope = envelope
        self.dialect = dialect
        self.confidence = confidence
        self.records = records


def _analyze_sample(sample, limits) -> _Shape:
    cached = getattr(sample, "shape_cache", None)
    if cached is not None:
        return cached
    shape = _analyze_text(sample.text, sample.lines, limits)
    try:
        sample.shape_cache = shape
    except AttributeError:
        pass
    return shape


def _analyze_text(text: str, lines: List[str], limits) -> _Shape:
    stripped = text.lstrip()
    if not stripped or stripped[0] not in "{[":
        return _Shape(None, None, "generic-json", 0.0, [])
    nonblank = [ln for ln in lines if ln.strip()]
    head = text[:8192]
    envelope = None
    for env in ENVELOPES:
        try:
            if env.detect(head):
                envelope = env
                break
        except Exception:
            continue
    # NDJSON: most non-blank lines are complete JSON objects (a single-line envelope document is not NDJSON)
    if nonblank and stripped[0] == "{" and not (len(nonblank) == 1 and envelope is not None):
        parsed = 0
        recs: List[Any] = []
        for ln in nonblank[:64]:
            st = ln.strip()
            if st.startswith("{") and st.endswith("}"):
                try:
                    recs.append(json.loads(st))
                    parsed += 1
                    continue
                except ValueError:
                    pass
        if parsed and parsed >= max(1, int(0.6 * min(len(nonblank), 64))):
            recs = [r for r in recs if isinstance(r, dict)]
            # apple .ips: header + body objects
            if recs and ("bug_type" in recs[0] or "incident_id" in recs[0]) and len(nonblank) >= 2:
                return _Shape("root-objects", None, "apple-ips", 0.95, recs)
            dialect, conf = detect_dialect(recs[:32])
            return _Shape("ndjson", None, dialect, max(conf, 0.5) * (parsed / float(min(len(nonblank), 64))), recs)
    if stripped[0] == "[":
        kind = "array"
        paths = [()]
        captures: list = []
    elif envelope is not None:
        kind = "envelope"
        paths = envelope.item_paths
        captures = envelope.capture_paths
    else:
        kind = "root-objects"
        paths = [ROOT]
        captures = []
    scanner = JsonItemScanner(paths, captures, limits.max_record_bytes)
    items: List[Any] = []
    context: Dict[str, Any] = {}
    for k, path, raw, _ln in scanner.feed(text):
        if k == "item" and raw is not None and len(items) < 32:
            try:
                items.append(json.loads(raw))
            except ValueError:
                pass
        elif k == "context" and raw is not None:
            try:
                context[path[-1] if isinstance(path[-1], str) else str(path)] = json.loads(raw)
            except ValueError:
                pass
    if scanner.error and not items:
        return _Shape(None, None, "generic-json", 0.0, [])
    if envelope is not None and envelope.dialect:
        dialect = envelope.dialect
        conf = 0.95
        recs = items
    elif envelope is not None and envelope.id == "elasticsearch-hits":
        recs = [it.get("_source") for it in items if isinstance(it, dict) and isinstance(it.get("_source"), dict)]
        dialect, conf = detect_dialect(recs)
    else:
        recs = [it for it in items if isinstance(it, dict)]
        if recs and ("bug_type" in recs[0] or "incident_id" in recs[0]) and len(items) >= 2:
            return _Shape("root-objects", None, "apple-ips", 0.95, recs)
        dialect, conf = detect_dialect(recs[:32])
        conf = max(conf, 0.5) if items else 0.0
    return _Shape(kind, envelope, dialect, conf, recs)


_NAME_TO_DIALECTS = {
    "otlp-json": {"otlp"}, "ecs-json": {"ecs"}, "docker-json": {"docker-json-file"}, "journal-json": {"journal-json"},
    "cloudwatch-json": {"cloudwatch-event", "cloudwatch-insights"}, "azure-json": {"azure-record", "azure-row"},
    "gcp-json": {"gcp-logentry"}, "loki-json": {"loki-logcli", "loki-stream"}, "apple-ips": {"apple-ips"},
}


def sniff(name: str, sample, ctx) -> float:
    shape = _analyze_sample(sample, ctx.limits)
    if shape.kind is None:
        return 0.0
    if name in _NAME_TO_DIALECTS:
        return 0.97 if shape.dialect in _NAME_TO_DIALECTS[name] else 0.0
    if name == "ndjson":
        return 0.85 if shape.kind == "ndjson" else 0.0
    if name == "json":
        return 0.85 if shape.kind in ("array", "envelope", "root-objects") else 0.0
    return 0.0


# ---------------------------------------------------------------------------
# parser
# ---------------------------------------------------------------------------
class StructuredParser(BaseParser):
    family = "json"

    def __init__(self, name: str = "json"):
        super().__init__(name)
        self._nested_sink: Optional[NestedSink] = None
        self._ips_header: Optional[Dict[str, Any]] = None
        self._dialect = "generic-json"
        self._envelope: Optional[Envelope] = None

    # -- nested text ----------------------------------------------------------
    def _sink(self, ctx: ParseContext) -> "NestedSink":
        if self._nested_sink is None:
            self._nested_sink = NestedSink(ctx, self.name, self._map_nested)
        return self._nested_sink

    def _map_nested(self, obj, ctx, line_no, offset, base):
        return self._record_event(obj, ctx, line_no, offset, None, base_meta=base)

    def _nested(self, text: str, base: Dict[str, Any], line_no: int, offset: Optional[int], ctx: ParseContext
                ) -> List[Event]:
        return self._sink(ctx).feed_text(text, base, line_no, offset)

    def _base_from(self, ev_ts: Optional[float], flags, attrs: Dict[str, Any], **ids) -> Dict[str, Any]:
        base = {"ts": ev_ts, "ts_flags": flags, "attrs": attrs}
        base.update({k: v for k, v in ids.items() if v})
        return base

    # -- record normalization ---------------------------------------------------
    def _record_event(self, rec: Dict[str, Any], ctx: ParseContext, line_no: int, offset: Optional[int],
                      context: Optional[Dict[str, Any]], dialect: Optional[str] = None,
                      base_meta: Optional[Dict[str, Any]] = None) -> Optional[Event]:
        limits = ctx.limits
        ev = ctx.new_event(self.name, line_no, offset)
        d = dialect or self._dialect
        consumed: set = set()
        dspec = _DIALECT_BY_ID.get(d)
        if dialect is None and self._envelope is None and dspec is not None and d not in _NESTED_TEXT_DIALECTS:
            try:
                if not dspec.signature(rec):
                    d2, conf2 = detect_dialect([rec])
                    if conf2 >= 0.8 and d2 not in _NESTED_TEXT_DIALECTS:
                        d, dspec = d2, _DIALECT_BY_ID.get(d2)
            except Exception:
                pass
        ev.layout = d
        if d == "otlp":
            _n_otlp(rec, ev, ctx, consumed, context)
        elif d == "gcp-logentry":
            _n_gcp(rec, ev, ctx, consumed)
        elif dspec is not None and dspec.normalize is not None:
            dspec.normalize(rec, ev, ctx, consumed)
        elif d in ("cloudwatch-event",):
            _n_cloudwatch_event(rec, ev, ctx, consumed)
        elif d == "loki-logcli":
            _n_loki_line(rec, ev, ctx, consumed)
        # generic fill for anything still missing
        if ev.ts is None and not ev.ts_flags:
            k, v = _get(rec, _TS_KEYS)
            if k is not None:
                set_ts(ev, ctx, v)
                consumed.add(k)
        if ev.level_num is None:
            k, v = _get(rec, _LEVEL_KEYS)
            if k is not None:
                if isinstance(v, bool):
                    pass
                elif isinstance(v, int):
                    if k in ("PRIORITY", "priority") and 0 <= v <= 7:
                        num, text = level_from_syslog(v)
                        ev.set_level(text, num)
                    elif v >= 100:
                        ev.set_level(str(v), level_from_monolog(v))
                    elif v >= 10 and k == "level":
                        ev.set_level(str(v), level_from_pino(v))
                    else:
                        ev.set_level(str(v), level_from_python(v * 10) if v <= 5 else None)
                    consumed.add(k)
                elif isinstance(v, str) and _LEVEL_WORD.match(v.strip()):
                    if level_from_text(v) is not None:
                        ev.set_level(v)
                        consumed.add(k)
        if not ev.message:
            k, v = _get(rec, _MSG_KEYS)
            if k is not None:
                ev.message = _s(v, limits.max_message_chars) or ""
                consumed.add(k)
        if not ev.exceptions:
            k, v = _get(rec, _EXC_KEYS)
            if k is not None:
                ev.exceptions = extract_exception(v, limits.max_frames)
                consumed.add(k)
        if ev.logger is None:
            k, v = _get(rec, _LOGGER_KEYS)
            if k is not None and isinstance(v, str):
                ev.logger = v[:200]
                consumed.add(k)
        if ev.service is None:
            k, v = _get(rec, _SERVICE_KEYS)
            if k is not None and isinstance(v, str):
                ev.service = v[:128]
                consumed.add(k)
        if ev.host is None:
            k, v = _get(rec, _HOST_KEYS)
            if k is not None and isinstance(v, str):
                ev.host = v[:128]
                consumed.add(k)
        if ev.env is None:
            k, v = _get(rec, _ENV_KEYS)
            if k is not None and isinstance(v, str):
                ev.env = v[:64]
                consumed.add(k)
        if ev.trace_id is None:
            k, v = _get(rec, _TRACE_KEYS)
            if k is not None and isinstance(v, (str, int)):
                ev.trace_id = str(v)[:64]
                consumed.add(k)
        if ev.span_id is None:
            k, v = _get(rec, _SPAN_KEYS)
            if k is not None and isinstance(v, (str, int)):
                ev.span_id = str(v)[:64]
                consumed.add(k)
        if ev.request_id is None:
            k, v = _get(rec, _REQ_KEYS)
            if k is not None and isinstance(v, (str, int)):
                ev.request_id = str(v)[:128]
                consumed.add(k)
        if ev.http_status is None:
            k, v = _get(rec, _STATUS_KEYS)
            if k is not None:
                try:
                    iv = int(v)
                    if 100 <= iv <= 599 and (k != "code" or isinstance(v, int)):
                        ev.http_status = iv
                        consumed.add(k)
                except (TypeError, ValueError):
                    pass
        if ev.http_method is None:
            k, v = _get(rec, _METHOD_KEYS)
            if k is not None and isinstance(v, str) and len(v) <= 10:
                ev.http_method = v.upper()
                consumed.add(k)
        if ev.http_path is None:
            k, v = _get(rec, _PATH_KEYS)
            if k is not None and isinstance(v, str):
                ev.http_path = v[:300]
                consumed.add(k)
        if ev.process is None:
            k, v = _get(rec, _PID_KEYS)
            if k is not None:
                ev.process = _s(v, 32)
                consumed.add(k)
        if ev.thread is None:
            k, v = _get(rec, _THREAD_KEYS)
            if k is not None:
                ev.thread = _s(v, 64)
                consumed.add(k)
        # remaining scalar fields -> attributes (bounded)
        for k, v in rec.items():
            if k in consumed or len(ev.attrs) >= limits.max_attributes_per_event:
                continue
            if isinstance(v, (str, int, float, bool)) or v is None:
                ev.add_attr(k, v, limits)
            elif isinstance(v, dict):
                for k2, v2 in list(v.items())[:16]:
                    if isinstance(v2, (str, int, float, bool)):
                        ev.add_attr(k + "." + k2, v2, limits)
            elif isinstance(v, list) and len(v) <= 8:
                ev.add_attr(k, v, limits)
        _promote_attrs(ev)
        if not ev.message:
            if ev.exceptions:
                head = ev.exceptions[0]
                ev.message = (head.type or "error") + ((": " + head.message) if head.message else "")
            else:
                ev.message = _s(rec, limits.max_message_chars) or ""
                ev.diagnostics.append("no_message_field")
        if base_meta:
            if ev.ts is None and base_meta.get("ts") is not None:
                ev.ts = base_meta["ts"]
                ev.ts_flags = tuple(base_meta.get("ts_flags", ())) + ("from_envelope",)
            elif base_meta.get("ts") is not None:
                ev.ts_observed = ev.ts_observed or base_meta["ts"]
            for key in ("service", "host", "app", "env", "trace_id", "request_id"):
                if base_meta.get(key) and getattr(ev, key) is None:
                    setattr(ev, key, base_meta[key])
            for k, v in (base_meta.get("attrs") or {}).items():
                if k not in ev.attrs:
                    ev.add_attr(k, v, limits)
        if ev.level_num is None and ev.exceptions:
            ev.set_level("error")
        if ev.message and "\n" in ev.message and not ev.exceptions:
            lines = ev.message.split("\n")
            excs, hint = parse_exception_block(lines[1:], lines[0], limits.max_frames)
            if excs:
                ev.exceptions = excs
                ev.category_hint = hint
                ev.message = lines[0]
        ev.bound(limits)
        return ev

    # -- wrapper dialects producing nested text -------------------------------------
    def _emit(self, rec: Any, ctx: ParseContext, line_no: int, offset: Optional[int], context: Dict[str, Any]
              ) -> List[Event]:
        d = self._dialect
        if d == "docker-json-file" and isinstance(rec, dict) and "log" in rec:
            ts, flags = ctx.ts(rec.get("time"))
            attrs = {"stream": rec.get("stream")} if rec.get("stream") else {}
            if isinstance(rec.get("attrs"), dict):
                for k, v in list(rec["attrs"].items())[:16]:
                    attrs[k] = v
            base = self._base_from(ts, flags, attrs)
            return self._nested(str(rec.get("log", "")), base, line_no, offset, ctx)
        if d == "cloudwatch-event" and isinstance(rec, dict) and "message" in rec:
            ts, flags = ctx.ts(rec.get("timestamp"))
            attrs = {}
            for k in ("logStreamName", "eventId"):
                if rec.get(k):
                    attrs[k] = rec[k]
            for k in ("logGroup", "logStream", "owner"):
                if context.get(k):
                    attrs[k] = context[k]
            base = self._base_from(ts, flags, attrs, service=(context.get("logGroup") or "").rsplit("/", 1)[-1] or None)
            return self._nested(str(rec.get("message", "")), base, line_no, offset, ctx)
        if d == "cloudwatch-insights" and isinstance(rec, list):
            fields = {}
            for cell in rec:
                if isinstance(cell, dict) and "field" in cell:
                    fields[str(cell["field"])] = cell.get("value")
            ev = self._record_event({"_fields": fields}, ctx, line_no, offset, context)
            if ev is not None and ev.message:
                # @message is the raw log line: parse it as nested text/JSON like every other export
                base = self._base_from(ev.ts, ev.ts_flags, {k: v for k, v in ev.attrs.items()})
                ctx.records -= 1
                return self._nested(ev.message, base, line_no, offset, ctx)
            return [ev] if ev is not None else []
        if d == "gcp-logentry" and isinstance(rec, dict) and isinstance(rec.get("textPayload"), str) \
                and not isinstance(rec.get("jsonPayload"), dict):
            ev = self._record_event(rec, ctx, line_no, offset, context)
            if ev is None:
                return []
            text = rec.get("textPayload", "")
            if text.lstrip().startswith("{") or "\n" in text or len(text) > 0:
                base = self._base_from(ev.ts, ev.ts_flags, dict(ev.attrs), service=ev.service, host=ev.host,
                                       trace_id=ev.trace_id, request_id=ev.request_id)
                base["level"] = ev.level_text
                base["level_num"] = ev.level_num
                ctx.records -= 1
                return self._nested(text, base, line_no, offset, ctx)
            return [ev]
        if d == "loki-stream" and isinstance(rec, list) and len(rec) >= 2:
            ts, flags = ctx.ts(rec[0])
            labels = context.get("stream") if isinstance(context.get("stream"), dict) else {}
            attrs = {"label." + k: v for k, v in list(labels.items())[:24]}
            base = self._base_from(ts, flags, attrs,
                                   service=labels.get("app") or labels.get("service") or labels.get("service_name") or labels.get("job") or labels.get("container"),
                                   host=labels.get("host") or labels.get("instance") or labels.get("pod"),
                                   env=labels.get("env") or labels.get("environment"))
            lvl = labels.get("level") or labels.get("severity") or labels.get("detected_level")
            if lvl:
                base["level"] = lvl
            return self._nested(str(rec[1]), base, line_no, offset, ctx)
        if d == "loki-logcli" and isinstance(rec, dict) and "line" in rec:
            ev = self._record_event(rec, ctx, line_no, offset, context)
            if ev is None:
                return []
            base = self._base_from(ev.ts, ev.ts_flags, dict(ev.attrs), service=ev.service, host=ev.host, env=ev.env)
            base["level"] = ev.level_text
            base["level_num"] = ev.level_num
            ctx.records -= 1
            return self._nested(str(rec.get("line", "")), base, line_no, offset, ctx)
        if d == "azure-row" and isinstance(rec, list):
            cols = context.get("columns")
            if not isinstance(cols, list):
                ctx.failure("azure-row-without-columns", "Azure table row seen before its columns definition", line_no)
                return []
            names = [c.get("name") if isinstance(c, dict) else str(c) for c in cols]
            obj = {names[i]: rec[i] for i in range(min(len(names), len(rec)))}
            if context.get("name"):
                obj.setdefault("_table", context.get("name"))
            ev = self._record_event(obj, ctx, line_no, offset, context, "azure-row")
            return [ev] if ev is not None else []
        if d == "apple-ips" and isinstance(rec, dict):
            if "bug_type" in rec or "incident_id" in rec:
                self._ips_header = rec
                return []
            rec = dict(rec)
            rec["_header"] = self._ips_header or {}
            ev = self._record_event(rec, ctx, line_no, offset, context, "apple-ips")
            return [ev] if ev is not None else []
        if isinstance(rec, dict):
            if self._envelope is not None and self._envelope.id == "elasticsearch-hits" and isinstance(rec.get("_source"), dict):
                rec = rec["_source"]
            ev = self._record_event(rec, ctx, line_no, offset, context)
            return [ev] if ev is not None else []
        ctx.failure("non-object-record", "JSON record is not an object: %s" % type(rec).__name__, line_no)
        return []

    # -- main ----------------------------------------------------------------------
    def parse(self, lines: Lines, ctx: ParseContext) -> Iterator[Event]:
        limits = ctx.limits
        head_lines: List[Tuple[int, int, str, bool]] = []
        it = iter(lines)
        head_chars = 0
        for item in it:
            head_lines.append(item)
            head_chars += len(item[2]) + 1
            if len(head_lines) >= limits.detect_sample_lines or head_chars >= limits.detect_sample_bytes:
                break
        head_text = "\n".join(h[2] for h in head_lines)
        shape = _analyze_text(head_text, [h[2] for h in head_lines], limits)
        forced = _NAME_TO_DIALECTS.get(self.name)
        if forced and shape.dialect not in forced:
            # --input-format pinned a platform adapter; keep the pinned dialect family
            shape.dialect = sorted(forced)[0] if shape.kind != "envelope" or shape.envelope is None or shape.envelope.dialect not in forced else shape.envelope.dialect
        self._dialect = shape.dialect
        self._envelope = shape.envelope
        ctx.dialect = shape.dialect
        ctx.layout = shape.kind
        if shape.kind is None:
            ctx.failure("not-json", "input does not start with a JSON value", head_lines[0][0] if head_lines else None)
            return

        def _chain():
            for b in head_lines:
                yield b
            for b in it:
                yield b

        if shape.kind == "ndjson":
            text_engine: Optional[LazyTextEngine] = None
            for line_no, offset, text, truncated in _chain():
                st = text.strip()
                if not st:
                    continue
                if st[0] == "{":
                    try:
                        rec = json.loads(st)
                    except ValueError as exc:
                        if truncated:
                            ctx.failure("oversized-record", "line %d exceeded max_line_bytes and was truncated; JSON unparseable" % line_no, line_no)
                        else:
                            ctx.failure("malformed-json-line", "line %d is not valid JSON: %s" % (line_no, str(exc)[:80]), line_no)
                        continue
                    if text_engine is not None:
                        for ev in text_engine.flush():
                            yield ev
                        text_engine = None
                    for ev in self._emit(rec, ctx, line_no, offset, {}):
                        yield ev
                else:
                    # plain text between JSON lines (e.g. a stack trace printed to stdout): keep it
                    ctx.failure("non-json-line", "line %d is not JSON; parsed as text" % line_no, line_no)
                    if text_engine is None:
                        text_engine = LazyTextEngine(ctx, self.name)
                    for ev in text_engine.feed(line_no, offset, text, truncated):
                        yield ev
            if text_engine is not None:
                for ev in text_engine.flush():
                    yield ev
            if self._nested_sink is not None:
                for ev in self._nested_sink.flush():
                    yield ev
            return

        if shape.kind == "array":
            paths, captures = [()], []
        elif shape.kind == "envelope" and shape.envelope is not None:
            paths, captures = shape.envelope.item_paths, shape.envelope.capture_paths
        else:
            paths, captures = [ROOT], []
        scanner = JsonItemScanner(paths, captures, limits.max_record_bytes)
        context: Dict[str, Any] = {}
        for line_no, offset, text, truncated in _chain():
            for kind, path, raw, start_line in scanner.feed(text + "\n", line_no):
                if kind == "oversized":
                    ctx.failure("oversized-record", "JSON item at line %d exceeds max_record_bytes and was skipped" % start_line, start_line)
                    continue
                if kind == "context":
                    try:
                        context[path[-1] if isinstance(path[-1], str) else str(path)] = json.loads(raw)
                    except ValueError:
                        pass
                    continue
                try:
                    rec = json.loads(raw)
                except ValueError as exc:
                    ctx.failure("malformed-json-item", "item at line %d is not valid JSON: %s" % (start_line, str(exc)[:80]), start_line)
                    continue
                for ev in self._emit(rec, ctx, start_line, None, context):
                    yield ev
            if scanner.error:
                break
        scanner.finish()
        if scanner.error:
            ctx.failure("json-structure-error", scanner.error)
        if self._nested_sink is not None:
            for ev in self._nested_sink.flush():
                yield ev


def make_parser(name: str):
    return StructuredParser(name)
