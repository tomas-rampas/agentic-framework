"""Plain-text layouts and multiline event assembly (the ``text`` parser).

The engine recognises one *layout* per input (chosen on the detection sample or
forced with ``--input-format text:<layout>``), falls back to generic
timestamp/level headers for lines the layout does not match, folds continuation
lines (stack traces, indented payloads) into the current event with bounded
buffering, and delegates exception extraction to :mod:`exceptions`.

Every layout listed in ``LAYOUTS`` is covered by a fixture in tests/log-triage;
the support matrix (docs/log-triage/support-matrix.md) is generated from this
table so a layout cannot be claimed without a regex and a fixture.
"""
from __future__ import annotations

import re
from typing import Any, Dict, Iterator, List, Optional, Tuple

from ..model import Event, level_from_syslog, level_from_text
from .base import BaseParser, Lines, ParseContext, set_ts
from .exceptions import (CONTINUATION_RE, EXCEPTION_START_RE, HEADLINE_EXPECTS_BODY_RE, TERMINATION_RE,
                         is_exception_headline, parse_exception_block)

_TS = (r"(?:\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:\s?(?:Z|[+-]\d{2}:?\d{2}|UTC|GMT))?"
       r"|\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?"
       r"|\d{2}:\d{2}:\d{2}(?:[.,]\d{1,9})?"
       r"|[A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}:\d{2}(?:\.\d+)?"
       r"|\d{1,2}-[A-Z][a-z]{2}-\d{4}(?:::| )\d{2}:\d{2}:\d{2}(?:\.\d+)?(?: UTC)?"
       r"|\d{4}-[A-Z][a-z]{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?"
       r"|[A-Z][a-z]{2,3}\.? \d{1,2}, \d{4} \d{1,2}:\d{2}:\d{2} [AP]M"
       r"|\d{13}|\d{10}(?:\.\d{1,6})?)")
_LEVELS = (r"(?:TRACE|DEBUG|INFO|INFORMATION|NOTICE|WARN|WARNING|ERROR|ERR|SEVERE|FATAL|CRITICAL|CRIT|ALERT|EMERG|EMERGENCY|"
           r"PANIC|VERBOSE|VRB|DBG|INF|WRN|FTL|TRC|FINE|FINER|FINEST|CONFIG|Trace|Debug|Info|Warn|Warning|Error|Fatal|Critical|"
           r"trace|debug|info|notice|warn|warning|error|fatal|critical|alert|emergency|panic|verbose)")


class Layout:
    __slots__ = ("id", "family", "ecosystem", "regex", "weight", "second_line", "msg_from_next", "blank_terminates",
                 "example", "notes", "exc_start_continues", "owns_block")

    def __init__(self, id_: str, family: str, ecosystem: str, pattern: str, example: str, weight: float = 1.0,
                 second_line: Optional[str] = None, msg_from_next: bool = False, blank_terminates: bool = False,
                 notes: str = "", exc_start_continues: bool = True, owns_block: bool = False):
        # exc_start_continues: an exception/crash headline right after a record of this layout belongs to
        # that record (logger.exception(...) style). False for producers that never print exceptions
        # inline (Go std log, Zap/Zerolog console, Rust panics), where a panic is a separate crash event.
        self.exc_start_continues = exc_start_continues
        # owns_block: a record owns every line until the next header of the layout (Rails request blocks:
        # "Started .. Completed <status>" plus the exception dump printed after it).
        self.owns_block = owns_block
        self.id = id_
        self.family = family          # logging library / producer
        self.ecosystem = ecosystem    # language ecosystem
        self.regex = re.compile(pattern)
        self.weight = weight
        self.second_line = re.compile(second_line) if second_line else None
        self.msg_from_next = msg_from_next
        self.blank_terminates = blank_terminates
        self.example = example
        self.notes = notes


LAYOUTS: List[Layout] = [
    # --- .NET -----------------------------------------------------------------
    Layout("serilog-text", "Serilog", "C#/.NET",
           r"^(?:(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} [+-]\d{2}:\d{2}|\d{2}:\d{2}:\d{2}|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+(?:Z|[+-]\d{2}:\d{2})?) )?\[(?P<level>VRB|DBG|INF|WRN|ERR|FTL)\] (?P<msg>.*)$",
           "2026-09-13 12:00:00.123 +02:00 [ERR] Failed to process order",
           weight=1.2, notes="Default file/console output template; time-only [12:00:00 INF] variant has no date"),
    Layout("mel-console", "Microsoft.Extensions.Logging", "C#/.NET",
           r"^(?:(?P<ts>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?)\s+)?(?P<level>trce|dbug|info|warn|fail|crit): (?P<logger>[\w.<>`$+-]+)\[(?P<eventid>\d+)\]\s*$",
           "fail: Acme.Orders.OrderService[0]", weight=1.3, msg_from_next=True,
           notes="Default console formatter: header line, message on the following indented lines"),
    Layout("nlog-default", "NLog", "C#/.NET",
           r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{4})\|(?P<level>[A-Za-z]+)\|(?P<logger>[^|]*)\|(?P<msg>.*)$",
           "2026-09-13 12:00:00.1234|ERROR|Acme.Orders.OrderService|Failed", weight=1.3,
           notes="${longdate}|${level:uppercase=true}|${logger}|${message} default layout"),
    Layout("log4net-default", "log4net", "C#/.NET",
           r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) \[(?P<thread>[^\]]*)\] (?P<level>[A-Z]+)\s+(?P<logger>\S+) - (?P<msg>.*)$",
           "2026-09-13 12:00:00,123 [1] ERROR Acme.Orders.OrderService - Failed", weight=1.1,
           notes="%date [%thread] %-5level %logger - %message (identical to log4j classic)"),
    # --- JVM (Java/Kotlin/Scala) -------------------------------------------
    Layout("jvm-classic", "log4j/log4j2/Logback PatternLayout", "Java/Kotlin/Scala",
           r"^(?P<ts>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[.,]\d{3}(?:Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}[.,]\d{3}) \[(?P<thread>[^\]]*)\] (?P<level>TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\s+(?P<logger>\S+) - (?P<msg>.*)$",
           "2026-09-13 12:00:00.123 [main] ERROR com.acme.OrderService - Failed", weight=1.1,
           notes="%d [%t] %-5level %logger - %msg (Logback/log4j2 defaults use time-only %d{HH:mm:ss.SSS})"),
    Layout("spring-boot", "Spring Boot default console", "Java/Kotlin",
           r"^(?P<ts>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}\.\d{3}(?:Z|[+-]\d{2}:\d{2})?)\s+(?P<level>TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\s+(?P<pid>\d+)\s+---\s+(?:\[(?P<app>[^\]]*)\]\s+)?\[\s*(?P<thread>[^\]]*)\]\s+(?P<logger>\S+)\s*:\s+(?P<msg>.*)$",
           "2026-09-13T12:00:00.123+02:00 ERROR 1234 --- [orders] [nio-8080-exec-1] c.a.o.OrderService : Failed", weight=1.4,
           notes="Spring Boot 2.x/3.x console pattern; application name group is optional"),
    Layout("jul-simple", "java.util.logging SimpleFormatter", "Java",
           r"^(?P<ts>[A-Z][a-z]{2,3}\.? \d{1,2}, \d{4} \d{1,2}:\d{2}:\d{2} [AP]M) (?P<logger>\S+) (?P<func>\S+)\s*$",
           "Sep 13, 2026 12:00:00 PM com.acme.OrderService place\nSEVERE: Failed", weight=1.3,
           second_line=r"^(?P<level>SEVERE|WARNING|INFO|CONFIG|FINE|FINER|FINEST): (?P<msg>.*)$",
           notes="Two-line default SimpleFormatter (US locale date); level and message on the second line"),
    # --- Python ------------------------------------------------------------------
    Layout("python-basic", "logging.basicConfig", "Python",
           r"^(?P<level>DEBUG|INFO|WARNING|ERROR|CRITICAL):(?P<logger>[\w.]+):(?P<msg>.*)$",
           "ERROR:root:Failed to charge", weight=1.2, notes="%(levelname)s:%(name)s:%(message)s"),
    Layout("python-asctime", "logging (asctime pattern)", "Python",
           r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}) - (?P<logger>[\w.]+) - (?P<level>DEBUG|INFO|WARNING|ERROR|CRITICAL) - (?P<msg>.*)$",
           "2026-09-13 12:00:00,123 - billing.worker - ERROR - Failed", weight=1.3,
           notes="%(asctime)s - %(name)s - %(levelname)s - %(message)s"),
    Layout("loguru-default", "Loguru", "Python",
           r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) \| (?P<level>[A-Z]+)\s*\| (?P<logger>[\w.<>]+):(?P<func>\w+):(?P<line>\d+) - (?P<msg>.*)$",
           "2026-09-13 12:00:00.123 | ERROR    | billing.worker:run:30 - Failed", weight=1.4,
           notes="Default sink format; SUCCESS level maps to info"),
    Layout("structlog-console", "structlog ConsoleRenderer", "Python",
           r"^(?P<ts>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?) \[(?P<level>\w+)\s*\] (?P<msg>.*)$",
           "2026-09-13T12:00:00.123456Z [error    ] Failed to charge    order_id=42", weight=1.2,
           notes="Trailing key=value pairs are extracted as attributes"),
    # --- JavaScript / TypeScript ---------------------------------------------
    Layout("winston-simple", "Winston (simple/printf)", "JavaScript/TypeScript",
           r"^(?:(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z) )?\[?(?P<level>error|warn|info|http|verbose|debug|silly)\]?: (?P<msg>.*)$",
           "2026-09-13T12:00:00.123Z error: Failed to charge", weight=1.1,
           notes="format.simple() and the common timestamp+printf `${timestamp} ${level}: ${message}`"),
    # --- Go ------------------------------------------------------------------------
    Layout("go-std", "log (standard library)", "Go",
           r"^(?:(?P<app>\[[^\]]+\]|\w+: )\s?)?(?P<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}(?:\.\d{6})?) (?:(?P<file>[\w./-]+\.go):(?P<line>\d+): )?(?P<msg>.*)$",
           "2026/09/13 12:00:00 main.go:42: dial tcp: connection refused", weight=1.2, exc_start_continues=False,
           notes="LstdFlags with optional Lmicroseconds/Lshortfile; no level field (inferred from message)"),
    Layout("zap-console", "Zap console encoder", "Go",
           r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(?:Z|[+-]\d{4}))\t(?P<level>[A-Z]+)\t(?:(?P<logger>[\w./-]+\.go:\d+)\t)?(?P<msg>[^\t]*)(?:\t(?P<kv>\{.*\}))?$",
           "2026-09-13T12:00:00.123+0200\tERROR\tworker/main.go:42\tcharge failed\t{\"order\": 42}", weight=1.4,
           exc_start_continues=False, notes="Tab-separated development encoder; trailing JSON fields parsed as attributes"),
    Layout("zerolog-console", "Zerolog ConsoleWriter", "Go",
           r"^(?P<ts>\d{1,2}:\d{2}(?:AM|PM)|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) (?P<level>TRC|DBG|INF|WRN|ERR|FTL|PNC|\?\?\?) (?P<msg>.*)$",
           "12:00PM ERR charge failed error=\"timeout\" order=42", weight=1.3, exc_start_continues=False,
           notes="Default ConsoleWriter (time-only 3:04PM stamp); key=value tail extracted"),
    # --- Rust -----------------------------------------------------------------------
    Layout("env-logger", "env_logger", "Rust",
           r"^\[(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z) (?P<level>TRACE|DEBUG|INFO|WARN|ERROR)\s+(?P<logger>[\w:]+)\] (?P<msg>.*)$",
           "[2026-09-13T12:00:00Z ERROR myapp::worker] charge failed", weight=1.4, exc_start_continues=False,
           notes="Default env_logger format (RUST_LOG); panics are separate crash events"),
    Layout("tracing-fmt", "tracing-subscriber fmt", "Rust",
           r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z)\s+(?P<level>TRACE|DEBUG|INFO|WARN|ERROR)\s+(?:(?P<span>[\w:]+(?:\{[^}]*\})?(?::[\w:]+\{[^}]*\})*):\s+)?(?P<logger>[\w:]+):\s+(?P<msg>.*)$",
           "2026-09-13T12:00:00.123456Z ERROR request{id=7}: myapp::worker: charge failed order=42", weight=1.4,
           exc_start_continues=False, notes="Default (full) fmt layer; spans and key=value fields captured; panics are separate crash events"),
    # --- C/C++ ----------------------------------------------------------------------
    Layout("spdlog-default", "spdlog", "C/C++",
           r"^\[(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\] (?:\[(?P<logger>[^\]]*)\] )?\[(?P<level>trace|debug|info|warning|error|critical|off)\] (?P<msg>.*)$",
           "[2026-09-13 12:00:00.123] [worker] [error] queue overflow", weight=1.3,
           notes="Default pattern [%Y-%m-%d %H:%M:%S.%e] [%n] [%l] %v"),
    Layout("boost-log", "Boost.Log (common [TimeStamp] [Severity] format)", "C/C++",
           r"^\[(?P<ts>\d{4}-[A-Z][a-z]{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6})\](?: \[(?P<thread>0x[0-9a-f]+)\])? \[(?P<level>\w+)\] (?P<msg>.*)$",
           "[2026-Sep-13 12:00:00.123456] [error] queue overflow", weight=1.3,
           notes="Boost.Log has no fixed default; this is the documented `[%TimeStamp%] [%Severity%] %Message%` form"),
    Layout("glog", "glog", "C/C++",
           r"^(?P<level>[IWEF])(?P<ts>\d{4,8} \d{2}:\d{2}:\d{2}\.\d{6})\s+(?P<thread>\d+) (?P<file>[\w./-]+):(?P<line>\d+)\] (?P<msg>.*)$",
           "E0913 12:00:00.123456 4242 worker.cc:42] queue overflow", weight=1.4,
           notes="Ldate/time without year (year inferred) or with year (glog >= 0.6 formats)"),
    # --- PHP --------------------------------------------------------------------------
    Layout("monolog-line", "Monolog LineFormatter", "PHP",
           r"^\[(?P<ts>\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[+-]\d{2}:\d{2})?)\] (?P<logger>[\w.-]+)\.(?P<level>DEBUG|INFO|NOTICE|WARNING|ERROR|CRITICAL|ALERT|EMERGENCY): (?P<msg>.*)$",
           "[2026-09-13T12:00:00.123456+00:00] app.ERROR: Payment failed {\"order\":42} []", weight=1.4,
           notes="[%datetime%] %channel%.%level_name%: %message% %context% %extra% (Laravel/Symfony default)"),
    Layout("php-error-log", "PHP error_log", "PHP",
           r"^\[(?P<ts>\d{2}-[A-Z][a-z]{2}-\d{4} \d{2}:\d{2}:\d{2}(?: [A-Za-z/_]+)?)\] (?P<msg>PHP (?P<level>Fatal error|Warning|Notice|Parse error|Deprecated|Error):\s+.*)$",
           "[13-Sep-2026 12:00:00 UTC] PHP Fatal error:  Uncaught RuntimeException: gateway down in /app/x.php:12", weight=1.4,
           notes="log_errors output; `Stack trace:` / `#0 ...` continuation lines folded in"),
    # --- Ruby -----------------------------------------------------------------------
    Layout("ruby-logger", "Logger::Formatter", "Ruby",
           r"^(?P<sev>[DIWEFAU]), \[(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}) #(?P<pid>\d+)\]\s+(?P<level>[A-Z]+) -- (?P<logger>[^:]*): (?P<msg>.*)$",
           "E, [2026-09-13T12:00:00.123456 #1234] ERROR -- billing: charge failed", weight=1.4,
           notes="Default Ruby Logger formatter; program name captured as logger"),
    Layout("rails-request", "Rails development/production request log", "Ruby",
           r"^(?:\[(?P<req>[0-9a-f-]{36})\] )?Started (?P<method>[A-Z]+) \"(?P<path>[^\"]*)\" for (?P<host>\S+) at (?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})\s*$",
           "Started GET \"/orders/42\" for 127.0.0.1 at 2026-09-13 12:00:00 +0000", weight=1.4, owns_block=True,
           notes="One request block per event (Started .. Completed <status>, plus the exception dump that follows); status and exception extracted"),
    # --- Swift / Objective-C ---------------------------------------------------
    Layout("apple-log-show", "Apple unified logging (`log show` default style)", "Swift/Objective-C",
           r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}[+-]\d{4})\s+0x[0-9a-f]+\s+(?P<level>Default|Info|Debug|Error|Fault)\s+0x[0-9a-f]+\s+(?P<pid>\d+)\s+\d+\s+(?P<proc>[^:]+?):\s+(?P<msg>.*)$",
           "2026-09-13 12:00:00.123456+0200 0x1a2b Error 0x0 1234 0 MyApp: (Foundation) [com.acme:net] request failed", weight=1.4,
           notes="`log show --style default` export; `--style syslog` exports are handled by the syslog parser"),
    # --- Erlang / Elixir ---------------------------------------------------------
    Layout("elixir-logger", "Elixir Logger console", "Erlang/Elixir",
           r"^(?P<ts>(?:\d{4}-\d{2}-\d{2} )?\d{2}:\d{2}:\d{2}\.\d{3})(?: (?P<kv>[\w.]+=\S+(?: [\w.]+=\S+)*))? \[(?P<level>debug|info|notice|warning|warn|error|critical|alert|emergency)\]\s+(?P<msg>.*)$",
           "12:00:00.123 [error] GenServer MyApp.Worker terminating", weight=1.3,
           notes="Default `$time $metadata[$level] $message` (time-only unless $date is configured)"),
    Layout("erlang-report", "Erlang OTP error_logger / logger reports", "Erlang/Elixir",
           r"^=(?P<level>ERROR|CRASH|SUPERVISOR|PROGRESS|INFO|WARNING) REPORT==== (?P<ts>\d{1,2}-[A-Z][a-z]{2}-\d{4}::\d{2}:\d{2}:\d{2}(?:\.\d+)?) ===\s*$",
           "=CRASH REPORT==== 13-Sep-2026::12:00:00.123456 ===", weight=1.5,
           notes="Legacy report headers; the report body is the event message/exception"),
    Layout("erlang-logger", "Erlang logger default formatter", "Erlang/Elixir",
           r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}[+-]\d{2}:\d{2}) (?P<level>debug|info|notice|warning|error|critical|alert|emergency): (?P<msg>.*)$",
           "2026-09-13T12:00:00.123456+02:00 error: Generic server my_server terminating", weight=1.3,
           notes="OTP 21+ logger_formatter default template"),
    # --- PowerShell --------------------------------------------------------------
    Layout("ps-transcript", "PowerShell Start-Transcript", "PowerShell",
           r"^(?:(?P<banner>\*{20,})|PS (?P<cwd>[^>]*)> ?(?P<msg>.*)|(?P<meta>Windows PowerShell transcript (?:start|end)|Start time: \d{14}|End time: \d{14}|Transcript started, output file is .*|Username: .*|RunAs User: .*|Machine: .*|Host Application: .*|Process ID: \d+|PSVersion: .*|Configuration Name: .*))$",
           "PS C:\\> Get-Item C:\\nope", weight=1.5,
           notes="Prompt lines start events (command + its output); error records inside output are parsed"),
    Layout("ps-error-records", "PowerShell error records (ConciseView / NormalView / Format-List)", "PowerShell",
           r"^(?:Exception\s*:\s+(?P<exc>.*)|(?P<cmd>[A-Z][a-z]+(?:-[A-Z][A-Za-z]+)+) ?: (?P<msg>.+))$",
           "Get-Item : Cannot find path 'C:\\nope' because it does not exist.", weight=1.2,
           notes="Exported $Error text; `At line:`, `+ CategoryInfo`, `+ FullyQualifiedErrorId` folded in"),
    # --- syslog ----------------------------------------------------------------------
    Layout("syslog-rfc5424", "syslog RFC 5424", "syslog",
           r"^(?:<(?P<pri>\d{1,3})>)?1 (?P<ts>-|\d{4}-\d{2}-\d{2}T[\d:.]+(?:Z|[+-]\d{2}:\d{2})) (?P<host>\S+) (?P<app>\S+) (?P<pid>\S+) (?P<msgid>\S+) (?P<sd>-|(?:\[[^\]]*\])+)\s?(?P<msg>.*)$",
           "<165>1 2026-09-13T12:00:00.123Z host01 orders 1234 ID47 [exampleSDID@32473 iut=\"3\"] charge failed", weight=1.6,
           notes="PRI decoded to facility/severity; STRUCTURED-DATA parameters become attributes"),
    Layout("syslog-rfc3164", "syslog RFC 3164 (BSD) / rsyslog RFC 3339 variant / `log show --style syslog`", "syslog",
           r"^(?:<(?P<pri>\d{1,3})>)?(?P<ts>[A-Z][a-z]{2}\s+\d{1,2} \d{2}:\d{2}:\d{2}(?:\.\d+)?|\d{4}-\d{2}-\d{2}T[\d:.]+(?:Z|[+-]\d{2}:?\d{2})|\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}[+-]\d{4})\s+(?!(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|CRITICAL|PANIC)\b)(?P<host>[A-Za-z0-9._-]+)\s+(?P<tag>[A-Za-z0-9._-]+)(?:\[(?P<pid>\d+)\])?:\s?(?P<msg>.*)$",
           "Sep 13 12:00:00 host01 orders[1234]: charge failed", weight=1.3,
           notes="No year in the BSD form (inferred); tag becomes the service identity"),
    # --- web servers ---------------------------------------------------------------
    Layout("apache-nginx-access", "Apache/Nginx Common and Combined Log Format", "web-server",
           r"^(?P<client>\S+) (?P<ident>\S+) (?P<user>\S+) \[(?P<ts>[^\]]+)\] \"(?P<req>[^\"]*)\" (?P<status>\d{3}) (?P<bytes>\S+)(?: \"(?P<referer>[^\"]*)\" \"(?P<ua>[^\"]*)\")?(?P<extra>.*)$",
           "10.0.0.1 - - [13/Sep/2026:12:00:00 +0000] \"POST /api/orders HTTP/1.1\" 502 512 \"-\" \"curl/8.0\"", weight=1.6,
           notes="Level derived from status (5xx error, 4xx warning); request split into method/path"),
    Layout("nginx-error", "Nginx error log", "web-server",
           r"^(?P<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}) \[(?P<level>\w+)\] (?P<pid>\d+)#(?P<tid>\d+): (?:\*(?P<conn>\d+) )?(?P<msg>.*)$",
           "2026/09/13 12:00:00 [error] 1234#1234: *42 connect() failed (111: Connection refused) while connecting to upstream, client: 10.0.0.1, server: api, request: \"GET /x HTTP/1.1\", upstream: \"http://10.0.0.5:8080/x\", host: \"api\"", weight=1.6,
           notes="client/server/request/upstream/host fields extracted as attributes"),
    Layout("apache-error", "Apache httpd error log (2.4 and 2.2 formats)", "web-server",
           r"^\[(?P<ts>[A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}:\d{2}(?:\.\d+)? \d{4})\] \[(?:(?P<module>[\w-]+):)?(?P<level>\w+)\](?: \[pid (?P<pid>\d+)(?::tid (?P<tid>\d+))?\])?(?: \[client (?P<client>[^\]]+)\])? (?P<msg>.*)$",
           "[Sun Sep 13 12:00:00.123456 2026] [proxy:error] [pid 1234:tid 5678] [client 10.0.0.1:5555] AH00898: Error reading from remote server", weight=1.6,
           notes="Module and AHxxxxx codes retained; PHP messages inside are parsed as exceptions"),
    # --- Cloud runtimes ---------------------------------------------------------------
    Layout("aws-lambda-node", "AWS Lambda managed runtime console (Node.js / .NET)", "AWS Lambda",
           r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)\t(?P<req>[0-9a-fA-F-]{8,36}|undefined)\t(?P<level>TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\t(?P<msg>.*)$",
           "2026-09-13T12:00:00.456Z\t8f1c2c3d-1111-2222-3333-444455556666\tERROR\tInvoke Error\t{\"errorType\":\"Error\"}", weight=1.5,
           notes="Tab-separated `timestamp\\trequestId\\tlevel\\tmessage` lines as delivered to CloudWatch; START/END/REPORT lines are headerless events"),
    Layout("aws-lambda-python", "AWS Lambda managed runtime console (Python)", "AWS Lambda",
           r"^\[(?P<level>DEBUG|INFO|WARNING|ERROR|CRITICAL)\]\t(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)\t(?P<req>[0-9a-fA-F-]{8,36})\t(?P<msg>.*)$",
           "[ERROR]\t2026-09-13T12:00:00.456Z\t8f1c2c3d-1111-2222-3333-444455556666\tcharge failed", weight=1.5,
           notes="`[LEVEL]\\ttimestamp\\trequestId\\tmessage` lines; tracebacks printed by the runtime follow as continuation"),
    # --- generic fallbacks ------------------------------------------------------
    Layout("generic-ts", "generic timestamp-first line", "any",
           r"^\[?(?P<ts>" + _TS + r")\]?\s*[|:-]?\s*(?:\[(?P<thread>[^\]\s]{1,40})\]\s*)?(?:\[?(?P<level>" + _LEVELS + r")\]?\s*[:|-]?\s+)?(?P<msg>.*)$",
           "2026-09-13 12:00:00 ERROR something happened", weight=0.6,
           notes="Fallback: recognised timestamp at line start, optional [thread] and level token"),
    Layout("generic-level", "generic level-first line", "any",
           r"^\[?(?P<level>" + _LEVELS + r")\]?\s*[:|-]?\s+(?P<msg>.*)$",
           "ERROR: something happened", weight=0.4,
           notes="Fallback: level token at line start, no timestamp"),
]

_LAYOUT_BY_ID = {l.id: l for l in LAYOUTS}
_GENERIC_TS = _LAYOUT_BY_ID["generic-ts"]
_GENERIC_LEVEL = _LAYOUT_BY_ID["generic-level"]
_SPECIFIC = [l for l in LAYOUTS if not l.id.startswith("generic-")]

_KV_RE = re.compile(r"(?:(?<=\s)|^)([A-Za-z_][\w.-]*)=(\"(?:[^\"\\]|\\.)*\"|'[^']*'|\[[^\]]*\]|\S+)")
_HTTP_STATUS_RE = re.compile(
    r"(?:\bstatus(?:[_ ]?code)?\s*[:=]?\s*|\bHTTP/\d(?:\.\d)?\"?\s+|\bCompleted\s+|\bresponded\s+(?:with\s+)?|"
    r"\breturned\s+(?:status\s+)?|\bstatusCode[=:]\s*|\bresponse(?:[_ ]?code)?\s*[:=]\s*|\bcode\s*[:=]\s*|\bsc-status=|\bhttp\.status(?:_code)?=)"
    r"\(?([1-5]\d{2})\b", re.IGNORECASE)
_ERROR_CODE_RE = re.compile(
    r"\b(ORA-\d{5}|SQLSTATE\[?[0-9A-Z]{5}\]?|0x8[0-9A-Fa-f]{7}|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENOTFOUND|EPIPE|EACCES|"
    r"EADDRINUSE|ENOENT|EEXIST|EMFILE|ENOMEM|ENOSPC|EHOSTUNREACH|ENETUNREACH|EAI_AGAIN|EPERM|EBADF|EINVAL|EIO|EAGAIN|"
    r"ECONNABORTED|ENOBUFS|EISDIR|ENOTDIR|EROFS|ELOOP|ENAMETOOLONG|ERR_[A-Z_]{3,}|WSAE[A-Z]{3,}|AH\d{5}|MSB\d{4}|CS\d{4}|"
    r"NU\d{4}|TS\d{4}|E\d{4}|[A-Z]{2,5}-\d{3,6}|HRESULT:? ?0x[0-9A-Fa-f]{8})\b")
_LEVEL_HINT_RE = re.compile(r"\b(panic|fatal|segfault|segmentation fault|unhandled exception|traceback|exception|error|failed|failure|warn(?:ing)?|timeout|timed out|refused|denied)\b", re.IGNORECASE)
_PS_PROPERTY_RE = re.compile(r"^(?:TargetObject|CategoryInfo|FullyQualifiedErrorId|ErrorDetails|InvocationInfo|ScriptStackTrace|PipelineIterationInfo|PSMessageDetails|Message|Data|InnerException|StackTrace|Source|HResult|HelpLink|TargetSite|Response|Status|ErrorRecord)\s*:")
_SD_RE = re.compile(r"\[([^\s\]]+)((?:\s+[^\s=\]]+=\"(?:[^\"\\]|\\.)*\")*)\]")
_SD_PARAM_RE = re.compile(r"([^\s=]+)=\"((?:[^\"\\]|\\.)*)\"")
_EXC_MARKER_MSG = re.compile(r"^(?:Traceback \(most recent call last\):|stack backtrace:|goroutine \d+ \[)")
_ERL_FIELD = re.compile(r"^\s*(initial call|exception (?:error|exit|throw)|supervisor|reason|errorContext|registered_name|offender):\s*(.*)$")
_ERL_TERMINATING = re.compile(r"^\*\* (Generic server|State machine|gen_event handler) (\S+) terminating")


def _erlang_report_message(kind: str, cont: List[str]) -> str:
    fields: Dict[str, str] = {}
    for c in cont[:40]:
        m = _ERL_TERMINATING.match(c.strip())
        if m:
            fields.setdefault("terminating", "%s %s terminating" % (m.group(1), m.group(2)))
            continue
        m = _ERL_FIELD.match(c)
        if m:
            key = m.group(1)
            if key.startswith("exception"):
                fields.setdefault("exception", key + ": " + m.group(2).strip())
            else:
                fields.setdefault(key, m.group(2).strip())
    parts = [kind + " REPORT"]
    if fields.get("terminating"):
        parts.append(fields["terminating"])
    if fields.get("initial call"):
        parts.append("initial call " + fields["initial call"])
    if fields.get("supervisor"):
        parts.append("supervisor " + fields["supervisor"])
    if fields.get("errorContext"):
        parts.append(fields["errorContext"])
    if fields.get("exception"):
        parts.append(fields["exception"])
    elif fields.get("reason"):
        parts.append("reason: " + fields["reason"])
    return ": ".join(parts[:2]) + ("; " + "; ".join(parts[2:]) if len(parts) > 2 else "")


_RAILS_COMPLETED = re.compile(r"^Completed (?P<status>\d{3}) [^\n]*? in (?P<dur>\d+)ms")
_RAILS_PROCESSING = re.compile(r"^Processing by (?P<ctrl>[\w:]+#\w+) as (?P<fmt>\w+)")


def level_hint_from_message(msg: str) -> Optional[str]:
    m = _LEVEL_HINT_RE.search(msg[:300])
    if not m:
        return None
    w = m.group(1).lower()
    if w in ("panic", "fatal", "segfault", "segmentation fault", "unhandled exception"):
        return "fatal"
    if w in ("traceback", "exception", "error", "failed", "failure", "refused", "denied"):
        return "error"
    if w in ("timeout", "timed out"):
        return "warning"
    return "warning"


class _Record:
    __slots__ = ("line", "offset", "line_end", "fields", "cont", "cont_bytes", "dropped", "layout", "base",
                 "truncated", "awaiting_second", "py_tb", "exc_head")

    def __init__(self, line: int, offset: int, fields: Dict[str, Any], layout: Optional[Layout], base: Optional[dict],
                 truncated: bool):
        self.line = line
        self.offset = offset
        self.line_end = line
        self.fields = fields
        self.cont: List[str] = []
        self.cont_bytes = 0
        self.dropped = 0
        self.layout = layout
        self.base = base
        self.truncated = truncated
        self.awaiting_second = False
        self.py_tb = False
        self.exc_head = False      # headerless record that starts with an exception/crash headline


class TextEngine:
    """Stateful line -> event assembler. Reusable by wrapper parsers for nested text.

    ``layouts`` is an ordered list (usually one entry; up to three for mixed files).
    """

    def __init__(self, ctx: ParseContext, layouts: Optional[List[Layout]], parser_name: str = "text",
                 allow_generic: bool = True):
        self.ctx = ctx
        self.layouts: List[Layout] = list(layouts or [])
        self.parser_name = parser_name
        self.allow_generic = allow_generic
        self.current: Optional[_Record] = None
        self.limits = ctx.limits
        self.events_out: List[Event] = []
        self.headerless = 0
        self.headerless_exc = 0     # headerless records that are recognised crash/exception blocks
        self.absorbed_unknown = 0   # non-continuation lines folded into a layout record as free text
        self.records = 0

    # -- public ---------------------------------------------------------------
    def feed(self, line_no: int, offset: int, text: str, truncated: bool = False,
             base: Optional[dict] = None) -> List[Event]:
        out = self.events_out
        out.clear()
        cur = self.current
        stripped = text.strip()

        if cur is not None and cur.awaiting_second and cur.layout is not None and cur.layout.second_line is not None:
            m = cur.layout.second_line.match(text)
            if m:
                cur.fields.update({k: v for k, v in m.groupdict().items() if v is not None})
                cur.awaiting_second = False
                cur.line_end = line_no
                return out
            cur.awaiting_second = False

        if not stripped:
            if cur is not None and cur.layout is not None and cur.layout.blank_terminates:
                self._finish(out)
            elif cur is not None:
                cur.line_end = line_no
            return out

        for layout in self.layouts:
            m = layout.regex.match(text)
            if m is not None:
                self._finish(out)
                fields = {k: v for k, v in m.groupdict().items() if v is not None}
                self.current = _Record(line_no, offset, fields, layout, base, truncated)
                if layout.second_line is not None:
                    self.current.awaiting_second = True
                if layout.id == "ps-transcript" and (fields.get("banner") or fields.get("meta")):
                    self.current = None  # transcript metadata lines are not events
                return out

        if text[:1] == "{" and stripped.endswith("}") and len(stripped) > 2 and self.layouts:
            # a complete JSON object embedded in a text log: its own record (normalized by the structured mapper)
            self._finish(out)
            self.current = _Record(line_no, offset, {"msg": text, "json": True}, None, base, truncated)
            return out
        exc_start = EXCEPTION_START_RE.match(text) is not None
        is_cont = (CONTINUATION_RE.match(text) is not None or _PS_PROPERTY_RE.match(text) is not None) and not exc_start
        # a headerless Rust panic headline whose message is printed on the following line
        expects_body = (cur is not None and cur.layout is None and cur.exc_head and not cur.cont
                        and HEADLINE_EXPECTS_BODY_RE.match(cur.fields.get("msg", "")) is not None)
        in_block = cur is not None and cur.layout is not None and cur.layout.owns_block
        if cur is not None and cur.layout is None and cur.exc_head and TERMINATION_RE.match(stripped):
            # "Aborted (core dumped)" right after an assertion or sanitizer report: its outcome
            self._append(cur, text, line_no)
            return out
        if cur is not None:
            if exc_start:
                # A headline closing a Python traceback ("ValueError: x" after File frames) continues the
                # record. A layout-owned record keeps an exception headline that immediately follows its
                # header or its frames (logger.exception style), unless the layout never prints exceptions
                # inline (Go std log: a panic is its own crash event). A block-owning layout keeps every
                # headline until its next header. Otherwise a headline starts a new record (two
                # consecutive Node stack traces stay separate).
                last_cont = cur.cont[-1] if cur.cont else None
                if cur.py_tb and last_cont is not None and last_cont[:1].isspace():
                    self._append(cur, text, line_no)
                    return out
                if in_block or expects_body or (cur.layout is not None and cur.layout.exc_start_continues and
                                                (last_cont is None or last_cont[:1].isspace() or CONTINUATION_RE.match(last_cont))):
                    self._append(cur, text, line_no)
                    return out
            elif is_cont:
                self._append(cur, text, line_no)
                return out
        if self.allow_generic and not is_cont and not exc_start and not in_block:
            g = _GENERIC_TS.regex.match(text)
            glayout = _GENERIC_TS
            if g is None:
                g = _GENERIC_LEVEL.regex.match(text)
                glayout = _GENERIC_LEVEL
            if g is not None:
                self._finish(out)
                fields = {k: v for k, v in g.groupdict().items() if v is not None}
                self.current = _Record(line_no, offset, fields, glayout, base, truncated)
                return out
        if cur is not None and not exc_start:
            if cur.layout is not None or is_cont or text[:1].isspace() or expects_body:
                # known layout, unknown line: part of the previous multiline message
                if not (is_cont or text[:1].isspace() or expects_body):
                    self.absorbed_unknown += 1
                self._append(cur, text, line_no)
                return out
        # headerless record
        self._finish(out)
        self.headerless += 1
        if exc_start:
            self.headerless_exc += 1
        fields = {"msg": text, "headerless": True}
        self.current = _Record(line_no, offset, fields, None, base, truncated)
        self.current.exc_head = exc_start
        if text.startswith("Traceback (most recent call last)"):
            self.current.py_tb = True
        return out

    def flush(self) -> List[Event]:
        out = self.events_out
        out.clear()
        self._finish(out)
        return list(out)

    # -- internals ---------------------------------------------------------------
    def _append(self, rec: _Record, text: str, line_no: int) -> None:
        rec.line_end = line_no
        if not rec.py_tb and (text.startswith("Traceback (most recent call last)") or text.startswith("The above exception")
                              or text.startswith("During handling of the above")):
            rec.py_tb = True
        n = len(text)
        if len(rec.cont) >= self.limits.max_multiline_lines or rec.cont_bytes + n > self.limits.max_record_bytes:
            rec.dropped += 1
            return
        rec.cont.append(text)
        rec.cont_bytes += n

    def _finish(self, out: List[Event]) -> None:
        rec = self.current
        if rec is None:
            return
        self.current = None
        self.records += 1
        ctx = self.ctx
        f = rec.fields
        layout = rec.layout
        if f.get("json"):
            import json as _json
            try:
                obj = _json.loads(f["msg"])
            except ValueError:
                obj = None
            if isinstance(obj, dict):
                from .structured import StructuredParser
                mapper = StructuredParser(self.parser_name)
                ev = mapper._record_event(obj, ctx, rec.line, rec.offset, None, None, base_meta=rec.base)
                if ev is not None:
                    ev.parser = self.parser_name
                    ev.layout = "json-in-text:" + (ev.layout or "generic-json")
                    if rec.cont:
                        ev.raw_excerpt = "\n".join(rec.cont)[: self.limits.max_exception_chars]
                    out.append(ev)
                    return
        ev = ctx.new_event(self.parser_name, rec.line, rec.offset)
        ev.line_end = rec.line_end
        ev.layout = layout.id if layout else "headerless"
        base = rec.base or {}
        # timestamp ------------------------------------------------------------
        ts_text = f.get("ts")
        if ts_text is not None:
            set_ts(ev, ctx, ts_text)
        if ev.ts is None and base.get("ts") is not None:
            ev.ts = base["ts"]
            ev.ts_flags = tuple(base.get("ts_flags", ())) + ("from_envelope",)
        elif ev.ts is None and ts_text is None and layout is not None and layout.id != "generic-level":
            ev.diagnostics.append("no_timestamp")
        # level ----------------------------------------------------------------------
        level = f.get("level")
        if level is None and f.get("sev"):
            level = f["sev"]
        if level is not None:
            ev.set_level(level.strip("[]: "))
        if ev.level_num is None and base.get("level") is not None:
            ev.set_level(base["level"], base.get("level_num"))
        # identity -------------------------------------------------------------------
        ev.logger = f.get("logger") or f.get("logger2")
        ev.thread = f.get("thread")
        ev.app = f.get("app")
        ev.host = f.get("host")
        ev.process = f.get("proc") or f.get("pid")
        if f.get("req") and layout is not None and layout.id not in ("apache-nginx-access",):
            ev.request_id = f["req"]
        if base:
            for key in ("service", "host", "app", "env", "process", "trace_id", "span_id", "request_id"):
                if base.get(key) and getattr(ev, key) is None:
                    setattr(ev, key, base[key])
            for k, v in (base.get("attrs") or {}).items():
                ev.add_attr(k, v, self.limits)
        # message --------------------------------------------------------------------
        msg = f.get("msg")
        cont = rec.cont
        if layout is not None and layout.msg_from_next:
            if cont:
                msg = cont[0].strip()
                cont = cont[1:]
            else:
                msg = ""
        if layout is not None and layout.id == "jul-simple" and msg is None:
            msg = ""
        if layout is not None and layout.id == "erlang-report":
            kind = f.get("level", "")
            ev.level_text = kind
            ev.level_num = {"ERROR": 17, "CRASH": 17, "SUPERVISOR": 17, "WARNING": 13}.get(kind, 9)
            msg = _erlang_report_message(kind, cont)
            ev.category_hint = "application_crash" if kind in ("CRASH", "SUPERVISOR") else None
        if layout is not None and layout.ecosystem == "syslog":
            pri = f.get("pri")
            if pri is not None:
                sev = int(pri) % 8
                num, text = level_from_syslog(sev)
                ev.set_level(text, num)
                ev.add_attr("syslog.facility", int(pri) // 8, self.limits)
            tag = f.get("tag") or f.get("app")
            if tag and tag != "-":
                ev.service = tag
            if f.get("msgid") and f["msgid"] != "-":
                ev.add_attr("syslog.msgid", f["msgid"], self.limits)
            sd = f.get("sd")
            if sd and sd != "-":
                for sd_id, params in _SD_RE.findall(sd):
                    for k, v in _SD_PARAM_RE.findall(params):
                        ev.add_attr("%s.%s" % (sd_id.split("@")[0], k), v, self.limits)
        if layout is not None and layout.id == "apache-nginx-access":
            status = int(f["status"])
            req = f.get("req") or ""
            parts = req.split(" ")
            method = parts[0] if parts and parts[0].isalpha() else None
            path = parts[1] if len(parts) > 1 else req
            ev.http_status = status
            ev.http_method = method
            ev.http_path = path.split("?", 1)[0][:300]
            ev.host = None
            ev.add_attr("client_ip", f.get("client"), self.limits)
            if f.get("bytes") and f["bytes"].isdigit():
                ev.add_attr("bytes", int(f["bytes"]), self.limits)
            if f.get("ua"):
                ev.add_attr("user_agent", f["ua"], self.limits)
            msg = "%s %s -> %d" % (method or "?", ev.http_path, status)
            ev.set_level("error" if status >= 500 else "warning" if status >= 400 else "info")
            if status >= 500:
                ev.category_hint = "availability"
        if layout is not None and layout.id == "nginx-error":
            for key in ("client", "server", "request", "upstream", "host", "referrer"):
                m2 = re.search(r"(?:^|, )%s: \"?([^\",]+)\"?" % key, msg or "")
                if m2:
                    ev.add_attr("nginx." + key, m2.group(1), self.limits)
            rm = re.search(r'request: "(?P<m>[A-Z]+) (?P<p>\S+)', msg or "")
            if rm:
                ev.http_method = rm.group("m")
                ev.http_path = rm.group("p").split("?", 1)[0][:300]
        if layout is not None and layout.id == "apache-error":
            if f.get("module"):
                ev.logger = f["module"]
            if f.get("client"):
                ev.add_attr("client_ip", f["client"], self.limits)
        if layout is not None and layout.id == "nlog-default" and msg and "|" in msg:
            # ${message}|${exception:format=tostring}: the exception headline rides in the message field
            head_part, tail_part = msg.rsplit("|", 1)
            if is_exception_headline(tail_part.strip()):
                msg = head_part.rstrip()
                cont = [tail_part.strip()] + list(cont)
        if layout is not None and layout.id == "ps-error-records":
            msg = f.get("msg") or (("Exception: " + f["exc"]) if f.get("exc") else "")
        if layout is not None and layout.id == "rails-request":
            status = None
            for c in cont:
                mm = _RAILS_COMPLETED.match(c.strip())
                if mm:
                    status = int(mm.group("status"))
                    ev.add_attr("duration_ms", int(mm.group("dur")), self.limits)
                pm = _RAILS_PROCESSING.match(c.strip())
                if pm:
                    ev.add_attr("controller", pm.group("ctrl"), self.limits)
            ev.http_method = f.get("method")
            ev.http_path = f.get("path")
            ev.http_status = status
            msg = "%s %s -> %s" % (f.get("method"), f.get("path"), status if status else "no response logged")
            if f.get("req"):
                ev.request_id = f["req"]
            if status is not None:
                ev.set_level("error" if status >= 500 else "warning" if status >= 400 else "info")
        if msg is None:
            msg = ""
        msg = msg.rstrip()
        if f.get("kv"):
            for k, v in _KV_RE.findall(f["kv"]):
                ev.add_attr(k, v.strip("\"'"), self.limits)
        # key=value tail (structlog console, tracing, zerolog, slog-ish text)
        if "=" in msg:
            tail = msg[-600:]
            pairs = _KV_RE.findall(tail)
            if len(pairs) >= 1:
                for k, v in pairs[: self.limits.max_attributes_per_event]:
                    ev.add_attr(k, v.strip("\"'"), self.limits)
        if layout is not None and layout.id == "zap-console" and f.get("kv"):
            try:
                import json
                for k, v in json.loads(f["kv"]).items():
                    ev.add_attr(k, v, self.limits)
            except Exception:
                pass
        _promote_attrs(ev)
        # exceptions -----------------------------------------------------------------
        exceptions, hint = parse_exception_block(cont, msg if msg else None, self.limits.max_frames)
        ev.exceptions = exceptions
        if hint and not ev.category_hint:
            ev.category_hint = hint
        if exceptions and (not msg or _EXC_MARKER_MSG.match(msg)):
            head = exceptions[0]
            msg = (head.type or "") + ((": " + head.message) if head.message else "")
        if not msg and cont:
            msg = cont[0].strip()
        if cont and not exceptions:
            ev.raw_excerpt = "\n".join(cont)[: self.limits.max_exception_chars]
        ev.message = msg
        if ev.level_num is None:
            if exceptions and ev.category_hint == "application_crash":
                ev.set_level("fatal")
            elif exceptions:
                ev.set_level("error")
            else:
                h = level_hint_from_message(msg)
                if h:
                    ev.set_level(h)
                    ev.diagnostics.append("level_inferred")
        # http / error codes -----------------------------------------------------------
        if ev.http_status is None:
            hm = _HTTP_STATUS_RE.search(msg)
            if hm:
                ev.http_status = int(hm.group(1))
        cm = _ERROR_CODE_RE.search(msg)
        if cm:
            ev.error_code = cm.group(1)
        if rec.dropped:
            ev.truncated = True
            ev.diagnostics.append("continuation_lines_dropped:%d" % rec.dropped)
            ctx.diag("multiline-limit", "warning",
                     "event exceeded max_multiline_lines/max_record_bytes; %d continuation line(s) dropped" % rec.dropped,
                     rec.line)
        if rec.truncated:
            ev.truncated = True
        if f.get("headerless") and layout is None:
            ev.diagnostics.append("headerless")
        ev.confidence = 1.0 if layout is not None and not layout.id.startswith("generic-") else (0.6 if layout is not None else 0.3)
        ev.bound(self.limits)
        out.append(ev)


_PROMOTE = {
    "trace_id": "trace_id", "traceid": "trace_id", "trace.id": "trace_id", "traceId": "trace_id",
    "span_id": "span_id", "spanid": "span_id", "span.id": "span_id", "spanId": "span_id",
    "request_id": "request_id", "requestid": "request_id", "request.id": "request_id", "requestId": "request_id",
    "req_id": "request_id", "reqId": "request_id", "RequestId": "request_id",
    "correlation_id": "correlation_id", "correlationId": "correlation_id", "CorrelationId": "correlation_id",
    "service": "service", "service.name": "service", "app": "app", "application": "app", "env": "env",
    "environment": "env", "host": "host", "hostname": "host",
}


def _promote_attrs(ev: Event) -> None:
    if not ev.attrs:
        return
    for k, target in _PROMOTE.items():
        v = ev.attrs.get(k)
        if v and isinstance(v, str) and getattr(ev, target) is None and len(v) <= 128:
            setattr(ev, target, v)


def choose_layouts(lines: List[str], ctx: Optional[ParseContext] = None) -> Tuple[List[Layout], float, Dict[str, float]]:
    """Pick the layouts for a file: the best one, plus up to two more when the file mixes layouts.

    Returns (layouts, confidence, scores). Confidence is the fraction of sampled header lines the
    chosen layouts match or, when ``ctx`` is given and that is low, the fraction of *records* they
    explain (see :func:`record_coverage`): block-structured producers (Rails request blocks,
    PowerShell error records, a crash dump after a single logger line) match few header lines but
    own the lines in between.
    """
    best, conf, scores = choose_layout(lines)
    if best is None:
        return [], 0.0, scores
    chosen = [best]
    covered = scores.get(best.id, 0.0)
    if covered < 0.9:
        others = sorted(((v, k) for k, v in scores.items() if k != best.id and v >= 0.1), reverse=True)
        for v, k in others[:2]:
            chosen.append(_LAYOUT_BY_ID[k])
            covered += v
    confidence = min(1.0, covered)
    if ctx is not None and confidence < 0.9:
        confidence = max(confidence, record_coverage(lines, chosen, ctx))
    return chosen, confidence, scores


def record_coverage(lines: List[str], layouts: List[Layout], ctx: ParseContext) -> float:
    """Replay ``lines`` through a throwaway engine and measure how much the layouts explain.

    A record is explained when a layout owns it or it is a recognised crash/exception block.
    Free-text lines folded into a layout record count against the result, so one accidental
    header match in a prose file cannot claim the whole file.
    """
    from ..model import DiagnosticSink
    probe = ParseContext(ctx.limits, ctx.options, DiagnosticSink(4), None, ctx.now)
    engine = TextEngine(probe, layouts, "probe")
    total = 0
    for i, ln in enumerate(lines):
        if ln.strip():
            total += 1
        engine.feed(i + 1, 0, ln)
    engine.flush()
    if not engine.records or not total:
        return 0.0
    unexplained = engine.headerless - engine.headerless_exc
    by_record = (engine.records - unexplained) / float(engine.records)
    by_line = (total - engine.absorbed_unknown) / float(total)
    return max(0.0, min(by_record, by_line))


def choose_layout(lines: List[str]) -> Tuple[Optional[Layout], float, Dict[str, float]]:
    """Score every specific layout on sample lines; return (layout, confidence, scores)."""
    candidates = [ln for ln in lines if ln.strip() and not CONTINUATION_RE.match(ln)]
    if not candidates:
        return None, 0.0, {}
    scores: Dict[str, float] = {}
    best: Optional[Layout] = None
    best_score = 0.0
    for layout in _SPECIFIC:
        hits = 0
        for ln in candidates:
            if layout.regex.match(ln):
                hits += 1
        if hits == 0:
            continue
        frac = hits / float(len(candidates))
        score = min(1.0, frac) * layout.weight
        scores[layout.id] = round(min(1.0, frac), 3)
        if score > best_score:
            best, best_score = layout, score
    if best is not None:
        return best, min(1.0, scores[best.id]), scores
    return None, 0.0, scores


def generic_fraction(lines: List[str]) -> float:
    candidates = [ln for ln in lines if ln.strip() and not CONTINUATION_RE.match(ln)]
    if not candidates:
        return 0.0
    hits = sum(1 for ln in candidates if _GENERIC_TS.regex.match(ln) or _GENERIC_LEVEL.regex.match(ln))
    return hits / float(len(candidates))


def sniff(name: str, sample, ctx) -> float:
    lines = sample.lines
    if not lines:
        return 0.05
    layouts, conf, _ = choose_layouts(lines, ctx)
    if layouts and conf >= 0.3:
        return min(0.9, 0.5 + conf * 0.45)
    gf = generic_fraction(lines)
    if gf >= 0.3:
        return min(0.6, 0.3 + gf * 0.3)
    # unknown text layout: weak fallback claim
    return 0.1


class TextParser(BaseParser):
    name = "text"
    family = "text"

    def __init__(self, name: str = "text", layout_id: Optional[str] = None):
        super().__init__(name)
        self.layout_id = layout_id

    def parse(self, lines: Lines, ctx: ParseContext) -> Iterator[Event]:
        layouts: List[Layout] = []
        if self.layout_id:
            layout = _LAYOUT_BY_ID.get(self.layout_id)
            if layout is None:
                raise ValueError("unknown text layout %r (known: %s)" % (self.layout_id, ", ".join(sorted(_LAYOUT_BY_ID))))
            layouts = [layout]
        elif ctx.layout and ctx.layout in _LAYOUT_BY_ID:
            layouts = [_LAYOUT_BY_ID[ctx.layout]]
        if not layouts and not self.layout_id:
            head: List[str] = []
            buffered: List[Tuple[int, int, str, bool]] = []
            it = iter(lines)
            for item in it:
                buffered.append(item)
                head.append(item[2])
                if len(head) >= ctx.limits.detect_sample_lines:
                    break
            layouts, conf, _ = choose_layouts(head, ctx)
            if layouts and conf < 0.3:
                layouts = []
            if not layouts:
                gf = generic_fraction(head)
                if gf < 0.3 and head:
                    ctx.diag("unknown-text-layout", "warning",
                             "no known text layout matched the sample; using headerless fallback "
                             "(%.0f%% of sampled lines carry a timestamp or level)" % (gf * 100))

            def _chain():
                for b in buffered:
                    yield b
                for b in it:
                    yield b
            lines = _chain()
        ctx.layout = "+".join(l.id for l in layouts) if layouts else "headerless-fallback"
        engine = TextEngine(ctx, layouts, self.name)
        for line_no, offset, text, truncated in lines:
            for ev in engine.feed(line_no, offset, text, truncated):
                yield ev
        for ev in engine.flush():
            yield ev
        if engine.headerless and engine.records and layouts:
            frac = (engine.headerless - engine.headerless_exc) / float(engine.records)
            if frac > 0.5:
                ctx.diag("layout-mismatch", "warning",
                         "%.0f%% of records did not match layout %s" % (frac * 100, ctx.layout))


class LazyTextEngine:
    """TextEngine that picks its layouts from the first sampled lines it receives.

    Used for nested text (Docker/CRI/CloudWatch/GCP/Loki/journal message bodies): the
    wrapper does not know the inner layout up front, so the first ``detect_sample_lines``
    lines are buffered, layouts are chosen, and the buffer is replayed.
    """

    def __init__(self, ctx: ParseContext, parser_name: str):
        self.ctx = ctx
        self.parser_name = parser_name
        self._buffer: List[Tuple[int, int, str, bool, Optional[dict]]] = []
        self._engine: Optional[TextEngine] = None
        self.layout_ids: Optional[str] = None

    def _ensure(self) -> TextEngine:
        if self._engine is None:
            layouts, conf, _ = choose_layouts([b[2] for b in self._buffer], self.ctx)
            if layouts and conf < 0.3:
                layouts = []
            self._engine = TextEngine(self.ctx, layouts, self.parser_name)
            self.layout_ids = "+".join(l.id for l in layouts) if layouts else "headerless-fallback"
        return self._engine

    def feed(self, line_no: int, offset: int, text: str, truncated: bool = False,
             base: Optional[dict] = None) -> List[Event]:
        if self._engine is None:
            self._buffer.append((line_no, offset, text, truncated, base))
            if len(self._buffer) < self.ctx.limits.detect_sample_lines:
                return []
            return self._replay()
        return self._engine.feed(line_no, offset, text, truncated, base)

    def _replay(self) -> List[Event]:
        engine = self._ensure()
        out: List[Event] = []
        for item in self._buffer:
            out.extend(engine.feed(*item))
        self._buffer = []
        return out

    def flush(self) -> List[Event]:
        out: List[Event] = []
        if self._engine is None:
            if not self._buffer:
                return out
            out.extend(self._replay())
        out.extend(self._engine.flush())
        return out


_FAMILY_LAYOUTS = {
    "syslog": ["syslog-rfc5424", "syslog-rfc3164"],
    "access-log": ["apache-nginx-access", "nginx-error", "apache-error"],
}


class FamilyTextParser(TextParser):
    """The ``syslog`` and ``access-log`` parser names: text engine pinned to a layout family."""

    def __init__(self, name: str):
        super().__init__(name)
        self.family_layouts = [_LAYOUT_BY_ID[i] for i in _FAMILY_LAYOUTS[name]]

    def parse(self, lines: Lines, ctx: ParseContext) -> Iterator[Event]:
        ctx.layout = "+".join(l.id for l in self.family_layouts)
        engine = TextEngine(ctx, self.family_layouts, self.name)
        for line_no, offset, text, truncated in lines:
            for ev in engine.feed(line_no, offset, text, truncated):
                yield ev
        for ev in engine.flush():
            yield ev


def family_sniff(name: str, sample) -> float:
    lines = sample.lines
    if not lines:
        return 0.0
    candidates = [ln for ln in lines if ln.strip() and not CONTINUATION_RE.match(ln)]
    if not candidates:
        return 0.0
    layouts = [_LAYOUT_BY_ID[i] for i in _FAMILY_LAYOUTS[name]]
    hits = sum(1 for ln in candidates if any(l.regex.match(ln) for l in layouts))
    frac = hits / float(len(candidates))
    return 0.95 * frac if frac >= 0.5 else 0.0


def make_parser(name: str):
    if name in _FAMILY_LAYOUTS:
        return FamilyTextParser(name)
    return TextParser(name)


def layout_ids() -> List[str]:
    return [l.id for l in LAYOUTS]
