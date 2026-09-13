"""Shared helpers for the log-triage test suite (stdlib unittest, no third-party packages)."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from typing import Any, Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
TOOL_DIR = os.path.join(REPO_ROOT, "scripts", "log-triage")
FIX = os.path.join(HERE, "fixtures")
SCHEMA = os.path.join(REPO_ROOT, "docs", "log-triage", "schema", "analysis.schema.json")
NOW = "2026-09-14T00:00:00Z"

if TOOL_DIR not in sys.path:
    sys.path.insert(0, TOOL_DIR)


def fixture(*parts: str) -> str:
    return os.path.join(FIX, *parts)


def run_cli(args: List[str], env: Optional[Dict[str, str]] = None, cwd: Optional[str] = None) -> Tuple[int, str, str]:
    full_env = dict(os.environ)
    full_env["PYTHONDONTWRITEBYTECODE"] = "1"
    if env:
        full_env.update(env)
    proc = subprocess.run([sys.executable, TOOL_DIR] + args, capture_output=True, text=True, env=full_env, cwd=cwd or REPO_ROOT)
    return proc.returncode, proc.stdout, proc.stderr


class TriageTestCase(unittest.TestCase):
    """Base class with a per-test temporary directory and a CLI runner returning the JSON document."""

    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp(prefix="lt-test-")

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def out_dir(self, name: str = "out") -> str:
        return os.path.join(self.tmp, name)

    @staticmethod
    def read_text(path: str) -> str:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()

    def analyze(self, inputs: List[str], extra: Optional[List[str]] = None, formats: Optional[List[str]] = None,
                expect_code: Optional[int] = 0, env: Optional[Dict[str, str]] = None, out: Optional[str] = None) -> Dict[str, Any]:
        out = out or self.out_dir()
        args = list(inputs) + ["--out", out, "--quiet", "--now", NOW]
        for f in (formats or ["json"]):
            args += ["--format", f]
        args += list(extra or [])
        code, so, se = run_cli(args, env=env)
        if expect_code is not None:
            self.assertEqual(code, expect_code, "exit %d != %d\nstdout:\n%s\nstderr:\n%s" % (code, expect_code, so, se))
        path = os.path.join(out, "analysis.json")
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as fh:
                doc = json.load(fh)
            doc["_exit_code"] = code
            doc["_stdout"] = so
            doc["_stderr"] = se
            return doc
        return {"_exit_code": code, "_stdout": so, "_stderr": se}

    def write(self, name: str, content, binary: bool = False) -> str:
        path = os.path.join(self.tmp, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb" if binary else "w", **({} if binary else {"encoding": "utf-8", "newline": "\n"})) as fh:
            fh.write(content)
        return path


def parse_events(path: str, parser: Optional[str] = None, limits=None, options=None):
    """In-process parsing of a file: returns (events, ctx, parser_name, confidence)."""
    from log_triage.config import Limits, Options
    from log_triage.model import DiagnosticSink
    from log_triage.parsers import detect, get_parser
    from log_triage.parsers.base import ParseContext
    from log_triage.reader import LineReader, read_sample
    from log_triage.timestamps import parse_timestamp
    limits = limits or Limits()
    options = options or Options(limits=limits)
    now, _ = parse_timestamp(NOW, 0)
    ctx = ParseContext(limits, options, DiagnosticSink(200), None, now)
    sample = read_sample(path, limits)
    name, conf, scores = detect(sample, ctx)
    if parser:
        name = parser
    p = get_parser(name)
    reader = LineReader(path, limits)
    events = list(p.parse(iter(reader), ctx))
    return events, ctx, name, conf


def groups_by_template(doc: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    return {g["template"]: g for g in doc.get("groups", [])}
