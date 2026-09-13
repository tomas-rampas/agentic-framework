"""Message templating (fingerprint version 1).

``template(text)`` replaces instance-specific values with typed placeholders while
protecting values that change the meaning of a failure (HTTP status codes in
context, error codes, HRESULTs, errno/exit codes). The full rule list is in
docs/log-triage/canonical-model.md ("Normalization rules").
"""
from __future__ import annotations

import re
from typing import List, Optional

TEMPLATE_VERSION = "1"

_PROTECT = re.compile(
    r"(?P<httpctx>\b(?:status(?:\s*code)?|http|code|returned|responded|response|result)\s*[:=]?\s*\(?[1-5]\d{2}\b)"
    r"|(?P<httpline>\bHTTP/\d(?:\.\d)?\"?\s+[1-5]\d{2}\b)"
    r"|(?P<errcode>(?-i:\b[A-Z]{1,6}[-_]?\d{3,6}\b))"
    r"|(?P<hresult>\b0x8[0-9A-Fa-f]{7}\b)"
    r"|(?P<sqlstate>\bSQLSTATE\[?\w{5}\]?)"
    r"|(?P<errno>\b(?:errno|exit code|exit status|signal|error code|errorcode|error_code|rc)\s*[:=]?\s*-?\d+\b)"
    r"|(?P<techtok>\b(?:sha256|sha512|sha1|md5|utf8|utf-8|utf16|utf-16|base64|base32|http2|http1\.1|http/1\.1|http/2|log4j|log4j2|log4net|s3|ec2|oauth2|x509|ipv4|ipv6|i18n|l10n|k8s|h264|h265|win32|win64|x64|x86|amd64|arm64|py3|python3|c99|c11|c17|java8|java11|java17|java21|net6|net7|net8|net9|net48|1st|2nd|3rd|4th|tls1\.2|tls1\.3|tls12|tls13|ssl3|v1|v2|v3|v4|api/v1|api/v2|mp3|mp4|p2p|b2b|3d|2d|e2e|s3://)\b)",
    re.IGNORECASE,
)

_POD = re.compile(r"\b([a-z][a-z0-9]*(?:-[a-z][a-z0-9]*)*)-[0-9a-f]{7,10}-[a-z0-9]{5}\b")
_UUID = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
_TS = re.compile(
    r"\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?(?:[.,]\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?\b"
    r"|\b\d{4}/\d{2}/\d{2}(?:[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)?\b"
    r"|\b\d{1,2}/[A-Za-z]{3}/\d{4}(?::\d{2}:\d{2}:\d{2})?(?:\s[+-]\d{4})?"
    r"|\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)?\s?(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}(?:,\s+\d{4})?\s+\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:\s?[AP]M)?\b"
    r"|\b\d{1,2}:\d{2}:\d{2}(?:[.,]\d+)?\b"
)
_URL = re.compile(r"\b[a-z][a-z0-9+.-]*://[^\s\"'<>)\]]+", re.IGNORECASE)
_IP6 = re.compile(r"\b(?:[0-9a-fA-F]{1,4}:){2,7}(?:[0-9a-fA-F]{1,4})?(?:::)?(?:[0-9a-fA-F]{1,4})?\b(?=[^:]|$)")
_IP4 = re.compile(r"\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?::\d{1,5})?\b")
_EMAILPH = re.compile(r"<(email|ip):[0-9a-f]{6}>")
_HEX0X = re.compile(r"\b0x[0-9a-fA-F]+\b")
_HEXLONG = re.compile(r"\b(?=[0-9a-fA-F]*\d)(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{8,}\b")
_TOKEN = re.compile(r"\b(?=[A-Za-z0-9+_=-]*\d)(?=[A-Za-z0-9+_=-]*[A-Za-z])[A-Za-z0-9+_-]{24,}={0,2}(?![\w/])")
_DUR = re.compile(r"(?<![\w.])\d+(?:\.\d+)?\s?(?:ns|us|µs|ms|s|sec|secs|seconds?|m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)\b")
_SIZE = re.compile(r"(?<![\w.])\d+(?:\.\d+)?\s?(?:B|KB|KiB|MB|MiB|GB|GiB|TB|TiB|bytes?|k|K|M|G)\b")
_PCT = re.compile(r"(?<![\w.])\d+(?:\.\d+)?%")
_TMP = re.compile(r"\b(?:tmp|temp)[A-Za-z0-9_]{4,}\b")
_WINPATH = re.compile(r"\b[A-Za-z]:\\(?:[^\\\s\"'<>|:*?]+\\)*[^\\\s\"'<>|:*?]*")
_UNIXPATH = re.compile(r"(?<![\w.])/(?:[\w.@+~-]+/)+[\w.@+~-]*")
_LONGQUOTE = re.compile(r"([\"'])([^\"']{40,})\1")
_SEPID = re.compile(r"(?<=[-=:#])(?=[A-Za-z0-9]*\d)[A-Za-z0-9]+\b(?![.:]\d)")
_NUMBER = re.compile(r"(?<![\w.])[-+]?\d+(?:\.\d+)?(?![\w.]|\.\d)")
_WORDDIGITS = re.compile(r"(?<=[A-Za-z_-])\d{2,}(?![A-Za-z])|(?<=[A-Za-z_-])\d+\b")
_WS = re.compile(r"\s+")
_PLACEHOLDER = re.compile(r"<[a-z0-9:-]+>")
_SENTINEL = "\x00%s\x00"


def _alpha(n: int) -> str:
    out = ""
    while True:
        out = chr(97 + n % 26) + out
        n //= 26
        if n == 0:
            return out



def _from_alpha(s: str) -> int:
    n = 0
    for ch in s:
        n = n * 26 + (ord(ch) - 97)
    return n


_SEG_DIGITS = re.compile(r"\d{2,}|(?<=[^\d])\d+$")


def _path_segment(seg: str) -> str:
    if not seg or not any(ch.isdigit() for ch in seg):
        return seg
    if seg.isdigit() or _HEXLONG.fullmatch(seg) or _UUID.fullmatch(seg):
        return "<n>"
    return _SEG_DIGITS.sub("<n>", seg)


def _norm_path(path: str, sep: str) -> str:
    parts = path.split(sep)
    return sep.join(_path_segment(p) for p in parts)


def _norm_url(m: "re.Match") -> str:
    url = m.group(0)
    scheme, rest = url.split("://", 1)
    rest = rest.split("#", 1)[0]
    path_q = rest.split("?", 1)
    base = path_q[0]
    qs = "?<qs>" if len(path_q) > 1 else ""
    host_path = base.split("/", 1)
    host = host_path[0]
    host = _IP4.sub("<ip>", host)
    host = re.sub(r":\d{1,5}$", ":<n>", host)
    path = ""
    if len(host_path) > 1:
        path = "/" + _norm_path(host_path[1], "/")
    return "%s://%s%s%s" % (scheme.lower(), host, path, qs)


def template(text: Optional[str], max_chars: int = 1000) -> str:
    """Normalize ``text`` into a message template (deterministic, version 1)."""
    if text and "\x00" in text:
        text = text.replace("\x00", "")   # NUL is the protect sentinel; log NULs must not alias it
    if not text:
        return ""
    s = text
    if len(s) > max_chars * 2:
        s = s[: max_chars * 2]
    protected: List[str] = []

    def _keep(m: "re.Match") -> str:
        protected.append(m.group(0))
        return _SENTINEL % _alpha(len(protected) - 1)

    # pseudonyms collapse to their kind (<email:3f9a1c> -> <email>); other placeholders are kept intact
    s = _EMAILPH.sub(lambda m: "<" + m.group(1) + ">", s)
    s = _PLACEHOLDER.sub(_keep, s)
    s = _PROTECT.sub(_keep, s)
    s = _POD.sub(r"\1-<pod>", s)
    s = _UUID.sub("<uuid>", s)
    s = _TS.sub("<ts>", s)
    s = _URL.sub(_norm_url, s)
    s = _IP4.sub(lambda m: "<ip>" + (":<n>" if ":" in m.group(0) else ""), s)
    s = _IP6.sub(lambda m: "<ip6>" if ("::" in m.group(0) or re.search(r"[a-fA-F]", m.group(0))) else m.group(0), s)
    s = _TMP.sub("<tmp>", s)
    s = _WINPATH.sub(lambda m: _norm_path(m.group(0), "\\"), s)
    s = _UNIXPATH.sub(lambda m: _norm_path(m.group(0), "/"), s)
    s = _HEX0X.sub("<hex>", s)
    s = _HEXLONG.sub("<hex>", s)
    s = _TOKEN.sub("<token>", s)
    s = _LONGQUOTE.sub(lambda m: m.group(1) + "<str>" + m.group(1), s)
    s = _DUR.sub("<dur>", s)
    s = _SIZE.sub("<size>", s)
    s = _PCT.sub("<pct>", s)
    s = _SEPID.sub("<id>", s)
    s = _NUMBER.sub("<n>", s)
    s = _WORDDIGITS.sub("<n>", s)
    s = _WS.sub(" ", s).strip()
    if protected:
        s = re.sub(r"\x00([a-z]+)\x00", lambda m: protected[_from_alpha(m.group(1))] if _from_alpha(m.group(1)) < len(protected) else "", s)
    if len(s) > max_chars:
        s = s[:max_chars]
    return s


_FRAME_LAMBDA = re.compile(r"\$\$Lambda\$\d+/0x[0-9a-f]+|\$\$Lambda\$\d+|\$\$Lambda/0x[0-9a-f]+|<lambda_\d+>|\$lambda\$\d+|\$\d+")
_FRAME_HEX = re.compile(r"0x[0-9a-fA-F]+")


def frame_signature(function: Optional[str], file: Optional[str]) -> str:
    fn = function or "?"
    fn = _FRAME_LAMBDA.sub("$λ", fn)
    fn = _FRAME_HEX.sub("<hex>", fn)
    fn = re.sub(r"\d{2,}", "<n>", fn)
    base = ""
    if file:
        base = file.replace("\\", "/").rsplit("/", 1)[-1]
    return fn + "|" + base
