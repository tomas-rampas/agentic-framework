"""Repository discovery and lightweight inventory (docs/log-triage/README.md, "Repositories").

* ``--repo``: one Git repository or worktree (``.git`` may be a directory or a file).
* ``--repos-dir``: bounded traversal (depth, directories visited, repository count);
  directory symlinks are not followed; dependency/build directories are skipped;
  a repository's contents are not searched for nested repositories unless
  ``--include-nested-repos`` (submodules are therefore listed only when nested
  discovery is on, and then as separate repositories).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
from typing import Any, Dict, List, Optional, Set, Tuple

SKIP_DIRS = {
    "node_modules", "vendor", "target", "bin", "obj", "build", "dist", "out", ".git", "__pycache__", ".venv", "venv",
    "env", ".tox", ".mypy_cache", ".pytest_cache", ".idea", ".vs", ".vscode", "packages", "bower_components", ".gradle",
    ".terraform", ".next", ".nuxt", "coverage", "htmlcov", "site-packages", ".cache", "tmp", "temp", "logs", "log",
    "_build", "deps", ".bundle", "Pods", "DerivedData", "cmake-build-debug", "cmake-build-release", ".dart_tool",
}
SOURCE_EXTENSIONS = {
    ".cs", ".vb", ".fs", ".java", ".kt", ".kts", ".scala", ".groovy", ".py", ".pyx", ".ts", ".tsx", ".js", ".jsx", ".mjs",
    ".cjs", ".go", ".rs", ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".m", ".mm", ".swift", ".php", ".rb", ".erb",
    ".ex", ".exs", ".erl", ".hrl", ".ps1", ".psm1", ".sh", ".sql", ".proto", ".graphql", ".lua", ".pl", ".pm", ".dart",
    ".clj", ".cljs", ".hs", ".ml", ".r", ".jl", ".mq4", ".mq5", ".mqh",
}
_MANIFESTS = {"package.json", "go.mod", "Cargo.toml", "pyproject.toml", "setup.py", "setup.cfg", "pom.xml",
              "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "mix.exs", "composer.json",
              "Package.swift", "Gemfile", "Dockerfile", "CMakeLists.txt", "Makefile"}


def _read_head(path: str, limit: int = 65536) -> str:
    try:
        with open(path, "rb") as fh:
            return fh.read(limit).decode("utf-8", "replace")
    except OSError:
        return ""


class Inventory:
    def __init__(self) -> None:
        self.files: List[str] = []
        self.basenames: Dict[str, List[str]] = {}
        self.names: Set[str] = set()          # service/package/module names (lower-case, normalized)
        self.namespaces: Set[str] = set()     # code namespace prefixes (case-preserved) e.g. com.acme.orders, Acme.Orders
        self.languages: Dict[str, int] = {}
        self.truncated = False
        self.source = "none"

    def to_dict(self) -> Dict[str, Any]:
        return {"files_indexed": len(self.files), "truncated": self.truncated, "source": self.source,
                "names": sorted(self.names)[:50], "namespaces": sorted(self.namespaces)[:50],
                "languages": dict(sorted(self.languages.items(), key=lambda kv: -kv[1])[:10])}


class Repo:
    def __init__(self, path: str, kind: str, git_dir: Optional[str]):
        self.path = path
        self.name = os.path.basename(path.rstrip(os.sep)) or path
        self.kind = kind
        self.git_dir = git_dir
        self.head: Optional[str] = None
        self.branch: Optional[str] = None
        self.dirty: Optional[bool] = None
        self.dirty_reason: Optional[str] = None
        self.inventory = Inventory()
        self.id = "R" + hashlib.sha1(os.path.realpath(path).encode("utf-8", "replace")).hexdigest()[:8]
        self.notes: List[str] = []

    def to_dict(self) -> Dict[str, Any]:
        return {"id": self.id, "name": self.name, "path": self.path, "kind": self.kind, "head": self.head,
                "branch": self.branch, "working_tree_dirty": self.dirty, "working_tree_note": self.dirty_reason,
                "inventory": self.inventory.to_dict(), "notes": self.notes}


class RepoSet:
    def __init__(self) -> None:
        self.repos: List[Repo] = []
        self.skipped: List[Dict[str, str]] = []
        self.incomplete = False
        self.incomplete_reasons: List[str] = []
        self.dirs_visited = 0
        self.mode = "none"
        self.root: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {"mode": self.mode, "root": self.root, "discovered": [r.to_dict() for r in self.repos],
                "skipped": self.skipped[:200], "skipped_total": len(self.skipped), "incomplete": self.incomplete,
                "incomplete_reasons": self.incomplete_reasons, "directories_visited": self.dirs_visited}

    def by_id(self, rid: str) -> Optional[Repo]:
        for r in self.repos:
            if r.id == rid:
                return r
        return None


def _git_dir_of(path: str) -> Tuple[Optional[str], Optional[str]]:
    """Return (kind, git_dir) for a directory; kind is 'repository', 'worktree' or None."""
    dot = os.path.join(path, ".git")
    if os.path.isdir(dot):
        return "repository", dot
    if os.path.isfile(dot):
        text = _read_head(dot, 4096).strip()
        m = re.match(r"gitdir:\s*(.+)$", text)
        if m:
            gd = m.group(1).strip()
            if not os.path.isabs(gd):
                gd = os.path.normpath(os.path.join(path, gd))
            kind = "worktree" if os.sep + "worktrees" + os.sep in gd or "/worktrees/" in gd.replace("\\", "/") else "submodule"
            return kind, gd
    return None, None


def _resolve_head(repo: Repo) -> None:
    gd = repo.git_dir
    if not gd:
        return
    head = _read_head(os.path.join(gd, "HEAD"), 4096).strip()
    if head.startswith("ref: "):
        ref = head[5:].strip()
        repo.branch = ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref
        common = gd
        cd = os.path.join(gd, "commondir")
        if os.path.isfile(cd):
            c = _read_head(cd, 1024).strip()
            common = c if os.path.isabs(c) else os.path.normpath(os.path.join(gd, c))
        sha = _read_head(os.path.join(common, ref), 128).strip()
        if not sha:
            packed = _read_head(os.path.join(common, "packed-refs"), 1_048_576)
            m = re.search(r"^([0-9a-f]{40,64}) " + re.escape(ref) + r"$", packed, re.M)
            if m:
                sha = m.group(1)
        repo.head = sha or None
    elif re.match(r"^[0-9a-f]{40,64}$", head):
        repo.head = head
        repo.branch = None
        repo.notes.append("detached HEAD")


def _git(args: List[str], cwd: str, timeout: float = 20.0) -> Optional[str]:
    if shutil.which("git") is None:
        return None
    try:
        res = subprocess.run(["git"] + args, cwd=cwd, capture_output=True, timeout=timeout, check=False,
                             env=dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0"))
    except (OSError, subprocess.SubprocessError):
        return None
    if res.returncode != 0:
        return None
    return res.stdout.decode("utf-8", "replace")


def _dirty_state(repo: Repo) -> None:
    out = _git(["status", "--porcelain", "--untracked-files=no"], repo.path)
    if out is None:
        repo.dirty = None
        repo.dirty_reason = "git status unavailable (git missing, timed out, or failed); working-tree state unknown"
        return
    repo.dirty = bool(out.strip())
    repo.dirty_reason = "uncommitted tracked changes present" if repo.dirty else "clean (tracked files)"


def _walk_files(root: str, limit: int) -> Tuple[List[str], bool]:
    out: List[str] = []
    truncated = False
    for dirpath, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not os.path.islink(os.path.join(dirpath, d)))
        rel_dir = os.path.relpath(dirpath, root)
        for name in sorted(files):
            rel = name if rel_dir == "." else os.path.join(rel_dir, name)
            out.append(rel.replace(os.sep, "/"))
            if len(out) >= limit:
                return out, True
    return out, truncated


def build_inventory(repo: Repo, limits) -> None:
    inv = repo.inventory
    files: List[str] = []
    out = _git(["ls-files", "-z"], repo.path, timeout=60.0)
    if out is not None:
        raw = out.split("\0")
        files = [f for f in raw if f]
        inv.source = "git ls-files"
        if len(files) > limits.max_repo_files_indexed:
            files = files[: limits.max_repo_files_indexed]
            inv.truncated = True
    else:
        files, inv.truncated = _walk_files(repo.path, limits.max_repo_files_indexed)
        inv.source = "directory walk"
    inv.files = files
    for f in files:
        base = f.rsplit("/", 1)[-1]
        inv.basenames.setdefault(base, []).append(f)
        ext = os.path.splitext(base)[1].lower()
        if ext in SOURCE_EXTENSIONS:
            inv.languages[ext] = inv.languages.get(ext, 0) + 1
    _derive_names(repo)


def _norm_name(n: str) -> str:
    return re.sub(r"[^a-z0-9]", "", n.lower())


def _derive_names(repo: Repo) -> None:
    inv = repo.inventory
    inv.names.add(_norm_name(repo.name))
    inv.names.add(repo.name.lower())
    manifest_hits = 0
    for f in inv.files:
        base = f.rsplit("/", 1)[-1]
        parts = f.split("/")
        # JVM namespace roots from source layout
        for marker in ("java", "kotlin", "scala", "groovy"):
            if marker in parts:
                i = parts.index(marker)
                pkg = parts[i + 1:-1]
                if pkg and len(pkg) >= 2 and base.endswith((".java", ".kt", ".scala", ".groovy")):
                    inv.namespaces.add(".".join(pkg[:3]))
                    inv.namespaces.add(".".join(pkg[:2]))
                break
        if base.endswith((".csproj", ".vbproj", ".fsproj")):
            stem = base.rsplit(".", 1)[0]
            inv.namespaces.add(stem)
            inv.names.add(_norm_name(stem))
            text = _read_head(os.path.join(repo.path, f), 32768)
            for tag in ("RootNamespace", "AssemblyName", "PackageId"):
                m = re.search(r"<%s>([^<]+)</%s>" % (tag, tag), text)
                if m:
                    inv.namespaces.add(m.group(1).strip())
                    inv.names.add(_norm_name(m.group(1)))
            manifest_hits += 1
        if base.endswith(".py") and "__init__.py" == base and len(parts) >= 2:
            pkg_parts = [p for p in parts[:-1] if p not in ("src", "lib")]
            if pkg_parts:
                inv.namespaces.add(".".join(pkg_parts[-2:]) if len(pkg_parts) >= 2 else pkg_parts[-1])
                inv.namespaces.add(pkg_parts[-1])
        if base.endswith(".go") and len(parts) >= 2:
            inv.namespaces.add("/".join(parts[:-1]))
        if base.endswith(".rb") and parts[0] == "lib" and len(parts) >= 2:
            inv.namespaces.add(_camel(parts[1].replace(".rb", "")))
        if base.endswith((".ex", ".exs")) and parts[0] == "lib" and len(parts) >= 2:
            inv.namespaces.add(_camel(parts[1].replace(".ex", "")))
        if base in _MANIFESTS and len(parts) <= 3 and manifest_hits < 64:
            manifest_hits += 1
            _read_manifest(repo, f)
    inv.names.discard("")


def _camel(s: str) -> str:
    return "".join(p[:1].upper() + p[1:] for p in re.split(r"[_-]", s) if p)


def _read_manifest(repo: Repo, rel: str) -> None:
    inv = repo.inventory
    base = rel.rsplit("/", 1)[-1]
    text = _read_head(os.path.join(repo.path, rel), 65536)
    if not text:
        return
    try:
        if base in ("package.json", "composer.json"):
            data = json.loads(text)
            if isinstance(data, dict):
                name = data.get("name")
                if isinstance(name, str):
                    inv.names.add(_norm_name(name.split("/")[-1]))
                    inv.names.add(name.lower())
                    if "/" in name:
                        inv.namespaces.add(name)
                auto = data.get("autoload", {}) if base == "composer.json" else {}
                if isinstance(auto, dict):
                    for ns in (auto.get("psr-4") or {}):
                        inv.namespaces.add(ns.strip("\\"))
            return
        if base == "go.mod":
            m = re.search(r"^module\s+(\S+)", text, re.M)
            if m:
                inv.namespaces.add(m.group(1))
                inv.names.add(_norm_name(m.group(1).split("/")[-1]))
            return
        if base in ("Cargo.toml", "pyproject.toml"):
            m = re.search(r'^\s*name\s*=\s*"([^"]+)"', text, re.M)
            if m:
                inv.names.add(_norm_name(m.group(1)))
                inv.namespaces.add(m.group(1).replace("-", "_"))
            return
        if base in ("setup.py", "setup.cfg"):
            m = re.search(r'name\s*=\s*["\']?([\w.-]+)', text)
            if m:
                inv.names.add(_norm_name(m.group(1)))
                inv.namespaces.add(m.group(1).replace("-", "_"))
            return
        if base == "pom.xml":
            for tag in ("artifactId", "groupId"):
                m = re.search(r"<%s>([^<]+)</%s>" % (tag, tag), text)
                if m:
                    val = m.group(1).strip()
                    if tag == "groupId":
                        inv.namespaces.add(val)
                    else:
                        inv.names.add(_norm_name(val))
            return
        if base.startswith("settings.gradle"):
            m = re.search(r"rootProject\.name\s*=\s*['\"]([^'\"]+)['\"]", text)
            if m:
                inv.names.add(_norm_name(m.group(1)))
            return
        if base == "mix.exs":
            m = re.search(r"app:\s*:(\w+)", text)
            if m:
                inv.names.add(_norm_name(m.group(1)))
                inv.namespaces.add(_camel(m.group(1)))
            return
        if base == "Package.swift":
            m = re.search(r'name:\s*"([^"]+)"', text)
            if m:
                inv.names.add(_norm_name(m.group(1)))
            return
    except (ValueError, TypeError):
        return


def discover(options, limits, diagnostics) -> RepoSet:
    rs = RepoSet()
    if options.repo:
        rs.mode = "repo"
        rs.root = options.repo
        path = os.path.abspath(options.repo)
        if not os.path.isdir(path):
            diagnostics.add("repo-invalid", "error", "--repo path is not a directory: %s" % options.repo)
            rs.incomplete = True
            rs.incomplete_reasons.append("repo path invalid")
            return rs
        kind, gd = _git_dir_of(path)
        if kind is None:
            diagnostics.add("repo-invalid", "error", "--repo path is not a Git repository or worktree (no .git): %s" % options.repo)
            rs.incomplete = True
            rs.incomplete_reasons.append("not a git repository")
            return rs
        repo = Repo(path, kind, gd)
        _resolve_head(repo)
        _dirty_state(repo)
        build_inventory(repo, limits)
        rs.repos.append(repo)
        return rs
    if options.repos_dir:
        rs.mode = "repos-dir"
        rs.root = options.repos_dir
        root = os.path.abspath(options.repos_dir)
        if not os.path.isdir(root):
            diagnostics.add("repos-dir-invalid", "error", "--repos-dir path is not a directory: %s" % options.repos_dir)
            rs.incomplete = True
            rs.incomplete_reasons.append("repos-dir path invalid")
            return rs
        seen: Set[str] = set()
        root_depth = root.rstrip(os.sep).count(os.sep)
        kind0, gd0 = _git_dir_of(root)
        if kind0 is not None:
            repo = Repo(root, kind0, gd0)
            rs.repos.append(repo)
            seen.add(os.path.realpath(root))
        for dirpath, dirs, files in os.walk(root, followlinks=options.follow_symlinks):
            rs.dirs_visited += 1
            depth = dirpath.rstrip(os.sep).count(os.sep) - root_depth
            if rs.dirs_visited > limits.max_repo_dirs_visited:
                rs.incomplete = True
                rs.incomplete_reasons.append("max_repo_dirs_visited (%d) reached" % limits.max_repo_dirs_visited)
                break
            keep = []
            for d in sorted(dirs):
                full = os.path.join(dirpath, d)
                if d in SKIP_DIRS:
                    rs.skipped.append({"path": full, "reason": "skipped-directory-name"})
                    continue
                if os.path.islink(full) and not options.follow_symlinks:
                    rs.skipped.append({"path": full, "reason": "symlink-not-followed"})
                    continue
                if depth + 1 > limits.max_repo_depth:
                    rs.skipped.append({"path": full, "reason": "max_repo_depth"})
                    rs.incomplete = True
                    if "max_repo_depth reached" not in rs.incomplete_reasons:
                        rs.incomplete_reasons.append("max_repo_depth reached")
                    continue
                kind, gd = _git_dir_of(full)
                if kind is not None:
                    real = os.path.realpath(full)
                    if real in seen:
                        rs.skipped.append({"path": full, "reason": "duplicate-repository"})
                        continue
                    if len(rs.repos) >= limits.max_repos:
                        rs.incomplete = True
                        if "max_repos reached" not in rs.incomplete_reasons:
                            rs.incomplete_reasons.append("max_repos (%d) reached" % limits.max_repos)
                        rs.skipped.append({"path": full, "reason": "max_repos"})
                        continue
                    seen.add(real)
                    rs.repos.append(Repo(full, kind, gd))
                    if not options.include_nested_repos:
                        continue   # do not search inside a repository for nested repositories/submodules
                keep.append(d)
            dirs[:] = keep
        for repo in rs.repos:
            _resolve_head(repo)
            _dirty_state(repo)
            build_inventory(repo, limits)
        return rs
    return rs
