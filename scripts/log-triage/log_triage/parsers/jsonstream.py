"""Incremental JSON boundary scanner.

Finds the raw text of *items* (array elements at configured paths, or top-level
values) and *captured context* values (small sibling objects such as an OTLP
``resource`` or a Loki ``stream`` label set) in a JSON document fed chunk by
chunk. Items are decoded with :func:`json.loads` (C speed); the scanner only
tracks structure, strings and key/index paths. Memory is bounded by the size of
the item currently being captured (``max_item_bytes``).

Path components are object keys (str) or array indices (int). Patterns use
``"*"`` for any array index. The special pattern ``ROOT`` matches every
top-level value (NDJSON-like concatenated documents, pretty-printed or not).
"""
from __future__ import annotations

import re
from typing import Iterator, List, Optional, Sequence, Tuple

ROOT = ("$",)
_STRUCT = re.compile(r'["\[\]{}:,]')
_STR_END = re.compile(r'(?:[^"\\]|\\.)*"')


def _match(pattern: Sequence, path: Sequence) -> bool:
    if len(pattern) != len(path):
        return False
    for p, c in zip(pattern, path):
        if p == "*":
            if not isinstance(c, int):
                return False
        elif p != c:
            return False
    return True


class JsonItemScanner:
    def __init__(self, item_paths: Sequence[Sequence], capture_paths: Sequence[Sequence] = (),
                 max_item_bytes: int = 1_048_576):
        self.item_paths = [tuple(p) for p in item_paths]
        self.capture_paths = [tuple(p) for p in capture_paths]
        self.root_items = ROOT in self.item_paths
        self.max_item_bytes = max_item_bytes
        self._buf = ""
        self._pos = 0
        self._stack: List[list] = []   # [kind('o'|'a'), child_key_or_index, expect_key]
        self._cap_start: Optional[int] = None
        self._cap_depth = 0
        self._cap_kind: Optional[str] = None
        self._cap_path: Tuple = ()
        self._cap_line = 0
        self._cap_oversized = False
        self.items = 0
        self.oversized = 0
        self.error: Optional[str] = None
        self.depth_max = 0
        self._line = 0

    # ------------------------------------------------------------------
    def _path(self) -> Tuple:
        return tuple(f[1] for f in self._stack)

    def _value_start(self, i: int, kind_hint: str) -> None:
        """Called when a value starts at buffer index ``i`` (before the char is consumed)."""
        if self._cap_start is not None:
            return
        path = self._path()
        if not self._stack:
            if self.root_items:
                self._begin_capture(i, path, "item")
            return
        for pat in self.item_paths:
            if pat is not ROOT and _match(pat, path[:-1]) and isinstance(path[-1], int):
                self._begin_capture(i, path, "item")
                return
        for pat in self.capture_paths:
            if _match(pat, path):
                self._begin_capture(i, path, "context")
                return

    def _begin_capture(self, i: int, path: Tuple, kind: str) -> None:
        self._cap_start = i
        self._cap_depth = len(self._stack)
        self._cap_kind = kind
        self._cap_path = path
        self._cap_line = self._line
        self._cap_oversized = False

    def _end_capture(self, end: int, out: List[Tuple[str, Tuple, Optional[str], int]]) -> None:
        start = self._cap_start
        self._cap_start = None
        if start is None:
            return
        if self._cap_oversized or end - start > self.max_item_bytes:
            self.oversized += 1
            out.append(("oversized", self._cap_path, None, self._cap_line))
            return
        if self._cap_kind == "item":
            self.items += 1
        out.append((self._cap_kind or "item", self._cap_path, self._buf[start:end], self._cap_line))

    def feed(self, chunk: str, line_no: int = 0) -> List[Tuple[str, Tuple, Optional[str], int]]:
        """Feed text; returns a list of (kind, path, raw_text|None, start_line) tuples."""
        out: List[Tuple[str, Tuple, Optional[str], int]] = []
        if self.error:
            return out
        self._line = line_no
        self._buf += chunk
        buf = self._buf
        pos = self._pos
        n = len(buf)
        stack = self._stack
        while pos < n:
            m = _STRUCT.search(buf, pos)
            if m is None:
                pos = n
                break
            i = m.start()
            ch = buf[i]
            if ch == '"':
                is_key = bool(stack) and stack[-1][0] == "o" and stack[-1][2]
                if not is_key:
                    self._value_start(i, "s")
                sm = _STR_END.match(buf, i + 1)
                if sm is None:
                    # unterminated in this buffer; wait for more input
                    pos = i
                    break
                end = sm.end()
                if is_key:
                    stack[-1][1] = buf[i + 1:end - 1]
                    stack[-1][2] = False
                elif self._cap_start is not None and self._cap_depth == len(stack) and self._cap_start == i:
                    self._end_capture(end, out)
                pos = end
                continue
            if ch == "{" or ch == "[":
                self._value_start(i, ch)
                if ch == "{":
                    stack.append(["o", None, True])
                else:
                    stack.append(["a", 0, False])
                if len(stack) > self.depth_max:
                    self.depth_max = len(stack)
                if len(stack) > 512:
                    self.error = "JSON nesting deeper than 512 levels"
                    return out
                pos = i + 1
                continue
            if ch == "}" or ch == "]":
                if not stack:
                    self.error = "unbalanced closing bracket at line %d" % line_no
                    return out
                expected = "o" if ch == "}" else "a"
                if stack[-1][0] != expected:
                    self.error = "mismatched bracket %r at line %d" % (ch, line_no)
                    return out
                stack.pop()
                if self._cap_start is not None and len(stack) == self._cap_depth:
                    self._end_capture(i + 1, out)
                pos = i + 1
                continue
            if ch == ":":
                pos = i + 1
                continue
            if ch == ",":
                if stack:
                    top = stack[-1]
                    if top[0] == "o":
                        top[2] = True
                    else:
                        top[1] += 1
                pos = i + 1
                continue
            pos = i + 1
        # compact the buffer: keep the capture in progress (or the unterminated string tail)
        if self._cap_start is not None:
            if pos - self._cap_start > self.max_item_bytes:
                # too big to keep: remember that it is oversized and drop the text
                self._cap_oversized = True
                self._buf = buf[pos:]
                self._cap_start = 0
                self._pos = 0
            else:
                self._buf = buf[self._cap_start:]
                self._pos = pos - self._cap_start
                self._cap_start = 0
        else:
            self._buf = buf[pos:]
            self._pos = 0
        if len(self._buf) > self.max_item_bytes * 2 and self._cap_start is None:
            # a giant string outside any item (should not happen with sane inputs)
            self._buf = self._buf[-self.max_item_bytes:]
            self._pos = 0
        return out

    def finish(self) -> List[Tuple[str, Tuple, Optional[str], int]]:
        out: List[Tuple[str, Tuple, Optional[str], int]] = []
        if self._stack and not self.error:
            self.error = "unterminated JSON document (%d open container(s))" % len(self._stack)
        tail = self._buf.strip()
        if tail and not self._stack and not self.error and self._cap_start is None and self.root_items:
            # bare scalar or malformed trailing text
            self.error = "trailing content is not valid JSON"
        return out
