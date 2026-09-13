"""SARIF 2.1.0 export (mapping documented in docs/log-triage/sarif-mapping.md).

One rule and one result per reported issue group. Input-log evidence locations are
``locations`` with ``properties.locationKind = "log-evidence"``; verified source
references are ``relatedLocations`` with ``locationKind = "source-verified"`` (or
``source-unverified``) and a repository ``uriBaseId``. Nothing is invented: a group
without verified source references carries no source location.
"""
from __future__ import annotations

import json
import os
import pathlib
from typing import Any, Dict, List, Optional
from urllib.parse import quote

from .. import INFORMATION_URI, TOOL_NAME, TOOL_VERSION
from ..classify import SEVERITY_TO_RANK100, SEVERITY_TO_SARIF
from ..config import OUTPUT_FILENAMES
from .base import AtomicFile, Exporter

SARIF_SCHEMA = "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json"


def file_uri(path: Optional[str]) -> str:
    if not path:
        return "file:///unknown"
    try:
        return pathlib.Path(os.path.abspath(path)).as_uri()
    except ValueError:
        return "file:///" + quote(path.replace("\\", "/").lstrip("/"))


class SarifExporter(Exporter):
    name = "sarif"
    filenames = [OUTPUT_FILENAMES["sarif"]]

    def write(self, analysis, out_dir: str) -> List[str]:
        path = os.path.join(out_dir, self.filenames[0])
        meta = analysis.meta
        limits = self.limits
        artifacts: List[Dict[str, Any]] = []
        artifact_index: Dict[str, int] = {}
        for f in meta.get("inputs", {}).get("files", []):
            artifact_index[f["path"]] = len(artifacts)
            artifacts.append({
                "location": {"uri": file_uri(f.get("real_path") or f.get("path"))},
                "roles": ["analysisTarget"],
                "length": f.get("size_bytes", -1),
                "properties": {"format": f.get("format"), "detectionConfidence": f.get("detection_confidence"),
                               "status": f.get("status"), "events": f.get("events"), "encoding": f.get("encoding"),
                               "compression": f.get("compression")},
            })
        base_ids: Dict[str, Dict[str, str]] = {}
        repo_by_id: Dict[str, Dict[str, Any]] = {}
        for r in meta.get("repositories", {}).get("discovered", []):
            base_ids["REPO_" + r["id"]] = {"uri": file_uri(r["path"]).rstrip("/") + "/",
                                           "description": {"text": "%s (%s, HEAD %s)" % (r["name"], r["kind"], (r.get("head") or "unknown")[:12])}}
            repo_by_id[r["id"]] = r

        rules: List[Dict[str, Any]] = []
        results: List[Dict[str, Any]] = []
        for idx, g in enumerate(analysis.groups()):
            a = g.get("assessment") or {}
            sev = g.get("severity", "info")
            level = SEVERITY_TO_SARIF[sev]
            template = g.get("template") or ""
            rules.append({
                "id": g["id"],
                "name": (g.get("category") or "unknown").replace("_", "-"),
                "shortDescription": {"text": template[:200] or "(empty message template)"},
                "fullDescription": {"text": "Assessed %s (%s, confidence %.2f, %s). %s" % (
                    sev, g.get("category"), a.get("confidence", 0.0), a.get("basis", "unknown"), " ".join(a.get("rationale", [])[:3]))[:1000]},
                "helpUri": INFORMATION_URI,
                "defaultConfiguration": {"level": level if level != "none" else "note", "enabled": True},
                "properties": {"category": g.get("category"), "severity": sev, "fingerprintVersion": g.get("fingerprint_version"),
                               "tags": ["log-triage", g.get("category") or "unknown", sev]},
            })
            locations: List[Dict[str, Any]] = []
            for ex in (g.get("examples") or [])[: limits.max_examples_per_group + 1]:
                inp = ex.get("input")
                loc: Dict[str, Any] = {"physicalLocation": {"artifactLocation": {"uri": file_uri(inp)}}}
                if inp in artifact_index:
                    loc["physicalLocation"]["artifactLocation"]["index"] = artifact_index[inp]
                region: Dict[str, Any] = {}
                if isinstance(ex.get("line"), int) and ex["line"] >= 1:
                    region["startLine"] = ex["line"]
                    if isinstance(ex.get("line_end"), int) and ex["line_end"] >= ex["line"]:
                        region["endLine"] = ex["line_end"]
                if isinstance(ex.get("byte_offset"), int) and ex["byte_offset"] >= 0:
                    region["byteOffset"] = ex["byte_offset"]
                if region:
                    loc["physicalLocation"]["region"] = region
                loc["message"] = {"text": (ex.get("message") or "")[:500]}
                loc["properties"] = {"locationKind": "log-evidence", "timestamp": ex.get("timestamp"), "level": ex.get("level")}
                locations.append(loc)
            related: List[Dict[str, Any]] = []
            inv = g.get("investigation") or {}
            for ref in (inv.get("source_references") or [])[:8]:
                rid = ref.get("repo_id")
                rel: Dict[str, Any] = {
                    "physicalLocation": {"artifactLocation": {"uri": quote(ref.get("path") or "", safe="/"), "uriBaseId": "REPO_" + str(rid)}},
                    "message": {"text": ("verified source reference: " if ref.get("verified") else "unverified source reference: ") + (ref.get("note") or "")},
                    "properties": {"locationKind": "source-verified" if ref.get("verified") else "source-unverified",
                                   "match": ref.get("match"), "function": ref.get("function"), "repository": ref.get("repo")},
                }
                if isinstance(ref.get("line"), int) and ref["line"] >= 1:
                    rel["physicalLocation"]["region"] = {"startLine": ref["line"]}
                related.append(rel)
            exc = g.get("exception") or {}
            msg = template[:300]
            if exc.get("type"):
                msg = "%s: %s" % (exc["type"], msg) if msg else exc["type"]
            result: Dict[str, Any] = {
                "ruleId": g["id"],
                "ruleIndex": idx,
                "level": level if level != "none" else "note",
                "kind": "informational" if sev == "info" else "fail",
                "message": {"text": "%s (%d occurrence%s, assessed %s %s)" % (msg or "(no message)", g.get("count", 0),
                                                                             "" if g.get("count") == 1 else "s", sev, g.get("category"))},
                "occurrenceCount": g.get("count", 0),
                "rank": SEVERITY_TO_RANK100.get(sev, 0.0),
                "fingerprints": {"logTriage/fingerprint/v%s" % g.get("fingerprint_version", "1"): g.get("fingerprint")},
                "partialFingerprints": {"logTriage/template/v%s" % g.get("fingerprint_version", "1"): g.get("fingerprint", "")[:16]},
                "properties": {
                    "severity": sev, "category": g.get("category"), "confidence": a.get("confidence"), "basis": a.get("basis"),
                    "firstSeen": g.get("first_seen"), "lastSeen": g.get("last_seen"), "untimedCount": g.get("untimed_count"),
                    "levels": g.get("levels"), "services": g.get("services"), "exceptionChain": exc.get("chain"),
                    "httpStatus": (g.get("http") or {}).get("status"), "errorCode": g.get("error_code"),
                    "attribution": {"status": (g.get("attribution") or {}).get("status"),
                                    "candidates": [{"repo": c.get("repo"), "confidence": c.get("confidence")} for c in (g.get("attribution") or {}).get("candidates", [])[:3]]},
                    "investigationStatus": inv.get("status"),
                    "suggestions": [{"kind": s.get("kind"), "summary": s.get("summary"), "confidence": s.get("confidence")} for s in (inv.get("suggestions") or [])[:3]],
                    "groupingConfidence": (g.get("grouping") or {}).get("confidence"),
                },
            }
            if locations:
                result["locations"] = locations
            if related:
                result["relatedLocations"] = related
            results.append(result)

        diags = meta.get("diagnostics", {})
        notifications = []
        for d in diags.get("records", [])[:50]:
            notifications.append({"level": {"error": "error", "warning": "warning", "info": "note"}.get(d.get("severity"), "note"),
                                  "message": {"text": "%s: %s" % (d.get("code"), d.get("message"))},
                                  "descriptor": {"id": d.get("code")},
                                  "properties": {"input": d.get("input"), "line": d.get("line"), "count": d.get("count")}})
        status = meta.get("status", {})
        run: Dict[str, Any] = {
            "tool": {"driver": {"name": TOOL_NAME, "version": TOOL_VERSION, "informationUri": INFORMATION_URI,
                                "semanticVersion": TOOL_VERSION, "rules": rules}},
            "invocations": [{"executionSuccessful": status.get("completion") in ("complete", "partial"),
                             "exitCode": status.get("exit_code") if isinstance(status.get("exit_code"), int) else 0,
                             "startTimeUtc": meta.get("analysis_started_at"), "endTimeUtc": meta.get("generated_at"),
                             "toolExecutionNotifications": notifications,
                             "properties": {"completion": status.get("completion"), "reasons": status.get("reasons")}}],
            "artifacts": artifacts,
            "results": results,
            "columnKind": "utf16CodeUnits",
            "properties": {
                "schemaVersion": meta.get("schema_version"),
                "coverage": meta.get("coverage"),
                "filtering": meta.get("filtering"),
                "note": ("Results describe runtime log issue groups, not static-analysis findings. Locations point into the "
                         "analysed log files; source locations appear only as relatedLocations and only when verified in a "
                         "repository checkout. Not every SARIF consumer renders runtime-log results meaningfully."),
            },
        }
        if base_ids:
            run["originalUriBaseIds"] = base_ids
        doc = {"$schema": SARIF_SCHEMA, "version": "2.1.0", "runs": [run]}
        with AtomicFile(path) as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=1, default=str)
            fh.write("\n")
        return [path]
