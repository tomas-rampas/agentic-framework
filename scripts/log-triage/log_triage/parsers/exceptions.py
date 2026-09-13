"""Exception headline, cause-chain and stack-frame extraction for 13 ecosystems.

``parse_exception_block(lines)`` accepts the tail of a log record (the lines after
the header) and returns ``(exceptions, category_hint)`` where ``exceptions`` is a
list of :class:`ExceptionInfo` ordered *outermost first*. Everything is regex based
and deliberately conservative: a headline is only recognised when the type token
looks like an exception class or a well-known runtime failure marker.
"""
from __future__ import annotations

import re
from typing import List, Optional, Tuple

from ..model import safe_int, ExceptionInfo, Frame

# ---------------------------------------------------------------------------
# Headlines
# ---------------------------------------------------------------------------
_TYPE_SUFFIX = r"(?:Exception|Error|Throwable|Fault|Failure|Timeout|Interrupt|Abort|Violation|Exit|Denied|Overflow|Underflow|Cancel(?:led|ed)|Panic|Warning|Notice|Invalid|NotFound|Rejection|Unavailable|Refused|Reset)"
_JVM_DOTNET_HEAD = re.compile(
    r"^\s*(?:Caused by:\s*|Suppressed:\s*|Unhandled exception\.\s*|Unhandled Exception:\s*|"
    r"Exception in thread \"[^\"]*\"\s*|\s*--->\s*|Inner Exception:\s*|Exception:\s*|error:\s*)?"
    r"(?P<type>[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*" + _TYPE_SUFFIX + r"[\w$]*|[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+)"
    r"(?:\s*\((?P<hres>0x[0-9A-Fa-f]{8})\))?"
    r"(?::\s?(?P<msg>.*))?$"
)
_PY_HEAD = re.compile(r"^(?P<type>[A-Za-z_][\w.]*(?:Exception|Error|Interrupt|Exit|Warning|Timeout|Cancelled|Stop(?:Iteration|AsyncIteration)|NotImplemented|KeyboardInterrupt))(?::\s?(?P<msg>.*))?$")
_PY_TRACEBACK = re.compile(r"^Traceback \(most recent call last\):\s*$")
_PY_HEAD_ANY = re.compile(r"^(?P<type>[A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*)*)(?::\s?(?P<msg>.*))?$")
_PY_CHAIN = re.compile(r"^(?:The above exception was the direct cause of the following exception:|During handling of the above exception, another exception occurred:)\s*$")
_GO_PANIC = re.compile(r"^(?:panic: |fatal error: )(?P<msg>.*)$")
_GO_ROUTINE = re.compile(r"^goroutine \d+ \[[^\]]*\]:\s*$")
_RUST_PANIC_NEW = re.compile(r"^thread '(?P<thread>[^']*)' panicked at (?P<file>[^:]+):(?P<line>\d+):(?P<col>\d+):\s*$")
_RUST_PANIC_OLD = re.compile(r"^thread '(?P<thread>[^']*)' panicked at '(?P<msg>.*)', (?P<file>[^:]+):(?P<line>\d+):(?P<col>\d+)\s*$")
_RUST_BACKTRACE = re.compile(r"^stack backtrace:\s*$")
_NODE_HEAD = re.compile(r"^(?:Uncaught |UnhandledPromiseRejectionWarning: |\[cause\]: )?(?P<type>[A-Z][A-Za-z]*Error|Error|AssertionError|AggregateError|DOMException)(?: \[(?P<code>[A-Z_0-9]+)\])?(?::\s?(?P<msg>.*))?$")
_RUBY_HEAD = re.compile(r"^(?P<file>[^:\s]+):(?P<line>\d+):in [`'](?P<func>[^']*)': (?P<msg>.*) \((?P<type>[A-Z][\w:]*)\)\s*$")
_RUBY_RAILS_HEAD = re.compile(r"^(?P<type>[A-Z][\w:]*(?:Error|Exception|NotFound|Invalid|Timeout|Missing|Failed|Unauthorized|Forbidden)) \((?P<msg>.*)\):\s*$")
_PHP_UNCAUGHT = re.compile(r"^(?:PHP (?:Fatal error|Warning|Notice|Parse error|Deprecated|Error)|Fatal error|Warning|Notice|Parse error|Deprecated):\s+(?:Uncaught (?P<type>[\w\\]+): (?P<msg>.*?)(?: in (?P<file>\S+?):(?P<line>\d+))?|(?P<msg2>.*?)(?: in (?P<file2>\S+) on line (?P<line2>\d+))?)\s*$")
_PHP_KIND = re.compile(r"^(?:PHP )?(?P<kind>Fatal error|Warning|Notice|Parse error|Deprecated|Error):")
_ELIXIR_HEAD = re.compile(r"^\*\* \((?P<type>[A-Z][\w.]*)\) (?P<msg>.*)$")
_ERLANG_EXC = re.compile(r"^\s*(?:\*\* )?exception (?P<kind>error|exit|throw): (?P<msg>.*)$")
_ERLANG_REASON = re.compile(r"^\*\* Reason for termination ==\s*$")
_ERLANG_TERMINATING = re.compile(r"^\*\* (?:Generic server|State machine|gen_event handler) .* terminating\s*$")
_ERLANG_REPORT = re.compile(r"^=(?P<kind>ERROR|CRASH|SUPERVISOR|PROGRESS|INFO|WARNING) REPORT====")
_ELIXIR_GENSERVER = re.compile(r"^(?:GenServer|Task|Agent|Process) (?P<name>\S+) terminating\s*$")
_SANITIZER = re.compile(r"^==\d+==\s*(?:ERROR|WARNING): (?P<tool>AddressSanitizer|LeakSanitizer|ThreadSanitizer|MemorySanitizer|UndefinedBehaviorSanitizer|HWAddressSanitizer): (?P<kind>detected memory leaks|attempting free on address not malloc\(\)-ed|attempting double-free|use-of-uninitialized-value|data race|[\w-]+)(?P<rest>.*)$")
_SANITIZER_SUMMARY = re.compile(r"^SUMMARY: (?P<tool>\w+Sanitizer): (?P<kind>\S+)(?: (?P<loc>\S+))?")
_UBSAN = re.compile(r"^(?P<file>[^:\s]+):(?P<line>\d+):(?P<col>\d+): runtime error: (?P<msg>.*)$")
_TSAN_WARN = re.compile(r"^WARNING: ThreadSanitizer: (?P<kind>[a-z -]+?) \(pid=\d+\)\s*$")
_ASSERT_BSD = re.compile(r"^Assertion failed: \((?P<expr>.*)\), function (?P<func>\S+), file (?P<file>[^,]+), line (?P<line>\d+)\.?\s*$")
_ASSERT_GLIBC = re.compile(r"^(?P<prog>[^:\s]+): (?P<file>[^:]+):(?P<line>\d+): (?P<func>[^:]+): Assertion [`'](?P<expr>.*)' failed\.?\s*$")
_ASSERT_MSVC = re.compile(r"^Assertion failed: (?P<expr>.*?), file (?P<file>[^,]+), line (?P<line>\d+)\s*$")
_ASSERT_GENERIC = re.compile(r"^(?:Assertion failed|Assertion failure|assert failed|ASSERT(?:ION)? FAILED)[:.]?\s*(?P<msg>.*)$", re.IGNORECASE)
_SEGFAULT = re.compile(r"^(?:Segmentation fault|Bus error|Illegal instruction|Floating point exception|Aborted|Killed)(?: \(core dumped\))?\s*$")
_APPLE_EXC_TYPE = re.compile(r"^Exception Type:\s+(?P<type>\S+)(?:\s+\((?P<sig>[^)]+)\))?\s*$")
_APPLE_EXC_CODES = re.compile(r"^Exception Codes:\s+(?P<codes>.*)$")
_APPLE_CRASHED = re.compile(r"^Thread (?P<n>\d+) Crashed:")
_APPLE_THREAD = re.compile(r"^Thread \d+")
_APPLE_TERM = re.compile(r"^Termination Reason:\s+(?P<msg>.*)$")
_PS_EXCEPTION = re.compile(r"^\s*Exception\s*:\s+(?P<type>[\w.]+)(?::\s?(?P<msg>.*))?$")
_PS_CATEGORY = re.compile(r"^\s*\+?\s*CategoryInfo\s*:\s+(?P<cat>\w+): \((?P<target>.*)\) \[(?P<activity>[^\]]*)\], (?P<type>[\w.]+)\s*$")
_PS_FQID = re.compile(r"^\s*\+?\s*FullyQualifiedErrorId\s*:\s+(?P<id>\S+)\s*$")
_PS_AT = re.compile(r"^At (?:line:(?P<line>\d+) char:(?P<char>\d+)|(?P<file>.+?):(?P<line2>\d+) char:(?P<char2>\d+))\s*$")
_PS_CONCISE = re.compile(r"^(?P<cmd>[A-Z][\w-]+)\s?: (?P<msg>.+)$")
_PS_SCRIPTSTACK = re.compile(r"^\s*ScriptStackTrace\s*:\s*(?P<rest>.*)$")
_PS_STACK_FRAME = re.compile(r"^\s*at (?P<func>[^,]+), (?P<file>.+?): line (?P<line>\d+)\s*$")
_DOTNET_PROCESS_TERMINATED = re.compile(r"^Process terminated\. (?P<msg>.*)$")
_JAVA_OOM_KILLED = re.compile(r"^(?:java\.lang\.)?OutOfMemoryError")
_JAVA_MORE = re.compile(r"^\s*\.\.\. \d+ (?:more|common frames omitted)\s*$")
_DOTNET_END_INNER = re.compile(r"^\s*--- End of (?:inner exception stack trace|stack trace from previous location)[^-]*---\s*$")

# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------
_F_JVM = re.compile(r"^\s*at (?P<func>[\w$.<>/\[\]]+(?:\$\$Lambda\$[\d/x.a-f]+)?(?:\.[\w$<>]+)?)\((?P<loc>[^)]*)\)\s*(?:~\[.*\])?\s*$")
_F_DOTNET = re.compile(r"^\s*at (?P<func>[^\s(][^(]*)\((?P<args>[^)]*)\)(?: in (?P<file>.+?):line (?P<line>\d+))?\s*$")
_F_PY = re.compile(r"^\s*File \"(?P<file>[^\"]+)\", line (?P<line>\d+)(?:, in (?P<func>.+))?\s*$")
_F_NODE = re.compile(r"^\s*at (?:(?P<func>[^\s(][^(]*?) \()?(?P<file>(?:[A-Za-z]:)?[^():]*?):(?P<line>\d+)(?::(?P<col>\d+))?\)?\s*$")
_F_NODE_ANON = re.compile(r"^\s*at (?P<func>[^\s(][^(]*?) \((?:<anonymous>|native|node:[\w/]+(?::\d+)*)\)\s*$")
_F_GO_FUNC = re.compile(r"^(?P<func>[\w./*()\[\]-]+(?:\.[\w*()\[\]-]+)*)\((?P<args>[^)]*)\)\s*$")
_F_GO_FUNC_LOOSE = re.compile(r"^(?P<func>[\w./*\[\]-]+(?:\.[\w*\[\]-]+)+)\s*$")
_F_GO_FILE = re.compile(r"^\s+(?P<file>\S+\.go):(?P<line>\d+)(?: \+0x[0-9a-f]+)?\s*$")
_F_RUST_FN = re.compile(r"^\s*(?P<n>\d+): (?P<func>.+?)\s*$")
_F_RUST_AT = re.compile(r"^\s+at (?P<file>[^:]+):(?P<line>\d+)(?::(?P<col>\d+))?\s*$")
_F_RUBY = re.compile(r"^\s*(?:from )?(?P<file>[^:\s]+):(?P<line>\d+):in [`'](?P<func>[^']*)'\s*$")
_F_PHP = re.compile(r"^\s*#\d+ (?:(?P<file>[^(]+)\((?P<line>\d+)\): (?P<func>.*)|\{main\})\s*$")
_F_ELIXIR = re.compile(r"^\s+\((?P<app>[\w-]+)(?: [\w.+-]+)?\) (?P<file>[^:\s]+):(?P<line>\d+): (?P<func>.+?)\s*$")
_F_ELIXIR_NOAPP = re.compile(r"^\s+(?P<file>[\w/.-]+\.exs?):(?P<line>\d+): (?P<func>.+?)\s*$")
_F_ERLANG = re.compile(r"^\s*(?:in call from |in function\s+)?(?P<func>[a-z_][\w]*:[a-z_][\w]*/\d+)(?: \((?P<file>[^,]+), line (?P<line>\d+)\))?\s*$")
_F_SANITIZER = re.compile(r"^\s*#\d+ 0x[0-9a-f]+ in (?P<func>.+?) (?P<file>[^\s:]+)(?::(?P<line>\d+)(?::\d+)?)?\s*$")
_F_SANITIZER_MOD = re.compile(r"^\s*#\d+ 0x[0-9a-f]+\s+\((?P<mod>[^+]+)\+0x[0-9a-f]+\)\s*$")
_F_APPLE = re.compile(r"^(?P<n>\d+)\s+(?P<image>\S+)\s+0x[0-9a-fA-F]+\s+(?P<func>.+?)(?: \+ \d+)?(?: \((?P<file>[^:)]+):(?P<line>\d+)\))?\s*$")
_F_SWIFT_BT = re.compile(r"^\s*(?P<n>\d+)\s+(?P<func>.+?)\s+\+\s+\d+\s+in\s+(?P<image>\S+)\s+at\s+(?P<file>[^:]+):(?P<line>\d+)")
_F_PS = _PS_STACK_FRAME
_F_CPP_GDB = re.compile(r"^#\d+\s+(?:0x[0-9a-f]+ in )?(?P<func>[^\s(]+) \(.*?\)(?: at (?P<file>[^:]+):(?P<line>\d+))?\s*$")

_NOT_IN_APP = re.compile(
    r"^(?:java\.|javax\.|jakarta\.|jdk\.|sun\.|com\.sun\.|kotlin\.|kotlinx\.|scala\.|org\.springframework\.|"
    r"org\.apache\.|org\.hibernate\.|org\.eclipse\.|io\.netty\.|reactor\.|io\.micrometer\.|ch\.qos\.|org\.slf4j\.|"
    r"System\.|Microsoft\.|Newtonsoft\.|Npgsql\.|MySql\.Data\.|StackExchange\.|Serilog\.|NLog\.|log4net\.|Polly\.|"
    r"node:|internal/|<anonymous>|new Promise|process\.|Module\._|Object\.<anonymous>|"
    r"runtime\.|runtime/|reflect\.|net/http|syscall\.|"
    r"std::|core::|alloc::|tokio::|hyper::|std/src|core/src|/rustc/|rust_begin_unwind|rust_panic|__rust_|"
    r"gen_server|gen_statem|proc_lib|supervisor|:gen_server|:proc_lib|"
    r"__libc_|libc\.|libsystem|CoreFoundation|UIKitCore|Foundation |libdispatch|libobjc|dyld|"
    r"Microsoft\.PowerShell|System\.Management\.Automation)"
)
_NOT_IN_APP_FILE = re.compile(
    r"(?:^|/)(?:site-packages|dist-packages|node_modules|vendor|\.cargo|\.rustup|\.nuget|lib/python\d|rustc|"
    r"lib/ruby|gems|deps|_build|usr/lib|usr/local/lib|Program Files|\.gradle|\.m2)(?:/|\\|$)|^<frozen |^node:"
)


_APPLE_SYSTEM_IMAGES = re.compile(r"^(?:UIKitCore|UIKit|Foundation|CoreFoundation|libdispatch\.dylib|libsystem_\w+\.dylib|libobjc\.A\.dylib|dyld|AppKit|SwiftUI|libswiftCore\.dylib|libswift\w+\.dylib|CFNetwork|Security|QuartzCore|CoreGraphics|GraphicsServices|FrontBoardServices|libc\+\+\.1\.dylib|libc\+\+abi\.dylib|CoreData|CoreServices|Metal|WebKit|JavaScriptCore)$")


def _in_app(func: Optional[str], file: Optional[str]) -> bool:
    if func and _NOT_IN_APP.match(func):
        return False
    if file and _APPLE_SYSTEM_IMAGES.match(file):
        return False
    if file and _NOT_IN_APP_FILE.search(file.replace("\\", "/")):
        return False
    return True


def _mk_frame(func: Optional[str], file: Optional[str], line: Optional[str], raw: str) -> Frame:
    ln = safe_int(line) if line else None
    return Frame(func, file, ln, _in_app(func, file), raw if len(raw) < 400 else raw[:400])


def parse_frame(line: str, family_hint: Optional[str] = None) -> Optional[Frame]:
    """Parse one stack-frame line from any supported ecosystem."""
    s = line.rstrip()
    if not s.strip():
        return None
    m = _F_PY.match(s)
    if m:
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    m = _F_DOTNET.match(s)
    if m and (m.group("file") or "." in m.group("func")) and "(" not in m.group("func"):
        if m.group("file") or family_hint == "dotnet" or not _F_JVM.match(s):
            if m.group("file") or " in " in s or family_hint == "dotnet":
                return _mk_frame(m.group("func").strip(), m.group("file"), m.group("line"), s)
    m = _F_JVM.match(s)
    if m:
        loc = m.group("loc")
        file = line_no = None
        if ":" in loc:
            file, line_no = loc.rsplit(":", 1)
            if not line_no.isdigit():
                file, line_no = loc, None
        elif loc and loc not in ("Native Method", "Unknown Source") and re.match(r"^[\w.$-]+\.\w+$", loc):
            file = loc
        return _mk_frame(m.group("func"), file, line_no, s)
    if s.endswith(" {"):
        s = s[:-2]
    m = _F_NODE.match(s)
    if m and (m.group("file").endswith((".js", ".ts", ".mjs", ".cjs", ".jsx", ".tsx")) or "/" in m.group("file")
              or m.group("file").startswith("node:") or "\\" in m.group("file")):
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    m = _F_NODE_ANON.match(s)
    if m:
        return _mk_frame(m.group("func"), None, None, s)
    if _F_DOTNET.match(s):
        m = _F_DOTNET.match(s)
        return _mk_frame(m.group("func").strip(), m.group("file"), m.group("line"), s)
    m = _F_RUBY.match(s)
    if m:
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    m = _F_PHP.match(s)
    if m:
        if m.group("file") is None:
            return _mk_frame("{main}", None, None, s)
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    m = _F_ELIXIR.match(s)
    if m:
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    m = _F_ELIXIR_NOAPP.match(s)
    if m:
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    m = _F_SANITIZER.match(s)
    if m:
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    m = _F_SANITIZER_MOD.match(s)
    if m:
        return _mk_frame(None, m.group("mod"), None, s)
    m = _F_PS.match(s)
    if m:
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    m = _F_CPP_GDB.match(s)
    if m:
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    m = _F_SWIFT_BT.match(s)
    if m:
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    m = _F_APPLE.match(s)
    if m and family_hint in ("apple", None) and not s.lstrip().startswith("#"):
        return _mk_frame(m.group("func"), m.group("file") or m.group("image"), m.group("line"), s)
    m = _F_ERLANG.match(s)
    if m:
        return _mk_frame(m.group("func"), m.group("file"), m.group("line"), s)
    return None


class _Block:
    __slots__ = ("type", "message", "frames", "raw")

    def __init__(self, type_: Optional[str], message: Optional[str]):
        self.type = type_
        self.message = message
        self.frames: List[Frame] = []
        self.raw: List[str] = []


def _headline(s: str) -> Optional[Tuple[str, Optional[str], str]]:
    """Return (type, message, family) when ``s`` is an exception headline."""
    st = s.strip()
    if not st:
        return None
    m = _GO_PANIC.match(st)
    if m:
        msg = m.group("msg")
        typ = "panic"
        if st.startswith("fatal error:"):
            typ = "fatal error"
        elif msg.startswith("runtime error:"):
            typ = "runtime error"
            msg = msg[len("runtime error:"):].strip()
        return typ, msg, "go"
    m = _RUST_PANIC_OLD.match(st)
    if m:
        return "panic", m.group("msg"), "rust"
    m = _RUST_PANIC_NEW.match(st)
    if m:
        return "panic", None, "rust"
    m = _ELIXIR_HEAD.match(st)
    if m:
        return m.group("type"), m.group("msg"), "elixir"
    m = _ERLANG_EXC.match(st)
    if m:
        return "exception " + m.group("kind"), m.group("msg"), "erlang"
    m = _SANITIZER.match(st)
    if m:
        return m.group("tool") + ": " + m.group("kind"), (m.group("rest") or "").strip(" :") or None, "sanitizer"
    m = _TSAN_WARN.match(st)
    if m:
        return "ThreadSanitizer: " + m.group("kind"), None, "sanitizer"
    m = _UBSAN.match(st)
    if m:
        return "UndefinedBehaviorSanitizer: runtime error", m.group("msg"), "sanitizer"
    m = _ASSERT_BSD.match(st) or _ASSERT_GLIBC.match(st) or _ASSERT_MSVC.match(st)
    if m:
        return "AssertionFailure", m.group("expr"), "assert"
    m = _ASSERT_GENERIC.match(st)
    if m:
        return "AssertionFailure", m.group("msg") or None, "assert"
    if _SEGFAULT.match(st):
        return "Signal", st, "signal"
    m = _RUBY_HEAD.match(st)
    if m:
        return m.group("type"), m.group("msg"), "ruby"
    m = _RUBY_RAILS_HEAD.match(st)
    if m:
        return m.group("type"), m.group("msg"), "ruby"
    m = _PHP_UNCAUGHT.match(st)
    if m:
        if m.group("type"):
            return m.group("type"), m.group("msg"), "php"
        kind = _PHP_KIND.match(st).group("kind")
        return "PHP " + kind, m.group("msg2"), "php"
    m = _PY_HEAD.match(st)
    if m:
        return m.group("type"), m.group("msg"), "python"
    m = _NODE_HEAD.match(st)
    if m:
        typ = m.group("type")
        if m.group("code"):
            typ = typ + " [" + m.group("code") + "]"
        return typ, m.group("msg"), "node"
    m = _JVM_DOTNET_HEAD.match(st)
    if m:
        typ = m.group("type")
        if "." not in typ and not re.search(_TYPE_SUFFIX + r"[\w$]*$", typ):
            return None
        if typ[0].islower() and "." in typ:
            # java.io.IOException style; require an Exception-ish last segment or a message
            last = typ.rsplit(".", 1)[-1]
            if not last[:1].isupper():
                return None
        msg = m.group("msg")
        if m.group("hres"):
            msg = ("(%s) " % m.group("hres")) + (msg or "")
        return typ, msg, "jvm-dotnet"
    m = _APPLE_EXC_TYPE.match(st)
    if m:
        typ = m.group("type") + ((" (%s)" % m.group("sig")) if m.group("sig") else "")
        return typ, None, "apple"
    m = _PS_EXCEPTION.match(st)
    if m:
        return m.group("type"), m.group("msg"), "powershell"
    return None


def is_exception_headline(text: str) -> bool:
    """True when ``text`` looks like an exception headline in any supported ecosystem."""
    return _headline(text) is not None


def parse_exception_block(lines: List[str], head_message: Optional[str] = None, max_frames: int = 50
                          ) -> Tuple[List[ExceptionInfo], Optional[str]]:
    """Extract exceptions (outermost first) from record lines. Returns (exceptions, category_hint)."""
    blocks: List[_Block] = []
    hint: Optional[str] = None
    py_mode = False
    py_pending_frames: List[Frame] = []
    py_blocks: List[_Block] = []
    current: Optional[_Block] = None
    family: Optional[str] = None
    rust_pending_fn: Optional[str] = None
    go_pending_fn: Optional[str] = None
    apple_in_crashed = False
    ps_type: Optional[str] = None
    ps_msg: Optional[str] = None
    ps_frames: List[Frame] = []
    ps_fqid: Optional[str] = None
    erl_reason_next = False
    outer_stack: List[_Block] = []
    first_line: Optional[str] = None
    head_blocks: List[_Block] = []

    candidates: List[Tuple[str, bool]] = []
    if head_message:
        candidates.append((head_message, True))
    candidates.extend((ln, False) for ln in lines)

    for raw, is_head in candidates:
        s = raw.rstrip()
        st = s.strip()
        if not st:
            continue
        if first_line is None:
            first_line = st
        if _PY_TRACEBACK.match(st):
            py_mode = True
            py_pending_frames = []
            continue
        if _PY_CHAIN.match(st):
            py_mode = True
            continue
        if py_mode:
            fm = _F_PY.match(s)
            if fm:
                py_pending_frames.append(_mk_frame(fm.group("func"), fm.group("file"), fm.group("line"), s))
                continue
            hm = _PY_HEAD.match(st) or (_PY_HEAD_ANY.match(st) if py_pending_frames else None)
            if hm and (py_pending_frames or not blocks) and hm.group("type")[:1].isupper() or (hm and "." in hm.group("type") and py_pending_frames):
                b = _Block(hm.group("type"), hm.group("msg"))
                b.frames = py_pending_frames[::-1][:max_frames]  # innermost call first
                py_pending_frames = []
                py_blocks.append(b)
                family = family or "python"
                py_mode = False
                continue
            if s.startswith("    ") and py_pending_frames:
                continue  # source line under a File frame
            if s.startswith("  ") and not st.startswith("File"):
                continue
            py_mode = False
        if _DOTNET_END_INNER.match(st):
            if outer_stack:
                current = outer_stack.pop()
            continue
        if _JAVA_MORE.match(st) or _GO_ROUTINE.match(st) \
                or _RUST_BACKTRACE.match(st) or st.startswith("note: run with `RUST_BACKTRACE"):
            if _GO_ROUTINE.match(st) and current is not None:
                family = "go"
            continue
        if _ERLANG_TERMINATING.match(st):
            hint = hint or "application_crash"
            continue
        if _ERLANG_REASON.match(st):
            erl_reason_next = True
            continue
        if erl_reason_next:
            erl_reason_next = False
            body = st[2:].strip() if st.startswith("**") else st
            b = _Block("exit", body)
            blocks.append(b)
            current = b
            family = family or "erlang"
            continue
        m = _ELIXIR_GENSERVER.match(st)
        if m:
            hint = hint or "application_crash"
            continue
        m = _APPLE_TERM.match(st)
        if m and current is not None and family == "apple":
            current.message = (current.message + "; " if current.message else "") + m.group("msg")
            continue
        m = _APPLE_EXC_CODES.match(st)
        if m and current is not None and family == "apple":
            current.message = m.group("codes")
            continue
        if _APPLE_CRASHED.match(st):
            apple_in_crashed = True
            continue
        if apple_in_crashed and _APPLE_THREAD.match(st):
            apple_in_crashed = False
        # PowerShell error record fields
        m = _PS_CATEGORY.match(st)
        if m:
            ps_type = ps_type or m.group("type")
            family = family or "powershell"
            continue
        m = _PS_FQID.match(st)
        if m:
            ps_fqid = m.group("id")
            family = family or "powershell"
            continue
        m = _PS_AT.match(st)
        if m and family in ("powershell", None) and (ps_type or ps_msg or current is None):
            file = m.group("file")
            ln = m.group("line") or m.group("line2")
            ps_frames.append(_mk_frame(None, file, ln, s))
            family = family or "powershell"
            continue
        if _PS_SCRIPTSTACK.match(st):
            rest = _PS_SCRIPTSTACK.match(st).group("rest")
            fm = _F_PS.match(rest)
            if fm:
                ps_frames.append(_mk_frame(fm.group("func"), fm.group("file"), fm.group("line"), rest))
            family = "powershell"
            continue
        head = _headline(st)
        if head is not None and not (family == "apple" and apple_in_crashed):
            typ, msg, fam = head
            if fam == "powershell":
                ps_type, ps_msg = typ, msg
                continue
            if fam == "rust" and msg is None:
                b = _Block(typ, None)
                rm = _RUST_PANIC_NEW.match(st)
                b.frames.append(_mk_frame(None, rm.group("file"), rm.group("line"), s))
                b.message = "__NEXT_LINE__"
                blocks.append(b)
                current = b
                family = family or fam
                rust_pending_fn = None
                continue
            if fam == "rust":
                b = _Block(typ, msg)
                rm = _RUST_PANIC_OLD.match(st)
                b.frames.append(_mk_frame(None, rm.group("file"), rm.group("line"), s))
                blocks.append(b)
                current = b
                family = family or fam
                continue
            if fam == "ruby":
                b = _Block(typ, msg)
                rm = _RUBY_HEAD.match(st)
                if rm:
                    b.frames.append(_mk_frame(rm.group("func"), rm.group("file"), rm.group("line"), s))
                blocks.append(b)
                current = b
                family = family or fam
                continue
            if fam == "php":
                b = _Block(typ, msg)
                pm = _PHP_UNCAUGHT.match(st)
                f = pm.group("file") or pm.group("file2")
                ln = pm.group("line") or pm.group("line2")
                if f:
                    b.frames.append(_mk_frame(None, f, ln, s))
                blocks.append(b)
                current = b
                family = family or fam
                continue
            b = _Block(typ, msg)
            if blocks and current is not None and (current.type, current.message) == (typ, msg) and not current.frames:
                continue  # same headline repeated (header message + first continuation line)
            if st.lstrip().startswith("--->") and current is not None:
                outer_stack.append(current)
            blocks.append(b)
            if is_head and fam == "jvm-dotnet":
                head_blocks.append(b)
            current = b
            family = family or fam
            if fam in ("sanitizer", "signal", "assert", "apple"):
                hint = hint or "application_crash"
            continue
        if current is not None and current.message == "__NEXT_LINE__":
            current.message = st
            continue
        if _SANITIZER_SUMMARY.match(st):
            continue
        # frames ------------------------------------------------------
        # Go frames come in pairs: "pkg.Func(args)" (or bare "pkg.Func" in Zap stacktraces) then "\tfile.go:NN".
        fm = _F_GO_FILE.match(s)
        if fm and go_pending_fn is not None:
            if current is None:
                current = _Block(None, None)
                blocks.append(current)
            if len(current.frames) < max_frames:
                current.frames.append(_mk_frame(go_pending_fn, fm.group("file"), fm.group("line"), s))
            go_pending_fn = None
            family = family or "go"
            continue
        if not s.startswith(" ") and not s.startswith("\t"):
            gm = _F_GO_FUNC.match(st) or _F_GO_FUNC_LOOSE.match(st)
            if gm and (family == "go" or current is None or (current is not None and current.type in ("panic", "fatal error", "runtime error"))
                       or "/" in gm.group("func") or gm.group("func").count(".") >= 1):
                go_pending_fn = gm.group("func")
                if _F_GO_FUNC.match(st) or family == "go" or (current is not None and current.type in ("panic", "fatal error", "runtime error")):
                    continue
                # loose match: keep scanning this line as a potential frame/headline for other families
        if current is not None or ps_type or ps_msg or family == "go" or True:
            if family == "rust" or (current is not None and current.type == "panic"):
                rm = _F_RUST_FN.match(s)
                if rm:
                    rust_pending_fn = rm.group("func")
                    continue
                am = _F_RUST_AT.match(s)
                if am and current is not None:
                    if len(current.frames) < max_frames:
                        current.frames.append(_mk_frame(rust_pending_fn, am.group("file"), am.group("line"), s))
                    rust_pending_fn = None
                    continue
            if family == "apple":
                if apple_in_crashed:
                    fm = _F_APPLE.match(st)
                    if fm and current is not None and len(current.frames) < max_frames:
                        current.frames.append(_mk_frame(fm.group("func"), fm.group("file") or fm.group("image"),
                                                        fm.group("line"), s))
                continue
            fr = parse_frame(s, "dotnet" if family == "jvm-dotnet" and " in " in s else None)
            if fr is not None:
                target = current
                if target is None and (ps_type or ps_msg):
                    ps_frames.append(fr)
                    continue
                if target is None:
                    # frames without a headline (structured "stack" strings, Monolog traces): anonymous block
                    target = _Block(None, None)
                    blocks.append(target)
                    current = target
                if len(target.frames) < max_frames:
                    target.frames.append(fr)
                continue
            if current is not None and current.type in ("panic", "fatal error", "runtime error") and st.startswith("[signal "):
                current.message = (current.message or "") + " " + st
                continue

    if ps_type or ps_msg or ps_fqid:
        merged = False
        for b in blocks:
            bt = b.type or ""
            if ps_type and (bt == ps_type or bt.endswith("." + ps_type)):
                # Format-List record: "Exception : System.Net.WebException: ..." already produced this
                # block and CategoryInfo repeats the short type name. Attach the script-stack frames to
                # it instead of reporting the same exception twice.
                b.frames.extend(ps_frames[: max(0, max_frames - len(b.frames))])
                merged = True
                break
        if not merged:
            if ps_msg is None and first_line:
                cm = _PS_CONCISE.match(first_line)
                if cm:
                    ps_msg = cm.group("msg")
            b = _Block(ps_type or (ps_fqid.split(",")[0] if ps_fqid else "PowerShellError"), ps_msg)
            b.frames = ps_frames[:max_frames]
            blocks.insert(0, b)
        family = family or "powershell"
    if py_blocks:
        # Python prints the cause first; the last block is the outermost exception.
        blocks = py_blocks[::-1] + blocks

    # A dotted token in the header message alone ("com.acme.Foo: started") is not an exception
    # unless frames followed it or the type carries an exception-like suffix.
    for b in head_blocks:
        if not b.frames and b in blocks and not re.search(_TYPE_SUFFIX + r"[\w$]*$", b.type or "") \
                and len(blocks) == 1:
            blocks.remove(b)
    result: List[ExceptionInfo] = []
    for b in blocks:
        if b.message == "__NEXT_LINE__":
            b.message = None
        result.append(ExceptionInfo(b.type, b.message, b.frames))
    if result and hint is None:
        t = (result[0].type or "").lower()
        if any(k in t for k in ("outofmemory", "stackoverflow", "panic", "fatal", "sanitizer", "assertion", "signal",
                                "exc_bad", "exc_crash", "segmentation")):
            hint = "application_crash"
    return result, hint


# Continuation detection used by the text engine (prefix-anchored, cheap).
CONTINUATION_RE = re.compile(
    r"^(?:[ \t]|at |Caused by: |Suppressed: |Traceback \(most recent|  File \"|from |#\d+ |\.\.\. \d+ (?:more|common)|"
    r"goroutine \d+|stack backtrace:|note: run with|\d+: |---|\s*\+ (?:CategoryInfo|FullyQualifiedErrorId|~+)|"
    r"Exception Type:|Exception Codes:|Exception Subtype:|Exception Note:|Termination Reason:|Thread \d+|Binary Images:|"
    r"==\d+==|SUMMARY: |exit status \d+|\*\* |"
    r"(?:READ|WRITE|Read|Write|Atomic (?:read|write)|Previous (?:read|write|atomic \w+)) of size \d+|"
    r"(?:freed|previously allocated|allocated) by thread|Thread T\d+ |Mutex M\d+ |Location is |Shadow bytes|Shadow byte legend|Legend: |"
    r"0x[0-9a-fA-F]+ is located |(?:Direct|Indirect) leak of |Uninitialized value was |"
    r"Stack trace:|  thrown in |    \(|\[signal |main\.|created by |The above exception|During handling|"
    r"Last message|State: |Exception in thread|Unhandled exception\.|--> |\{main\}|[\]\)}]+,?\s*$|"
    r"\S+\.go:\d+|\s*\d+\s+\S+\s+0x[0-9a-fA-F]{8,})"
)

EXCEPTION_START_RE = re.compile(
    r"^(?:Traceback \(most recent call last\):|panic: |fatal error: |thread '[^']*' panicked at |Unhandled exception\. |"
    r"Exception in thread \"|==\d+==\s*(?:ERROR|WARNING): |\*\* \([A-Z][\w.]*\) |PHP (?:Fatal error|Warning|Notice|Parse error|Deprecated):|"
    r"[A-Z][A-Za-z]*Error: |Error: |Assertion failed|=(?:CRASH|ERROR|SUPERVISOR) REPORT====|"
    r"WARNING: (?:Thread|Memory|Leak)Sanitizer: |ERROR: (?:Address|Leak|Memory|UndefinedBehavior|HWAddress|Thread)Sanitizer: |"
    r"\S+:\d+:\d+: runtime error: |[^\s:]+: [^\s:]+:\d+: [^\s:]+: Assertion |"
    r"Process:\s+\S+ \[\d+\]|Incident Identifier: )"
)

# A process-termination line ("Aborted (core dumped)") that follows a crash block belongs to it.
TERMINATION_RE = _SEGFAULT

# Rust (1.73+) panic headline: the panic message is printed on the *next* line.
HEADLINE_EXPECTS_BODY_RE = re.compile(r"^thread '[^']*' panicked at \S+:\d+(?::\d+)?:\s*$")
