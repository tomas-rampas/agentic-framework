"""Timestamp parsing with explicit handling of time zones, missing years and epochs.

All results are epoch seconds (float, UTC). ``flags`` explain how the value
was derived:
  naive           - no offset in the text; ``assume_offset`` was applied
  year_inferred   - the layout carries no year (syslog RFC 3164, glog, ...)
  time_only       - only a time of day was present; no date could be derived (ts=None)
  epoch_unit      - numeric epoch, unit chosen by magnitude (s/ms/us/ns)
"""
from __future__ import annotations

import calendar
import re
import time
from typing import Optional, Tuple

_MONTHS = {m.lower(): i for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}
_MONTHS["sept"] = 9

# ISO 8601 / RFC 3339 and the common "space" and "comma millis" variants.
_ISO_RE = re.compile(
    r"^\s*(?P<y>\d{4})-(?P<mo>\d{2})-(?P<d>\d{2})"
    r"(?:[T _](?P<h>\d{2}):(?P<mi>\d{2})(?::(?P<s>\d{2})(?:[.,](?P<f>\d{1,9}))?)?)?"
    r"\s*(?P<tz>Z|z|UTC|GMT|[+-]\d{2}(?::?\d{2})?)?\s*$"
)
# 20260913T120000Z / 20260913120000 (PowerShell transcripts use the latter)
_BASIC_RE = re.compile(r"^\s*(?P<y>(?:19|20)\d{2})(?P<mo>0[1-9]|1[0-2])(?P<d>0[1-9]|[12]\d|3[01])(?:T?(?P<h>[01]\d|2[0-4])(?P<mi>[0-5]\d)(?P<s>[0-5]\d)(?:[.,](?P<f>\d{1,9}))?)?(?P<tz>Z)?\s*$")
# 2026/09/13 12:00:00[.123456] (Go std log, nginx)
_SLASH_RE = re.compile(r"^\s*(?P<y>\d{4})/(?P<mo>\d{2})/(?P<d>\d{2})[ T](?P<h>\d{2}):(?P<mi>\d{2}):(?P<s>\d{2})(?:[.,](?P<f>\d{1,9}))?\s*(?P<tz>Z|[+-]\d{2}:?\d{2})?\s*$")
# 13/Sep/2026:12:00:00 +0000 (Apache/Nginx access)
_CLF_RE = re.compile(r"^\s*\[?(?P<d>\d{1,2})/(?P<mon>[A-Za-z]{3})/(?P<y>\d{4}):(?P<h>\d{2}):(?P<mi>\d{2}):(?P<s>\d{2})\s*(?P<tz>[+-]\d{4})?\]?\s*$")
# Sun Sep 13 12:00:00.123456 2026 (Apache error log), Sep 13 12:00:00 2026
_APACHE_ERR_RE = re.compile(r"^\s*\[?(?:[A-Za-z]{3}\s+)?(?P<mon>[A-Za-z]{3})\s+(?P<d>\d{1,2})\s+(?P<h>\d{2}):(?P<mi>\d{2}):(?P<s>\d{2})(?:\.(?P<f>\d{1,9}))?\s+(?P<y>\d{4})\]?\s*$")
# Sep 13 12:00:00 (syslog RFC 3164 - no year, no zone)
_SYSLOG_RE = re.compile(r"^\s*(?P<mon>[A-Za-z]{3})\s+(?P<d>\d{1,2})\s+(?P<h>\d{2}):(?P<mi>\d{2}):(?P<s>\d{2})(?:\.(?P<f>\d{1,9}))?\s*$")
# 13-Sep-2026 12:00:00 [UTC] (PHP error log), 13-Sep-2026::12:00:00.123456 (Erlang reports)
_DMY_RE = re.compile(r"^\s*(?P<d>\d{1,2})-(?P<mon>[A-Za-z]{3})-(?P<y>\d{4})(?:::|[ T])(?P<h>\d{2}):(?P<mi>\d{2}):(?P<s>\d{2})(?:[.,](?P<f>\d{1,9}))?\s*(?P<tz>UTC|GMT|Z|[+-]\d{2}:?\d{2})?\s*$")
# 2026-Sep-13 12:00:00.123456 (Boost.Log default TimeStamp)
_YMON_RE = re.compile(r"^\s*(?P<y>\d{4})-(?P<mon>[A-Za-z]{3})-(?P<d>\d{2})[ T](?P<h>\d{2}):(?P<mi>\d{2}):(?P<s>\d{2})(?:[.,](?P<f>\d{1,9}))?\s*$")
# Sep 13, 2026 12:00:00 PM (java.util.logging SimpleFormatter default, US locale)
_JUL_RE = re.compile(r"^\s*(?P<mon>[A-Za-z]{3,4})\.?\s+(?P<d>\d{1,2}),\s+(?P<y>\d{4})\s+(?P<h>\d{1,2}):(?P<mi>\d{2}):(?P<s>\d{2})\s*(?P<ampm>[AaPp]\.?[Mm]\.?)?\s*$")
# glog: I0913 12:34:56.789012 (month/day, no year) or I20260913 12:34:56.789012
_GLOG_RE = re.compile(r"^\s*(?:(?P<y>\d{4}))?(?P<mo>\d{2})(?P<d>\d{2})\s+(?P<h>\d{2}):(?P<mi>\d{2}):(?P<s>\d{2})(?:\.(?P<f>\d{1,9}))?\s*$")
# 12:00:00.123 / 12:00:00,123 / 12:00PM (time only)
_TIME_ONLY_RE = re.compile(r"^\s*(?P<h>\d{1,2}):(?P<mi>\d{2})(?::(?P<s>\d{2})(?:[.,](?P<f>\d{1,9}))?)?\s*(?P<ampm>[AaPp][Mm])?\s*$")
# numeric epochs
_EPOCH_RE = re.compile(r"^\s*(?P<n>\d{9,19})(?:\.(?P<f>\d{1,9}))?\s*$")

_TZ_NAMES = {"z": 0, "utc": 0, "gmt": 0}


def _tz_seconds(tz: Optional[str]) -> Optional[int]:
    if tz is None:
        return None
    t = tz.strip()
    low = t.lower()
    if low in _TZ_NAMES:
        return 0
    sign = 1 if t[0] == "+" else -1
    body = t[1:].replace(":", "")
    if len(body) == 2:
        hh, mm = int(body), 0
    else:
        hh, mm = int(body[:2]), int(body[2:4])
    return sign * (hh * 3600 + mm * 60)


def _frac(f: Optional[str]) -> float:
    if not f:
        return 0.0
    return int(f) / (10 ** len(f))


def _mk(y: int, mo: int, d: int, h: int, mi: int, s: int, frac: float, tz_seconds: Optional[int],
        assume_offset: int) -> Tuple[Optional[float], Tuple[str, ...]]:
    try:
        base = calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0))
    except (ValueError, OverflowError):
        return None, ("invalid",)
    if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 24 or mi > 59 or s > 61:
        return None, ("invalid",)
    if tz_seconds is None:
        return base - assume_offset + frac, ("naive",)
    return base - tz_seconds + frac, ()


def infer_year(mo: int, d: int, h: int, mi: int, s: int, now: float) -> int:
    """Pick the most recent year for which the date is not in the future (+1 day slack)."""
    year = time.gmtime(now).tm_year
    try:
        candidate = calendar.timegm((year, mo, d, h, mi, s, 0, 0, 0))
    except (ValueError, OverflowError):
        return year
    if candidate > now + 86400:
        return year - 1
    return year


def parse_timestamp(text: Optional[str], assume_offset: int = 0, now: Optional[float] = None
                    ) -> Tuple[Optional[float], Tuple[str, ...]]:
    """Parse a timestamp string. Returns (epoch_seconds or None, flags)."""
    if text is None:
        return None, ("missing",)
    if not isinstance(text, str):
        if isinstance(text, bool):
            return None, ("missing",)
        if isinstance(text, (int, float)):
            return parse_epoch(float(text))
        text = str(text)
    if not text or len(text) > 64:
        return None, ("missing",)
    now = now if now is not None else time.time()

    m = _ISO_RE.match(text)
    if m:
        return _mk(int(m.group("y")), int(m.group("mo")), int(m.group("d")),
                   int(m.group("h") or 0), int(m.group("mi") or 0), int(m.group("s") or 0),
                   _frac(m.group("f")), _tz_seconds(m.group("tz")), assume_offset)
    m = _BASIC_RE.match(text)
    if m:
        return _mk(int(m.group("y")), int(m.group("mo")), int(m.group("d")), int(m.group("h") or 0),
                   int(m.group("mi") or 0), int(m.group("s") or 0), _frac(m.group("f")),
                   _tz_seconds(m.group("tz")), assume_offset)
    m = _EPOCH_RE.match(text)
    if m:
        return parse_epoch(float(m.group("n")) + _frac(m.group("f")) if m.group("f") else int(m.group("n")))
    m = _SLASH_RE.match(text)
    if m:
        return _mk(int(m.group("y")), int(m.group("mo")), int(m.group("d")), int(m.group("h")),
                   int(m.group("mi")), int(m.group("s")), _frac(m.group("f")), _tz_seconds(m.group("tz")),
                   assume_offset)
    m = _CLF_RE.match(text)
    if m:
        mon = _MONTHS.get(m.group("mon").lower())
        if not mon:
            return None, ("invalid",)
        return _mk(int(m.group("y")), mon, int(m.group("d")), int(m.group("h")), int(m.group("mi")),
                   int(m.group("s")), 0.0, _tz_seconds(m.group("tz")), assume_offset)
    m = _APACHE_ERR_RE.match(text)
    if m:
        mon = _MONTHS.get(m.group("mon").lower())
        if not mon:
            return None, ("invalid",)
        return _mk(int(m.group("y")), mon, int(m.group("d")), int(m.group("h")), int(m.group("mi")),
                   int(m.group("s")), _frac(m.group("f")), None, assume_offset)
    m = _DMY_RE.match(text)
    if m:
        mon = _MONTHS.get(m.group("mon").lower())
        if not mon:
            return None, ("invalid",)
        return _mk(int(m.group("y")), mon, int(m.group("d")), int(m.group("h")), int(m.group("mi")),
                   int(m.group("s")), _frac(m.group("f")), _tz_seconds(m.group("tz")), assume_offset)
    m = _YMON_RE.match(text)
    if m:
        mon = _MONTHS.get(m.group("mon").lower())
        if not mon:
            return None, ("invalid",)
        return _mk(int(m.group("y")), mon, int(m.group("d")), int(m.group("h")), int(m.group("mi")),
                   int(m.group("s")), _frac(m.group("f")), None, assume_offset)
    m = _JUL_RE.match(text)
    if m:
        mon = _MONTHS.get(m.group("mon").lower()[:3])
        if not mon:
            return None, ("invalid",)
        h = int(m.group("h"))
        ampm = (m.group("ampm") or "").lower().replace(".", "")
        if ampm == "pm" and h < 12:
            h += 12
        elif ampm == "am" and h == 12:
            h = 0
        return _mk(int(m.group("y")), mon, int(m.group("d")), h, int(m.group("mi")), int(m.group("s")),
                   0.0, None, assume_offset)
    m = _SYSLOG_RE.match(text)
    if m:
        mon = _MONTHS.get(m.group("mon").lower())
        if not mon:
            return None, ("invalid",)
        d, h, mi, s = int(m.group("d")), int(m.group("h")), int(m.group("mi")), int(m.group("s"))
        y = infer_year(mon, d, h, mi, s, now)
        ts, flags = _mk(y, mon, d, h, mi, s, _frac(m.group("f")), None, assume_offset)
        return ts, flags + ("year_inferred",)
    m = _GLOG_RE.match(text)
    if m:
        mo, d = int(m.group("mo")), int(m.group("d"))
        h, mi, s = int(m.group("h")), int(m.group("mi")), int(m.group("s"))
        flags_extra: Tuple[str, ...] = ()
        if m.group("y"):
            y = int(m.group("y"))
        else:
            y = infer_year(mo, d, h, mi, s, now)
            flags_extra = ("year_inferred",)
        ts, flags = _mk(y, mo, d, h, mi, s, _frac(m.group("f")), None, assume_offset)
        return ts, flags + flags_extra
    m = _TIME_ONLY_RE.match(text)
    if m:
        return None, ("time_only",)
    return None, ("unparsed",)


def parse_epoch(value: float) -> Tuple[Optional[float], Tuple[str, ...]]:
    """Numeric epoch; unit chosen by magnitude: s (<1e11), ms (<1e14), us (<1e17), else ns."""
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None, ("invalid",)
    if v <= 0:
        return None, ("invalid",)
    if v < 1e11:
        return v, ("epoch_unit:s",)
    if v < 1e14:
        return v / 1e3, ("epoch_unit:ms",)
    if v < 1e17:
        return v / 1e6, ("epoch_unit:us",)
    return v / 1e9, ("epoch_unit:ns",)


def parse_offset_spec(spec: str) -> int:
    """Parse ``UTC``, ``Z``, ``+02:00``, ``-0530`` into seconds east of UTC."""
    s = spec.strip()
    if s.lower() in ("utc", "z", "gmt", "local"):
        if s.lower() == "local":
            return time.localtime().tm_gmtoff   # the offset in effect now, DST included
        return 0
    m = re.match(r"^([+-])(\d{2}):?(\d{2})$", s)
    if not m:
        raise ValueError("invalid time zone offset %r (expected UTC, Z, local, or +HH:MM)" % spec)
    sign = 1 if m.group(1) == "+" else -1
    return sign * (int(m.group(2)) * 3600 + int(m.group(3)) * 60)


def format_iso(ts: Optional[float]) -> Optional[str]:
    if ts is None:
        return None
    try:
        whole = int(ts // 1)
        frac = ts - whole
        tm = time.gmtime(whole)
    except (OverflowError, ValueError, OSError):
        return None
    base = time.strftime("%Y-%m-%dT%H:%M:%S", tm)
    if frac >= 0.0005:
        base += ".%03d" % int(round(frac * 1000)) if int(round(frac * 1000)) < 1000 else ".999"
    return base + "Z"
