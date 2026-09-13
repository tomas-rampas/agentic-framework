"""Parser registry and bounded-sample format detection.

Every parser module exposes ``NAME``, ``FAMILY``, ``sniff(sample, ctx) -> float`` and a
``Parser`` class with ``parse(lines, ctx) -> Iterator[Event]``. Detection scores each
parser on the bounded head sample and reports the winner's confidence; ties are
broken by registry order (more specific parsers first). ``--input-format`` bypasses
detection; the ``text`` parser is the documented fallback for unknown layouts.
"""
from __future__ import annotations

from typing import Dict, List, Optional, Tuple

from .base import ParseContext  # noqa: F401

_REGISTRY: List[Tuple[str, str]] = [
    # (parser name, module) - order matters for ties: specific before generic.
    ("winevt-xml", "xml_log"),
    ("xml", "xml_log"),
    ("otlp-json", "structured"),
    ("loki-json", "structured"),
    ("cloudwatch-json", "structured"),
    ("azure-json", "structured"),
    ("gcp-json", "structured"),
    ("journal-json", "structured"),
    ("docker-json", "structured"),
    ("ecs-json", "structured"),
    ("apple-ips", "structured"),
    ("json", "structured"),
    ("ndjson", "structured"),
    ("iis-w3c", "tabular"),
    ("csv", "tabular"),
    ("tsv", "tabular"),
    ("cri", "wrappers"),
    ("syslog", "wrappers"),
    ("access-log", "wrappers"),
    ("apple-crash", "wrappers"),
    ("logfmt", "wrappers"),
    ("text", "text"),
]

_MODULES: Dict[str, object] = {}


def _module(name: str):
    mod = _MODULES.get(name)
    if mod is None:
        import importlib
        mod = importlib.import_module("log_triage.parsers." + name)
        _MODULES[name] = mod
    return mod


def parser_names() -> List[str]:
    return [n for n, _ in _REGISTRY]


def get_parser(name: str):
    for pname, modname in _REGISTRY:
        if pname == name:
            return _module(modname).make_parser(name)
    raise KeyError(name)


def detect(sample, ctx) -> Tuple[str, float, Dict[str, float]]:
    """Score every parser on ``sample``; return (name, confidence, all scores)."""
    scores: Dict[str, float] = {}
    best_name, best_score = "text", 0.0
    for pname, modname in _REGISTRY:
        try:
            score = float(_module(modname).sniff(pname, sample, ctx))
        except Exception as exc:  # pragma: no cover - a sniff must never abort detection
            ctx.diag("detector-error", "warning", "%s sniff failed: %s" % (pname, exc))
            score = 0.0
        scores[pname] = round(score, 3)
        if score > best_score:
            best_name, best_score = pname, score
    if best_score <= 0.0:
        best_name, best_score = "text", 0.0
    return best_name, best_score, scores
