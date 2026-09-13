"""Bounded-memory issue aggregation with SQLite spill-to-disk.

``GroupStore.add(event)`` redacts, templates and fingerprints an event and folds it
into its group accumulator. When more than ``max_groups_in_memory`` groups are live,
every accumulator is merged into a SQLite table in the temp directory and memory is
released (exact counts are preserved by the merge). ``finalize()`` classifies every
group, orders them deterministically and exposes an iterator that exporters share.
"""
from __future__ import annotations

import json
import os
import sqlite3
from typing import Any, Dict, Iterator, List, Optional, Set, Tuple

from .classify import classify
from .config import SEVERITY_RANK
from .fingerprint import build_key, group_id
from .model import Event, level_class
from .normalize import template
from .timestamps import format_iso

ACC_FIELDS = ("fp", "template", "count", "first_ts", "last_ts", "untimed", "levels", "level_max", "level_max_text", "services",
              "hosts", "hosts_overflow", "logger", "parser", "layouts", "exc", "http", "error_code", "category_hint", "examples",
              "last_example", "trace_ids", "request_ids", "corr_truncated", "inputs", "inputs_overflow", "distinct_messages",
              "key_parts", "sev_rank", "assessment", "attribution", "investigation", "first_line", "first_input")


class GroupAcc:
    __slots__ = ACC_FIELDS

    def __init__(self, fp: str, tmpl: str, key_parts: List[str]):
        self.fp = fp
        self.template = tmpl
        self.count = 0
        self.first_ts: Optional[float] = None
        self.last_ts: Optional[float] = None
        self.untimed = 0
        self.levels: Dict[str, int] = {}
        self.level_max: Optional[int] = None
        self.level_max_text: Optional[str] = None
        self.services: Dict[str, int] = {}
        self.hosts: List[str] = []
        self.hosts_overflow = False
        self.logger: Optional[str] = None
        self.parser: Optional[str] = None
        self.layouts: List[str] = []
        self.exc: Optional[Dict[str, Any]] = None
        self.http: Optional[Dict[str, Any]] = None
        self.error_code: Optional[str] = None
        self.category_hint: Optional[str] = None
        self.examples: List[Dict[str, Any]] = []
        self.last_example: Optional[Dict[str, Any]] = None
        self.trace_ids: List[str] = []
        self.request_ids: List[str] = []
        self.corr_truncated = False
        self.inputs: Dict[str, int] = {}
        self.inputs_overflow = False
        self.distinct_messages: List[int] = []   # bounded list of message hashes seen (grouping confidence)
        self.key_parts = key_parts
        self.sev_rank = 0
        self.assessment: Optional[Dict[str, Any]] = None
        self.attribution: Optional[Dict[str, Any]] = None
        self.investigation: Optional[Dict[str, Any]] = None
        self.first_line: Optional[int] = None
        self.first_input: Optional[int] = None

    def to_json(self) -> str:
        return json.dumps({f: getattr(self, f) for f in ACC_FIELDS}, ensure_ascii=False, separators=(",", ":"), default=str)

    @classmethod
    def from_json(cls, text: str) -> "GroupAcc":
        d = json.loads(text)
        acc = cls(d["fp"], d["template"], d.get("key_parts") or [])
        for f in ACC_FIELDS:
            if f in d:
                setattr(acc, f, d[f])
        return acc

    def merge(self, other: "GroupAcc", limits) -> None:
        """Fold ``other`` (newer) into self (older)."""
        self.count += other.count
        if other.first_ts is not None and (self.first_ts is None or other.first_ts < self.first_ts):
            self.first_ts = other.first_ts
        if other.last_ts is not None and (self.last_ts is None or other.last_ts > self.last_ts):
            self.last_ts = other.last_ts
        self.untimed += other.untimed
        for k, v in other.levels.items():
            if k in self.levels or len(self.levels) < limits.max_levels_per_group:
                self.levels[k] = self.levels.get(k, 0) + v
            else:
                self.levels["_other"] = self.levels.get("_other", 0) + v
        if other.level_max is not None and (self.level_max is None or other.level_max > self.level_max):
            self.level_max, self.level_max_text = other.level_max, other.level_max_text
        for k, v in other.services.items():
            if k in self.services or len(self.services) < limits.max_services_per_group:
                self.services[k] = self.services.get(k, 0) + v
        for h in other.hosts:
            if h not in self.hosts:
                if len(self.hosts) < 64:
                    self.hosts.append(h)
                else:
                    self.hosts_overflow = True
        self.hosts_overflow = self.hosts_overflow or other.hosts_overflow
        self.logger = self.logger or other.logger
        self.parser = self.parser or other.parser
        for l in other.layouts:
            if l not in self.layouts and len(self.layouts) < 5:
                self.layouts.append(l)
        self.exc = self.exc or other.exc
        self.http = self.http or other.http
        self.error_code = self.error_code or other.error_code
        self.category_hint = self.category_hint or other.category_hint
        for ex in other.examples:
            if len(self.examples) < limits.max_examples_per_group:
                self.examples.append(ex)
            else:
                # the retained examples are full: the newest of the incoming ones becomes last-seen
                self.last_example = ex
        if other.last_example is not None:
            self.last_example = other.last_example
        for t in other.trace_ids:
            if t not in self.trace_ids:
                if len(self.trace_ids) < limits.max_correlation_ids_per_group:
                    self.trace_ids.append(t)
                else:
                    self.corr_truncated = True
        for t in other.request_ids:
            if t not in self.request_ids:
                if len(self.request_ids) < limits.max_correlation_ids_per_group:
                    self.request_ids.append(t)
                else:
                    self.corr_truncated = True
        self.corr_truncated = self.corr_truncated or other.corr_truncated
        for k, v in other.inputs.items():
            if k in self.inputs or len(self.inputs) < limits.max_inputs_per_group:
                self.inputs[k] = self.inputs.get(k, 0) + v
            else:
                self.inputs_overflow = True
        for h in other.distinct_messages:
            if h not in self.distinct_messages and len(self.distinct_messages) < 8:
                self.distinct_messages.append(h)
        if self.first_line is None:
            self.first_line, self.first_input = other.first_line, other.first_input


def _frames_dicts(frames, limit: int = 20) -> List[Dict[str, Any]]:
    return [f.to_dict() for f in frames[:limit]]


class GroupStore:
    def __init__(self, limits, temp_dir: str, redactor, timeline, input_paths: Dict[int, str]):
        self.limits = limits
        self.temp_dir = temp_dir
        self.redactor = redactor
        self.timeline = timeline
        self.input_paths = input_paths
        self.groups: Dict[str, GroupAcc] = {}
        self._db: Optional[sqlite3.Connection] = None
        self._db_path = os.path.join(temp_dir, "groups.sqlite")
        self.spilled = False
        self.spill_count = 0
        self.temp_bytes_peak = 0
        self.events = 0
        self._fp_cache: Dict[Tuple, Tuple[str, str, List[str]]] = {}
        self._finalized = False
        self._ordered_fps: Optional[List[str]] = None
        self.total_groups = 0
        self.by_severity: Dict[str, Dict[str, int]] = {}

    # ------------------------------------------------------------------
    def _redact_event(self, ev: Event) -> None:
        r = self.redactor
        if not r.enabled:
            return
        ev.message = r.redact(ev.message) or ""
        for exc in ev.exceptions:
            if exc.message:
                exc.message = r.redact(exc.message)
        if ev.attrs:
            for k, v in list(ev.attrs.items()):
                if isinstance(v, str) and v:
                    ev.attrs[k] = r.redact_attr(k, v)
        if ev.http_path:
            ev.http_path = r.redact(ev.http_path)
        if ev.raw_excerpt:
            ev.raw_excerpt = r.redact(ev.raw_excerpt)
        for exc in ev.exceptions:
            for fr in exc.frames:
                if fr.raw and r.prefilter_hit(fr.raw):
                    fr.raw = r.redact(fr.raw)

    def add(self, ev: Event) -> str:
        limits = self.limits
        self._redact_event(ev)
        self.events += 1
        self.timeline.add(ev.ts, ev.level_num)
        cache_key = None
        if not ev.exceptions:
            cache_key = (ev.service, ev.logger, ev.message, ev.http_status, ev.error_code)
            cached = self._fp_cache.get(cache_key)
        else:
            cached = None
        if cached is None:
            tmpl = template(ev.message, 1000)
            fp, parts = build_key(ev, tmpl)
            if cache_key is not None:
                if len(self._fp_cache) >= limits.fingerprint_cache_size:
                    self._fp_cache.clear()
                self._fp_cache[cache_key] = (fp, tmpl, parts)
        else:
            fp, tmpl, parts = cached
        acc = self.groups.get(fp)
        if acc is None:
            acc = GroupAcc(fp, tmpl, parts)
            acc.parser = ev.parser
            acc.logger = ev.logger
            acc.error_code = ev.error_code
            acc.first_line = ev.line
            acc.first_input = ev.input_id
            if ev.exceptions:
                head = ev.exceptions[0]
                chain_frames: List[Dict[str, Any]] = []
                for e in ev.exceptions[:8]:
                    for fr in e.frames:
                        if len(chain_frames) >= 20:
                            break
                        chain_frames.append(fr.to_dict())
                acc.exc = {
                    "type": head.type,
                    "message_template": template(head.message or "", 300) if head.message else None,
                    "chain": [e.type for e in ev.exceptions[:8]],
                    "frames": chain_frames,   # outermost exception first, then causes (bounded)
                }
            if ev.http_status is not None or ev.http_method or ev.http_path:
                acc.http = {"status": ev.http_status, "method": ev.http_method,
                            "path_template": template(ev.http_path, 300) if ev.http_path else None}
            self.groups[fp] = acc
        acc.count += 1
        if ev.ts is None:
            acc.untimed += 1
        else:
            if acc.first_ts is None or ev.ts < acc.first_ts:
                acc.first_ts = ev.ts
            if acc.last_ts is None or ev.ts > acc.last_ts:
                acc.last_ts = ev.ts
        lvl = (ev.level_text or "none").upper()[:16]
        if lvl in acc.levels or len(acc.levels) < limits.max_levels_per_group:
            acc.levels[lvl] = acc.levels.get(lvl, 0) + 1
        else:
            acc.levels["_other"] = acc.levels.get("_other", 0) + 1
        if ev.level_num is not None and (acc.level_max is None or ev.level_num > acc.level_max):
            acc.level_max, acc.level_max_text = ev.level_num, ev.level_text
        if ev.service:
            if ev.service in acc.services or len(acc.services) < limits.max_services_per_group:
                acc.services[ev.service] = acc.services.get(ev.service, 0) + 1
        if ev.host and ev.host not in acc.hosts:
            if len(acc.hosts) < 64:
                acc.hosts.append(ev.host)
            else:
                acc.hosts_overflow = True
        if ev.layout and ev.layout not in acc.layouts and len(acc.layouts) < 5:
            acc.layouts.append(ev.layout)
        if ev.category_hint and not acc.category_hint:
            acc.category_hint = ev.category_hint
        if ev.trace_id and ev.trace_id not in acc.trace_ids:
            if len(acc.trace_ids) < limits.max_correlation_ids_per_group:
                acc.trace_ids.append(ev.trace_id)
            else:
                acc.corr_truncated = True
        rid = ev.request_id or ev.correlation_id
        if rid and rid not in acc.request_ids:
            if len(acc.request_ids) < limits.max_correlation_ids_per_group:
                acc.request_ids.append(rid)
            else:
                acc.corr_truncated = True
        ikey = str(ev.input_id)
        if ikey in acc.inputs or len(acc.inputs) < limits.max_inputs_per_group:
            acc.inputs[ikey] = acc.inputs.get(ikey, 0) + 1
        else:
            acc.inputs_overflow = True
        mh = hash(ev.message) & 0xFFFFFFFF
        if mh not in acc.distinct_messages and len(acc.distinct_messages) < 8:
            acc.distinct_messages.append(mh)
        if len(acc.examples) < limits.max_examples_per_group:
            acc.examples.append(self._example(ev))
        else:
            acc.last_example = self._example(ev, brief=True)
        if len(self.groups) > limits.max_groups_in_memory:
            self._spill()
        return fp

    def _example(self, ev: Event, brief: bool = False) -> Dict[str, Any]:
        limits = self.limits
        ex: Dict[str, Any] = {
            "input_id": ev.input_id,
            "input": self.input_paths.get(ev.input_id),
            "line": ev.line,
            "line_end": ev.line_end if ev.line_end and ev.line_end != ev.line else None,
            "byte_offset": ev.byte_offset,
            "timestamp": format_iso(ev.ts),
            "level": ev.level_text,
            "message": ev.message[: limits.max_report_example_chars],
        }
        if brief:
            return ex
        ex["exception_text"] = ev.exception_text(limits)
        if ev.raw_excerpt and not ex["exception_text"]:
            ex["body"] = ev.raw_excerpt[: limits.max_exception_chars]
        attrs = {}
        for k, v in list(ev.attrs.items())[:24]:
            attrs[k] = v if not isinstance(v, str) else v[:200]
        ex["attributes"] = attrs
        ex["parser"] = ev.parser
        ex["layout"] = ev.layout
        ex["ts_flags"] = list(ev.ts_flags) if ev.ts_flags else []
        ex["truncated"] = ev.truncated
        for k in ("service", "host", "logger", "thread", "trace_id", "span_id", "request_id"):
            v = getattr(ev, k)
            if v:
                ex[k] = v
        return ex

    # ------------------------------------------------------------------
    def _open_db(self) -> sqlite3.Connection:
        if self._db is None:
            self._db = sqlite3.connect(self._db_path)
            self._db.execute("PRAGMA journal_mode=OFF")
            self._db.execute("PRAGMA synchronous=OFF")
            self._db.execute("PRAGMA cache_size=-8192")
            self._db.execute("CREATE TABLE IF NOT EXISTS g (fp TEXT PRIMARY KEY, sev INTEGER, cnt INTEGER, first REAL, last REAL, data TEXT)")
            try:
                os.chmod(self._db_path, 0o600)
            except OSError:
                pass
        return self._db

    def _assess(self, acc: GroupAcc) -> None:
        exc = acc.exc or {}
        a = classify(acc.template, exc.get("chain") or ([exc["type"]] if exc.get("type") else []),
                     exc.get("message_template") or "", acc.level_max,
                     (acc.http or {}).get("status"), acc.error_code, acc.category_hint, acc.count)
        acc.assessment = a.to_dict()
        acc.sev_rank = SEVERITY_RANK[a.severity]

    def _spill(self) -> None:
        db = self._open_db()
        self.spilled = True
        self.spill_count += 1
        cur = db.cursor()
        cur.execute("BEGIN")
        for fp, acc in self.groups.items():
            row = cur.execute("SELECT data FROM g WHERE fp=?", (fp,)).fetchone()
            if row is not None:
                old = GroupAcc.from_json(row[0])
                old.merge(acc, self.limits)
                acc = old
            self._assess(acc)
            cur.execute("INSERT OR REPLACE INTO g (fp, sev, cnt, first, last, data) VALUES (?,?,?,?,?,?)",
                        (fp, acc.sev_rank, acc.count, acc.first_ts, acc.last_ts, acc.to_json()))
        cur.execute("COMMIT")
        self.groups.clear()
        self._fp_cache.clear()
        self._track_temp()

    def _track_temp(self) -> None:
        try:
            size = os.path.getsize(self._db_path)
        except OSError:
            size = 0
        if size > self.temp_bytes_peak:
            self.temp_bytes_peak = size

    def finalize(self) -> None:
        if self._finalized:
            return
        self._finalized = True
        if self.spilled:
            if self.groups:
                self._spill()
            db = self._open_db()
            db.execute("CREATE INDEX IF NOT EXISTS g_order ON g (sev DESC, cnt DESC, first, fp)")
            self.total_groups = db.execute("SELECT COUNT(*) FROM g").fetchone()[0]
            self.by_severity = {}
            for sev, n, events in db.execute("SELECT sev, COUNT(*), SUM(cnt) FROM g GROUP BY sev"):
                name = _sev_name(sev)
                self.by_severity[name] = {"groups": n, "events": events}
            self._track_temp()
        else:
            for acc in self.groups.values():
                self._assess(acc)
            self._ordered_fps = sorted(self.groups, key=lambda fp: self._sort_key(self.groups[fp]))
            self.total_groups = len(self._ordered_fps)
            self.by_severity = {}
            for acc in self.groups.values():
                name = _sev_name(acc.sev_rank)
                d = self.by_severity.setdefault(name, {"groups": 0, "events": 0})
                d["groups"] += 1
                d["events"] += acc.count

    @staticmethod
    def _sort_key(acc: GroupAcc):
        return (-acc.sev_rank, -acc.count, acc.first_ts is None, acc.first_ts if acc.first_ts is not None else 0.0, acc.fp)

    # ------------------------------------------------------------------
    def iter_accs(self, min_rank: int = 0) -> Iterator[GroupAcc]:
        """Ordered iteration (severity desc, count desc, first seen asc, fingerprint)."""
        if not self._finalized:
            self.finalize()
        if self.spilled:
            db = self._open_db()
            cur = db.cursor()
            cur.execute("SELECT data FROM g WHERE sev >= ? ORDER BY sev DESC, cnt DESC, first IS NULL, first ASC, fp ASC", (min_rank,))
            while True:
                rows = cur.fetchmany(256)
                if not rows:
                    break
                for (data,) in rows:
                    yield GroupAcc.from_json(data)
        else:
            for fp in self._ordered_fps or []:
                acc = self.groups[fp]
                if acc.sev_rank >= min_rank:
                    yield acc

    def get_acc(self, fp: str) -> Optional[GroupAcc]:
        if self.spilled:
            row = self._open_db().execute("SELECT data FROM g WHERE fp=?", (fp,)).fetchone()
            return GroupAcc.from_json(row[0]) if row else None
        return self.groups.get(fp)

    def update_acc(self, acc: GroupAcc) -> None:
        if self.spilled:
            self._open_db().execute("UPDATE g SET data=? WHERE fp=?", (acc.to_json(), acc.fp))
            self._open_db().commit()
        else:
            self.groups[acc.fp] = acc

    def iter_groups(self, min_rank: int = 0) -> Iterator[Dict[str, Any]]:
        for acc in self.iter_accs(min_rank):
            yield acc_to_dict(acc, self.input_paths)

    def close(self) -> None:
        if self._db is not None:
            try:
                self._db.close()
            except Exception:
                pass
            self._db = None


def _sev_name(rank: int) -> str:
    for name, r in SEVERITY_RANK.items():
        if r == rank:
            return name
    return "info"


def acc_to_dict(acc: GroupAcc, input_paths: Dict[int, str]) -> Dict[str, Any]:
    assessment = acc.assessment or {}
    examples = list(acc.examples)
    if acc.last_example is not None:
        examples.append(dict(acc.last_example, is_last_seen=True))
    for ex in examples:
        if ex.get("input") is None and ex.get("input_id") is not None:
            ex["input"] = input_paths.get(ex["input_id"])
    grouping_conf = 0.9 if acc.exc else (0.8 if acc.template and "<" in acc.template else 0.7)
    notes: List[str] = []
    if acc.exc:
        notes.append("grouped by exception chain %s and message template" % ">".join(t or "?" for t in acc.exc.get("chain", [])))
    else:
        notes.append("grouped by normalized message template")
    if acc.http:
        notes.append("HTTP status %s and route template are part of the key" % acc.http.get("status"))
    if acc.error_code:
        notes.append("error code %s is part of the key" % acc.error_code)
    if len(acc.distinct_messages) >= 8:
        notes.append("8+ distinct raw messages folded into this template (placeholders vary)")
    if acc.levels and len([k for k in acc.levels if k != "_other"]) > 1:
        notes.append("events with different producer levels share this template")
        grouping_conf -= 0.1
    if acc.services and len(acc.services) > 1:
        notes.append("multiple services report this template")
    return {
        "id": group_id(acc.fp),
        "fingerprint": acc.fp,
        "fingerprint_version": acc.key_parts[0][1:] if acc.key_parts else "1",
        "template": acc.template,
        "severity": assessment.get("severity", "info"),
        "category": assessment.get("category", "unknown"),
        "assessment": assessment,
        "count": acc.count,
        "first_seen": format_iso(acc.first_ts),
        "last_seen": format_iso(acc.last_ts),
        "untimed_count": acc.untimed,
        "levels": dict(acc.levels),
        "level_max": acc.level_max_text,
        "services": dict(acc.services),
        "hosts": {"distinct": len(acc.hosts), "truncated": acc.hosts_overflow, "sample": acc.hosts[:5]},
        "logger": acc.logger,
        "parser": acc.parser,
        "layouts": list(acc.layouts),
        "exception": acc.exc,
        "http": acc.http,
        "error_code": acc.error_code,
        "examples": examples,
        "correlation": {"trace_ids": list(acc.trace_ids), "request_ids": list(acc.request_ids), "truncated": acc.corr_truncated},
        "inputs": {input_paths.get(int(k), k) if str(k).isdigit() else k: v for k, v in acc.inputs.items()},
        "inputs_truncated": acc.inputs_overflow,
        "grouping": {"confidence": round(max(0.3, grouping_conf), 2), "notes": notes, "key_components": list(acc.key_parts)},
        "attribution": acc.attribution or {"status": "not_attempted", "candidates": []},
        "investigation": acc.investigation or {"status": "not_attempted", "suggestions": [], "source_references": [],
                                                "root_cause": None},
    }
