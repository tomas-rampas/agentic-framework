"""Nested-content sink shared by wrapper parsers (Docker, CRI, CloudWatch, GCP, Loki, ...).

Inner content is either a JSON object (normalized through the structured record
mapper) or free text. Single-line text is fed to a persistent
:class:`LazyTextEngine` so stack traces split across envelope records are
reassembled; multi-line text is parsed as one self-contained unit.
"""
from __future__ import annotations

import json
from typing import Any, Dict, List, Optional

from ..model import Event
from .base import ParseContext
from .text import LazyTextEngine


class NestedSink:
    def __init__(self, ctx: ParseContext, parser_name: str, record_mapper=None):
        self.ctx = ctx
        self.parser_name = parser_name
        self._engine: Optional[LazyTextEngine] = None
        self._mapper = record_mapper   # callable(obj, ctx, line_no, offset, base) -> Optional[Event]

    def feed_text(self, text: str, base: Dict[str, Any], line_no: int, offset: Optional[int]) -> List[Event]:
        out: List[Event] = []
        st = text.strip("\n")
        if not st.strip():
            return out
        head = st.lstrip()
        if self._mapper is not None and head.startswith("{") and st.rstrip().endswith("}") and "\n" not in st.strip():
            try:
                obj = json.loads(st)
            except ValueError:
                obj = None
            if isinstance(obj, dict):
                out.extend(self.flush())
                ev = self._mapper(obj, self.ctx, line_no, offset, base)
                if ev is not None:
                    out.append(ev)
                return out
        if "\n" in st:
            out.extend(self.flush())
            eng = LazyTextEngine(self.ctx, self.parser_name)
            for i, ln in enumerate(st.split("\n")):
                out.extend(eng.feed(line_no, offset if i == 0 else None, ln, False, base))
            out.extend(eng.flush())
            return out
        if self._engine is None:
            self._engine = LazyTextEngine(self.ctx, self.parser_name)
        out.extend(self._engine.feed(line_no, offset, st, False, base))
        return out

    def flush(self) -> List[Event]:
        if self._engine is None:
            return []
        out = self._engine.flush()
        self._engine = None
        return out


def make_base(ts: Optional[float], flags, attrs: Dict[str, Any], **ids) -> Dict[str, Any]:
    base: Dict[str, Any] = {"ts": ts, "ts_flags": tuple(flags or ()), "attrs": attrs}
    for k, v in ids.items():
        if v:
            base[k] = v
    return base
