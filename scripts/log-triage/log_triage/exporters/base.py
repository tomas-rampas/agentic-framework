"""Exporter interface and atomic file writing."""
from __future__ import annotations

import os
from typing import Any, Dict, Iterator, List, Optional


class Exporter:
    name = "base"
    filenames: List[str] = []       # files this exporter writes (relative to the output directory)

    def __init__(self, options):
        self.options = options
        self.limits = options.limits

    def write(self, analysis, out_dir: str) -> List[str]:  # pragma: no cover - interface
        raise NotImplementedError


class AtomicFile:
    """Write to ``<path>.tmp`` then rename, so a failed export never leaves a truncated file behind.

    Set ``LOG_TRIAGE_TEST_ENOSPC_AT=<basename>`` to simulate disk exhaustion (tests only).
    """

    def __init__(self, path: str, mode: str = "w", encoding: Optional[str] = "utf-8", newline: Optional[str] = None):
        self.path = path
        self.tmp = path + ".tmp"
        self.mode = mode
        self.encoding = encoding
        self.newline = newline
        self.fh = None

    def __enter__(self):
        if "b" in self.mode:
            self.fh = open(self.tmp, self.mode)
        else:
            self.fh = open(self.tmp, self.mode, encoding=self.encoding, newline=self.newline)
        if os.environ.get("LOG_TRIAGE_TEST_ENOSPC_AT") == os.path.basename(self.path):
            self.fh.close()
            try:
                os.unlink(self.tmp)
            except OSError:
                pass
            raise OSError(28, "No space left on device (simulated)")
        return self.fh

    def __exit__(self, exc_type, exc, tb):
        try:
            if self.fh is not None:
                self.fh.close()
        finally:
            if exc_type is None:
                os.replace(self.tmp, self.path)
            else:
                try:
                    os.unlink(self.tmp)
                except OSError:
                    pass
        return False


def meta_for_output(meta: Dict[str, Any]) -> Dict[str, Any]:
    """The document minus the (streamed) groups array."""
    return {k: v for k, v in meta.items() if k != "groups"}
