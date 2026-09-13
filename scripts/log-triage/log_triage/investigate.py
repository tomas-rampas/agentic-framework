"""Deterministic source investigation and fix suggestions.

For attributed groups: resolve in-app frames to repository files, read a bounded
snippet, verify that the referenced symbol appears near the referenced line, search
for message literals when no frame verified, and produce category-specific suggestion
templates. Suggestions are ``source_backed`` only when at least one reference was
verified in the checkout; otherwise they are ``generic`` troubleshooting guidance and
say so. Nothing here modifies source code. The compact ``investigation_queue`` is what
the slash command hands to the model for targeted refinement.
"""
from __future__ import annotations

import os
import re
from typing import Any, Dict, List, Optional, Tuple

from .repos import Repo, RepoSet, SOURCE_EXTENSIONS
from .attribute import _path_score


def _read_lines(path: str, max_bytes: int) -> Optional[List[str]]:
    try:
        if os.path.getsize(path) > max_bytes:
            return None
        with open(path, "rb") as fh:
            data = fh.read(max_bytes)
    except OSError:
        return None
    return data.decode("utf-8", "replace").split("\n")


def _symbol_tokens(function: Optional[str]) -> List[str]:
    if not function:
        return []
    f = re.sub(r"\(.*\)$", "", function)
    f = re.sub(r"\$\$Lambda.*$", "", f)
    parts = re.split(r"[.:/#>-]+|::", f)
    toks = [p for p in parts if p and re.match(r"^[A-Za-z_]\w*$", p) and p not in ("<lambda>", "lambda", "main", "run", "invoke", "call", "async", "anonymous")]
    return toks[-2:] if toks else []


def resolve_reference(frame: Dict[str, Any], repo: Repo, limits) -> Optional[Dict[str, Any]]:
    file = frame.get("file")
    if not file:
        return None
    sc, matched, kind = _path_score(file, repo)
    if not matched or sc < 0.15:
        return None
    ambiguous = kind == "basename" and len(repo.inventory.basenames.get(file.replace("\\", "/").rsplit("/", 1)[-1], [])) > 1
    ref: Dict[str, Any] = {"repo_id": repo.id, "repo": repo.name, "path": matched, "line": frame.get("line"),
                           "function": frame.get("function"), "match": kind, "verified": False, "note": None, "snippet": None}
    if ambiguous:
        ref["note"] = "basename matches several files in the repository; reference not verified"
        return ref
    lines = _read_lines(os.path.join(repo.path, matched), limits.max_repo_file_bytes)
    if lines is None:
        ref["note"] = "file could not be read or exceeds max_repo_file_bytes"
        return ref
    line = frame.get("line")
    toks = _symbol_tokens(frame.get("function"))
    if isinstance(line, int) and line >= 1:
        if line > len(lines):
            ref["note"] = "line %d is beyond end of file (%d lines): the checkout likely differs from the version that produced the log" % (line, len(lines))
            return ref
        lo, hi = max(0, line - 1 - limits.max_snippet_lines // 2), min(len(lines), line - 1 + limits.max_snippet_lines // 2 + 1)
        window = "\n".join(lines[lo:hi])
        ref["snippet"] = "\n".join("%5d%s %s" % (i + 1, ">" if i + 1 == line else " ", lines[i][:200]) for i in range(lo, hi))
        if toks:
            found = [t for t in toks if re.search(r"\b" + re.escape(t) + r"\b", window)]
            if found:
                ref["verified"] = True
                ref["note"] = "symbol %s found within %d lines of line %d" % ("/".join(found), limits.max_snippet_lines // 2, line)
            else:
                ref["note"] = "symbol %s not found near line %d; the checkout may differ from the deployed version" % ("/".join(toks), line)
        else:
            ref["verified"] = True
            ref["note"] = "file and line exist in the checkout (no symbol to cross-check)"
        return ref
    # no line: locate the symbol in the file
    if toks:
        for i, text in enumerate(lines):
            if all(re.search(r"\b" + re.escape(t) + r"\b", text) for t in toks[-1:]):
                ref["line"] = i + 1
                lo, hi = max(0, i - limits.max_snippet_lines // 2), min(len(lines), i + limits.max_snippet_lines // 2 + 1)
                ref["snippet"] = "\n".join("%5d%s %s" % (j + 1, ">" if j == i else " ", lines[j][:200]) for j in range(lo, hi))
                ref["verified"] = True
                ref["note"] = "symbol %s located at line %d (log carried no line number)" % (toks[-1], i + 1)
                return ref
        ref["note"] = "symbol %s not found in file" % "/".join(toks)
    else:
        ref["note"] = "file exists in the checkout; no line or symbol to verify"
    return ref


def _literal_fragment(template: str) -> Optional[str]:
    parts = re.split(r"<[a-z0-9:-]+>|[\"'`{}\[\]()]", template)
    best = ""
    for p in parts:
        p = p.strip(" :,;-.")
        if len(p) > len(best) and re.search(r"[A-Za-z]{4,}", p):
            best = p
    return best if len(best) >= 12 else None


def search_literal(fragment: str, repo: Repo, limits) -> List[Dict[str, Any]]:
    hits: List[Dict[str, Any]] = []
    scanned = 0
    scanned_bytes = 0
    budget = 50_000_000
    needle = fragment.lower()
    for rel in repo.inventory.files:
        if os.path.splitext(rel)[1].lower() not in SOURCE_EXTENSIONS:
            continue
        if scanned >= limits.max_literal_search_files or scanned_bytes >= budget:
            break
        scanned += 1
        full = os.path.join(repo.path, rel)
        try:
            size = os.path.getsize(full)
            if size > limits.max_repo_file_bytes:
                continue
            with open(full, "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        scanned_bytes += len(data)
        low = data.lower()
        if needle.encode("utf-8") not in low:
            continue
        text = data.decode("utf-8", "replace")
        for i, ln in enumerate(text.split("\n")):
            if needle in ln.lower():
                hits.append({"repo_id": repo.id, "repo": repo.name, "path": rel, "line": i + 1, "match": "message-literal",
                             "verified": True, "note": "message text %r found in source" % fragment[:60],
                             "snippet": "%5d> %s" % (i + 1, ln.strip()[:200])})
                if len(hits) >= limits.max_literal_search_hits:
                    return hits
    return hits


_SUGGESTIONS: Dict[str, Dict[str, Any]] = {
    "timeout": {
        "summary": "Bound the slow call and make its failure explicit",
        "rationale": "The group is dominated by timeout evidence; the code path at the referenced location waits on a dependency without a bounded, observable deadline.",
        "changes": ["set explicit connect/read timeouts at the call site", "add a bounded retry with exponential backoff and jitter only for idempotent operations", "include the dependency name and elapsed time in the logged error"],
        "tests": ["unit test with a stalled/fake dependency asserting the call fails within the configured timeout", "regression test that the timeout error carries the dependency name"],
        "verify": ["reproduce against a stalled dependency in staging", "confirm the group's occurrence count stops growing after deploy (re-run log-triage on new logs)"],
        "alternatives": ["make the operation asynchronous and idempotent so the caller does not block"],
    },
    "dependency_failure": {
        "summary": "Isolate the failing dependency call and fail fast with diagnostic context",
        "rationale": "Errors reference a downstream dependency (connection refused/reset, upstream errors). The calling code should distinguish dependency outages from local bugs.",
        "changes": ["wrap the dependency call with a circuit breaker or health gate", "log endpoint, operation and correlation id on failure", "review connection pool sizing and keep-alive settings"],
        "tests": ["integration test with the dependency unavailable asserting a clean, typed error", "test that retries stop after the configured budget"],
        "verify": ["check the dependency's own logs/health for the same time range", "confirm error rate drops when the dependency recovers"],
        "alternatives": ["queue work for later processing when the dependency is down"],
    },
    "network": {
        "summary": "Harden network error handling at the call site",
        "rationale": "Network-level failures (DNS, TLS, resets) dominate; the code should retry transient failures and surface persistent ones clearly.",
        "changes": ["classify transient vs. persistent network errors", "retry transient errors with backoff", "surface TLS/DNS details in the error"],
        "tests": ["unit test injecting connection reset / DNS failure"],
        "verify": ["correlate with infrastructure changes (DNS, certificates, load balancer) in the time window"],
        "alternatives": [],
    },
    "application_crash": {
        "summary": "Guard the failing code path and convert the crash into a handled error",
        "rationale": "The exception type/termination marker indicates an unhandled failure at the referenced frame (null/nil dereference, index out of range, panic, or unhandled exception).",
        "changes": ["validate inputs and optional values before dereferencing at the referenced line", "return a domain error (or Result) instead of panicking/throwing", "add a top-level handler that logs context and keeps the process alive where appropriate"],
        "tests": ["regression test using the exact input shape from the log example (null/empty/out-of-range)"],
        "verify": ["re-run the failing request with the fix; confirm no crash group with this fingerprint appears"],
        "alternatives": ["make the invariant impossible by construction (non-nullable types, bounded collections)"],
    },
    "resource_exhaustion": {
        "summary": "Find the unbounded allocation or leak and add limits",
        "rationale": "Out-of-memory, disk-full, pool- or descriptor-exhaustion evidence points to unbounded growth or missing release near the referenced code.",
        "changes": ["bound queues/caches/pools near the referenced code", "ensure handles/connections are released in finally/using/defer blocks", "align container memory limits with runtime heap settings"],
        "tests": ["load test asserting memory/handle counts stay flat", "unit test for resource release on the error path"],
        "verify": ["watch memory/descriptor metrics after deploy", "confirm no OOM-kill events in new logs"],
        "alternatives": ["backpressure the producer instead of buffering"],
    },
    "data_integrity": {
        "summary": "Make the write idempotent and validate consistency before committing",
        "rationale": "Constraint/checksum/corruption evidence indicates conflicting or invalid writes at the referenced location.",
        "changes": ["add uniqueness/consistency checks before the write", "use upsert or optimistic concurrency with retry", "add a repair/migration step for already-affected rows"],
        "tests": ["test concurrent writers producing the conflict", "test that corrupted input is rejected with a clear error"],
        "verify": ["run a consistency check over affected data", "confirm the group disappears from new logs"],
        "alternatives": ["serialize the writes through a single owner"],
    },
    "auth": {
        "summary": "Verify credential provisioning and expiry handling",
        "rationale": "Authentication/authorization failures; distinguish expected client behaviour from misconfigured or expired credentials.",
        "changes": ["refresh tokens before expiry and retry once on 401", "log the principal/client id (never the secret) with the failure", "return a specific error for missing vs. invalid credentials"],
        "tests": ["test expired-token refresh path", "test that a missing credential fails fast at startup"],
        "verify": ["check whether failures cluster on one client/principal"],
        "alternatives": [],
    },
    "configuration": {
        "summary": "Validate configuration at startup and fail fast with a clear message",
        "rationale": "Missing files/settings/environment variables are detected late, at the point of use.",
        "changes": ["validate required settings during startup", "document defaults and required environment variables", "reject unknown or invalid values with the offending key in the message"],
        "tests": ["test startup with the setting missing asserting a clear error", "test default values"],
        "verify": ["compare the deployed configuration with the documented required set"],
        "alternatives": [],
    },
    "availability": {
        "summary": "Check upstream health and readiness handling for the failing operation",
        "rationale": "5xx responses/health-check failures indicate requests failing at the service boundary.",
        "changes": ["return 503 with Retry-After while dependencies are unavailable instead of 500", "review readiness/liveness probes and startup ordering", "add timeouts and retries where the referenced code calls upstreams"],
        "tests": ["test the handler with the upstream failing asserting the intended status code"],
        "verify": ["compare the group's time window with deployments/restarts", "confirm 5xx rate drops after the fix"],
        "alternatives": ["shed load or degrade gracefully instead of failing requests"],
    },
    "client_error": {
        "summary": "Return structured validation errors and check client integrations",
        "rationale": "Repeated 4xx responses usually indicate a client integration bug or missing validation feedback.",
        "changes": ["return field-level validation errors", "log the client identity for repeated failures"],
        "tests": ["contract tests for the affected endpoint"],
        "verify": ["identify the client producing most failures via request ids"],
        "alternatives": [],
    },
    "performance": {
        "summary": "Profile the slow operation and bound retries",
        "rationale": "Latency/retry evidence; the referenced code path is slow or retrying excessively.",
        "changes": ["add caching, pagination or an index for the slow operation", "cap retries and add backoff", "instrument the operation with timing metrics"],
        "tests": ["performance test with a latency budget"],
        "verify": ["confirm p95 latency improves after deploy"],
        "alternatives": [],
    },
    "security": {
        "summary": "Review the authentication surface and rate-limit repeated failures",
        "rationale": "Security-relevant failures (failed logins, invalid signatures); evidence does not by itself establish an incident.",
        "changes": ["rate-limit and alert on repeated failures per source", "verify signature/certificate validation settings"],
        "tests": ["test lockout/rate limiting behaviour"],
        "verify": ["cross-check sources against known clients"],
        "alternatives": [],
    },
}
_GENERIC = {
    "summary": "Increase diagnostic context around the failing operation",
    "rationale": "No category-specific evidence; the group needs more context (correlation ids, inputs, dependency names) before a targeted fix.",
    "changes": ["log correlation/request ids and the operation inputs (redacted) at the failure point", "convert generic error messages into typed errors"],
    "tests": ["add a test that reproduces the failure once the cause is known"],
    "verify": ["re-run log-triage with a repository to obtain source references"],
    "alternatives": [],
}


def generic_action(category: Optional[str]) -> str:
    """Category-level next action used when no repository investigation ran (generic guidance)."""
    tpl = _SUGGESTIONS.get(category or "", _GENERIC)
    return tpl["summary"] + " (generic guidance; no source investigation)"


def build_suggestion(group: Dict[str, Any], references: List[Dict[str, Any]], repos: RepoSet) -> Dict[str, Any]:
    cat = group.get("category") or "unknown"
    tpl = _SUGGESTIONS.get(cat, _GENERIC)
    verified = [r for r in references if r.get("verified")]
    kind = "source_backed" if verified else "generic"
    loc = ""
    if verified:
        r = verified[0]
        loc = " at %s:%s (%s)" % (r["path"], r.get("line") or "?", r["repo"])
    summary = tpl["summary"] + loc
    conf = 0.6 if verified else 0.3
    if group.get("assessment", {}).get("basis") == "observed":
        conf += 0.15
    rationale = tpl["rationale"]
    if not verified:
        rationale += " No source reference could be verified in the available checkouts, so this is generic guidance, not a source-backed fix."
    else:
        rationale += " Reference verified in the checkout (%s)." % "; ".join(r["note"] for r in verified[:2] if r.get("note"))
    return {
        "origin": "deterministic",
        "kind": kind,
        "summary": summary,
        "rationale": rationale,
        "suggested_changes": list(tpl["changes"]),
        "references": references[:6],
        "confidence": round(min(0.9, conf), 2),
        "alternatives": list(tpl["alternatives"]),
        "regression_tests": list(tpl["tests"]),
        "verification_steps": list(tpl["verify"]),
    }


def root_cause_assessment(group: Dict[str, Any], references: List[Dict[str, Any]], repos: RepoSet) -> Dict[str, Any]:
    exc = group.get("exception") or {}
    a = group.get("assessment") or {}
    observed = [
        "%d occurrence(s) between %s and %s" % (group.get("count", 0), group.get("first_seen") or "unknown", group.get("last_seen") or "unknown"),
        "producer level(s): %s" % ", ".join("%s x%d" % (k, v) for k, v in (group.get("levels") or {}).items()),
    ]
    if exc.get("chain"):
        observed.append("exception chain: %s" % " -> ".join(t or "?" for t in exc["chain"]))
    if group.get("http"):
        observed.append("HTTP status %s" % group["http"].get("status"))
    if group.get("services"):
        observed.append("services: %s" % ", ".join(group["services"]))
    hyp = []
    if a.get("category") and a.get("category") != "unknown":
        hyp.append({"hypothesis": "%s failure at %s" % (a["category"].replace("_", " "), (references[0]["path"] + ":" + str(references[0].get("line")) if references else "an unresolved code location")),
                    "evidence": a.get("rationale", [])[:3], "confidence": a.get("confidence", 0.3)})
    uncertainty = ["the analysed checkout (%s) may not be the version that produced the log" % ", ".join(
        "%s@%s%s" % (r["repo"], (r.get("head") or "unknown")[:12], " (dirty)" if r.get("dirty") else "") for r in (
            [{"repo": rp.name, "head": rp.head, "dirty": rp.dirty} for rp in repos.repos][:3]))] if repos.repos else []
    if not references:
        uncertainty.append("no source reference resolved; the root cause location is inferred from the message only")
    elif not any(r.get("verified") for r in references):
        uncertainty.append("source references resolved by path but not verified (symbol/line mismatch)")
    if a.get("basis") == "inferred":
        uncertainty.append("category inferred from message wording, not from an explicit error type or status")
    alt = ["the message may be a symptom of an upstream failure sharing the same time window (check correlated groups)"]
    return {"observed": observed, "hypotheses": hyp, "uncertainty": uncertainty, "alternatives": alt}


def investigate_all(store, repos: RepoSet, limits, options) -> Dict[str, Any]:
    from .aggregate import acc_to_dict
    summary = {"attempted": 0, "with_verified_reference": 0, "generic": 0, "insufficient_evidence": 0,
               "not_investigated": 0, "queue": []}
    queue: List[Dict[str, Any]] = []
    if not repos.repos:
        return summary
    import itertools
    n = 0
    # attribution only exists on the first max_attributed_groups groups, so that prefix is all that
    # can be investigated; it is materialised as a bounded list (the store may be disk-backed)
    for acc in list(itertools.islice(store.iter_accs(), limits.max_attributed_groups)):
        att = acc.attribution or {}
        if n >= limits.max_investigations:
            if att.get("status") in ("resolved", "ambiguous"):
                acc.investigation = {"status": "not_investigated", "reason": "max_investigations (%d) reached" % limits.max_investigations,
                                     "suggestions": [], "source_references": [], "root_cause": None}
                store.update_acc(acc)
                summary["not_investigated"] += 1
            continue
        if att.get("status") not in ("resolved", "ambiguous"):
            if acc.attribution is not None:
                acc.investigation = {"status": "insufficient_evidence", "reason": att.get("reason") or "no repository attributed",
                                     "suggestions": [], "source_references": [], "root_cause": None}
                store.update_acc(acc)
                summary["insufficient_evidence"] += 1
            continue
        n += 1
        summary["attempted"] += 1
        g = acc_to_dict(acc, store.input_paths)
        refs: List[Dict[str, Any]] = []
        cands = [c for c in att.get("candidates", []) if c.get("confidence", 0) >= 0.4][:3]
        exc = g.get("exception") or {}
        frames = [f for f in (exc.get("frames") or []) if f.get("in_app")][:8]
        for c in cands:
            repo = repos.by_id(c["repo_id"])
            if repo is None:
                continue
            for f in frames:
                r = resolve_reference(f, repo, limits)
                if r is not None:
                    refs.append(r)
                if len(refs) >= 6:
                    break
        if not any(r.get("verified") for r in refs):
            frag = _literal_fragment(g.get("template") or "")
            if frag:
                for c in cands[:2]:
                    repo = repos.by_id(c["repo_id"])
                    if repo is not None:
                        refs.extend(search_literal(frag, repo, limits))
                    if any(r.get("verified") for r in refs):
                        break
        suggestion = build_suggestion(g, refs, repos)
        rc = root_cause_assessment(g, refs, repos)
        cross = [c["repo"] for c in cands[1:]] if len(cands) > 1 else []
        inv = {"status": "deterministic", "suggestions": [suggestion], "source_references": refs[:8], "root_cause": rc,
               "cross_service": ("evidence also matches %s; check for a cross-service failure" % ", ".join(cross)) if cross else None,
               "model_refinement": "pending"}
        acc.investigation = inv
        store.update_acc(acc)
        if suggestion["kind"] == "source_backed":
            summary["with_verified_reference"] += 1
        else:
            summary["generic"] += 1
        if len(queue) < limits.max_model_queue_groups:
            queue.append(_queue_entry(g, refs, suggestion, limits))
    summary["queue"] = queue
    return summary


def _queue_entry(g: Dict[str, Any], refs: List[Dict[str, Any]], suggestion: Dict[str, Any], limits) -> Dict[str, Any]:
    budget = limits.max_model_context_chars
    exc = g.get("exception") or {}
    entry = {
        "id": g["id"],
        "severity": g.get("severity"),
        "category": g.get("category"),
        "count": g.get("count"),
        "template": (g.get("template") or "")[:300],
        "exception": {"chain": exc.get("chain"), "message_template": (exc.get("message_template") or "")[:200],
                      "top_frames": [{"function": f.get("function"), "file": f.get("file"), "line": f.get("line")} for f in (exc.get("frames") or [])[:5]]} if exc else None,
        "candidates": [{"repo": c["repo"], "confidence": c["confidence"]} for c in (g.get("attribution") or {}).get("candidates", [])[:3]],
        "references": [],
        "deterministic_suggestion": suggestion["summary"],
        "questions": [
            "Does the referenced code explain the observed message/exception, or is the failure upstream?",
            "Which concrete change (file:line) addresses the root cause, and what regression test proves it?",
        ],
    }
    used = len(str(entry))
    for r in refs[:4]:
        snippet = (r.get("snippet") or "")
        if used + len(snippet) > budget:
            snippet = snippet[: max(0, budget - used)]
        entry["references"].append({"repo": r["repo"], "path": r["path"], "line": r.get("line"), "verified": r.get("verified"),
                                    "note": r.get("note"), "snippet": snippet})
        used += len(snippet) + 80
        if used >= budget:
            break
    return entry
