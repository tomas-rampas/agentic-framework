"""Evidence-based repository attribution for issue groups.

Each candidate repository receives a score from independent evidence kinds:
  path       frame/message file path matches an inventory path (full > 2 trailing
             components > basename only; a basename alone never resolves attribution)
  namespace  frame symbol / logger / exception type namespace prefix matches a repository
             namespace (JVM packages, .NET root namespaces, Go module path, Python
             packages, Ruby/Elixir modules, PHP PSR-4 prefixes)
  service    a service/application identity equals a repository, package or manifest name
Status: resolved (top >= 0.6 and a clear margin), ambiguous (top >= 0.4 without margin),
unresolved (no candidate >= 0.4). Weak evidence is reported, never used alone.
"""
from __future__ import annotations

import re
from typing import Any, Dict, List, Optional, Tuple

from .repos import Repo, RepoSet, SOURCE_EXTENSIONS

_PATH_IN_TEXT = re.compile(r"(?:[A-Za-z]:\\|/)?(?:[\w.-]+[\\/])+[\w.-]+\.(?:cs|java|kt|scala|py|ts|tsx|js|go|rs|cc|cpp|c|h|hpp|m|mm|swift|php|rb|ex|exs|erl|ps1|sql)\b")


def _norm_name(n: str) -> str:
    return re.sub(r"[^a-z0-9]", "", n.lower())


def _path_score(path: str, repo: Repo) -> Tuple[float, Optional[str], str]:
    """Return (score, matched inventory path, kind)."""
    inv = repo.inventory
    p = path.replace("\\", "/").lstrip("./")
    base = p.rsplit("/", 1)[-1]
    cands = inv.basenames.get(base)
    if not cands:
        return 0.0, None, "none"
    comps = [c for c in p.split("/") if c and c != "."]
    best = 0.0
    best_path = None
    kind = "basename"
    for cand in cands:
        cc = cand.split("/")
        n = 0
        while n < len(comps) and n < len(cc) and comps[-1 - n] == cc[-1 - n]:
            n += 1
        if n >= len(cc) and n >= 2:
            score, k = 0.6, "path"
        elif n >= 3:
            score, k = 0.5, "path"
        elif n == 2:
            score, k = 0.4, "path"
        else:
            score, k = 0.15, "basename"
        if len(cands) > 1 and k == "basename":
            score = 0.1
        if score > best:
            best, best_path, kind = score, cand, k
    return best, best_path, kind


def _ns_candidates(symbol: str) -> List[str]:
    """Namespace prefixes to try for a symbol like com.acme.orders.OrderService.place or Acme.Orders.Api.X."""
    out: List[str] = []
    sym = symbol.replace("::", ".").replace("/", ".")
    parts = [p for p in sym.split(".") if p]
    for n in (3, 2, 1):
        if len(parts) > n:
            out.append(".".join(parts[:n]))
    return out


def _ns_score(symbol: str, repo: Repo) -> Tuple[float, Optional[str]]:
    nss = repo.inventory.namespaces
    if not nss:
        return 0.0, None
    lower = {n.lower(): n for n in nss}
    for cand in _ns_candidates(symbol):
        hit = lower.get(cand.lower())
        if hit:
            return (0.5 if cand.count(".") >= 1 else 0.3), hit
    # Go: symbol like github.com/acme/orders/internal/x.Func
    for ns in nss:
        if "/" in ns and symbol.startswith(ns):
            return 0.5, ns
    return 0.0, None


def attribute_group(group: Dict[str, Any], repos: RepoSet, limits) -> Dict[str, Any]:
    scores: Dict[str, float] = {}
    evidence: Dict[str, List[Dict[str, Any]]] = {}

    def add(repo: Repo, kind: str, value: str, matched: Optional[str], weight: float) -> None:
        if weight <= 0:
            return
        ev = evidence.setdefault(repo.id, [])
        if any(e["kind"] == kind and e["value"] == value for e in ev):
            return
        ev.append({"kind": kind, "value": value[:200], "matched": matched, "weight": round(weight, 2)})
        scores[repo.id] = scores.get(repo.id, 0.0) + weight

    exc = group.get("exception") or {}
    frames = [f for f in (exc.get("frames") or []) if f.get("in_app")][:12]
    symbols: List[str] = []
    for f in frames:
        if f.get("function"):
            symbols.append(f["function"])
    if group.get("logger"):
        symbols.append(group["logger"])
    for t in (exc.get("chain") or []):
        if t and ("." in t or "::" in t):
            symbols.append(t)
    services = list((group.get("services") or {}).keys())
    template = group.get("template") or ""
    mentioned_paths = _PATH_IN_TEXT.findall(template)[:5]

    for repo in repos.repos:
        for f in frames:
            if f.get("file"):
                sc, matched, kind = _path_score(f["file"], repo)
                if sc:
                    add(repo, kind, f["file"], matched, sc)
        for p in mentioned_paths:
            sc, matched, kind = _path_score(p, repo)
            if sc:
                add(repo, kind + "-in-message", p, matched, sc * 0.8)
        for sym in symbols:
            sc, matched = _ns_score(sym, repo)
            if sc:
                add(repo, "namespace", sym, matched, sc)
        for svc in services:
            n = _norm_name(svc)
            if n and (n in repo.inventory.names or svc.lower() in repo.inventory.names):
                add(repo, "service", svc, repo.name, 0.5)
        if repo.name.lower() in template.lower() and len(repo.name) >= 4:
            add(repo, "name-in-message", repo.name, repo.name, 0.1)

    cands = []
    for rid, sc in scores.items():
        repo = repos.by_id(rid)
        kinds = {e["kind"] for e in evidence[rid]}
        strong = any(k in ("path", "namespace", "service", "path-in-message") for k in kinds)
        conf = min(1.0, sc)
        if not strong:
            conf = min(conf, 0.3)   # basename-only / name-in-message evidence is never sufficient
        cands.append({"repo_id": rid, "repo": repo.name if repo else rid, "path": repo.path if repo else None,
                      "head": repo.head if repo else None, "confidence": round(conf, 2), "evidence": evidence[rid]})
    cands.sort(key=lambda c: (-c["confidence"], c["repo"]))
    result: Dict[str, Any] = {"candidates": cands[:5]}
    if not cands:
        result["status"] = "unresolved"
        result["reason"] = "no path, namespace or service evidence matched any discovered repository"
    else:
        top = cands[0]["confidence"]
        second = cands[1]["confidence"] if len(cands) > 1 else 0.0
        if len(cands) > 1 and cands[0].get("head") and cands[0]["head"] == cands[1]["head"] and top == second:
            # identical checkouts (a repository and its worktree, or two clones at the same commit)
            result["note"] = "candidates %s and %s are at the same commit; attributing to %s" % (
                cands[0]["repo"], cands[1]["repo"], cands[0]["repo"])
            second = 0.0
        if top >= 0.6 and top - second >= 0.2:
            result["status"] = "resolved"
        elif top >= 0.4 and top - second >= 0.2:
            result["status"] = "resolved"
            result["reason"] = "moderate evidence; verify against the deployed version"
        elif top >= 0.4:
            result["status"] = "ambiguous"
            result["reason"] = "several repositories match with similar evidence (%s)" % ", ".join(c["repo"] for c in cands[:3])
        else:
            result["status"] = "unresolved"
            result["reason"] = "only weak evidence (basename or name mention) matched; not attributed"
    return result


def attribute_all(store, repos: RepoSet, limits) -> Dict[str, Any]:
    """Attribute the top ``max_attributed_groups`` groups; returns a summary."""
    summary = {"attempted": 0, "resolved": 0, "ambiguous": 0, "unresolved": 0, "per_repo": {}}
    if not repos.repos:
        return summary
    from .aggregate import acc_to_dict
    import itertools
    # only the top max_attributed_groups groups are materialised (the store may hold millions on disk)
    for acc in list(itertools.islice(store.iter_accs(), limits.max_attributed_groups)):
        g = acc_to_dict(acc, store.input_paths)
        res = attribute_group(g, repos, limits)
        acc.attribution = res
        store.update_acc(acc)
        summary["attempted"] += 1
        summary[res["status"]] = summary.get(res["status"], 0) + 1
        if res["status"] in ("resolved", "ambiguous") and res["candidates"]:
            rid = res["candidates"][0]["repo"]
            summary["per_repo"][rid] = summary["per_repo"].get(rid, 0) + 1
    return summary
