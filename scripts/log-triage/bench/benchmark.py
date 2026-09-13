#!/usr/bin/env python3
"""Reproducible large-file benchmark for log-triage.

Generates synthetic logs with KNOWN totals (events and distinct groups), runs the
analyzer as a subprocess with fixed limits, and records: input size, event count,
elapsed wall time, peak resident memory of the analyzer process (``ru_maxrss`` of
the child via ``resource.getrusage(RUSAGE_CHILDREN)``; kilobytes on Linux), and
temporary-disk usage (``aggregation.temp_bytes_peak`` from analysis.json, i.e. the
peak size of the SQLite spill file). Event/group counts in analysis.json are compared
with the generator's totals.

Usage:
  python3 scripts/log-triage/bench/benchmark.py --sizes-mib 256,512 --modes normal,high-cardinality --work /tmp/bench --out docs/log-triage/benchmark-results.json

Generation is deterministic (seeded). The "normal" mode has a fixed set of message
templates (each with a fixed exception shape) so groups == templates; the
"high-cardinality" mode gives every event a unique alphabetic token so
groups == events and the aggregator must spill to disk.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import resource
import subprocess
import sys
import time
from typing import Dict, List, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)

_WORDS = ("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo "
          "sierra tango uniform victor whiskey xray yankee zulu amber birch cedar dune ember fjord glade harbor isle jade "
          "kelp lagoon marsh nectar oasis pine quartz ridge summit tundra umber vale willow yarrow zenith").split()

_NORMAL_TEMPLATES: List[Tuple[str, str, str]] = []  # (level, logger, message with {n} placeholders)
for i in range(200):
    lvl = ["INFO", "INFO", "INFO", "WARN", "ERROR"][i % 5]
    logger = "c.a.%s.%s" % (_WORDS[i % len(_WORDS)], _WORDS[(i * 7) % len(_WORDS)].capitalize())
    msg = "%s %s for order {n} took {n}ms (attempt {n}/5) user={n}" % (_WORDS[(i * 3) % len(_WORDS)], _WORDS[(i * 11) % len(_WORDS)])
    _NORMAL_TEMPLATES.append((lvl, logger, msg))

_STACK = ("java.lang.IllegalStateException: Sequence contains no elements\n"
          "\tat com.acme.orders.OrderService.place(OrderService.java:42)\n"
          "\tat com.acme.orders.api.OrdersController.post(OrdersController.java:77)\n"
          "\tat org.springframework.web.method.support.InvocableHandlerMethod.invoke(InvocableHandlerMethod.java:205)\n"
          "Caused by: java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms\n"
          "\tat com.acme.orders.repo.OrderRepo.save(OrderRepo.java:88)\n")


class _NullWriter:
    def write(self, _s):
        return None

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def generate(path: str, target_bytes: int, mode: str, seed: int = 20260913, unique_ratio: float = 0.25,
             dry_run: bool = False) -> Dict[str, int]:
    """Write a synthetic log of about ``target_bytes``. ``unique_ratio`` (high-cardinality mode) is the
    fraction of events that carry a unique token; the rest repeat 1,000 distinct tokens.
    ``dry_run`` recomputes the expected totals without writing (deterministic per seed)."""
    rnd = random.Random(seed)
    events = 0
    groups: set = set()
    written = 0
    base_ts = 1789000000
    with (_NullWriter() if dry_run else open(path, "w", encoding="utf-8", buffering=1 << 20)) as fh:
        while written < target_bytes:
            ts = base_ts + events // 50
            stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts)) + ".%03d+00:00" % (events % 1000)
            if mode == "normal":
                idx = rnd.randrange(len(_NORMAL_TEMPLATES))
                lvl, logger, msg = _NORMAL_TEMPLATES[idx]
                body = msg.replace("{n}", str(rnd.randrange(1, 999999)), 1).replace("{n}", str(rnd.randrange(1, 5000)), 1) \
                          .replace("{n}", str(rnd.randrange(1, 5)), 1).replace("{n}", str(rnd.randrange(1, 100000)), 1)
                line = "%s %5s 1234 --- [orders] [nio-8080-exec-%d] %s : %s\n" % (stamp, lvl, rnd.randrange(1, 50), logger, body)
                # expected group identity = what survives templating: logger + literal words of the message (+ stack)
                key = (logger, msg, False)
                if lvl == "ERROR" and idx % 4 == 0:
                    line += _STACK
                    key = (logger, msg, True)
                groups.add(key)
            else:
                # unique alphabetic token (survives templating: no digits) for unique_ratio of the events,
                # otherwise one of 1,000 repeating bases; the trailing word depends on the event index, so the
                # expected group count is the number of distinct token strings emitted (each is its own template).
                n = events if rnd.random() < unique_ratio else 10_000_000 + (events % 1000)
                tok = []
                while True:
                    tok.append(_WORDS[n % len(_WORDS)])
                    n //= len(_WORDS)
                    if n == 0:
                        break
                token = "-".join(tok) + "-" + _WORDS[(events * 13) % len(_WORDS)]
                line = "%s ERROR 1234 --- [orders] [nio-8080-exec-%d] c.a.hc.Worker : queue %s stalled for %dms\n" % (stamp, rnd.randrange(1, 50), token, rnd.randrange(1, 9999))
                groups.add(token)
            fh.write(line)
            written += len(line.encode("utf-8"))
            events += 1
    return {"events": events, "groups": len(groups), "bytes": written, "mode": mode, "seed": seed}


def run_once(input_path: str, out_dir: str, limits: List[str], quiet: bool = True) -> Dict[str, object]:
    cmd = [sys.executable, TOOL, input_path, "--format", "json", "--out", out_dir, "--quiet", "--no-redact"]
    for l in limits:
        cmd += ["--limit", l]
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.time()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    elapsed = time.time() - t0
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    # ru_maxrss is the max over all waited-for children; run each measurement in a fresh benchmark process for isolation
    peak_kib = after.ru_maxrss
    result: Dict[str, object] = {"command": " ".join(cmd), "exit_code": proc.returncode, "elapsed_seconds": round(elapsed, 2),
                                 "peak_rss_kib": peak_kib, "stderr_tail": proc.stderr[-500:]}
    try:
        with open(os.path.join(out_dir, "analysis.json"), "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        result.update({
            "events_parsed": doc["coverage"]["events_parsed"], "events_included": doc["coverage"]["events_included"],
            "groups_total": doc["filtering"]["groups_total"], "spilled": doc["aggregation"]["spilled_to_disk"],
            "spill_count": doc["aggregation"]["spill_count"], "temp_bytes_peak": doc["aggregation"]["temp_bytes_peak"],
            "completion": doc["status"]["completion"], "duration_reported": doc["duration_seconds"],
        })
    except (OSError, KeyError, ValueError) as exc:
        result["analysis_error"] = str(exc)
    return result


def render_report(paths: List[str]) -> str:
    """Markdown table of measured runs (one row per run) plus the measurement method."""
    rows = ["| Run | Input | Events | Groups (expected) | Counts exact | Elapsed | Throughput | Peak RSS | Spilled (spills) | Temp disk peak | Exit |",
            "|---|---|---|---|---|---|---|---|---|---|---|"]
    method = None
    for path in paths:
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        method = method or doc.get("measurement")
        for r in doc.get("results", []):
            m = r.get("measured", {})
            exp = r.get("expected", {})
            rows.append("| %s | %.0f MiB (%s bytes) | %s | %s (%s) | %s | %.1f s | %.2f MiB/s | %.1f MiB | %s (%s) | %s | %s |" % (
                r.get("name"), r.get("input_bytes", 0) / 1048576.0, "{:,}".format(r.get("input_bytes", 0)),
                "{:,}".format(m.get("events_included", 0)), "{:,}".format(m.get("groups_total", 0)), "{:,}".format(exp.get("groups", 0)),
                "yes" if r.get("counts_match") else "NO", m.get("elapsed_seconds", 0.0), r.get("throughput_mib_per_s", 0.0),
                m.get("peak_rss_kib", 0) / 1024.0, "yes" if m.get("spilled") else "no", m.get("spill_count", 0),
                ("%.2f GiB" % (m.get("temp_bytes_peak", 0) / 1073741824.0)) if m.get("temp_bytes_peak") else "0",
                m.get("exit_code")))
    out = "\n".join(rows)
    if method:
        out += "\n\nMeasurement: " + "; ".join("%s = %s" % (k, v) for k, v in method.items())
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sizes-mib", default="256,512")
    ap.add_argument("--modes", default="normal,high-cardinality")
    ap.add_argument("--work", help="scratch directory for generated inputs and outputs (required unless --report)")
    ap.add_argument("--out", help="results JSON path (required unless --report)")
    ap.add_argument("--limit", action="append", default=[], help="extra --limit KEY=VALUE passed to the analyzer (fixed across sizes)")
    ap.add_argument("--keep-inputs", action="store_true")
    ap.add_argument("--unique-ratio", type=float, default=0.25, help="high-cardinality mode: fraction of events with a unique token (default 0.25)")
    ap.add_argument("--child", help=argparse.SUPPRESS)   # internal: run a single measurement in a fresh process
    ap.add_argument("--report", nargs="+", metavar="RESULTS_JSON",
                    help="render one or more results files as a Markdown table (no benchmark is run)")
    args = ap.parse_args()
    if args.report:
        print(render_report(args.report))
        return 0
    if not args.work or not args.out:
        ap.error("--work and --out are required")
    if args.child:
        spec = json.loads(args.child)
        print(json.dumps(run_once(spec["input"], spec["out"], spec["limits"])))
        return 0
    os.makedirs(args.work, exist_ok=True)
    results = []
    for mode in [m.strip() for m in args.modes.split(",") if m.strip()]:
        for size in [int(s) for s in args.sizes_mib.split(",") if s.strip()]:
            name = "%s-%dmib" % (mode, size)
            inp = os.path.join(args.work, name + ".log")
            out = os.path.join(args.work, name + "-out")
            sys.stderr.write("generating %s ...\n" % inp)
            t0 = time.time()
            expected = generate(inp, size * 1024 * 1024, mode, unique_ratio=args.unique_ratio)
            gen_s = time.time() - t0
            sys.stderr.write("  %d events, %d groups, %d bytes in %.1fs; running analyzer ...\n" % (expected["events"], expected["groups"], expected["bytes"], gen_s))
            child = subprocess.run([sys.executable, os.path.abspath(__file__), "--work", args.work, "--out", args.out,
                                    "--child", json.dumps({"input": inp, "out": out, "limits": args.limit})],
                                   capture_output=True, text=True)
            try:
                measured = json.loads(child.stdout.strip().splitlines()[-1])
            except (ValueError, IndexError):
                measured = {"error": child.stderr[-1000:], "stdout": child.stdout[-1000:]}
            row = {"name": name, "mode": mode, "input_mib": size, "input_bytes": os.path.getsize(inp), "expected": expected,
                   "measured": measured,
                   "counts_match": measured.get("events_included") == expected["events"] and measured.get("groups_total") == expected["groups"],
                   "throughput_mib_per_s": round(os.path.getsize(inp) / 1048576.0 / max(0.001, float(measured.get("elapsed_seconds", 0) or 1)), 2),
                   "generation_seconds": round(gen_s, 1)}
            results.append(row)
            sys.stderr.write("  done: %s\n" % json.dumps({k: row[k] for k in ("counts_match", "throughput_mib_per_s")}, ) + json.dumps({k: measured.get(k) for k in ("elapsed_seconds", "peak_rss_kib", "groups_total", "spilled", "temp_bytes_peak", "exit_code")}) + "\n")
            if not args.keep_inputs:
                os.unlink(inp)
    doc = {"tool": "log-triage benchmark", "python": sys.version.split()[0], "unique_ratio": args.unique_ratio, "platform": os.uname().sysname + " " + os.uname().release,
           "cpu_count": os.cpu_count(), "fixed_limits": args.limit, "measurement": {
               "elapsed": "wall-clock of the analyzer subprocess", "peak_memory": "resource.getrusage(RUSAGE_CHILDREN).ru_maxrss of the analyzer (KiB on Linux), measured in a fresh parent process per run",
               "temp_disk": "aggregation.temp_bytes_peak from analysis.json (peak SQLite spill file size)",
               "counts": "coverage.events_included and filtering.groups_total compared with the generator's totals"},
           "results": results}
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1)
    sys.stdout.write(json.dumps(doc, indent=1) + "\n")
    return 0 if all(r["counts_match"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
