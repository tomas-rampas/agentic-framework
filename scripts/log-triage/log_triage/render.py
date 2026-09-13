"""Render mode: regenerate reports from an existing analysis.json, optionally merging
model-refined suggestions (docs/log-triage/README.md, "Model-assisted refinement").

Groups are loaded into memory (render mode is meant for the standard case of hundreds
to a few thousand groups); the analysis itself is never re-run.
"""
from __future__ import annotations

import json
import os
from typing import Any, Dict, List, Optional, Tuple

from .config import SEVERITY_RANK
from .engine import Analysis
from .inputs import InputSet
from .parsers.jsonstream import JsonItemScanner
from .repos import RepoSet
from .timestamps import format_iso
import time

SUGGESTIONS_SCHEMA_VERSION = "1"
_ALLOWED_KINDS = {"source_backed", "generic"}


STREAM_THRESHOLD_BYTES = 256 * 1024 * 1024   # larger documents are streamed (tests lower this)
_GROUPS_DELIMITER = ',\n "groups": ['           # exactly what exporters/json_exporter.py writes


def load_analysis(path: str, limits) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    size = os.path.getsize(path)
    if size <= STREAM_THRESHOLD_BYTES:
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        groups = doc.pop("groups", [])
        return doc, groups
    # large document: stream the groups array, keep the rest
    scanner = JsonItemScanner([("groups",)], [], limits.max_record_bytes * 4)
    groups: List[Dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), ""):
            for kind, _p, raw, _ln in scanner.feed(chunk):
                if kind == "item" and raw:
                    groups.append(json.loads(raw))
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read(50 * 1024 * 1024)
    # meta = everything before the groups array. The exporter writes the array last, on its own line;
    # a plain search for '"groups"' would stop at filtering.by_severity[*].groups.
    idx = text.find(_GROUPS_DELIMITER)
    if idx < 0:
        raise ValueError("cannot locate the groups array in %s (not written by this tool's JSON exporter?)" % path)
    meta = json.loads(text[:idx] + "}")
    return meta, groups


def merge_suggestions(groups: List[Dict[str, Any]], suggestions_doc: Dict[str, Any]) -> Dict[str, Any]:
    """Merge a model-suggestions document into groups (by id). Returns a summary."""
    by_id = {g.get("id"): g for g in groups}
    entries = suggestions_doc.get("groups") or {}
    applied, unknown, rejected = 0, [], []
    for gid, payload in entries.items():
        g = by_id.get(gid)
        if g is None:
            unknown.append(gid)
            continue
        if not isinstance(payload, dict):
            rejected.append(gid)
            continue
        inv = g.setdefault("investigation", {"status": "not_attempted", "suggestions": [], "source_references": [], "root_cause": None})
        known_refs = {(r.get("repo"), r.get("path"), r.get("line")) for r in inv.get("source_references") or [] if r.get("verified")}
        new_sugs = []
        for s in payload.get("suggestions") or []:
            if not isinstance(s, dict) or not s.get("summary"):
                continue
            refs = []
            for r in s.get("references") or []:
                if not isinstance(r, dict):
                    continue
                key = (r.get("repo"), r.get("path"), r.get("line"))
                refs.append({"repo": r.get("repo"), "path": r.get("path"), "line": r.get("line"),
                             "verified": key in known_refs or bool(r.get("verified_by_reading")),
                             "note": r.get("note") or ("cited by the model" + ("; matches a tool-verified reference" if key in known_refs else "; not verified by the tool")),
                             "snippet": r.get("snippet")})
            kind = s.get("kind") if s.get("kind") in _ALLOWED_KINDS else ("source_backed" if any(r["verified"] for r in refs) else "generic")
            if kind == "source_backed" and not any(r["verified"] for r in refs):
                kind = "generic"
            new_sugs.append({
                "origin": "model", "kind": kind, "summary": str(s.get("summary"))[:300],
                "rationale": str(s.get("rationale") or "")[:2000],
                "suggested_changes": [str(x)[:300] for x in (s.get("suggested_changes") or [])][:10],
                "references": refs[:8],
                "confidence": float(s.get("confidence")) if isinstance(s.get("confidence"), (int, float)) else 0.5,
                "alternatives": [str(x)[:300] for x in (s.get("alternatives") or [])][:5],
                "regression_tests": [str(x)[:300] for x in (s.get("regression_tests") or [])][:6],
                "verification_steps": [str(x)[:300] for x in (s.get("verification_steps") or [])][:6],
            })
        if new_sugs:
            inv["suggestions"] = new_sugs + [s for s in inv.get("suggestions", []) if s.get("origin") != "model"]
        rc = payload.get("root_cause")
        if isinstance(rc, dict):
            if inv.get("root_cause") and inv["root_cause"].get("origin") != "model":
                inv["deterministic_root_cause"] = inv["root_cause"]
            inv["root_cause"] = {"origin": "model",
                                 "observed": [str(x)[:300] for x in (rc.get("observed") or [])][:12],
                                 "hypotheses": [h if isinstance(h, dict) else {"hypothesis": str(h)} for h in (rc.get("hypotheses") or [])][:6],
                                 "uncertainty": [str(x)[:300] for x in (rc.get("uncertainty") or [])][:8],
                                 "alternatives": [str(x)[:300] for x in (rc.get("alternatives") or [])][:6]}
        if payload.get("notes"):
            inv["model_notes"] = str(payload["notes"])[:2000]
        if new_sugs or isinstance(rc, dict):
            inv["status"] = "model_refined"
            inv["model_refinement"] = "applied"
            applied += 1
    return {"applied": applied, "unknown_ids": unknown[:50], "rejected": rejected[:50], "suggestions_schema_version": suggestions_doc.get("schema_version")}


def build_render_analysis(options, analysis_path: str, suggestions_path: Optional[str]) -> Analysis:
    meta, groups = load_analysis(analysis_path, options.limits)
    summary = None
    if suggestions_path:
        with open(suggestions_path, "r", encoding="utf-8") as fh:
            sdoc = json.load(fh)
        if not isinstance(sdoc, dict):
            raise ValueError("suggestions file must contain a JSON object")
        summary = merge_suggestions(groups, sdoc)
        meta.setdefault("status", {})["model_refinement"] = summary
        for g in groups:
            inv = g.get("investigation") or {}
            if inv.get("model_refinement") == "pending":
                inv["model_refinement"] = "not_investigated_by_model"
    meta["rendered_from"] = {"analysis": analysis_path, "suggestions": suggestions_path, "rendered_at": format_iso(time.time())}
    min_rank = SEVERITY_RANK.get(options.min_severity, 0)
    if options.min_severity != meta.get("filtering", {}).get("min_severity"):
        meta.setdefault("filtering", {})["render_min_severity"] = options.min_severity
    a = Analysis(meta, None, min_rank, InputSet(), RepoSet(), None, options.limits.max_output_groups)
    a._override_groups = groups
    return a
