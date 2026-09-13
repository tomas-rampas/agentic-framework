"""XML log exports, parsed incrementally with expat and all entity expansion disabled.

Security posture: external entities are never resolved (parameter entity parsing is
off and the external-entity handler refuses), *any* entity declaration aborts the
input with an ``xml-entity-rejected`` diagnostic (defeats billion-laughs style
expansion), and DOCTYPE internal subsets are rejected for the same reason.

Record boundaries: known record elements (``Event``, ``event``/``log4j:event``/
``log4net:event``/``nlog:event``, ``record``) or, for unknown documents, the
repeated children of the root element. Fragment files without a root (e.g. the
output of ``wevtutil qe /f:xml`` or log4j's XMLLayout) are wrapped in a synthetic
root before parsing.
"""
from __future__ import annotations

import re
from typing import Any, Dict, Iterator, List, Optional
from xml.parsers import expat

from ..model import Event, ExceptionInfo, Frame, level_from_text, level_from_winevt, safe_int
from .base import BaseParser, Lines, ParseContext, set_ts
from .exceptions import parse_exception_block, _in_app
from .text import _promote_attrs

KNOWN_RECORD_NAMES = {"Event", "event", "log4j:event", "log4net:event", "nlog:event", "record", "LogEntry", "logEntry",
                      "entry", "Entry", "logevent", "LogEvent", "log4j:Event"}
_XML_DECL = re.compile(r"^\s*<\?xml[^>]*\?>\s*", re.DOTALL)
_DOCTYPE = re.compile(r"^\s*<!DOCTYPE[^>\[]*(\[[^\]]*\])?\s*>\s*", re.DOTALL)
_WINEVT_NS = "http://schemas.microsoft.com/win/2004/08/events/event"


class _Node:
    __slots__ = ("tag", "attrs", "text", "children")

    def __init__(self, tag: str, attrs: Dict[str, str]):
        self.tag = tag
        self.attrs = attrs
        self.text: List[str] = []
        self.children: List["_Node"] = []

    def local(self) -> str:
        return self.tag.rsplit(":", 1)[-1]

    def child(self, name: str) -> Optional["_Node"]:
        for c in self.children:
            if c.local() == name:
                return c
        return None

    def children_named(self, name: str) -> List["_Node"]:
        return [c for c in self.children if c.local() == name]

    def get_text(self) -> str:
        return "".join(self.text).strip()

    def find(self, path: str) -> Optional["_Node"]:
        node: Optional[_Node] = self
        for part in path.split("/"):
            if node is None:
                return None
            node = node.child(part)
        return node


class EntityRejected(Exception):
    pass


def sniff(name: str, sample, ctx) -> float:
    text = sample.text.lstrip()[:4096]
    if not text.startswith("<"):
        return 0.0
    if name == "winevt-xml":
        if _WINEVT_NS in text or re.search(r"<Events?\b", text) and "<System>" in text:
            return 0.97
        return 0.0
    if re.match(r"<(\?xml|[A-Za-z_][\w:.-]*)", text) and (">" in text):
        return 0.85
    return 0.0


class XmlParser(BaseParser):
    family = "xml"

    def __init__(self, name: str = "xml"):
        super().__init__(name)

    def parse(self, lines: Lines, ctx: ParseContext) -> Iterator[Event]:
        limits = ctx.limits
        parser = expat.ParserCreate()
        parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
        state: Dict[str, Any] = {"depth": 0, "records": [], "record_depth": None, "record_name": None,
                                 "mode": None, "stack": [], "capturing": False, "nodes": 0, "pending_top": None,
                                 "top_count": 0, "cur_line": 0, "rec_line": 0, "oversized": 0}
        events_out: List[Event] = []

        def reject_entity(*args):
            raise EntityRejected("entity declaration")

        def external_ref(*args):
            raise EntityRejected("external entity reference")

        def doctype(name, sysid, pubid, has_internal_subset):
            if has_internal_subset:
                raise EntityRejected("DOCTYPE internal subset")

        parser.EntityDeclHandler = reject_entity
        parser.ExternalEntityRefHandler = external_ref
        parser.StartDoctypeDeclHandler = doctype

        def start(tag, attrs):
            state["depth"] += 1
            depth = state["depth"]
            stack = state["stack"]
            if state["capturing"]:
                if state["nodes"] < 2048:
                    node = _Node(tag, attrs)
                    stack[-1].children.append(node)
                    stack.append(node)
                    state["nodes"] += 1
                else:
                    stack.append(_Node(tag, {}))
                    state["oversized"] += 1
                return
            rd = state["record_depth"]
            if rd is None:
                if tag in KNOWN_RECORD_NAMES and depth >= 2:
                    state["record_depth"], state["record_name"], state["mode"] = depth, tag, "known"
                elif depth == 3 and state["mode"] is None:
                    # first grandchild of the synthetic root: children of the file's root are records
                    state["record_depth"], state["record_name"], state["mode"] = 3, None, "root-children"
                elif depth == 2:
                    state["top_count"] += 1
                    if state["top_count"] >= 2 and state["mode"] is None:
                        state["record_depth"], state["record_name"], state["mode"] = 2, None, "fragment"
                rd = state["record_depth"]
            if rd is not None and depth == rd and (state["record_name"] is None or tag == state["record_name"]):
                node = _Node(tag, attrs)
                state["stack"] = [node]
                state["capturing"] = True
                state["nodes"] = 1
                state["rec_line"] = state["cur_line"]
                state["oversized"] = 0

        def end(tag):
            depth = state["depth"]
            if state["capturing"]:
                stack = state["stack"]
                if depth == state["record_depth"]:
                    state["capturing"] = False
                    root = stack[0]
                    if state["oversized"]:
                        ctx.diag("xml-record-truncated", "warning",
                                 "record at line %d exceeded the node limit; %d element(s) dropped" % (state["rec_line"], state["oversized"]), state["rec_line"])
                    state["records"].append((root, state["rec_line"]))
                else:
                    stack.pop()
            elif depth == 2 and state["mode"] is None and state["top_count"] == 1:
                state["pending_top"] = True
            state["depth"] -= 1

        def chars(data):
            if state["capturing"]:
                node = state["stack"][-1]
                if sum(len(t) for t in node.text) < limits.max_exception_chars:
                    node.text.append(data)

        parser.StartElementHandler = start
        parser.EndElementHandler = end
        parser.CharacterDataHandler = chars
        parser.buffer_text = True

        ctx.layout = "xml"
        prolog_done = False
        prolog: List[str] = []
        try:
            parser.Parse("<log-triage-root>", False)
            for line_no, offset, text, truncated in lines:
                state["cur_line"] = line_no
                if not prolog_done:
                    # Buffer the prolog (XML declaration, DOCTYPE, comments) until the first element start.
                    prolog.append(text)
                    joined = "\n".join(prolog)
                    probe = _XML_DECL.sub("", joined, count=1)
                    probe = re.sub(r"^\s*<!--.*?-->\s*", "", probe, count=1, flags=re.DOTALL)
                    if "<!DOCTYPE" in probe and not _DOCTYPE.match(probe):
                        if len(prolog) > 64:
                            ctx.failure("xml-malformed", "unterminated DOCTYPE declaration in the first 64 lines")
                            return
                        continue  # DOCTYPE not complete yet
                    dm = _DOCTYPE.match(probe)
                    if dm:
                        if "<!ENTITY" in dm.group(0):
                            ctx.failure("xml-entity-rejected", "DOCTYPE declares entities; input rejected (entities are never expanded)", line_no)
                            return
                        ctx.diag("xml-doctype-ignored", "info", "DOCTYPE declaration ignored (no DTD is ever loaded)")
                        probe = _DOCTYPE.sub("", probe, count=1)
                    if not probe.strip():
                        if len(prolog) > 64:
                            ctx.failure("xml-malformed", "no element found in the first 64 lines")
                            return
                        continue
                    prolog_done = True
                    text = probe
                try:
                    parser.Parse(text + "\n", False)
                except EntityRejected as exc:
                    ctx.failure("xml-entity-rejected", "input rejected at line %d: %s (entities are never expanded)" % (line_no, exc), line_no)
                    return
                except expat.ExpatError as exc:
                    ctx.failure("xml-malformed", "XML parse error at line %d: %s; records before the error were kept" % (line_no, expat.errors.messages.get(exc.code, str(exc)) if hasattr(expat, "errors") else exc), line_no)
                    break
                for root, rec_line in state["records"]:
                    ev = self._record(root, rec_line, ctx)
                    if ev is not None:
                        yield ev
                state["records"] = []
            try:
                parser.Parse("</log-triage-root>", True)
            except (expat.ExpatError, EntityRejected):
                if state["capturing"]:
                    ctx.failure("xml-unterminated", "document ended inside a record element; partial record dropped")
            for root, rec_line in state["records"]:
                ev = self._record(root, rec_line, ctx)
                if ev is not None:
                    yield ev
        finally:
            pass
        if state["mode"] is None and state["top_count"] == 1 and not state["records"] and state["record_depth"] is None:
            ctx.diag("xml-no-records", "warning", "no repeating record element found in the document")

    # -- normalizers ----------------------------------------------------------------
    def _record(self, node: _Node, line_no: int, ctx: ParseContext) -> Optional[Event]:
        limits = ctx.limits
        ev = ctx.new_event(self.name, line_no, None)
        local = node.local()
        if local == "Event" and (node.child("System") is not None):
            self._winevt(node, ev, ctx)
        elif local == "event" and node.tag.startswith("log4net"):
            self._log4net(node, ev, ctx)
        elif local == "event" and (node.tag.startswith("log4j") or node.tag.startswith("nlog")
                                   or node.child("message") is not None and "logger" in node.attrs):
            self._log4j(node, ev, ctx)
        elif local == "record" and node.child("level") is not None and node.child("logger") is not None:
            self._jul(node, ev, ctx)
        else:
            self._generic(node, ev, ctx)
        _promote_attrs(ev)
        if ev.message and "\n" in ev.message and not ev.exceptions:
            lines = ev.message.split("\n")
            excs, hint = parse_exception_block(lines[1:], lines[0], limits.max_frames)
            if excs:
                ev.exceptions = excs
                ev.category_hint = hint
            ev.message = lines[0]
        if ev.level_num is None and ev.exceptions:
            ev.set_level("error")
        ev.bound(limits)
        return ev

    def _winevt(self, node: _Node, ev: Event, ctx: ParseContext) -> None:
        limits = ctx.limits
        ev.layout = "winevt-xml"
        sysn = node.child("System")
        prov = sysn.child("Provider") if sysn else None
        provider = (prov.attrs.get("Name") or prov.attrs.get("Guid")) if prov is not None else None
        eid = (sysn.child("EventID").get_text() if sysn and sysn.child("EventID") is not None else None)
        lvl = sysn.child("Level").get_text() if sysn and sysn.child("Level") is not None else None
        tc = sysn.child("TimeCreated") if sysn else None
        if tc is not None and tc.attrs.get("SystemTime"):
            set_ts(ev, ctx, tc.attrs["SystemTime"])
        comp = sysn.child("Computer") if sysn else None
        ev.host = comp.get_text() if comp is not None else None
        ex = sysn.child("Execution") if sysn else None
        if ex is not None:
            ev.process = ex.attrs.get("ProcessID")
            ev.thread = ex.attrs.get("ThreadID")
        if safe_int(lvl) is not None:
            num, text = level_from_winevt(safe_int(lvl))
            ri = node.child("RenderingInfo")
            rtext = ri.child("Level").get_text() if ri is not None and ri.child("Level") is not None else None
            ev.set_level(rtext or text, num)
        ev.logger = provider
        ev.error_code = ("EventID:" + eid) if eid else None
        chan = sysn.child("Channel") if sysn else None
        if chan is not None:
            ev.add_attr("channel", chan.get_text(), limits)
        rid = sysn.child("EventRecordID") if sysn else None
        if rid is not None:
            ev.add_attr("event_record_id", rid.get_text(), limits)
        for k in ("Task", "Opcode", "Keywords", "Version"):
            c = sysn.child(k) if sysn else None
            if c is not None and c.get_text():
                ev.add_attr(k.lower(), c.get_text(), limits)
        data_vals: List[str] = []
        ed = node.child("EventData") or node.child("UserData")
        if ed is not None:
            for i, d in enumerate(ed.children):
                name = d.attrs.get("Name") or ("data%d" % i)
                val = d.get_text()
                if d.local() != "Data" and d.children:
                    for sub in d.children:
                        ev.add_attr(sub.local(), sub.get_text(), limits)
                    continue
                ev.add_attr(name, val, limits)
                if val:
                    data_vals.append(val)
        ri = node.child("RenderingInfo")
        msg = ri.child("Message").get_text() if ri is not None and ri.child("Message") is not None else None
        if not msg:
            msg = "; ".join(v for v in data_vals if len(v) < 500)[:limits.max_message_chars]
        ev.message = "[%s:%s] %s" % (provider or "?", eid or "?", msg or "")
        if ri is not None:
            for k in ("Task", "Opcode", "Channel", "Provider"):
                c = ri.child(k)
                if c is not None and c.get_text():
                    ev.add_attr("rendered_" + k.lower(), c.get_text(), limits)

    def _log4j(self, node: _Node, ev: Event, ctx: ParseContext) -> None:
        limits = ctx.limits
        ev.layout = "log4j-xml"
        a = node.attrs
        ev.logger = a.get("logger")
        ev.thread = a.get("thread")
        ev.set_level(a.get("level"))
        if a.get("timestamp"):
            set_ts(ev, ctx, a["timestamp"])
        m = node.child("message")
        ev.message = m.get_text() if m is not None else ""
        th = node.child("throwable")
        if th is not None and th.get_text():
            lines = th.get_text().split("\n")
            excs, hint = parse_exception_block(lines[1:], lines[0], limits.max_frames)
            ev.exceptions = excs
            ev.category_hint = hint
        loc = node.child("locationInfo")
        if loc is not None:
            ev.add_attr("location", "%s.%s(%s:%s)" % (loc.attrs.get("class"), loc.attrs.get("method"), loc.attrs.get("file"), loc.attrs.get("line")), limits)
        props = node.child("properties")
        if props is not None:
            for d in props.children_named("data"):
                ev.add_attr(d.attrs.get("name", "prop"), d.attrs.get("value"), limits)
        ndc = node.child("NDC")
        if ndc is not None and ndc.get_text():
            ev.add_attr("ndc", ndc.get_text(), limits)

    def _log4net(self, node: _Node, ev: Event, ctx: ParseContext) -> None:
        limits = ctx.limits
        ev.layout = "log4net-xml"
        a = node.attrs
        ev.logger = a.get("logger")
        ev.thread = a.get("thread")
        ev.set_level(a.get("level"))
        if a.get("timestamp"):
            set_ts(ev, ctx, a["timestamp"])
        if a.get("domain"):
            ev.app = a.get("domain")
        m = node.child("message")
        ev.message = m.get_text() if m is not None else ""
        ex = node.child("exception")
        if ex is not None and ex.get_text():
            lines = ex.get_text().split("\n")
            excs, hint = parse_exception_block(lines[1:], lines[0], limits.max_frames)
            ev.exceptions = excs
            ev.category_hint = hint
        props = node.child("properties")
        if props is not None:
            for d in props.children_named("data"):
                ev.add_attr(d.attrs.get("name", "prop"), d.attrs.get("value"), limits)
        loc = node.child("locationInfo")
        if loc is not None:
            ev.add_attr("location", "%s.%s(%s:%s)" % (loc.attrs.get("class"), loc.attrs.get("method"), loc.attrs.get("file"), loc.attrs.get("line")), limits)
        if a.get("username"):
            ev.add_attr("username", a.get("username"), limits)

    def _jul(self, node: _Node, ev: Event, ctx: ParseContext) -> None:
        limits = ctx.limits
        ev.layout = "jul-xml"
        d = node.child("date")
        ms = node.child("millis")
        if d is not None and d.get_text():
            set_ts(ev, ctx, d.get_text())
        elif ms is not None and safe_int(ms.get_text()) is not None:
            set_ts(ev, ctx, safe_int(ms.get_text()))
        lg = node.child("logger")
        ev.logger = lg.get_text() if lg is not None else None
        lv = node.child("level")
        ev.set_level(lv.get_text() if lv is not None else None)
        m = node.child("message")
        ev.message = m.get_text() if m is not None else ""
        th = node.child("thread")
        ev.thread = th.get_text() if th is not None else None
        cls, meth = node.child("class"), node.child("method")
        if cls is not None:
            ev.add_attr("source", "%s.%s" % (cls.get_text(), meth.get_text() if meth is not None else "?"), limits)
        ex = node.child("exception")
        if ex is not None:
            em = ex.child("message")
            frames: List[Frame] = []
            for fr in ex.children_named("frame")[: limits.max_frames]:
                c, mm, ln = fr.child("class"), fr.child("method"), fr.child("line")
                func = "%s.%s" % (c.get_text() if c else "?", mm.get_text() if mm else "?")
                line_i = safe_int(ln.get_text()) if ln is not None else None
                frames.append(Frame(func, None, line_i, _in_app(func, None)))
            text = em.get_text() if em is not None else ""
            typ, _, msg = text.partition(": ")
            if not re.match(r"^[\w.$]+$", typ):
                typ, msg = None, text
            ev.exceptions = [ExceptionInfo(typ, msg or None, frames)]

    def _generic(self, node: _Node, ev: Event, ctx: ParseContext) -> None:
        limits = ctx.limits
        ev.layout = "xml-generic:" + node.local()
        fields: Dict[str, str] = {}
        for k, v in node.attrs.items():
            fields[k.lower()] = v
        for c in node.children:
            if c.children and c.local().lower() not in ("message", "exception", "stacktrace"):
                for cc in c.children[:32]:
                    fields[(c.local() + "." + cc.local()).lower()] = cc.get_text()
                    for k, v in cc.attrs.items():
                        fields[(c.local() + "." + cc.local() + "@" + k).lower()] = v
            fields[c.local().lower()] = c.get_text()
            for k, v in c.attrs.items():
                fields[(c.local() + "@" + k).lower()] = v
        text_self = node.get_text()

        def pick(*names):
            for n in names:
                if fields.get(n):
                    return fields[n]
            return None

        ts = pick("timestamp", "time", "date", "datetime", "@timestamp", "timecreated@systemtime", "eventtime", "created", "logged")
        if ts:
            set_ts(ev, ctx, ts)
        lvl = pick("level", "severity", "loglevel", "priority", "type")
        if lvl and level_from_text(lvl) is not None:
            ev.set_level(lvl)
        ev.message = pick("message", "msg", "text", "description", "body", "rendereddescription") or text_self or ""
        ev.logger = pick("logger", "source", "category", "channel", "provider@name", "provider")
        ev.service = pick("service", "application", "app", "appname", "program")
        ev.host = pick("host", "hostname", "computer", "machine")
        ev.thread = pick("thread")
        exc = pick("exception", "stacktrace", "stack_trace", "throwable", "error")
        if exc:
            lines = exc.split("\n")
            excs, hint = parse_exception_block(lines[1:], lines[0], limits.max_frames)
            ev.exceptions = excs
            ev.category_hint = hint
        consumed = {"timestamp", "time", "date", "datetime", "@timestamp", "level", "severity", "message", "msg", "text",
                    "logger", "source", "host", "hostname", "thread", "exception", "stacktrace", "throwable"}
        for k, v in fields.items():
            if k not in consumed and v and len(ev.attrs) < limits.max_attributes_per_event:
                ev.add_attr(k, v, limits)


def make_parser(name: str):
    return XmlParser(name)
