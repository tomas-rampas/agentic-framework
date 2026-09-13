"""Severity, category and impact assessment (docs/log-triage/canonical-model.md, "Assessment").

The producer's log level and the assessed operational impact are separate. Rules are
deterministic and evidence-based: every assessment carries the tokens that triggered
it, a confidence, and a basis label (observed / inferred / unknown). Occurrence counts
never change severity.
"""
from __future__ import annotations

import re
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .config import SEVERITIES, SEVERITY_RANK
from .model import LEVEL_CRITICAL, LEVEL_ERROR, LEVEL_INFO, LEVEL_WARN

# --- evidence tables (lower-cased regexes) ------------------------------------------
_R = lambda p: re.compile(p, re.IGNORECASE)  # noqa: E731

RULES: List[Tuple[str, "re.Pattern", str]] = [
    # (category, pattern, signal label)
    ("application_crash", _R(r"\bpanic(?:ked)?\b|segmentation fault|\bsigsegv\b|\bsigabrt\b|\bsigbus\b|\bsigill\b|exc_bad_access|exc_crash|"
                             r"core dumped|unhandled exception|\bfatal error\b|stack ?overflow|\baborted\b|assertion (?:failed|failure)|"
                             r"addresssanitizer|threadsanitizer|memorysanitizer|leaksanitizer|undefinedbehaviorsanitizer|"
                             r"process terminated|\bcrashed\b|\bterminating\b|exit(?:ed)? (?:with )?(?:code|status) [1-9]|"
                             r"unhandled promise rejection|uncaught (?:exception|typeerror|error)|nullreferenceexception|nullpointerexception"),
     "crash"),
    ("resource_exhaustion", _R(r"out ?of ?memory|outofmemoryerror|no space left|\benospc\b|disk (?:is )?full|too many open files|\bemfile\b|\benfile\b|"
                               r"pool (?:is )?exhausted|connection pool|max_connections|too many connections|quota exceeded|rate.?limit|throttl|"
                               r"\b429\b|resource temporarily unavailable|\beagain\b|memory limit|oomkill|oom-kill|killed process|"
                               r"gc overhead limit|heap space|cannot allocate|allocation failed|insufficient memory|thread pool|"
                               r"queue (?:is )?full|backpressure|file descriptor"),
     "resource_exhaustion"),
    ("data_integrity", _R(r"\bcorrupt|checksum|\bcrc\b|inconsisten|constraint violation|duplicate key|unique (?:constraint|violation)|"
                          r"foreign key|integrity|data loss|lost \d+ (?:messages|records|events|rows)|dropped \d+ (?:messages|records|events)|"
                          r"truncated (?:table|data|file)|serialization failure|schema mismatch|version mismatch|migration failed|"
                          r"could not (?:de)?serialize|deserialization|invalid (?:utf-?8|encoding)|malformed (?:record|message|packet)|"
                          r"optimistic (?:lock|concurrency)|stale (?:data|read|object)|write conflict"),
     "data_integrity"),
    ("security", _R(r"failed password|invalid user|brute.?force|sql injection|\bxss\b|\battack\b|malicious|exploit|"
                    r"tamper|signature (?:invalid|mismatch|verification failed)|certificate (?:expired|invalid|verify failed|unknown)|"
                    r"self.signed|possible break-in|intrusion|unauthorized access|privilege escalation|csrf|replay attack|"
                    r"suspicious|blocked (?:ip|request)|waf\b"),
     "security"),
    ("auth", _R(r"unauthori[sz]ed|\bforbidden\b|\b40[13]\b|authenticat|invalid (?:token|credentials|password|api.?key|signature)|"
                r"expired token|token (?:expired|invalid|rejected)|access denied|permission denied|\beacces\b|\beperm\b|login failed|"
                r"\bjwt\b|oauth|not allowed|insufficient (?:permissions|privileges|scope)|invalid_grant|invalid_client"),
     "auth"),
    ("timeout", _R(r"timed? ?out|\btimeout\b|deadline exceeded|\betimedout\b|context deadline|read timed out|gateway timeout|\b504\b|"
                   r"took too long|exceeded (?:the )?time limit|wait timeout|lock wait timeout|no response (?:within|after)"),
     "timeout"),
    ("dependency_failure", _R(r"\bupstream\b|\bdatabase\b|\bdb\b|\bsql\b|\bredis\b|\bkafka\b|rabbit|\bamqp\b|\bmongo|elastic|\bs3\b|\bbucket\b|"
                              r"\bqueue\b|\bbroker\b|\bgrpc\b|\brpc\b|remote server|downstream|dependency|\b502\b|\b503\b|bad gateway|"
                              r"service unavailable|\bpostgres|\bmysql|\bmariadb|\bmssql|\boracle\b|\bcassandra|\bdynamo|\bsqs\b|\bsns\b|"
                              r"\bldap\b|\bsmtp\b|\bimap\b|http client|httpclient|webclient|feign|resttemplate|axios|fetch failed|"
                              r"max retries exceeded|connection refused|econnrefused|connection reset|econnreset|broken pipe|\bepipe\b|"
                              r"circuit ?breaker|no healthy upstream"),
     "dependency"),
    ("availability", _R(r"service unavailable|\b50[023]\b|bad gateway|health.?check (?:failed|failing|error)|not responding|\boutage\b|"
                        r"liveness|readiness|circuit (?:breaker )?(?:is )?open|no healthy|no available (?:instances|backends|replicas)|"
                        r"all (?:attempts|retries) failed|failed to start|startup failed|listen(?:ing)? (?:failed|error)|address already in use|"
                        r"\beaddrinuse\b|bind(?:ing)? failed|port .{0,20} in use|shutting down|shutdown|\brestart(?:ing|ed)?\b|"
                        r"unhealthy|unavailable|\b500\b|internal server error|leader (?:lost|election)|split.?brain|node (?:down|lost)"),
     "availability"),
    ("network", _R(r"unreachable|\behostunreach\b|\benetunreach\b|no route to host|\bdns\b|\benotfound\b|eai_again|name resolution|"
                   r"getaddrinfo|\btls\b|\bssl\b|handshake|\bsocket\b|connect(?:ion)? (?:failed|error|closed|lost|aborted|timed out)|"
                   r"network (?:error|unreachable|is down)|host (?:not found|unknown)|proxy error|\btcp\b|\budp\b|packet loss|"
                   r"connection refused|econnrefused|connection reset|econnreset|broken pipe|\bepipe\b|eof|unexpected end of stream"),
     "network"),
    ("configuration", _R(r"\bconfig(?:uration)?\b|misconfigur|missing (?:environment|env|setting|property|required|configuration|parameter)|"
                         r"environment variable|is not set|not configured|invalid (?:option|setting|configuration|property|argument)|"
                         r"unknown (?:option|flag|property|setting)|could not (?:find|load|read) (?:config|settings|properties)|"
                         r"no such file|\benoent\b|file not found|filenotfound|classnotfound|noclassdeffound|module not found|cannot find module|"
                         r"dll not found|unable to locate|(?:yaml|yml|toml|ini|properties|conf|cfg|json) (?:file )?(?:not found|invalid|missing|parse)|"
                         r"unsupported (?:version|option)|deprecated|feature flag|unresolved (?:placeholder|property|dependency)|bean creation|"
                         r"port must be|invalid port|invalid url|unknown host"),
     "configuration"),
    ("client_error", _R(r"bad request|\b400\b|\b404\b|not found|validation (?:failed|error)|invalid (?:input|request|payload|parameter|json|body)|"
                        r"unprocessable|\b422\b|method not allowed|\b405\b|unsupported media|\b415\b|\b409\b|conflict|payload too large|"
                        r"\b413\b|\b410\b|\b406\b|malformed request|missing (?:parameter|field|header)|required (?:field|parameter)"),
     "client_error"),
    ("performance", _R(r"\bslow\b|latenc|took \d+|exceeded .{0,30}threshold|degraded|high (?:cpu|memory|load|latency)|backlog|\blag\b|"
                       r"queue depth|saturat|deadlock|\bretry(?:ing)?\b|\bretries\b|backoff|attempt \d+|long.?running|"
                       r"gc pause|stop.the.world|slow query|took longer|response time|\bp99\b|\bp95\b"),
     "performance"),
    ("operational", _R(r"\bstart(?:ed|ing)\b|\blistening\b|\bstopped\b|\bcompleted\b|\bconnected\b|initializ|\bloaded\b|"
                       r"shutting down gracefully|\bready\b|\bhealthy\b|\bsucceeded\b|\bsuccess\b|\bok\b|\bfinished\b|\bdone\b"),
     "operational"),
]

# explicit, high-confidence "observed" signals
_TERMINATION = _R(r"\bpanic(?:ked)?\b|segmentation fault|\bsigsegv\b|\bsigabrt\b|exc_bad_access|exc_crash|core dumped|"
                  r"process terminated|exit(?:ed)? (?:with )?(?:code|status) [1-9]|oomkill|oom-kill|killed process|"
                  r"addresssanitizer|threadsanitizer|memorysanitizer|leaksanitizer|undefinedbehaviorsanitizer|assertion (?:failed|failure)|"
                  r"\bcrashed\b|\bterminating\b|fatal error|unhandled exception")
_DATA_LOSS = _R(r"\bcorrupt|data loss|lost \d+ (?:messages|records|events|rows)|checksum (?:mismatch|failed|error)|dropped \d+ (?:messages|records|events)")
_DISK_OOM = _R(r"out ?of ?memory|outofmemoryerror|no space left|\benospc\b|disk (?:is )?full|oomkill|oom-kill|killed process")
_CRASH_EXC_TYPES = _R(r"OutOfMemoryError|StackOverflow|AccessViolation|Segmentation|EXC_|panic|fatal error|Sanitizer|AssertionFailure|Signal|"
                      r"NullReferenceException|NullPointerException|IndexOutOfRange|ArrayIndexOutOfBounds|runtime error|SIGSEGV|SIGABRT")
_TIMEOUT_EXC = _R(r"Timeout|TimedOut|Deadline|Cancell?ed")
_NET_EXC = _R(r"Socket|Connect|Http|Network|Dns|UnknownHost|Unreachable|IOException|EOF|Pipe|Tls|Ssl|Certificate")
_AUTH_EXC = _R(r"Auth|Unauthori|Forbidden|Permission|AccessDenied|Credential|Token|Jwt|Security")
_CONFIG_EXC = _R(r"Config|FileNotFound|NoSuchFile|ClassNotFound|NoClassDefFound|ModuleNotFound|ImportError|MissingArgument|Argument|Option|Parse|Syntax|Yaml|Json")
_DB_EXC = _R(r"Sql|Db|Database|Redis|Mongo|Kafka|Amqp|Jdbc|Npgsql|Dbal|Mysql|Postgres|Deadlock|Transaction|Query|Elastic|Grpc|Rpc")
_DATA_EXC = _R(r"Integrity|Constraint|Duplicate|Serializ|Deserializ|Checksum|Corrupt|Conflict|Concurrency|Stale|Version")
_RESOURCE_EXC = _R(r"OutOfMemory|Quota|TooMany|Exhausted|RateLimit|Throttl|PoolExhausted|ResourceExhausted")


class Assessment:
    __slots__ = ("severity", "category", "confidence", "basis", "rationale", "signals")

    def __init__(self) -> None:
        self.severity = "info"
        self.category = "unknown"
        self.confidence = 0.35
        self.basis = "unknown"
        self.rationale: List[str] = []
        self.signals: List[str] = []

    def to_dict(self) -> Dict[str, Any]:
        return {"severity": self.severity, "category": self.category, "confidence": round(self.confidence, 2),
                "basis": self.basis, "rationale": list(self.rationale), "impact_signals": sorted(set(self.signals))}


def _cap(sev: str, cap: str) -> str:
    return sev if SEVERITY_RANK[sev] <= SEVERITY_RANK[cap] else cap


def _raise(sev: str, floor: str) -> str:
    return sev if SEVERITY_RANK[sev] >= SEVERITY_RANK[floor] else floor


_CACHE: Dict[Tuple, Assessment] = {}
_CACHE_MAX = 50_000
_RULE_INDEX = {cat: (pat, signal) for cat, pat, signal in RULES}
_WORD_RE = re.compile(r"[a-z0-9]+")


def _split_alternatives(src: str) -> List[str]:
    """Split a regex source on top-level '|' (outside groups/classes, escapes respected)."""
    out: List[str] = []
    depth = 0
    cur: List[str] = []
    i = 0
    while i < len(src):
        ch = src[i]
        if ch == "\\":
            cur.append(src[i:i + 2])
            i += 2
            continue
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "|" and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    out.append("".join(cur))
    return out


def _derive_triggers(src: str) -> Optional[set]:
    """For each top-level alternative, take the longest plain-literal word before the first regex
    metacharacter; it is a necessary substring of any match. Returns None when some alternative has
    no such literal (the rule must then always run)."""
    triggers: set = set()
    for alt in _split_alternatives(src):
        a = alt.strip()
        while a.startswith("\\b"):
            a = a[2:]
        gm = re.match(r"^\(\?:([a-z0-9 _|-]+)\)", a)
        if gm:
            # a leading group of plain literal alternatives: every option is a possible trigger
            for opt in gm.group(1).split("|"):
                words = [w for w in _WORD_RE.findall(opt) if len(w) >= 2]
                if not words:
                    return None
                triggers.add(max(words, key=len))
            continue
        m = re.match(r"^([a-z0-9 _-]+)", a)
        if not m:
            return None
        words = [w for w in _WORD_RE.findall(m.group(1)) if len(w) >= 2]
        if not words:
            return None
        # the leading literal run ends before a metacharacter; the last word may be a prefix of a longer
        # word in the text (e.g. "connect" in "connect(?:ion)?"), which prefix matching tolerates
        triggers.add(max(words, key=len))
    return triggers


_TRIGGERS: Dict[str, Optional[set]] = {cat: _derive_triggers(pat.pattern) for cat, pat, _sig in RULES}
_ALL_TRIGGERS: set = set().union(*[t for t in _TRIGGERS.values() if t])


def _text_prefixes(low: str) -> set:
    """All prefixes (length >= 2) of the words in ``low`` that are known trigger words."""
    hits: set = set()
    for w in _WORD_RE.findall(low):
        n = len(w)
        for k in range(2, n + 1):
            p = w[:k]
            if p in _ALL_TRIGGERS:
                hits.add(p)
    return hits


def _scan_rules(low: str, only: Optional[Sequence[str]] = None) -> Dict[str, List[str]]:
    matched: Dict[str, List[str]] = {}
    prefixes = _text_prefixes(low)
    cats = [c for c, _p, _s in RULES] if only is None else list(only)
    for cat in cats:
        trig = _TRIGGERS[cat]
        if trig is not None and not (trig & prefixes):
            continue
        pat = _RULE_INDEX[cat][0]
        m = pat.search(low)
        if m:
            matched.setdefault(cat, []).append(m.group(0))
    return matched


def classify(template: str, exc_types: Sequence[str], exc_message: str, level_max: Optional[int],
             http_status: Optional[int], error_code: Optional[str], category_hint: Optional[str],
             count: int = 1) -> Assessment:
    """Assess one issue group. Results are cached on everything except ``count`` (which never
    changes severity); the cache is bounded and cleared when full."""
    key = (template, tuple(exc_types or ()), exc_message, level_max, http_status, error_code, category_hint)
    cached = _CACHE.get(key)
    if cached is not None:
        a = Assessment()
        a.severity, a.category, a.confidence, a.basis = cached.severity, cached.category, cached.confidence, cached.basis
        a.rationale = list(cached.rationale)
        a.signals = list(cached.signals)
        a.rationale.append("occurrence count (%d) does not influence severity" % count)
        return a
    a = _classify_uncached(template, exc_types, exc_message, level_max, http_status, error_code, category_hint)
    if len(_CACHE) >= _CACHE_MAX:
        _CACHE.clear()
    _CACHE[key] = a
    out = Assessment()
    out.severity, out.category, out.confidence, out.basis = a.severity, a.category, a.confidence, a.basis
    out.rationale = list(a.rationale) + ["occurrence count (%d) does not influence severity" % count]
    out.signals = list(a.signals)
    return out


def _classify_uncached(template: str, exc_types: Sequence[str], exc_message: str, level_max: Optional[int],
                       http_status: Optional[int], error_code: Optional[str], category_hint: Optional[str]) -> Assessment:
    a = Assessment()
    text = " ".join(x for x in (template or "", exc_message or "", " ".join(exc_types or []), error_code or "") if x)
    low = text.lower()
    exc_join = " ".join(exc_types or [])

    # --- exception-type evidence (observed) ------------------------------------------
    exc_cat: Optional[str] = None
    if exc_join:
        matched_type = None
        for pat, cat in ((_CRASH_EXC_TYPES, "application_crash"), (_RESOURCE_EXC, "resource_exhaustion"), (_DATA_EXC, "data_integrity"),
                         (_TIMEOUT_EXC, "timeout"), (_AUTH_EXC, "auth"), (_DB_EXC, "dependency_failure"), (_NET_EXC, "network"),
                         (_CONFIG_EXC, "configuration")):
            hit = next((t for t in exc_types if t and pat.search(t)), None)
            if hit is not None:
                exc_cat, matched_type = cat, hit
                if cat == "application_crash" and _RESOURCE_EXC.search(hit):
                    exc_cat = "resource_exhaustion"
                break
        if exc_cat:
            a.rationale.append("exception type %s indicates %s" % (matched_type, exc_cat.replace("_", " ")))

    # --- HTTP status evidence (observed) ------------------------------------------------
    http_cat: Optional[str] = None
    if http_status is not None:
        if http_status in (401, 403):
            http_cat = "auth"
        elif http_status == 408 or http_status == 504:
            http_cat = "timeout"
        elif http_status == 429:
            http_cat = "resource_exhaustion"
        elif http_status in (502, 503):
            http_cat = "availability"
            a.signals.append("dependency_or_upstream_failure")
        elif http_status >= 500:
            http_cat = "availability"
        elif http_status >= 400:
            http_cat = "client_error"
        if http_cat:
            a.rationale.append("HTTP status %d observed -> %s" % (http_status, http_cat.replace("_", " ")))
            if http_status >= 500:
                a.signals.append("failed_requests")

    # --- choose category by precedence ----------------------------------------------------
    precedence = ["application_crash", "resource_exhaustion", "data_integrity", "security", "auth", "timeout",
                  "dependency_failure", "availability", "network", "configuration", "client_error", "performance", "operational"]
    category: Optional[str] = None
    basis = "unknown"
    if category_hint in ("application_crash",):
        category, basis = category_hint, "observed"
        a.rationale.append("parser observed a crash/termination report")
    elif exc_cat:
        category, basis = exc_cat, "observed"
    elif http_cat and http_cat not in ("client_error",):
        category, basis = http_cat, "observed"
    # Message-wording rules: a full scan only when no observed category exists; otherwise only the
    # rules that feed impact signals (performance/security) run.
    matched = _scan_rules(low, None if category is None else ("performance", "security"))
    if category is None:
        for cat in precedence:
            if cat in matched:
                if cat == "dependency_failure" and "network" in matched and not any(
                        k in low for k in ("upstream", "database", " db", "sql", "redis", "kafka", "queue", "broker", "grpc",
                                           "remote server", "downstream", "502", "503", "unavailable", "postgres", "mysql", "mongo")):
                    continue
                category = cat
                basis = "inferred"
                a.rationale.append("message evidence %r -> %s" % (matched[cat][0], cat.replace("_", " ")))
                break
    if category is None and http_cat:
        category, basis = http_cat, "observed"
    if category is None and category_hint:
        category, basis = category_hint, "inferred"
    if category is None:
        category = "unknown"
        if level_max is not None and level_max >= LEVEL_ERROR:
            a.rationale.append("no categorical evidence; producer level indicates a failure of unknown kind")
        elif level_max is not None:
            a.rationale.append("no failure evidence in message or level")
        else:
            a.rationale.append("no level and no categorical evidence")
    a.category = category
    a.basis = basis
    for cat, toks in matched.items():
        if cat != category and cat not in ("operational",):
            a.signals.append("also_matches:" + cat)

    # --- impact signals ----------------------------------------------------------------------
    termination = bool(_TERMINATION.search(low) or (category_hint == "application_crash"))
    if termination:
        a.signals.append("process_termination")
    if _DATA_LOSS.search(low):
        a.signals.append("data_loss_or_corruption")
    if _DISK_OOM.search(low):
        a.signals.append("resource_exhausted")
    if "performance" in matched and re.search(r"retry|retries|backoff|attempt", low):
        a.signals.append("retries")
    if "performance" in matched and re.search(r"slow|latenc|took|degraded|lag", low):
        a.signals.append("degraded_performance")
    if "security" in matched:
        a.signals.append("security_relevant")
    if category in ("availability", "dependency_failure") and level_max is not None and level_max >= LEVEL_ERROR:
        a.signals.append("service_impact_possible")

    # --- severity ------------------------------------------------------------------------------
    sev = {
        "application_crash": "high", "resource_exhaustion": "high", "data_integrity": "high", "security": "high",
        "availability": "high", "dependency_failure": "high", "timeout": "medium", "network": "medium",
        "auth": "low", "configuration": "medium", "client_error": "low", "performance": "low",
        "operational": "info", "unknown": "medium",
    }[category]
    if category == "application_crash" and termination and (level_max is None or level_max >= LEVEL_ERROR):
        sev = "critical"
        a.rationale.append("explicit termination evidence -> critical")
    if category == "resource_exhaustion" and _DISK_OOM.search(low):
        sev = "critical"
        a.rationale.append("out-of-memory / disk-full evidence -> critical")
    if category == "data_integrity":
        if _DATA_LOSS.search(low):
            sev = "critical"
            a.rationale.append("data loss or corruption evidence -> critical")
        elif re.search(r"duplicate key|unique|constraint|foreign key|conflict|stale|optimistic", low):
            sev = "medium"
            a.rationale.append("constraint/concurrency violation without loss evidence -> medium")
    if category == "security" and re.search(r"failed password|invalid user|blocked", low):
        sev = "medium"
        a.rationale.append("authentication noise is common; security relevance noted without inferring an incident")
    if category == "availability" and http_status is not None and http_status >= 500 and level_max is not None and level_max < LEVEL_ERROR:
        sev = "medium"
    if category == "dependency_failure" and level_max is not None and level_max < LEVEL_ERROR:
        sev = "medium"
    if category == "unknown":
        if level_max is None:
            sev = "low"
        elif level_max >= LEVEL_CRITICAL:
            sev = "high"
        elif level_max >= LEVEL_ERROR:
            sev = "medium"
        elif level_max >= LEVEL_WARN:
            sev = "low"
        else:
            sev = "info"
        a.rationale.append("severity from producer level only (%s)" % _level_name(level_max))
    # producer-level caps: an INFO message is not an incident unless termination/data-loss evidence is explicit
    strong = termination or bool(_DATA_LOSS.search(low)) or bool(_DISK_OOM.search(low))
    if level_max is not None and level_max < LEVEL_WARN and not strong:
        if category in ("operational", "unknown"):
            sev = "info"
        else:
            sev = _cap(sev, "low")
            a.rationale.append("producer level is INFO/DEBUG; severity capped at low")
    elif level_max is not None and LEVEL_WARN <= level_max < LEVEL_ERROR and not strong:
        sev = _cap(sev, "medium")
        a.rationale.append("producer level is WARNING; severity capped at medium")
    if level_max is None and not strong and category not in ("application_crash",):
        sev = _cap(sev, "medium")
        a.rationale.append("no producer level available; severity capped at medium")
    if category == "operational" and not strong:
        sev = "info" if (level_max is None or level_max < LEVEL_WARN) else _cap(sev, "low")
    a.severity = sev

    # --- confidence ----------------------------------------------------------------------------
    if basis == "observed":
        conf = 0.85
    elif basis == "inferred":
        conf = 0.6
    else:
        conf = 0.35
    if len([c for c in matched if c not in ("operational", category)]) >= 2:
        conf -= 0.1
        a.rationale.append("multiple categories match; confidence reduced")
    if strong:
        conf = max(conf, 0.9)
    a.confidence = max(0.1, min(0.95, conf))
    return a


def _level_name(num: Optional[int]) -> str:
    if num is None:
        return "none"
    if num >= LEVEL_CRITICAL:
        return "FATAL/CRITICAL"
    if num >= LEVEL_ERROR:
        return "ERROR"
    if num >= LEVEL_WARN:
        return "WARN"
    if num >= LEVEL_INFO:
        return "INFO"
    return "DEBUG/TRACE"


SEVERITY_TO_SARIF = {"critical": "error", "high": "error", "medium": "warning", "low": "note", "info": "none"}
SEVERITY_TO_RANK100 = {"critical": 95.0, "high": 75.0, "medium": 50.0, "low": 25.0, "info": 5.0}
