"""Portable Markdown report (repository issues / PR workflows).

Escaping: every log-derived value in prose or tables passes through :func:`md`, which
neutralises Markdown/HTML structure (pipes, angle brackets, emphasis, headings, links)
and collapses newlines; raw examples go into fenced code blocks whose fence is longer
than any backtick run they contain. Bounds mirror the HTML report and omissions are
disclosed with a pointer to analysis.json.
"""
from __future__ import annotations

import json
import os
import re
from typing import Any, Dict, List

from .. import TOOL_NAME, TOOL_VERSION
from ..investigate import generic_action
from ..config import OUTPUT_FILENAMES, SEVERITIES
from .base import AtomicFile, Exporter

_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_SPECIAL = re.compile(r"([\\`*_\[\]<>|~])")
_LEADING = re.compile(r"^(\s*)([#>+\-]|\d+\.)(?=\s|$)")
_AUTOLINK = re.compile(r"(?i)\b((?:(?:https?|ftps?|ssh|git|file|mailto):/*|www\.))")


def md(value: Any) -> str:
    """Neutralise Markdown/HTML structure in an inline value (newlines collapsed)."""
    if value is None:
        return ""
    s = _CTRL.sub("", str(value)).replace("\r", "").replace("\n", " ")
    s = _SPECIAL.sub(r"\\\1", s)
    s = _LEADING.sub(lambda m: m.group(1) + "\\" + m.group(2), s)
    # GFM autolinks bare URLs (http://..., www....); a zero-width space after the scheme keeps log
    # content from becoming a clickable link while leaving it readable
    s = _AUTOLINK.sub(lambda m: m.group(1) + "\u200b", s)
    return s


def fence(text: str) -> str:
    text = _CTRL.sub("", text or "").replace("\r", "")
    longest = max((len(m.group(0)) for m in re.finditer(r"`+", text)), default=0)
    f = "`" * max(3, longest + 1)
    return "%s\n%s\n%s\n" % (f, text, f)


class MarkdownExporter(Exporter):
    name = "markdown"
    filenames = [OUTPUT_FILENAMES["markdown"]]

    def write(self, analysis, out_dir: str) -> List[str]:
        path = os.path.join(out_dir, self.filenames[0])
        limits = self.limits
        groups: List[Dict[str, Any]] = []
        reported = 0
        for g in analysis.groups():
            reported += 1
            if len(groups) < max(limits.max_report_groups, limits.max_findings_rows):
                groups.append(g)
        with AtomicFile(path) as fh:
            fh.write(self._render(analysis.meta, groups[: limits.max_findings_rows], groups[: limits.max_report_groups], reported))
        return [path]

    def _render(self, meta: Dict[str, Any], rows: List[Dict[str, Any]], detailed: List[Dict[str, Any]], reported: int) -> str:
        limits = self.limits
        status = meta.get("status", {})
        cov = meta.get("coverage", {})
        filt = meta.get("filtering", {})
        inputs = meta.get("inputs", {})
        summary = meta.get("summary", {})
        repos = meta.get("repositories", {})
        o: List[str] = []
        o.append("# log-triage report\n\n")
        o.append("Generated %s by %s %s (schema %s). Completion: **%s**.\n\n" % (md(meta.get("generated_at")), TOOL_NAME, TOOL_VERSION, md(meta.get("schema_version")), md(status.get("completion"))))
        # 1 summary
        o.append("## 1. Executive summary\n\n")
        isum = inputs.get("summary", {})
        tr = cov.get("time_range", {})
        o.append("| Item | Value |\n|---|---|\n")
        o.append("| Inputs | %d file(s): %s processed, %s partial, %s excluded, %s failed; %s bytes read |\n" % (len(inputs.get("files", [])), isum.get("processed", 0), isum.get("partial", 0), isum.get("excluded", 0), isum.get("failed", 0), cov.get("bytes_read", 0)))
        o.append("| Time range | %s to %s (%s timed, %s untimed events) |\n" % (md(tr.get("first") or "unknown"), md(tr.get("last") or "unknown"), cov.get("events_with_timestamp", 0), cov.get("events_without_timestamp", 0)))
        o.append("| Events | %s parsed, %s included (%s filtered by --since, %s untimed excluded) |\n" % (cov.get("events_parsed", 0), cov.get("events_included", 0), cov.get("events_filtered_by_since", 0), cov.get("events_untimed_excluded_by_since", 0)))
        o.append("| Issue groups | %s total, %s reported at or above `%s` (%s below threshold) |\n" % (filt.get("groups_total", 0), filt.get("groups_reported", 0), md(filt.get("min_severity")), filt.get("groups_filtered_by_severity", 0)))
        o.append("| Highest severity | %s |\n" % md(summary.get("highest_severity") or "none"))
        by = summary.get("counts_by_severity", {})
        o.append("| By severity | %s |\n\n" % "; ".join("%s: %s groups / %s events" % (s, by.get(s, {}).get("groups", 0), by.get(s, {}).get("events", 0)) for s in reversed(SEVERITIES)))
        o.append("### Highest-impact findings\n\n")
        for i, t in enumerate(summary.get("top_findings", [])[:10], 1):
            o.append("%d. **%s** (%s, %s, x%s) — %s\n" % (i, md(t["id"]), md(t["severity"]), md(t["category"]), t["count"], md(t["template"][:160])))
        if not summary.get("top_findings"):
            o.append("_No issue groups at or above the severity threshold._\n")
        o.append("\n### Completeness\n\n")
        if status.get("completion") == "complete":
            o.append("Analysis complete.\n")
        else:
            o.append("**Analysis %s.**\n\n" % md(status.get("completion")))
            for r in status.get("reasons", [])[:20]:
                o.append("- %s\n" % md(r))
        if reported > len(detailed):
            o.append("\n_Only the first %d of %d reported groups are detailed (max_report_groups); the full set is in analysis.json / groups.ndjson._\n" % (len(detailed), reported))
        if repos.get("discovered"):
            o.append("\n_Source references were checked against the current checkouts, which may differ from the version that produced the logs._\n")
        # 2 findings
        o.append("\n## 2. Prioritized findings\n\n")
        o.append("Showing %d of %d reported groups (%d total).\n\n" % (len(rows), reported, filt.get("groups_total", 0)))
        o.append("| ID | Severity | Category | Service / repo | Count | Confidence | First | Last | Template | Next action |\n|---|---|---|---|---:|---|---|---|---|---|\n")
        for g in rows:
            a = g.get("assessment") or {}
            att = g.get("attribution") or {}
            cands = att.get("candidates") or []
            repo = cands[0].get("repo", "") if cands else ""
            svc = ", ".join(list((g.get("services") or {}).keys())[:3])
            inv = g.get("investigation") or {}
            sugg = (inv.get("suggestions") or [{}])[0] if inv.get("suggestions") else {}
            action = sugg.get("summary") or generic_action(g.get("category"))
            o.append("| %s | %s | %s | %s%s | %s | %s (%s) | %s | %s | `%s` | %s |\n" % (
                md(g["id"]), md(g["severity"]), md(g["category"]), md(svc) or "n/a", (" [%s]" % md(repo)) if repo else "", g.get("count", 0),
                a.get("confidence", ""), md(a.get("basis", "")), md(g.get("first_seen") or "n/a"), md(g.get("last_seen") or "n/a"),
                g.get("template", "")[:120].replace("`", "'").replace("|", "\\|").replace("\n", " "), md(action[:120])))
        # 3 root cause
        o.append("\n## 3. Root-cause assessment\n\n")
        any_rc = False
        for g in detailed:
            inv = g.get("investigation") or {}
            rc = inv.get("root_cause")
            if not rc:
                continue
            any_rc = True
            o.append("### %s (%s, %s)\n\n" % (md(g["id"]), md(g["severity"]), md(g["category"])))
            o.append("Observed:\n\n" + "".join("- %s\n" % md(x) for x in rc.get("observed", [])))
            o.append("\nHypotheses:\n\n" + ("".join("- %s (confidence %s): %s\n" % (md(h.get("hypothesis")), h.get("confidence"), md("; ".join(h.get("evidence", [])))) for h in rc.get("hypotheses", [])) or "- none\n"))
            o.append("\nUncertainty / alternatives:\n\n" + "".join("- %s\n" % md(x) for x in rc.get("uncertainty", []) + rc.get("alternatives", [])))
            if inv.get("cross_service"):
                o.append("\n> %s\n" % md(inv["cross_service"]))
            o.append("\n")
        if not any_rc:
            o.append("_No root-cause assessment (no repository supplied or no group attributed)._\n")
        # 4 fix plan
        o.append("\n## 4. Fix plan\n\n")
        any_fix = False
        for g in detailed:
            inv = g.get("investigation") or {}
            sugs = inv.get("suggestions") or []
            if not sugs:
                continue
            any_fix = True
            o.append("### %s — %s\n\n" % (md(g["id"]), md(sugs[0].get("summary", "")[:120])))
            for s in sugs[:3]:
                o.append("**%s** (%s, %s, confidence %s)\n\n%s\n\n" % (md(s.get("summary")), md(s.get("kind")), md(s.get("origin")), s.get("confidence"), md(s.get("rationale"))))
                o.append("Suggested changes:\n\n" + "".join("- %s\n" % md(c) for c in s.get("suggested_changes", [])))
                refs = s.get("references") or []
                if refs:
                    o.append("\nSource references:\n\n" + "".join("- `%s:%s` in %s — %s%s\n" % (r.get("path", "").replace("`", "'"), r.get("line") or "?", md(r.get("repo")), "**verified**" if r.get("verified") else "unverified", (": " + md(r.get("note"))) if r.get("note") else "") for r in refs))
                else:
                    o.append("\n_No verified source reference — generic guidance._\n")
                o.append("\nRegression tests:\n\n" + "".join("- %s\n" % md(t) for t in s.get("regression_tests", [])))
                o.append("\nVerification:\n\n" + "".join("- %s\n" % md(t) for t in s.get("verification_steps", [])))
                if s.get("alternatives"):
                    o.append("\nAlternatives:\n\n" + "".join("- %s\n" % md(t) for t in s["alternatives"]))
                for r in refs[:2]:
                    if r.get("snippet"):
                        o.append("\n" + fence(r["snippet"]))
                o.append("\n")
        if not any_fix:
            o.append("_No fix suggestions (repository investigation not enabled or nothing attributed)._\n")
        # 5 issue details (bounded)
        o.append("\n## 5. Issue details\n\n")
        o.append("%d of %d reported groups; examples are redacted and bounded to %d per group.\n\n" % (len(detailed), reported, limits.max_examples_per_group + 1))
        for g in detailed:
            a = g.get("assessment") or {}
            exc = g.get("exception") or {}
            att = g.get("attribution") or {}
            o.append("### %s — %s %s (x%s)\n\n" % (md(g["id"]), md(g["severity"]), md(g["category"]), g.get("count", 0)))
            o.append("- Template: `%s`\n" % g.get("template", "")[:300].replace("`", "'").replace("\n", " "))
            o.append("- Fingerprint: `%s` (v%s)\n" % (g.get("fingerprint"), g.get("fingerprint_version")))
            o.append("- First/last seen: %s / %s%s\n" % (md(g.get("first_seen") or "unknown"), md(g.get("last_seen") or "unknown"), ("; %s without timestamp" % g["untimed_count"]) if g.get("untimed_count") else ""))
            o.append("- Producer levels: %s\n" % md(", ".join("%s x%s" % (k, v) for k, v in (g.get("levels") or {}).items())))
            o.append("- Assessment: confidence %s (%s); %s\n" % (a.get("confidence"), md(a.get("basis")), md("; ".join(a.get("rationale", [])))))
            if g.get("services"):
                o.append("- Services: %s\n" % md(", ".join(g["services"])))
            if exc:
                o.append("- Exception chain: `%s`%s\n" % (" -> ".join(t or "?" for t in (exc.get("chain") or [])).replace("`", "'"), (" — " + md(exc.get("message_template"))) if exc.get("message_template") else ""))
            if g.get("http"):
                o.append("- HTTP: %s %s -> %s\n" % (md(g["http"].get("method") or ""), md(g["http"].get("path_template") or ""), md(g["http"].get("status"))))
            if g.get("error_code"):
                o.append("- Error code: `%s`\n" % str(g["error_code"]).replace("`", "'"))
            o.append("- Grouping: confidence %s; %s\n" % ((g.get("grouping") or {}).get("confidence"), md("; ".join((g.get("grouping") or {}).get("notes", [])))))
            o.append("- Attribution: %s%s\n" % (md(att.get("status", "not attempted")), (" — " + md("; ".join("%s (%s)" % (c.get("repo"), c.get("confidence")) for c in att.get("candidates", [])[:3]))) if att.get("candidates") else ""))
            for ex in (g.get("examples") or [])[: limits.max_examples_per_group + 1]:
                o.append("\nExample `%s:%s` %s %s%s:\n\n" % (str(ex.get("input")).replace("`", "'"), ex.get("line"), md(ex.get("timestamp") or "no timestamp"), md(ex.get("level") or "no level"), " (last seen)" if ex.get("is_last_seen") else ""))
                body = (ex.get("message") or "")[: limits.max_report_example_chars]
                if ex.get("exception_text"):
                    body += "\n" + ex["exception_text"][: limits.max_exception_chars]
                elif ex.get("body"):
                    body += "\n" + ex["body"][: limits.max_exception_chars]
                o.append(fence(body))
            o.append("\n")
        # 6 coverage
        o.append("\n## 6. Coverage and limitations\n\n")
        o.append("| Input | Status | Format (confidence) | Layout / dialect | Events | Lines | Failures | Note |\n|---|---|---|---|---:|---:|---:|---|\n")
        for f in inputs.get("files", [])[:500]:
            o.append("| `%s` | %s | %s (%s) | %s | %s | %s | %s | %s%s |\n" % (str(f.get("path")).replace("`", "'").replace("|", "\\|"), md(f.get("status")), md(f.get("format")), f.get("detection_confidence"), md(f.get("layout") or f.get("dialect") or ""), f.get("events", 0), f.get("lines", 0), f.get("parse_failures", 0), md(f.get("reason") or ""), " (changed during analysis)" if f.get("changed_during_analysis") else ""))
        if inputs.get("unmatched"):
            o.append("\nUnmatched input arguments: %s\n" % md(", ".join(inputs["unmatched"])))
        if inputs.get("excluded_total"):
            o.append("\n%s path(s) excluded before parsing; first entries: %s\n" % (inputs["excluded_total"], md("; ".join("%s (%s)" % (e["path"], e["reason"]) for e in inputs.get("excluded", [])[:10]))))
        diag = meta.get("diagnostics", {})
        o.append("\nDiagnostics: %s total (%s retained). Counts by code: %s\n" % (diag.get("total", 0), len(diag.get("records", [])), md(json.dumps(diag.get("counts_by_code", {})))))
        red = cov.get("redaction", {})
        o.append("\nFilters: --since %s (%s events filtered, %s untimed excluded); --min-severity %s (%s groups / %s events hidden). Redaction %s (%s)%s. %s invalid byte sequences replaced, %s oversized lines truncated, %s parse failures.\n" % (
            md(filt.get("since") or "not set"), cov.get("events_filtered_by_since", 0), cov.get("events_untimed_excluded_by_since", 0), md(filt.get("min_severity")), filt.get("groups_filtered_by_severity", 0), filt.get("events_in_filtered_groups", 0),
            "enabled" if red.get("enabled") else "DISABLED", md(json.dumps(red.get("counts", {}))), "; IPs pseudonymized" if red.get("ips_pseudonymized") else "", cov.get("encoding_replacements", 0), cov.get("truncated_lines", 0), cov.get("parse_failures", 0)))
        if repos.get("discovered"):
            o.append("\nRepositories:\n\n| Repository | Kind | HEAD | Branch | Working tree | Files indexed |\n|---|---|---|---|---|---:|\n")
            for r in repos["discovered"][:200]:
                o.append("| %s | %s | `%s` | %s | %s | %s%s |\n" % (md(r["name"]), md(r["kind"]), (r.get("head") or "unknown")[:12], md(r.get("branch") or "detached/unknown"), "dirty" if r.get("working_tree_dirty") else ("clean" if r.get("working_tree_dirty") is False else "unknown"), r.get("inventory", {}).get("files_indexed", 0), " (truncated)" if r.get("inventory", {}).get("truncated") else ""))
            asum = repos.get("attribution_summary", {})
            isum2 = repos.get("investigation_summary", {})
            o.append("\nAttribution: %s attempted, %s resolved, %s ambiguous, %s unresolved. Investigation: %s attempted, %s with a verified source reference, %s generic, %s not investigated (limit).\n" % (
                asum.get("attempted", 0), asum.get("resolved", 0), asum.get("ambiguous", 0), asum.get("unresolved", 0), isum2.get("attempted", 0), isum2.get("with_verified_reference", 0), isum2.get("generic", 0), isum2.get("not_investigated", 0)))
            if repos.get("incomplete"):
                o.append("\n**Discovery incomplete:** %s\n" % md("; ".join(repos.get("incomplete_reasons", []))))
            o.append("\nSource-version uncertainty: references were verified against the checkouts above; the revision that produced the logs may differ.\n")
        else:
            o.append("\nNo repositories supplied; attribution and fix suggestions were not attempted.\n")
        o.append("\nComplete machine-readable results: `analysis.json` (authoritative), `analysis.sarif`, `groups.ndjson`, `groups.csv`.\n")
        return "".join(o)
