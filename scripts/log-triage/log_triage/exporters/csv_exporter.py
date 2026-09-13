"""Flat issue-group summary for spreadsheets (docs/log-triage/README.md, "CSV columns").

Escaping: RFC 4180 via the csv module (fields containing separators, quotes or newlines
are quoted). Formula-injection protection: any text cell starting with ``=``, ``+``,
``-``, ``@``, TAB or CR is prefixed with an apostrophe so spreadsheet applications treat
it as text. Encoding is UTF-8 with BOM; line endings are CRLF.
"""
from __future__ import annotations

import csv
import os
from typing import Any, List

from ..config import OUTPUT_FILENAMES
from .base import AtomicFile, Exporter

COLUMNS = [
    "id", "severity", "category", "confidence", "basis", "count", "first_seen", "last_seen", "untimed_count",
    "level_max", "services", "hosts_distinct", "logger", "exception_type", "exception_chain", "http_status",
    "http_method", "error_code", "template", "attribution_status", "repositories", "top_repo_confidence",
    "investigation_status", "suggestion_kind", "suggestion_summary", "example_input", "example_line", "fingerprint",
]

_DANGEROUS = ("=", "+", "-", "@", "\t", "\r")


def safe_cell(value: Any) -> Any:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return value
    s = str(value).replace("\r\n", " ").replace("\n", " ")
    if s[:1] in _DANGEROUS:
        return "'" + s
    return s


class CsvExporter(Exporter):
    name = "csv"
    filenames = [OUTPUT_FILENAMES["csv"]]

    def write(self, analysis, out_dir: str) -> List[str]:
        path = os.path.join(out_dir, self.filenames[0])
        with AtomicFile(path, encoding="utf-8-sig", newline="") as fh:
            w = csv.writer(fh, lineterminator="\r\n", quoting=csv.QUOTE_MINIMAL)
            w.writerow(COLUMNS)
            for g in analysis.groups():
                a = g.get("assessment") or {}
                exc = g.get("exception") or {}
                http = g.get("http") or {}
                att = g.get("attribution") or {}
                inv = g.get("investigation") or {}
                cands = att.get("candidates") or []
                sugg = (inv.get("suggestions") or [{}])[0] if inv.get("suggestions") else {}
                ex0 = (g.get("examples") or [{}])[0] if g.get("examples") else {}
                row = [
                    g.get("id"), g.get("severity"), g.get("category"), a.get("confidence"), a.get("basis"), g.get("count"),
                    g.get("first_seen"), g.get("last_seen"), g.get("untimed_count"), g.get("level_max"),
                    ";".join(sorted((g.get("services") or {}).keys())), (g.get("hosts") or {}).get("distinct"),
                    g.get("logger"), exc.get("type"), ">".join(t or "?" for t in (exc.get("chain") or [])),
                    http.get("status"), http.get("method"), g.get("error_code"), g.get("template"),
                    att.get("status"), ";".join(c.get("repo", "") for c in cands),
                    cands[0].get("confidence") if cands else None, inv.get("status"), sugg.get("kind"),
                    sugg.get("summary"), ex0.get("input"), ex0.get("line"), g.get("fingerprint"),
                ]
                w.writerow([safe_cell(v) for v in row])
        return [path]
