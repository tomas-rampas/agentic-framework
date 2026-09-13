"""Shared parser infrastructure."""
from __future__ import annotations

import time
from typing import Any, Dict, Iterator, List, Optional, Tuple

from ..model import Event, ExceptionInfo, Frame
from ..timestamps import parse_timestamp


class ParseContext:
    """Per-input parsing context handed to parsers."""

    def __init__(self, limits, options, diagnostics, input_file=None, now: Optional[float] = None):
        self.limits = limits
        self.options = options
        self.diagnostics = diagnostics
        self.input = input_file
        self.input_id = input_file.id if input_file is not None else 0
        self.input_path = input_file.path if input_file is not None else "<memory>"
        self.now = now if now is not None else (options.now_epoch or time.time())
        self.assume_offset = options.assume_tz_offset_seconds
        self.parse_failures = 0
        self.records = 0
        self.layout: Optional[str] = None
        self.dialect: Optional[str] = None

    def diag(self, code: str, severity: str, message: str, line: Optional[int] = None, dedupe: bool = True) -> None:
        self.diagnostics.add(code, severity, message, self.input_path, line, dedupe=dedupe)
        if self.input is not None:
            self.input.diagnostics += 1

    def failure(self, code: str, message: str, line: Optional[int] = None) -> None:
        self.parse_failures += 1
        if self.input is not None:
            self.input.parse_failures += 1
        self.diag(code, "warning", message, line)

    def ts(self, text: Any) -> Tuple[Optional[float], Tuple[str, ...]]:
        return parse_timestamp(text, self.assume_offset, self.now)

    def new_event(self, parser: str, line: int, offset: Optional[int] = None) -> Event:
        ev = Event()
        ev.parser = parser
        ev.input_id = self.input_id
        ev.line = line
        ev.line_end = line
        ev.byte_offset = offset
        self.records += 1
        return ev


Lines = Iterator[Tuple[int, int, str, bool]]


class BaseParser:
    name = "base"
    family = "base"

    def __init__(self, name: Optional[str] = None):
        if name:
            self.name = name

    def parse(self, lines: Lines, ctx: ParseContext) -> Iterator[Event]:  # pragma: no cover - interface
        raise NotImplementedError


def set_ts(ev: Event, ctx: ParseContext, text: Any) -> None:
    ts, flags = ctx.ts(text)
    ev.ts = ts
    ev.ts_flags = flags
    if ts is None and text not in (None, ""):
        if "time_only" in flags:
            ev.diagnostics.append("time_only_timestamp")
        elif "unparsed" in flags or "invalid" in flags:
            ev.diagnostics.append("unparsed_timestamp")


__all__ = ["ParseContext", "BaseParser", "Lines", "Event", "ExceptionInfo", "Frame", "set_ts"]
