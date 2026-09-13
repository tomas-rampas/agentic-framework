"""Secret redaction and pseudonymization (docs/log-triage/README.md, "Redaction").

Applied to every message, exception text and attribute value *before* templating,
example retention, report rendering, and any model context. Replacement tokens
are stable strings such as ``<redacted:aws-access-key>``; pseudonyms
(``<email:3f9a1c>``) are HMAC-derived from a per-run random key (or
``--redaction-salt`` for cross-run stability) so correlation inside a run is
preserved without exposing the value.

Limitations (documented): pattern-based; unknown secret formats, secrets split
across lines, and free-form sensitive prose are not detected.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import re
from typing import Dict, Optional, Tuple

_KV_KEYS = (r"pass(?:word|wd|phrase)?|pwd|passwd|secret|api[_-]?key|apikey|access[_-]?key|private[_-]?key|"
            r"client[_-]?secret|auth[_-]?token|access[_-]?token|refresh[_-]?token|id[_-]?token|token|"
            r"credentials?|x-api-key|session[_-]?id|sessionid|cookie|set-cookie|account[_-]?key|sas[_-]?token|"
            r"signature|sig|shared[_-]?access[_-]?key|authorization|proxy-authorization|x-auth-token|bearer")

_DASHES = "-" * 5
_PK_BEGIN = "BEGIN [A-Z ]*PRIVATE " + "KEY"
_PK_END = "END [A-Z ]*PRIVATE " + "KEY"
_MASTER = re.compile(
    (r"(?P<pk>%s%s%s.*?(?:%s%s%s|$))" % (_DASHES, _PK_BEGIN, _DASHES, _DASHES, _PK_END, _DASHES)) +
    r"|(?P<auth>\b(?:authorization|proxy-authorization)\s*[:=]\s*(?:basic|bearer|digest|token|negotiate|ntlm)?\s*[A-Za-z0-9._~+/=-]{8,})"
    r"|(?P<bearer>\bbearer\s+[A-Za-z0-9._~+/=-]{16,})"
    r"|(?P<jwt>\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b)"
    r"|(?P<aws>\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA)[0-9A-Z]{16}\b)"
    r"|(?P<gh>\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b)"
    r"|(?P<slack>\bxox[abprs]-[A-Za-z0-9-]{10,}\b)"
    r"|(?P<google>\bAIza[0-9A-Za-z_-]{35}\b)"
    r"|(?P<stripe>\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}\b)"
    r"|(?P<sg>\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\b)"
    r"|(?P<npm>\bnpm_[A-Za-z0-9]{36}\b)"
    r"|(?P<pypi>\bpypi-[A-Za-z0-9_-]{16,}\b)"
    r"|(?P<sk>\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}\b)"
    r"|(?P<azkey>\bAccountKey=[A-Za-z0-9+/=]{40,})"
    r"|(?P<urlcred>\b[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@)"
    r"|(?P<kv>(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_-])?(?:" + _KV_KEYS + r")\b[\"']?\s*[:=]\s*(?P<kvq>[\"']?)(?P<kvv>[^\s\"';,&]{4,})(?P=kvq))"
    r"|(?P<card>\b\d(?:[ -]?\d){12,18}\b)"
    r"|(?P<email>\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b)"
    r"|(?P<ip>\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b)",
    re.IGNORECASE | re.DOTALL,
)

_R = "<redacted:%s>"
# Private-key blocks are removed in a pre-pass: inside the master alternation a key=value match that
# starts earlier in the line ("credentials: -----BEGIN ...") would otherwise consume the BEGIN marker
# and leave the key body untouched.
_PK_RE = re.compile(r"%s%s%s.*?(?:%s%s%s|$)" % (_DASHES, _PK_BEGIN, _DASHES, _DASHES, _PK_END, _DASHES), re.DOTALL)
_PREFILTER = re.compile(r"[@=:]|\d|-----|akia|asia|agpa|aida|aroa|anpa|eyj|xox[abprs]-|aiza|sg\.|npm_|pypi-|sk-|gh[opsur]_|github_pat_|accountkey|bearer|authorization", re.IGNORECASE)
_SENSITIVE_KEY = re.compile("^(?:%s)$" % _KV_KEYS, re.IGNORECASE)
_KEY_SPLIT = re.compile(r"[._\-@/: ]+")
_COUNTER_SUFFIXES = {"count", "total", "alg", "algorithm", "version", "len", "length", "size", "type", "kind", "name", "id"}
_CAMEL = re.compile(r"([a-z0-9])([A-Z])")


def _is_sensitive_key(key: str) -> bool:
    """True when the attribute key, its flattened leaf (``ctx.password``), or any of the leaf's
    ``_``/``-``/camelCase segments (``user_password``, ``DB_PASSWORD``, ``passwordHash``) names a secret."""
    if not key:
        return False
    if _SENSITIVE_KEY.match(key):
        return True
    leaf = re.split(r"[.@/:]", key)[-1]
    if not leaf:
        return False
    if _SENSITIVE_KEY.match(leaf):
        return True
    segs = [seg for seg in _KEY_SPLIT.split(_CAMEL.sub(r"\1 \2", leaf)) if seg]
    if segs and segs[-1].lower() in _COUNTER_SUFFIXES:
        return False    # token_count, cookie_total, sig_alg: metadata about a secret, not the secret
    return any(_SENSITIVE_KEY.match(seg) for seg in segs)
_SIMPLE_TOKENS = {
    "pk": _R % "private-key", "jwt": _R % "jwt", "aws": _R % "aws-access-key",
    "gh": _R % "github-token", "slack": _R % "slack-token", "google": _R % "google-api-key",
    "stripe": _R % "stripe-key", "sg": _R % "sendgrid-key", "npm": _R % "npm-token",
    "pypi": _R % "pypi-token", "sk": _R % "api-key",
}

_PLACEHOLDER_VALUES = {"none", "null", "nil", "true", "false", "empty", "<redacted>", "*****", "********",
                       "xxxxxxxx", "hidden", "redacted", "masked", "[hidden]", "[redacted]", "<hidden>",
                       "undefined", "(null)", "n/a"}


def _luhn(digits: str) -> bool:
    total = 0
    parity = len(digits) % 2
    for i, ch in enumerate(digits):
        d = ord(ch) - 48
        if i % 2 == parity:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


class Redactor:
    def __init__(self, enabled: bool = True, redact_ips: bool = False, salt: Optional[str] = None):
        self.enabled = enabled
        self.redact_ips = redact_ips
        self.key = (salt or os.urandom(16).hex()).encode("utf-8")
        self.counts: Dict[str, int] = {}
        self._pseudo_cache: Dict[Tuple[str, str], str] = {}

    def pseudonym(self, kind: str, value: str) -> str:
        key = (kind, value.lower())
        cached = self._pseudo_cache.get(key)
        if cached is None:
            digest = hmac.new(self.key, key[1].encode("utf-8"), hashlib.sha256).hexdigest()[:6]
            cached = "<%s:%s>" % (kind, digest)
            if len(self._pseudo_cache) < 50_000:
                self._pseudo_cache[key] = cached
        return cached

    def _bump(self, kind: str) -> None:
        self.counts[kind] = self.counts.get(kind, 0) + 1

    def _replace(self, m: "re.Match") -> str:
        kind = m.lastgroup
        # the kv alternative has nested named groups; lastgroup may be kvq/kvv when they matched last
        if kind in ("kvq", "kvv"):
            kind = "kv"
        if kind in _SIMPLE_TOKENS:
            self._bump(kind)
            return _SIMPLE_TOKENS[kind]
        text = m.group(0)
        if kind == "auth":
            self._bump("auth-header")
            name = text.split(":", 1)[0].split("=", 1)[0]
            return name + ": <redacted:auth-token>"
        if kind == "bearer":
            self._bump("bearer-token")
            return text.split(None, 1)[0] + " <redacted:token>"
        if kind == "azkey":
            self._bump("azure-account-key")
            return "AccountKey=<redacted:azure-account-key>"
        if kind == "urlcred":
            self._bump("url-credentials")
            scheme = text.split("://", 1)[0]
            return scheme + "://<redacted:credentials>@"
        if kind == "kv":
            value = m.group("kvv")
            if value.lower() in _PLACEHOLDER_VALUES or value.startswith("<redacted") or value.startswith("${"):
                return text
            self._bump("key-value-secret")
            head = text[: text.index(m.group("kvq") + value)] if m.group("kvq") else text[: text.rfind(value)]
            keyname = re.split(r"[:=]", head, 1)[0].strip().lower()
            return head + "<redacted:" + keyname + ">"
        if kind == "card":
            digits = re.sub(r"[ -]", "", text)
            if 13 <= len(digits) <= 19 and _luhn(digits) and not (len(set(digits)) == 1):
                self._bump("card-number")
                return "<redacted:card>"
            return text
        if kind == "email":
            self._bump("email")
            return self.pseudonym("email", text)
        if kind == "ip":
            if not self.redact_ips:
                return text
            self._bump("ip")
            return self.pseudonym("ip", text)
        return text

    def redact(self, text: Optional[str]) -> Optional[str]:
        if not self.enabled or not text:
            return text
        if _PREFILTER.search(text) is None:
            return text
        if _DASHES in text:
            text, n = _PK_RE.subn(_SIMPLE_TOKENS["pk"], text)
            if n:
                self.counts["pk"] = self.counts.get("pk", 0) + n
        return _MASTER.sub(self._replace, text)

    def redact_attr(self, key: str, value: str) -> str:
        """Attribute values are redacted with their key as context (``password=...`` style)."""
        if not self.enabled or not isinstance(value, str) or not value:
            return value
        if _is_sensitive_key(key) and value.lower() not in _PLACEHOLDER_VALUES:
            self._bump("key-value-secret")
            return "<redacted:%s>" % key.lower()
        return self.redact(value)

    def prefilter_hit(self, text: str) -> bool:
        """Cheap check whether ``text`` could contain something the redactor would touch."""
        return bool(self.enabled and text and _PREFILTER.search(text))

    def summary(self) -> Dict[str, int]:
        return dict(sorted(self.counts.items()))
