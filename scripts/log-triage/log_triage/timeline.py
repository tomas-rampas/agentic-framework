"""Bounded, adaptive time-bucket timeline.

Buckets start at 60 s and coarsen (5 m, 15 m, 1 h, 6 h, 1 d, 7 d, 30 d) whenever the
number of buckets would exceed ``max_timeline_buckets``; merging is exact (counts are
re-summed), so totals never change. Events without a usable timestamp are counted
separately and reported as such.
"""
from __future__ import annotations

from typing import Dict, List, Optional

from .model import level_class
from .timestamps import format_iso

_STEPS = [60, 300, 900, 3600, 21600, 86400, 604800, 2592000]
_CLASSES = ("fatal", "error", "warn", "info", "debug", "unknown")


class Timeline:
    def __init__(self, max_buckets: int):
        self.max_buckets = max(8, max_buckets)
        self.step_index = 0
        self.buckets: Dict[int, List[int]] = {}   # bucket start -> counts per class (+ total at index 6)
        self.untimed = 0
        self.total = 0
        self.min_ts: Optional[float] = None
        self.max_ts: Optional[float] = None

    @property
    def bucket_seconds(self) -> int:
        return _STEPS[self.step_index]

    def add(self, ts: Optional[float], level_num: Optional[int]) -> None:
        self.total += 1
        if ts is None:
            self.untimed += 1
            return
        if self.min_ts is None or ts < self.min_ts:
            self.min_ts = ts
        if self.max_ts is None or ts > self.max_ts:
            self.max_ts = ts
        cls = level_class(level_num)
        idx = _CLASSES.index(cls)
        step = _STEPS[self.step_index]
        key = int(ts // step) * step
        b = self.buckets.get(key)
        if b is None:
            b = [0, 0, 0, 0, 0, 0, 0]
            self.buckets[key] = b
            if len(self.buckets) > self.max_buckets:
                self._coarsen()
                return self._readd(ts, idx)
        b[idx] += 1
        b[6] += 1

    def _readd(self, ts: float, idx: int) -> None:
        step = _STEPS[self.step_index]
        key = int(ts // step) * step
        b = self.buckets.setdefault(key, [0, 0, 0, 0, 0, 0, 0])
        b[idx] += 1
        b[6] += 1

    def _coarsen(self) -> None:
        while len(self.buckets) > self.max_buckets and self.step_index < len(_STEPS) - 1:
            self.step_index += 1
            step = _STEPS[self.step_index]
            merged: Dict[int, List[int]] = {}
            for key, counts in self.buckets.items():
                nk = int(key // step) * step
                tgt = merged.get(nk)
                if tgt is None:
                    merged[nk] = list(counts)
                else:
                    for i in range(7):
                        tgt[i] += counts[i]
            self.buckets = merged

    def to_dict(self) -> Dict:
        step = _STEPS[self.step_index]
        rows = []
        for key in sorted(self.buckets):
            c = self.buckets[key]
            rows.append({"start": format_iso(float(key)), "end": format_iso(float(key + step)),
                         "total": c[6], "counts": {name: c[i] for i, name in enumerate(_CLASSES) if c[i]}})
        return {
            "bucket_seconds": step,
            "buckets": rows,
            "bucket_count": len(rows),
            "events_with_timestamp": self.total - self.untimed,
            "events_without_timestamp": self.untimed,
            "first_timestamp": format_iso(self.min_ts),
            "last_timestamp": format_iso(self.max_ts),
            "coarsened": self.step_index > 0,
        }
