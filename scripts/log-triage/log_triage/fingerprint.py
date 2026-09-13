"""Stable issue fingerprint (version 1) and group identifiers.

Components, in order (see docs/log-triage/canonical-model.md, "Fingerprint v1"):
  1. fingerprint version
  2. service identity (lower-cased) when known
  3. logger/category when known
  4. exception type chain (outermost first, up to 5)
  5. template of the outermost exception message
  6. signatures of the first 3 in-app frames (or the first 2 frames when none is in-app)
  7. message template
  8. HTTP status and error code when present
Levels, hosts, timestamps, line numbers and identifiers never enter the fingerprint.
"""
from __future__ import annotations

import hashlib
from typing import List, Optional, Tuple

from . import FINGERPRINT_VERSION
from .normalize import frame_signature, template


def frames_signature(frames) -> List[str]:
    if not frames:
        return []
    in_app = [f for f in frames if f.in_app]
    chosen = in_app[:3] if in_app else frames[:2]
    return [frame_signature(f.function, f.file) for f in chosen]


def build_key(event, message_template: str) -> Tuple[str, List[str]]:
    parts: List[str] = ["v" + FINGERPRINT_VERSION]
    parts.append("svc=" + (event.service or "").lower())
    parts.append("log=" + (event.logger or ""))
    types = [e.type or "" for e in event.exceptions[:5]]
    parts.append("exc=" + ">".join(types))
    if event.exceptions and event.exceptions[0].message:
        parts.append("excmsg=" + template(event.exceptions[0].message, 300))
    else:
        parts.append("excmsg=")
    frames: List[str] = []
    for exc in event.exceptions:
        if exc.frames:
            frames = frames_signature(exc.frames)
            break
    parts.append("frames=" + ";".join(frames))
    parts.append("msg=" + message_template)
    parts.append("http=" + (str(event.http_status) if event.http_status else ""))
    parts.append("code=" + (event.error_code or ""))
    key = "\x1f".join(parts)
    return hashlib.sha256(key.encode("utf-8", "surrogatepass")).hexdigest(), parts


def group_id(fingerprint: str) -> str:
    return "LT-" + fingerprint[:12]
