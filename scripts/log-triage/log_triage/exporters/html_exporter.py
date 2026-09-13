"""Offline, self-contained HTML report (docs/log-triage/README.md, "HTML report").

Security: every log-derived string passes through :func:`esc` (HTML entity escaping,
control characters stripped); nothing from the logs is emitted as markup or script. The
page ships a Content-Security-Policy that forbids remote resources. Bounds: at most
``max_findings_rows`` findings rows and ``max_report_groups`` detailed groups, with
``max_examples_per_group`` examples of ``max_report_example_chars`` each; omitted
material is disclosed with a pointer to analysis.json.
"""
from __future__ import annotations

import html
import json
import os
import re
from typing import Any, Dict, List, Optional

from .. import TOOL_NAME, TOOL_VERSION
from ..investigate import generic_action
from ..config import OUTPUT_FILENAMES, SEVERITIES
from .base import AtomicFile, Exporter

_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def esc(value: Any) -> str:
    if value is None:
        return ""
    return html.escape(_CTRL.sub("", str(value)), quote=True)


_CSS = """
:root{--bg:#fff;--fg:#1b1f23;--muted:#586069;--line:#d0d7de;--crit:#8b0000;--high:#c62828;--med:#ef6c00;--low:#f9a825;--info:#2e7d32;--accent:#0b5fff}
*{box-sizing:border-box}body{margin:0;font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:var(--fg);background:var(--bg)}
header{padding:16px 24px;border-bottom:1px solid var(--line)}header h1{margin:0 0 4px;font-size:20px}header .meta{color:var(--muted);font-size:13px}
nav{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:6px 24px;z-index:2}nav a{margin-right:14px;color:var(--accent);text-decoration:none}nav a:focus,nav a:hover{text-decoration:underline}
main{padding:12px 24px 48px;max-width:1400px}section{margin:28px 0}h2{font-size:17px;border-bottom:1px solid var(--line);padding-bottom:4px}h3{font-size:15px;margin:14px 0 6px}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid var(--line);padding:4px 6px;vertical-align:top;text-align:left}th{background:#f6f8fa;cursor:pointer;user-select:none;white-space:nowrap}th[aria-sort]::after{content:" \\2195";color:var(--muted)}
.badge{display:inline-block;padding:1px 7px;border-radius:10px;color:#fff;font-size:12px;font-weight:600}.sev-critical{background:var(--crit)}.sev-high{background:var(--high)}.sev-medium{background:var(--med)}.sev-low{background:var(--low);color:#000}.sev-info{background:var(--info)}
.status-complete{color:var(--info);font-weight:600}.status-partial{color:var(--med);font-weight:600}.status-failed{color:var(--high);font-weight:600}
pre{background:#f6f8fa;border:1px solid var(--line);padding:8px;overflow:auto;white-space:pre-wrap;word-break:break-word;font-size:12px;max-height:340px}code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px}
details{border:1px solid var(--line);border-radius:4px;padding:6px 10px;margin:8px 0}summary{cursor:pointer;font-weight:600}details[open]>summary{margin-bottom:6px}
.controls{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:8px 0}.controls label{font-size:13px}.controls input[type=search]{padding:4px 6px;min-width:260px}
.muted{color:var(--muted)}.kv{display:grid;grid-template-columns:max-content 1fr;gap:2px 12px;font-size:13px}.kv div:nth-child(odd){color:var(--muted)}
.note{background:#fff8e1;border:1px solid #ffe082;padding:8px 10px;border-radius:4px;margin:8px 0}.warn{background:#fdecea;border-color:#f5c2c0}
.tl{width:100%;height:170px;border:1px solid var(--line);background:#fafbfc}.tl rect:hover{opacity:.8}
ul.compact{margin:4px 0;padding-left:18px}.hidden{display:none}button{font:inherit;padding:3px 9px}
@media print{nav,.controls,button{display:none}details{page-break-inside:avoid}details>*{display:block}pre{max-height:none}main{max-width:none}}
"""

_JS = r"""
(function(){
  var rows=[].slice.call(document.querySelectorAll('#findings-table tbody tr'));
  var blocks=[].slice.call(document.querySelectorAll('details.group'));
  var q=document.getElementById('q'),cat=document.getElementById('f-cat'),repo=document.getElementById('f-repo');
  var sevBoxes=[].slice.call(document.querySelectorAll('input.f-sev'));
  var shown=document.getElementById('shown');
  function visible(el){
    var t=(q.value||'').toLowerCase(), s=el.getAttribute('data-severity'), c=el.getAttribute('data-category'), r=el.getAttribute('data-repo')||'';
    var sevOk=sevBoxes.some(function(b){return b.checked&&b.value===s;});
    if(!sevOk) return false;
    if(cat.value&&cat.value!==c) return false;
    if(repo.value&&repo.value!==r) return false;
    if(t&&(el.getAttribute('data-search')||'').indexOf(t)<0) return false;
    return true;
  }
  function apply(){
    var n=0;
    rows.forEach(function(tr){var v=visible(tr);tr.classList.toggle('hidden',!v);if(v)n++;});
    blocks.forEach(function(d){d.classList.toggle('hidden',!visible(d));});
    shown.textContent=n;
  }
  [q,cat,repo].forEach(function(e){e.addEventListener('input',apply);});
  sevBoxes.forEach(function(b){b.addEventListener('change',apply);});
  var ths=[].slice.call(document.querySelectorAll('#findings-table th[data-col]'));
  ths.forEach(function(th){
    function sort(){
      var col=th.getAttribute('data-col'),num=th.getAttribute('data-num')==='1',dir=th.getAttribute('aria-sort')==='ascending'?-1:1;
      ths.forEach(function(o){if(o!==th)o.removeAttribute('aria-sort');});
      th.setAttribute('aria-sort',dir===1?'ascending':'descending');
      var tb=th.closest('table').tBodies[0];
      rows.sort(function(a,b){var x=a.getAttribute('data-'+col)||'',y=b.getAttribute('data-'+col)||'';
        if(num){x=parseFloat(x)||0;y=parseFloat(y)||0;return (x-y)*dir;} return x<y?-dir:x>y?dir:0;});
      rows.forEach(function(r){tb.appendChild(r);});
    }
    th.addEventListener('click',sort);
    th.setAttribute('tabindex','0');
    th.addEventListener('keydown',function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault();sort();}});
  });
  var ea=document.getElementById('expand-all'),ca=document.getElementById('collapse-all');
  if(ea)ea.addEventListener('click',function(){blocks.forEach(function(d){d.open=true;});});
  if(ca)ca.addEventListener('click',function(){blocks.forEach(function(d){d.open=false;});});
  apply();
})();
"""


def _fmt_int(n: Any) -> str:
    try:
        return "{:,}".format(int(n))
    except (TypeError, ValueError):
        return esc(n)


def _badge(sev: str) -> str:
    return '<span class="badge sev-%s">%s</span>' % (esc(sev), esc(sev))


def _timeline_svg(tl: Dict[str, Any]) -> str:
    buckets = tl.get("buckets") or []
    if not buckets:
        return '<p class="muted">No events with a usable timestamp; the timeline is empty.</p>'
    w, h, pad = 1000, 160, 22
    n = len(buckets)
    maxv = max(b["total"] for b in buckets) or 1
    bw = max(1.0, (w - 2 * pad) / float(n))
    parts = ['<svg class="tl" viewBox="0 0 %d %d" role="img" aria-label="events per time bucket">' % (w, h)]
    parts.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#999"/>' % (pad, h - pad, w - pad, h - pad))
    for i, b in enumerate(buckets):
        counts = b.get("counts") or {}
        total = b["total"]
        bh = (h - 2 * pad) * total / float(maxv)
        x = pad + i * bw
        y = h - pad - bh
        if counts.get("fatal") or counts.get("error"):
            color = "#c62828"
        elif counts.get("warn"):
            color = "#ef6c00"
        else:
            color = "#2e7d32"
        title = "%s .. %s: %d event(s) (%s)" % (b["start"], b["end"], total, ", ".join("%s %d" % (k, v) for k, v in counts.items()))
        parts.append('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s"><title>%s</title></rect>' % (x, y, max(0.5, bw - 0.5), bh, color, esc(title)))
    parts.append('<text x="%d" y="%d" font-size="11" fill="#555">%s</text>' % (pad, h - 6, esc(buckets[0]["start"])))
    parts.append('<text x="%d" y="%d" font-size="11" fill="#555" text-anchor="end">%s</text>' % (w - pad, h - 6, esc(buckets[-1]["end"])))
    parts.append('<text x="%d" y="%d" font-size="11" fill="#555">max %d</text>' % (pad, 14, maxv))
    parts.append("</svg>")
    return "".join(parts)


class HtmlExporter(Exporter):
    name = "html"
    filenames = [OUTPUT_FILENAMES["html"]]

    def write(self, analysis, out_dir: str) -> List[str]:
        path = os.path.join(out_dir, self.filenames[0])
        meta = analysis.meta
        limits = self.limits
        groups: List[Dict[str, Any]] = []
        reported = 0
        for g in analysis.groups():
            reported += 1
            if len(groups) < max(limits.max_report_groups, limits.max_findings_rows):
                groups.append(g)
        detailed = groups[: limits.max_report_groups]
        rows = groups[: limits.max_findings_rows]
        with AtomicFile(path) as fh:
            fh.write(self._render(meta, rows, detailed, reported))
        return [path]

    # ------------------------------------------------------------------
    def _render(self, meta: Dict[str, Any], rows: List[Dict[str, Any]], detailed: List[Dict[str, Any]], reported: int) -> str:
        limits = self.limits
        status = meta.get("status", {})
        cov = meta.get("coverage", {})
        filt = meta.get("filtering", {})
        inputs = meta.get("inputs", {})
        summary = meta.get("summary", {})
        repos = meta.get("repositories", {})
        tl = meta.get("timeline", {})
        o: List[str] = []
        o.append('<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
        o.append('<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; script-src \'unsafe-inline\'; img-src data:;">')
        o.append('<title>log-triage report</title><style>%s</style></head><body>' % _CSS)
        o.append('<header><h1>log-triage report</h1><div class="meta">Generated %s by %s %s &middot; schema %s &middot; completion: <span class="status-%s">%s</span></div></header>' % (
            esc(meta.get("generated_at")), esc(TOOL_NAME), esc(TOOL_VERSION), esc(meta.get("schema_version")), esc(status.get("completion")), esc(status.get("completion"))))
        o.append('<nav aria-label="Sections"><a href="#summary">Summary</a><a href="#findings">Findings</a><a href="#timeline">Timeline</a><a href="#issues">Issue details</a><a href="#rootcause">Root cause</a><a href="#fixplan">Fix plan</a><a href="#coverage">Coverage &amp; limitations</a></nav><main>')

        # 1. executive summary ------------------------------------------------------
        files = inputs.get("files", [])
        isum = inputs.get("summary", {})
        o.append('<section id="summary"><h2>1. Executive summary</h2><div class="kv">')
        o.append('<div>Scope</div><div>%d input file(s) (%s processed, %s partial, %s excluded, %s failed), %s bytes read; formats: %s</div>' % (
            len(files), _fmt_int(isum.get("processed", 0)), _fmt_int(isum.get("partial", 0)), _fmt_int(isum.get("excluded", 0)), _fmt_int(isum.get("failed", 0)),
            _fmt_int(cov.get("bytes_read", 0)), esc(", ".join(sorted({str(f.get("format")) for f in files})) or "none")))
        tr = cov.get("time_range", {})
        o.append('<div>Time range</div><div>%s &rarr; %s (%s events with timestamps, %s without)</div>' % (
            esc(tr.get("first") or "unknown"), esc(tr.get("last") or "unknown"), _fmt_int(cov.get("events_with_timestamp", 0)), _fmt_int(cov.get("events_without_timestamp", 0))))
        o.append('<div>Events</div><div>%s parsed, %s included after filters (%s filtered by --since, %s untimed excluded)</div>' % (
            _fmt_int(cov.get("events_parsed", 0)), _fmt_int(cov.get("events_included", 0)), _fmt_int(cov.get("events_filtered_by_since", 0)), _fmt_int(cov.get("events_untimed_excluded_by_since", 0))))
        o.append('<div>Issue groups</div><div>%s total, %s reported at or above <code>%s</code> (%s below threshold)</div>' % (
            _fmt_int(filt.get("groups_total", 0)), _fmt_int(filt.get("groups_reported", 0)), esc(filt.get("min_severity")), _fmt_int(filt.get("groups_filtered_by_severity", 0))))
        o.append('<div>Highest severity</div><div>%s</div>' % (_badge(summary.get("highest_severity")) if summary.get("highest_severity") else "none"))
        by = summary.get("counts_by_severity", {})
        o.append('<div>By severity</div><div>%s</div>' % " ".join('%s %s groups / %s events' % (_badge(s), _fmt_int(by.get(s, {}).get("groups", 0)), _fmt_int(by.get(s, {}).get("events", 0))) for s in reversed(SEVERITIES)))
        o.append('</div>')
        o.append('<h3>Highest-impact findings</h3><ol>')
        for t in summary.get("top_findings", [])[:10]:
            o.append('<li><a href="#g-%s">%s</a> %s <code>%s</code> &times;%s &mdash; %s</li>' % (esc(t["id"]), esc(t["id"]), _badge(t["severity"]), esc(t["category"]), _fmt_int(t["count"]), esc(t["template"][:160])))
        if not summary.get("top_findings"):
            o.append('<li class="muted">No issue groups at or above the severity threshold.</li>')
        o.append('</ol><h3>Completeness</h3>')
        if status.get("completion") == "complete":
            o.append('<p class="status-complete">Analysis complete.</p>')
        else:
            o.append('<div class="note warn"><strong>Analysis %s.</strong><ul class="compact">%s</ul></div>' % (esc(status.get("completion")), "".join("<li>%s</li>" % esc(r) for r in status.get("reasons", [])[:20])))
        lim_notes = []
        if reported > len(detailed):
            lim_notes.append("Only the first %d of %d reported groups are detailed below (max_report_groups); the complete set is in analysis.json / groups.ndjson." % (len(detailed), reported))
        if reported > len(rows):
            lim_notes.append("The findings table shows the first %d of %d reported groups (max_findings_rows)." % (len(rows), reported))
        if meta.get("diagnostics", {}).get("total"):
            lim_notes.append("%s diagnostic(s) were recorded during parsing; see section 7." % _fmt_int(meta["diagnostics"]["total"]))
        if repos.get("incomplete"):
            lim_notes.append("Repository discovery was incomplete: %s." % esc("; ".join(repos.get("incomplete_reasons", []))))
        if repos.get("discovered"):
            lim_notes.append("Source references were checked against the current checkouts, which may not match the version that produced the logs.")
        if lim_notes:
            o.append('<ul>%s</ul>' % "".join("<li>%s</li>" % esc(n) for n in lim_notes))
        o.append('</section>')

        # 2. findings ------------------------------------------------------------------
        cats = sorted({g["category"] for g in rows})
        repo_names = sorted({(g.get("attribution") or {}).get("candidates", [{}])[0].get("repo", "") for g in rows if (g.get("attribution") or {}).get("candidates")})
        o.append('<section id="findings"><h2>2. Prioritized findings</h2>')
        o.append('<div class="controls"><label>Search <input type="search" id="q" placeholder="template, exception, service, id" aria-label="Search findings"></label>')
        o.append('<span>Severity: %s</span>' % " ".join('<label><input type="checkbox" class="f-sev" value="%s" checked> %s</label>' % (s, s) for s in reversed(SEVERITIES)))
        o.append('<label>Category <select id="f-cat"><option value="">all</option>%s</select></label>' % "".join('<option value="%s">%s</option>' % (esc(c), esc(c)) for c in cats))
        o.append('<label>Repository <select id="f-repo"><option value="">all</option>%s</select></label>' % "".join('<option value="%s">%s</option>' % (esc(r), esc(r)) for r in repo_names if r))
        o.append('<button type="button" id="expand-all">Expand all</button><button type="button" id="collapse-all">Collapse all</button>')
        o.append('<span class="muted">Showing <span id="shown">%d</span> of %d listed (%d reported, %d total groups). Search and filters cover only the groups included in this report.</span></div>' % (len(rows), len(rows), reported, filt.get("groups_total", 0)))
        o.append('<table id="findings-table"><thead><tr><th scope="col" data-col="id">ID</th><th scope="col" data-col="sevrank" data-num="1">Severity</th><th scope="col" data-col="category">Category</th><th scope="col" data-col="service">Service / repository</th><th scope="col" data-col="count" data-num="1">Count</th><th scope="col" data-col="confidence" data-num="1">Confidence</th><th scope="col" data-col="first">First seen</th><th scope="col" data-col="last">Last seen</th><th scope="col">Template</th><th scope="col">Next action</th></tr></thead><tbody>')
        sev_rank = {s: i for i, s in enumerate(SEVERITIES)}
        for g in rows:
            a = g.get("assessment") or {}
            att = g.get("attribution") or {}
            cands = att.get("candidates") or []
            repo = cands[0].get("repo", "") if cands else ""
            svc = ", ".join(list((g.get("services") or {}).keys())[:3])
            inv = g.get("investigation") or {}
            sugg = (inv.get("suggestions") or [{}])[0] if inv.get("suggestions") else {}
            action = sugg.get("summary") or generic_action(g.get("category"))
            search = " ".join([g["id"], g.get("template", ""), " ".join(t or "" for t in ((g.get("exception") or {}).get("chain") or [])), svc, repo, g.get("category", "")]).lower()
            o.append('<tr data-severity="%s" data-sevrank="%d" data-category="%s" data-repo="%s" data-service="%s" data-count="%d" data-confidence="%s" data-first="%s" data-last="%s" data-id="%s" data-search="%s">' % (
                esc(g["severity"]), sev_rank.get(g["severity"], 0), esc(g["category"]), esc(repo), esc(svc), g.get("count", 0), esc(a.get("confidence", 0)), esc(g.get("first_seen") or ""), esc(g.get("last_seen") or ""), esc(g["id"]), esc(search[:600])))
            o.append('<td><a href="#g-%s">%s</a></td><td>%s</td><td>%s</td><td>%s%s</td><td>%s</td><td>%s (%s)</td><td>%s</td><td>%s</td><td><code>%s</code></td><td>%s</td></tr>' % (
                esc(g["id"]), esc(g["id"]), _badge(g["severity"]), esc(g["category"]), esc(svc) or '<span class="muted">n/a</span>',
                (' <span class="muted">[%s]</span>' % esc(repo)) if repo else "", _fmt_int(g.get("count", 0)), esc(a.get("confidence", "")), esc(a.get("basis", "")),
                esc(g.get("first_seen") or "n/a"), esc(g.get("last_seen") or "n/a"), esc(g.get("template", "")[:200]), esc(action[:200])))
        o.append('</tbody></table></section>')

        # 3. timeline -------------------------------------------------------------------
        o.append('<section id="timeline"><h2>3. Timeline</h2>')
        o.append('<p class="muted">Bucket size %s s (%s bucket(s)%s). %s event(s) have no usable timestamp and are not on the timeline. Coverage is limited to the processed inputs and the time range above.</p>' % (
            _fmt_int(tl.get("bucket_seconds", 0)), _fmt_int(tl.get("bucket_count", 0)), "; coarsened to respect max_timeline_buckets" if tl.get("coarsened") else "", _fmt_int(tl.get("events_without_timestamp", 0))))
        o.append(_timeline_svg(tl))
        o.append('</section>')

        # 4. issue details --------------------------------------------------------------
        o.append('<section id="issues"><h2>4. Issue details</h2><p class="muted">%d of %d reported groups detailed; examples are redacted and bounded to %d per group.</p>' % (len(detailed), reported, limits.max_examples_per_group + 1))
        for g in detailed:
            o.append(self._group_block(g))
        o.append('</section>')

        # 5. root cause -------------------------------------------------------------------
        o.append('<section id="rootcause"><h2>5. Root-cause assessment</h2>')
        any_rc = False
        for g in detailed:
            inv = g.get("investigation") or {}
            rc = inv.get("root_cause")
            if not rc:
                continue
            any_rc = True
            o.append('<details class="group" data-severity="%s" data-category="%s" data-repo="%s" data-search="%s"><summary>%s %s &mdash; %s</summary>' % (
                esc(g["severity"]), esc(g["category"]), esc(self._repo_of(g)), esc(g["id"].lower()), esc(g["id"]), _badge(g["severity"]), esc(g.get("template", "")[:120])))
            o.append('<h3>Observed</h3><ul class="compact">%s</ul>' % "".join("<li>%s</li>" % esc(x) for x in rc.get("observed", [])))
            o.append('<h3>Hypotheses</h3><ul class="compact">%s</ul>' % ("".join("<li>%s <span class=\"muted\">(confidence %s)</span><ul class=\"compact\">%s</ul></li>" % (esc(h.get("hypothesis")), esc(h.get("confidence")), "".join("<li>%s</li>" % esc(e) for e in h.get("evidence", []))) for h in rc.get("hypotheses", [])) or '<li class="muted">none</li>'))
            o.append('<h3>Uncertainty and alternatives</h3><ul class="compact">%s</ul>' % "".join("<li>%s</li>" % esc(x) for x in (rc.get("uncertainty", []) + rc.get("alternatives", []))))
            if inv.get("cross_service"):
                o.append('<p class="note">%s</p>' % esc(inv["cross_service"]))
            o.append('</details>')
        if not any_rc:
            o.append('<p class="muted">No root-cause assessment: supply <code>--repo</code> or <code>--repos-dir</code> to enable source investigation, or no group could be attributed.</p>')
        o.append('</section>')

        # 6. fix plan ------------------------------------------------------------------------
        o.append('<section id="fixplan"><h2>6. Fix plan</h2>')
        any_fix = False
        for g in detailed:
            inv = g.get("investigation") or {}
            sugs = inv.get("suggestions") or []
            if not sugs:
                continue
            any_fix = True
            o.append('<details class="group" data-severity="%s" data-category="%s" data-repo="%s" data-search="%s"><summary>%s %s &mdash; %s</summary>' % (
                esc(g["severity"]), esc(g["category"]), esc(self._repo_of(g)), esc(g["id"].lower()), esc(g["id"]), _badge(g["severity"]), esc(sugs[0].get("summary", "")[:140])))
            for s in sugs[:3]:
                o.append('<h3>%s <span class="muted">(%s, %s, confidence %s)</span></h3><p>%s</p>' % (esc(s.get("summary")), esc(s.get("kind")), esc(s.get("origin")), esc(s.get("confidence")), esc(s.get("rationale"))))
                o.append('<div class="kv"><div>Suggested changes</div><div><ul class="compact">%s</ul></div>' % "".join("<li>%s</li>" % esc(c) for c in s.get("suggested_changes", [])))
                refs = s.get("references") or []
                o.append('<div>Source references</div><div>%s</div>' % ("<ul class=\"compact\">%s</ul>" % "".join(
                    '<li><code>%s:%s</code> in %s &mdash; %s%s</li>' % (esc(r.get("path")), esc(r.get("line") or "?"), esc(r.get("repo")), "<strong>verified</strong>" if r.get("verified") else "unverified", (": " + esc(r.get("note"))) if r.get("note") else "") for r in refs) if refs else '<span class="muted">none verified &mdash; generic guidance</span>'))
                o.append('<div>Regression tests</div><div><ul class="compact">%s</ul></div><div>Verification</div><div><ul class="compact">%s</ul></div>' % (
                    "".join("<li>%s</li>" % esc(t) for t in s.get("regression_tests", [])), "".join("<li>%s</li>" % esc(t) for t in s.get("verification_steps", []))))
                if s.get("alternatives"):
                    o.append('<div>Alternatives</div><div><ul class="compact">%s</ul></div>' % "".join("<li>%s</li>" % esc(t) for t in s["alternatives"]))
                o.append('</div>')
                for r in refs[:3]:
                    if r.get("snippet"):
                        o.append('<pre><code>%s</code></pre>' % esc(r["snippet"]))
            o.append('</details>')
        if not any_fix:
            o.append('<p class="muted">No fix suggestions: repository investigation was not enabled or no group could be attributed to a repository.</p>')
        o.append('</section>')

        # 7. coverage & limitations ---------------------------------------------------------
        o.append('<section id="coverage"><h2>7. Coverage and limitations</h2>')
        o.append('<h3>Inputs</h3><table><thead><tr><th scope="col">Path</th><th scope="col">Status</th><th scope="col">Format (confidence)</th><th scope="col">Layout / dialect</th><th scope="col">Events</th><th scope="col">Lines</th><th scope="col">Bytes</th><th scope="col">Failures</th><th scope="col">Note</th></tr></thead><tbody>')
        for f in files[:500]:
            o.append('<tr><td><code>%s</code></td><td>%s</td><td>%s (%s)</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s%s</td></tr>' % (
                esc(f.get("path")), esc(f.get("status")), esc(f.get("format")), esc(f.get("detection_confidence")), esc(f.get("layout") or f.get("dialect") or ""),
                _fmt_int(f.get("events", 0)), _fmt_int(f.get("lines", 0)), _fmt_int(f.get("bytes_read", 0)), _fmt_int(f.get("parse_failures", 0)), esc(f.get("reason") or ""),
                " (changed during analysis)" if f.get("changed_during_analysis") else ""))
        o.append('</tbody></table>')
        if inputs.get("unmatched"):
            o.append('<p class="note warn">Unmatched input arguments: %s</p>' % esc(", ".join(inputs["unmatched"])))
        if inputs.get("excluded_total"):
            o.append('<p>%s path(s) excluded before parsing (extension, binary, unsupported compression or limits); first entries: %s</p>' % (_fmt_int(inputs["excluded_total"]), esc("; ".join("%s (%s)" % (e["path"], e["reason"]) for e in inputs.get("excluded", [])[:10]))))
        diag = meta.get("diagnostics", {})
        o.append('<h3>Parsing diagnostics</h3><p>%s diagnostic(s), %s retained records (%s dropped).</p>' % (_fmt_int(diag.get("total", 0)), _fmt_int(len(diag.get("records", []))), _fmt_int(diag.get("records_dropped", 0))))
        if diag.get("counts_by_code"):
            o.append('<table><thead><tr><th scope="col">Code</th><th scope="col">Count</th></tr></thead><tbody>%s</tbody></table>' % "".join("<tr><td><code>%s</code></td><td>%s</td></tr>" % (esc(k), _fmt_int(v)) for k, v in diag["counts_by_code"].items()))
        if diag.get("records"):
            o.append('<details><summary>First %d diagnostic records</summary><table><thead><tr><th scope="col">Code</th><th scope="col">Severity</th><th scope="col">Input</th><th scope="col">Line</th><th scope="col">Count</th><th scope="col">Message</th></tr></thead><tbody>%s</tbody></table></details>' % (
                min(200, len(diag["records"])), "".join('<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>' % (
                    esc(d.get("code")), esc(d.get("severity")), esc(d.get("input") or ""), esc(d.get("line") or ""), esc(d.get("count")), esc(d.get("message"))) for d in diag["records"][:200])))
        o.append('<h3>Filters and redaction</h3><div class="kv">')
        o.append('<div>--since</div><div>%s (%s events filtered, %s untimed events excluded)</div>' % (esc(filt.get("since") or "not set"), _fmt_int(filt.get("events_filtered_by_since", cov.get("events_filtered_by_since", 0))), _fmt_int(cov.get("events_untimed_excluded_by_since", 0))))
        o.append('<div>--min-severity</div><div>%s (%s groups / %s events below threshold not shown)</div>' % (esc(filt.get("min_severity")), _fmt_int(filt.get("groups_filtered_by_severity", 0)), _fmt_int(filt.get("events_in_filtered_groups", 0))))
        red = cov.get("redaction", {})
        o.append('<div>Redaction</div><div>%s; replacements by kind: %s%s</div>' % ("enabled" if red.get("enabled") else "DISABLED", esc(json.dumps(red.get("counts", {}))), "; IPs pseudonymized" if red.get("ips_pseudonymized") else ""))
        o.append('<div>Encoding / truncation</div><div>%s invalid byte sequences replaced, %s oversized lines truncated (%s bytes discarded), %s parse failures</div>' % (
            _fmt_int(cov.get("encoding_replacements", 0)), _fmt_int(cov.get("truncated_lines", 0)), _fmt_int(cov.get("discarded_bytes", 0)), _fmt_int(cov.get("parse_failures", 0))))
        agg = meta.get("aggregation", {})
        o.append('<div>Aggregation</div><div>%s groups; spill-to-disk %s (%s spill(s), peak temp %s bytes)</div></div>' % (
            _fmt_int(agg.get("groups_total", 0)), "used" if agg.get("spilled_to_disk") else "not needed", _fmt_int(agg.get("spill_count", 0)), _fmt_int(agg.get("temp_bytes_peak", 0))))
        o.append('<h3>Repositories</h3>')
        if repos.get("discovered"):
            o.append('<table><thead><tr><th scope="col">Repository</th><th scope="col">Kind</th><th scope="col">Path</th><th scope="col">HEAD</th><th scope="col">Branch</th><th scope="col">Working tree</th><th scope="col">Files indexed</th></tr></thead><tbody>%s</tbody></table>' % "".join(
                '<tr><td>%s</td><td>%s</td><td><code>%s</code></td><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s%s</td></tr>' % (
                    esc(r["name"]), esc(r["kind"]), esc(r["path"]), esc((r.get("head") or "unknown")[:12]), esc(r.get("branch") or "detached/unknown"),
                    esc("dirty" if r.get("working_tree_dirty") else ("clean" if r.get("working_tree_dirty") is False else "unknown")),
                    _fmt_int(r.get("inventory", {}).get("files_indexed", 0)), " (truncated)" if r.get("inventory", {}).get("truncated") else "") for r in repos["discovered"][:200]))
            asum = repos.get("attribution_summary", {})
            isum2 = repos.get("investigation_summary", {})
            o.append('<p>Attribution attempted for %s groups: %s resolved, %s ambiguous, %s unresolved. Investigation: %s attempted, %s with a verified source reference, %s generic, %s not investigated (limit).</p>' % (
                _fmt_int(asum.get("attempted", 0)), _fmt_int(asum.get("resolved", 0)), _fmt_int(asum.get("ambiguous", 0)), _fmt_int(asum.get("unresolved", 0)),
                _fmt_int(isum2.get("attempted", 0)), _fmt_int(isum2.get("with_verified_reference", 0)), _fmt_int(isum2.get("generic", 0)), _fmt_int(isum2.get("not_investigated", 0))))
            o.append('<p class="note">Source-version uncertainty: references were verified against the checkouts listed above. The revision that produced the logs may differ; line numbers and symbols were cross-checked and mismatches are reported per reference.</p>')
            if repos.get("skipped_total"):
                o.append('<p>%s path(s) skipped during discovery (dependency/build directories, symlinks, depth or count limits).</p>' % _fmt_int(repos["skipped_total"]))
            if repos.get("incomplete"):
                o.append('<p class="note warn">Discovery incomplete: %s</p>' % esc("; ".join(repos.get("incomplete_reasons", []))))
        else:
            o.append('<p class="muted">No repositories were supplied; attribution and fix suggestions were not attempted.</p>')
        o.append('<p class="muted">Complete machine-readable results: <code>analysis.json</code> (authoritative), <code>analysis.sarif</code>, <code>groups.ndjson</code>, <code>groups.csv</code> in the same output directory.</p>')
        o.append('</section></main><footer class="muted" style="padding:12px 24px;border-top:1px solid #d0d7de">%s %s &middot; log content is untrusted data and is rendered escaped.</footer>' % (esc(TOOL_NAME), esc(TOOL_VERSION)))
        o.append('<script>%s</script></body></html>\n' % _JS)
        return "\n".join(o)

    @staticmethod
    def _repo_of(g: Dict[str, Any]) -> str:
        cands = (g.get("attribution") or {}).get("candidates") or []
        return cands[0].get("repo", "") if cands else ""

    def _group_block(self, g: Dict[str, Any]) -> str:
        limits = self.limits
        a = g.get("assessment") or {}
        exc = g.get("exception") or {}
        att = g.get("attribution") or {}
        grp = g.get("grouping") or {}
        svc = ", ".join(list((g.get("services") or {}).keys())[:5])
        repo = self._repo_of(g)
        search = " ".join([g["id"], g.get("template", ""), " ".join(t or "" for t in (exc.get("chain") or [])), svc, repo, g.get("category", "")]).lower()
        o = ['<details class="group" id="g-%s" data-severity="%s" data-category="%s" data-repo="%s" data-search="%s"><summary>%s %s <code>%s</code> &times;%s &mdash; %s</summary>' % (
            esc(g["id"]), esc(g["severity"]), esc(g["category"]), esc(repo), esc(search[:600]), esc(g["id"]), _badge(g["severity"]), esc(g["category"]), _fmt_int(g.get("count", 0)), esc(g.get("template", "")[:160]))]
        o.append('<div class="kv"><div>Template</div><div><code>%s</code></div>' % esc(g.get("template", "")[:limits.max_report_example_chars]))
        o.append('<div>Fingerprint</div><div><code>%s</code> (v%s)</div>' % (esc(g.get("fingerprint")), esc(g.get("fingerprint_version"))))
        o.append('<div>Occurrences</div><div>%s (first %s, last %s%s)</div>' % (_fmt_int(g.get("count", 0)), esc(g.get("first_seen") or "unknown"), esc(g.get("last_seen") or "unknown"), (", %s without timestamp" % _fmt_int(g["untimed_count"])) if g.get("untimed_count") else ""))
        o.append('<div>Producer levels</div><div>%s</div>' % esc(", ".join("%s x%s" % (k, v) for k, v in (g.get("levels") or {}).items())))
        o.append('<div>Assessment</div><div>%s %s &mdash; confidence %s (%s)<ul class="compact">%s</ul></div>' % (_badge(g["severity"]), esc(g["category"]), esc(a.get("confidence")), esc(a.get("basis")), "".join("<li>%s</li>" % esc(r) for r in a.get("rationale", []))))
        if a.get("impact_signals"):
            o.append('<div>Impact signals</div><div>%s</div>' % esc(", ".join(a["impact_signals"])))
        if svc:
            o.append('<div>Services</div><div>%s</div>' % esc(svc))
        hosts = g.get("hosts") or {}
        if hosts.get("distinct"):
            o.append('<div>Hosts</div><div>%s distinct%s</div>' % (hosts["distinct"], " (bounded sample)" if hosts.get("truncated") else ""))
        if g.get("logger"):
            o.append('<div>Logger</div><div><code>%s</code></div>' % esc(g["logger"]))
        if g.get("http"):
            o.append('<div>HTTP</div><div>%s %s &rarr; %s</div>' % (esc(g["http"].get("method") or ""), esc(g["http"].get("path_template") or ""), esc(g["http"].get("status"))))
        if g.get("error_code"):
            o.append('<div>Error code</div><div><code>%s</code></div>' % esc(g["error_code"]))
        if exc:
            o.append('<div>Exception chain</div><div><code>%s</code>%s</div>' % (esc(" -> ".join(t or "?" for t in (exc.get("chain") or []))), (" &mdash; " + esc(exc.get("message_template"))) if exc.get("message_template") else ""))
            if exc.get("frames"):
                o.append('<div>Top frames</div><div><pre><code>%s</code></pre></div>' % esc("\n".join("%s%s" % (f.get("function") or "?", (" (%s%s)" % (f.get("file"), (":%s" % f["line"]) if f.get("line") else "")) if f.get("file") else "") + ("" if f.get("in_app") else "  [framework]") for f in exc["frames"][:8])))
        corr = g.get("correlation") or {}
        if corr.get("trace_ids") or corr.get("request_ids"):
            o.append('<div>Correlation ids</div><div>%s%s</div>' % (esc("; ".join(corr.get("trace_ids", []) + corr.get("request_ids", []))), " (more not retained)" if corr.get("truncated") else ""))
        o.append('<div>Grouping</div><div>confidence %s &mdash; %s</div>' % (esc(grp.get("confidence")), esc("; ".join(grp.get("notes", [])))))
        o.append('<div>Attribution</div><div>%s%s%s</div>' % (esc(att.get("status", "not attempted")), (": " + esc(att.get("reason"))) if att.get("reason") else "", ("<ul class=\"compact\">%s</ul>" % "".join(
            "<li>%s (confidence %s): %s</li>" % (esc(c.get("repo")), esc(c.get("confidence")), esc("; ".join("%s %s" % (e.get("kind"), e.get("matched") or e.get("value")) for e in c.get("evidence", [])[:4]))) for c in att.get("candidates", [])[:3])) if att.get("candidates") else ""))
        o.append('</div><h3>Examples (redacted)</h3>')
        for ex in (g.get("examples") or [])[: limits.max_examples_per_group + 1]:
            loc = "%s:%s%s" % (ex.get("input"), ex.get("line"), ("-%s" % ex["line_end"]) if ex.get("line_end") else "")
            o.append('<div class="muted">%s &middot; %s &middot; %s%s%s</div>' % (esc(loc), esc(ex.get("timestamp") or "no timestamp"), esc(ex.get("level") or "no level"), " &middot; byte offset %s" % esc(ex["byte_offset"]) if ex.get("byte_offset") is not None else "", " &middot; last seen" if ex.get("is_last_seen") else ""))
            o.append('<pre><code>%s</code></pre>' % esc((ex.get("message") or "")[: limits.max_report_example_chars]))
            if ex.get("exception_text"):
                o.append('<pre><code>%s</code></pre>' % esc(ex["exception_text"][: limits.max_exception_chars]))
            elif ex.get("body"):
                o.append('<div class="muted">continuation lines:</div><pre><code>%s</code></pre>' % esc(ex["body"][: limits.max_exception_chars]))
            if ex.get("attributes"):
                o.append('<div class="muted">attributes: <code>%s</code></div>' % esc(json.dumps(ex["attributes"], ensure_ascii=False, sort_keys=True)[:600]))
        o.append('</details>')
        return "\n".join(o)
