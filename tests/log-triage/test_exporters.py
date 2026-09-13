import csv
import json
import os
import re
import unittest

from _helpers import SCHEMA, TriageTestCase, fixture
from log_triage.schema_check import validate

INPUTS = [("jvm", "jvm-classic.log"), ("web", "access-combined.log"), ("python", "python-asctime.log"), ("edge", "grouping-equivalence.log")]


class ExporterTests(TriageTestCase):
    def setUp(self):
        super().setUp()
        self.doc = self.analyze([fixture(*p) for p in INPUTS], formats=["json", "sarif", "html", "markdown", "csv", "ndjson"],
                                extra=["--max-report-groups", "3", "--limit", "max_findings_rows=4"])
        self.out = self.out_dir()

    def read(self, name):
        with open(os.path.join(self.out, name), encoding="utf-8") as fh:
            return fh.read()

    def test_json_validates_against_schema(self):
        with open(SCHEMA, encoding="utf-8") as fh:
            schema = json.load(fh)
        errors = validate(json.loads(self.read("analysis.json")), schema)
        self.assertEqual(errors, [])
        meta = json.loads(self.read("groups.meta.json"))
        errors = validate(dict(meta, groups=[]), schema)
        self.assertEqual(errors, [])

    def test_sarif_structure(self):
        s = json.loads(self.read("analysis.sarif"))
        self.assertEqual(s["version"], "2.1.0")
        self.assertIn("sarif-schema-2.1.0", s["$schema"])
        run = s["runs"][0]
        rules = run["tool"]["driver"]["rules"]
        results = run["results"]
        self.assertEqual(len(rules), len(results))
        self.assertEqual(len(results), self.doc["filtering"]["groups_reported"])
        for i, (rule, res) in enumerate(zip(rules, results)):
            self.assertEqual(res["ruleId"], rule["id"])
            self.assertEqual(res["ruleIndex"], i)
            self.assertIn(res["level"], ("error", "warning", "note"))
            self.assertIn(res["kind"], ("fail", "informational"))
            self.assertIsInstance(res["message"]["text"], str)
            self.assertTrue(res["fingerprints"])
            self.assertGreaterEqual(res["occurrenceCount"], 1)
            for loc in res.get("locations", []):
                self.assertEqual(loc["properties"]["locationKind"], "log-evidence")
                self.assertTrue(loc["physicalLocation"]["artifactLocation"]["uri"].startswith("file:///"))
                if "region" in loc["physicalLocation"]:
                    self.assertGreaterEqual(loc["physicalLocation"]["region"]["startLine"], 1)
            self.assertNotIn("relatedLocations", res)   # no repositories -> no source locations invented
        self.assertEqual(len(run["artifacts"]), len(self.doc["inputs"]["files"]))
        self.assertTrue(run["invocations"][0]["executionSuccessful"])
        ids_json = [g["id"] for g in self.doc["groups"]]
        self.assertEqual([r["ruleId"] for r in results], ids_json)
        self.assertEqual([r["occurrenceCount"] for r in results], [g["count"] for g in self.doc["groups"]])

    def test_counts_and_ids_consistent_across_exporters(self):
        groups = self.doc["groups"]
        nd = [json.loads(l) for l in self.read("groups.ndjson").splitlines() if l.strip()]
        self.assertEqual([(g["id"], g["count"], g["severity"]) for g in nd], [(g["id"], g["count"], g["severity"]) for g in groups])
        with open(os.path.join(self.out, "groups.csv"), encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.DictReader(fh))
        self.assertEqual([(r["id"], int(r["count"]), r["severity"], r["fingerprint"]) for r in rows],
                         [(g["id"], g["count"], g["severity"], g["fingerprint"]) for g in groups])
        meta = json.loads(self.read("groups.meta.json"))
        self.assertEqual(meta["ndjson"]["groups_written"], len(groups))
        self.assertEqual(meta["filtering"], self.doc["filtering"])
        html = self.read("report.html")
        md = self.read("report.md")
        for g in groups[:3]:
            self.assertIn(g["id"], html)
            self.assertIn(g["id"], md)
            self.assertIn(str(g["count"]), html)

    def test_reports_bound_detail_and_disclose_omissions(self):
        html = self.read("report.html")
        md = self.read("report.md")
        n = self.doc["filtering"]["groups_reported"]
        self.assertGreater(n, 4)
        self.assertEqual(html.count('<details class="group" id="g-'), 3)
        self.assertEqual(len(re.findall(r'<tr data-severity=', html)), 4)
        self.assertIn("Only the first 3 of %d reported groups" % n, html)
        self.assertIn("first 4 of %d reported groups" % n, html)
        self.assertIn("Only the first 3 of %d reported groups" % n, md)
        self.assertIn("analysis.json", html)
        self.assertIn("analysis.json", md)
        self.assertIn("Search and filters cover only the groups included in this report", html)
        # html size stays bounded regardless of group count
        self.assertLess(len(html), 400_000)
        for section in ("1. Executive summary", "2. Prioritized findings", "3. Timeline", "4. Issue details", "5. Root-cause assessment", "6. Fix plan", "7. Coverage and limitations"):
            self.assertIn(section, html)
        for section in ("## 1. Executive summary", "## 2. Prioritized findings", "## 3. Root-cause assessment", "## 4. Fix plan", "## 6. Coverage and limitations"):
            self.assertIn(section, md)

    def test_html_is_offline_and_accessible(self):
        html = self.read("report.html")
        self.assertIn('<meta http-equiv="Content-Security-Policy"', html)
        self.assertNotRegex(html, r"(src|href)=[\"']https?://")
        self.assertIn('<nav aria-label="Sections">', html)
        self.assertIn('role="img"', html)
        self.assertIn("@media print", html)
        self.assertIn('<input type="search" id="q"', html)

    def test_output_group_limit_is_disclosed(self):
        out = self.out_dir("limited")
        doc = self.analyze([fixture(*p) for p in INPUTS], formats=["json", "sarif", "csv", "ndjson", "markdown"],
                           extra=["--limit", "max_output_groups=2"], out=out)
        filt = doc["filtering"]
        self.assertGreater(filt["groups_reported"], 2)
        self.assertEqual(len(doc["groups"]), 2)
        self.assertEqual(filt["groups_written"], 2)
        self.assertEqual(filt["groups_omitted_by_output_limit"], filt["groups_reported"] - 2)
        with open(os.path.join(out, "groups.ndjson"), encoding="utf-8") as fh:
            nd = [json.loads(ln) for ln in fh if ln.strip()]
        self.assertEqual([g["id"] for g in nd], [g["id"] for g in doc["groups"]])
        with open(os.path.join(out, "groups.csv"), encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.DictReader(fh))
        self.assertEqual([r["id"] for r in rows], [g["id"] for g in doc["groups"]])
        with open(os.path.join(out, "analysis.sarif"), encoding="utf-8") as fh:
            sarif = json.load(fh)
        self.assertEqual(len(sarif["runs"][0]["results"]), 2)
        # the full run (setUp) is not limited
        self.assertEqual(self.doc["filtering"]["groups_omitted_by_output_limit"], 0)

    def test_timeline_bounded(self):
        tl = self.doc["timeline"]
        self.assertLessEqual(tl["bucket_count"], 200)
        self.assertEqual(sum(b["total"] for b in tl["buckets"]), tl["events_with_timestamp"])
        self.assertEqual(tl["events_with_timestamp"] + tl["events_without_timestamp"], self.doc["coverage"]["events_included"])

    def test_timeline_coarsens_under_limit(self):
        content = "".join("2026-09-%02dT%02d:%02d:00Z ERROR svc failed %d\n" % (1 + (i // 1440) % 27, (i // 60) % 24, i % 60, i) for i in range(0, 20000, 7))
        path = self.write("wide.log", content)
        doc = self.analyze([path], extra=["--limit", "max_timeline_buckets=20"])
        tl = doc["timeline"]
        self.assertLessEqual(tl["bucket_count"], 20)
        self.assertTrue(tl["coarsened"])
        self.assertGreater(tl["bucket_seconds"], 60)
        self.assertEqual(sum(b["total"] for b in tl["buckets"]), doc["coverage"]["events_included"])


if __name__ == "__main__":
    unittest.main()
