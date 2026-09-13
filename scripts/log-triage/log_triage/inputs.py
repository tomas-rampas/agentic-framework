"""Input resolution: files, directories, globs; deduplication; ordering; exclusions.

Rules (documented in docs/log-triage/README.md, "Inputs"):
  * an argument naming an existing file is taken as is;
  * an existing directory is walked recursively (regular files only, directory
    symlinks not followed unless ``--follow-symlinks``);
  * anything else is a glob pattern (``*``, ``?``, ``[...]``, ``**``); a pattern that
    matches nothing is reported as *unmatched*;
  * matches are deduplicated by resolved real path and processed in lexicographic
    order of that path, independent of argument order;
  * more than ``max_files`` inputs: the surplus is excluded with a diagnostic.
"""
from __future__ import annotations

import glob
import os
import stat
from typing import Dict, List, Optional, Tuple

# Obvious non-log media excluded up front (documented). Everything else is sniffed.
EXCLUDED_EXTENSIONS = {
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".svgz",
    ".mp3", ".mp4", ".avi", ".mov", ".mkv", ".wav", ".flac",
    ".exe", ".dll", ".so", ".dylib", ".class", ".pyc", ".o", ".a", ".lib",
    ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".pdf",
    ".jar", ".war", ".ear", ".whl", ".egg", ".nupkg",
    ".tar", ".tgz", ".zip", ".7z", ".rar", ".bz2", ".xz", ".zst", ".lz4",
    ".db", ".sqlite", ".sqlite3", ".mdb",
    ".iso", ".img", ".dmg", ".vhd", ".vhdx", ".vmdk",
    ".woff", ".woff2", ".ttf", ".otf", ".eot",
}


class InputFile:
    __slots__ = ("id", "path", "real_path", "size", "mtime_ns", "origin", "status", "reason",
                 "format", "detection_confidence", "encoding", "compressed", "events", "bytes_read",
                 "lines", "parse_failures", "changed", "diagnostics", "layout", "dialect")

    def __init__(self, id_: int, path: str, real_path: str, size: int, mtime_ns: int, origin: str):
        self.id = id_
        self.path = path
        self.real_path = real_path
        self.size = size
        self.mtime_ns = mtime_ns
        self.origin = origin          # the argument that produced this file
        self.status = "pending"       # pending|processed|partial|excluded|failed
        self.reason: Optional[str] = None
        self.format: Optional[str] = None
        self.detection_confidence: Optional[float] = None
        self.encoding: Optional[str] = None
        self.compressed: Optional[str] = None
        self.events = 0
        self.bytes_read = 0
        self.lines = 0
        self.parse_failures = 0
        self.changed = False
        self.diagnostics = 0
        self.layout: Optional[str] = None
        self.dialect: Optional[str] = None

    def check_changed(self) -> bool:
        try:
            st = os.stat(self.real_path)
        except OSError:
            self.changed = True
            return True
        if st.st_size != self.size or st.st_mtime_ns != self.mtime_ns:
            self.changed = True
        return self.changed

    def to_dict(self) -> Dict:
        return {
            "id": self.id, "path": self.path, "real_path": self.real_path, "origin": self.origin,
            "size_bytes": self.size, "status": self.status, "reason": self.reason,
            "format": self.format, "detection_confidence": self.detection_confidence,
            "encoding": self.encoding, "compression": self.compressed, "layout": self.layout,
            "dialect": self.dialect, "events": self.events, "bytes_read": self.bytes_read,
            "lines": self.lines, "parse_failures": self.parse_failures,
            "changed_during_analysis": self.changed, "diagnostics": self.diagnostics,
        }


class InputSet:
    def __init__(self) -> None:
        self.files: List[InputFile] = []
        self.unmatched: List[str] = []
        self.duplicates: List[Tuple[str, str]] = []   # (duplicate path, kept path)
        self.excluded: List[Dict] = []                 # {"path","reason"}
        self.skipped_symlinks: List[str] = []
        self.limit_hit = False
        self.requested: List[str] = []

    def summary(self) -> Dict:
        counts = {"discovered": len(self.files) + len(self.excluded), "processed": 0, "partial": 0,
                  "excluded": len(self.excluded), "failed": 0, "pending": 0}
        for f in self.files:
            if f.status == "excluded":
                counts["excluded"] += 1
                continue
            counts[f.status] = counts.get(f.status, 0) + 1
        counts["unmatched_arguments"] = len(self.unmatched)
        counts["duplicates_removed"] = len(self.duplicates)
        return counts


def _walk(directory: str, follow_symlinks: bool, out: List[str], skipped_symlinks: List[str],
          max_files: int) -> None:
    for root, dirs, files in os.walk(directory, followlinks=follow_symlinks):
        dirs.sort()
        if not follow_symlinks:
            keep = []
            for d in dirs:
                full = os.path.join(root, d)
                if os.path.islink(full):
                    skipped_symlinks.append(full)
                else:
                    keep.append(d)
            dirs[:] = keep
        for name in sorted(files):
            out.append(os.path.join(root, name))
            if len(out) > max_files * 2:
                return


def resolve_inputs(args: List[str], limits, follow_symlinks: bool = False) -> InputSet:
    result = InputSet()
    result.requested = list(args)
    candidates: List[Tuple[str, str]] = []  # (path, origin)
    for arg in args:
        if not arg:
            continue
        if os.path.isfile(arg):
            candidates.append((arg, arg))
            continue
        if os.path.isdir(arg):
            found: List[str] = []
            _walk(arg, follow_symlinks, found, result.skipped_symlinks, limits.max_files)
            if not found:
                result.unmatched.append(arg)
            for p in found:
                candidates.append((p, arg))
            continue
        matches = sorted(glob.glob(arg, recursive=True))
        expanded = []
        for m in matches:
            if os.path.isdir(m):
                found = []
                _walk(m, follow_symlinks, found, result.skipped_symlinks, limits.max_files)
                expanded.extend(found)
            elif os.path.isfile(m):
                expanded.append(m)
        if not expanded:
            result.unmatched.append(arg)
        for p in expanded:
            candidates.append((p, arg))

    seen: Dict[str, str] = {}
    entries: List[Tuple[str, str, str]] = []
    for path, origin in candidates:
        try:
            real = os.path.realpath(path)
        except OSError:
            real = os.path.abspath(path)
        if real in seen:
            result.duplicates.append((path, seen[real]))
            continue
        seen[real] = path
        entries.append((real, path, origin))
    entries.sort(key=lambda e: e[0])

    next_id = 1
    for real, path, origin in entries:
        ext = os.path.splitext(path)[1].lower()
        if ext in EXCLUDED_EXTENSIONS:
            result.excluded.append({"path": path, "reason": "excluded-extension:%s" % ext})
            continue
        try:
            st = os.stat(real)
        except OSError as exc:
            result.excluded.append({"path": path, "reason": "stat-failed: %s" % exc})
            continue
        if not stat.S_ISREG(st.st_mode):
            result.excluded.append({"path": path, "reason": "not-a-regular-file"})
            continue
        if len(result.files) >= limits.max_files:
            result.limit_hit = True
            result.excluded.append({"path": path, "reason": "limit-reached:max_files=%d" % limits.max_files})
            continue
        result.files.append(InputFile(next_id, path, real, st.st_size, st.st_mtime_ns, origin))
        next_id += 1
    return result
