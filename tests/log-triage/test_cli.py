import json
import os
import unittest

from _helpers import FIX, TriageTestCase, fixture, run_cli


class CliContractTests(TriageTestCase):
    def test_version_and_lists(self):
        code, so, _ = run_cli(["--version"])
        self.assertEqual(code, 0)
        self.assertIn("log-triage 1.0.0", so)
        code, so, _ = run_cli(["--list-formats"])
        self.assertEqual(code, 0)
        self.assertIn("serilog-text", so)
        self.assertIn("Report formats", so)
        code, so, _ = run_cli(["--list-limits"])
        self.assertEqual(code, 0)
        self.assertIn("max_groups_in_memory", so)

    def test_no_input_is_usage_error(self):
        code, _, se = run_cli([])
        self.assertEqual(code, 2)
        self.assertIn("no input", se)

    def test_unmatched_only_input_is_usage_error(self):
        code, _, se = run_cli([os.path.join(self.tmp, "nothing-*.log"), "--out", self.out_dir()])
        self.assertEqual(code, 2)
        self.assertIn("no input file matched", se)

    def test_repeated_format_and_rejections(self):
        doc = self.analyze([fixture("jvm", "jvm-classic.log")], formats=["json", "csv", "ndjson"])
        for name in ("analysis.json", "groups.csv", "groups.ndjson", "groups.meta.json"):
            self.assertTrue(os.path.exists(os.path.join(self.out_dir(), name)), name)
        self.assertFalse(os.path.exists(os.path.join(self.out_dir(), "report.html")))
        code, _, se = run_cli([fixture("jvm", "jvm-classic.log"), "--format", "auto", "--format", "json", "--out", self.out_dir("x")])
        self.assertEqual(code, 2)
        self.assertIn("auto cannot be combined", se)
        code, _, se = run_cli([fixture("jvm", "jvm-classic.log"), "--format", "pdf", "--out", self.out_dir("y")])
        self.assertEqual(code, 2)
        self.assertIn("unsupported --format", se)
        # comma-separated and md alias
        doc = self.analyze([fixture("jvm", "jvm-classic.log")], formats=["json,md"], out=self.out_dir("z"))
        self.assertTrue(os.path.exists(os.path.join(self.out_dir("z"), "report.md")))

    def test_default_auto_formats(self):
        code, so, se = run_cli([fixture("jvm", "jvm-classic.log"), "--out", self.out_dir(), "--quiet"])
        self.assertEqual(code, 0, se)
        names = sorted(os.listdir(self.out_dir()))
        self.assertEqual(names, ["analysis.json", "analysis.sarif", "report.html", "report.md"])

    def test_repo_options_mutually_exclusive(self):
        code, _, se = run_cli([fixture("jvm", "jvm-classic.log"), "--repo", self.tmp, "--repos-dir", self.tmp, "--out", self.out_dir()])
        self.assertEqual(code, 2)
        self.assertIn("not allowed with", se)

    def test_unknown_limit_and_config(self):
        code, _, se = run_cli([fixture("jvm", "jvm-classic.log"), "--limit", "no_such_limit=3", "--out", self.out_dir()])
        self.assertEqual(code, 2)
        self.assertIn("unknown limit", se)
        cfg = self.write("cfg.json", json.dumps({"max_examples_per_group": 1, "max_report_groups": 2}))
        doc = self.analyze([fixture("jvm", "jvm-classic.log")], extra=["--config", cfg])
        self.assertEqual(doc["configuration"]["limits"]["max_examples_per_group"], 1)
        self.assertLessEqual(max(len(g["examples"]) for g in doc["groups"]), 2)  # 1 example + last-seen

    def test_paths_with_spaces_globs_and_dedup(self):
        p1 = self.write("dir with space/app one.log", "2026-09-13 12:00:00,123 - a - ERROR - failed 1\n")
        p2 = self.write("dir with space/app two.log", "2026-09-13 12:00:01,123 - a - ERROR - failed 2\n")
        link = os.path.join(self.tmp, "dir with space", "link.log")
        os.symlink(p1, link)
        doc = self.analyze([p1, os.path.join(self.tmp, "dir with space", "app *.log"), link, p1])
        files = doc["inputs"]["files"]
        self.assertEqual(sorted(os.path.basename(f["path"]) for f in files), ["app one.log", "app two.log"])
        self.assertEqual(doc["inputs"]["summary"]["duplicates_removed"], 3)  # glob dup, link, repeated arg
        self.assertEqual(doc["coverage"]["events_included"], 2)

    def test_directory_traversal_and_unmatched_reported(self):
        self.write("logs/a/one.log", "2026-09-13 12:00:00,123 - a - ERROR - failed 1\n")
        self.write("logs/b/two.log", "2026-09-13 12:00:01,123 - a - ERROR - failed 2\n")
        self.write("logs/b/pic.png", b"\x89PNG\r\n\x1a\n" + b"\x00" * 50, binary=True)
        doc = self.analyze([os.path.join(self.tmp, "logs"), os.path.join(self.tmp, "missing-*.log")], expect_code=3)
        self.assertEqual(doc["status"]["completion"], "partial")
        self.assertEqual(doc["inputs"]["unmatched"], [os.path.join(self.tmp, "missing-*.log")])
        self.assertEqual(len(doc["inputs"]["files"]), 2)
        self.assertEqual(doc["inputs"]["excluded"][0]["reason"], "excluded-extension:.png")
        self.assertIn("unmatched-input", doc["diagnostics"]["counts_by_code"])

    def test_input_list_file(self):
        p1 = self.write("x.log", "2026-09-13 12:00:00,123 - a - ERROR - failed 1\n")
        lst = self.write("inputs.txt", "# comment\n%s\n" % p1)
        doc = self.analyze([], extra=["--input-list", lst])
        self.assertEqual(doc["coverage"]["events_included"], 1)

    def test_min_severity_filter_disclosed(self):
        doc = self.analyze([fixture("jvm", "jvm-classic.log")], extra=["--min-severity", "high"])
        self.assertTrue(all(g["severity"] in ("high", "critical") for g in doc["groups"]))
        f = doc["filtering"]
        self.assertEqual(f["groups_total"], f["groups_reported"] + f["groups_filtered_by_severity"])
        self.assertGreater(f["groups_filtered_by_severity"], 0)
        self.assertEqual(f["events_in_reported_groups"] + f["events_in_filtered_groups"], doc["coverage"]["events_included"])

    def test_fail_on_severity_exit_4(self):
        doc = self.analyze([fixture("jvm", "jvm-classic.log")], extra=["--fail-on-severity", "high"], expect_code=4)
        self.assertEqual(doc["status"]["exit_code"], 4)
        doc = self.analyze([fixture("jvm", "jvm-classic.log")], extra=["--fail-on-severity", "critical"], out=self.out_dir("b"))
        self.assertEqual(doc["_exit_code"], 0)

    def test_since_validation(self):
        code, _, se = run_cli([fixture("jvm", "jvm-classic.log"), "--since", "yesterday", "--out", self.out_dir()])
        self.assertEqual(code, 2)
        self.assertIn("--since must be", se)

    def test_input_format_override_and_unknown(self):
        code, _, se = run_cli([fixture("jvm", "jvm-classic.log"), "--input-format", "nope", "--out", self.out_dir()])
        self.assertEqual(code, 2)
        doc = self.analyze([fixture("jvm", "jvm-classic.log")], extra=["--input-format", "text:jvm-classic"], out=self.out_dir("b"))
        self.assertEqual(doc["inputs"]["files"][0]["format"], "text:jvm-classic")
        self.assertEqual(doc["coverage"]["events_included"], 3)

    def test_output_overwrite_and_temp_cleanup(self):
        doc1 = self.analyze([fixture("jvm", "jvm-classic.log")], extra=["--keep-temp"])
        temp = doc1["aggregation"]["temp_dir"]
        self.assertTrue(temp and os.path.isdir(temp))
        import shutil
        shutil.rmtree(temp, ignore_errors=True)
        doc2 = self.analyze([fixture("jvm", "jvm-classic.log")])
        self.assertIsNone(doc2["aggregation"]["temp_dir"])
        # second run overwrote the same file names in place
        self.assertEqual(doc2["coverage"]["events_included"], doc1["coverage"]["events_included"])

    def test_render_mode_with_suggestions(self):
        doc = self.analyze([fixture("jvm", "jvm-classic.log")])
        gid = doc["groups"][0]["id"]
        sugg = self.write("sugg.json", json.dumps({"schema_version": "1", "groups": {
            gid: {"root_cause": {"observed": ["obs"], "hypotheses": [{"hypothesis": "h", "evidence": ["e"], "confidence": 0.7}], "uncertainty": ["u"]},
                  "suggestions": [{"summary": "Model fix <b>bold</b>", "rationale": "because", "kind": "source_backed", "confidence": 0.8,
                                   "references": [{"repo": "orders", "path": "src/X.java", "line": 3}]}]},
            "LT-000000000000": {"suggestions": []}}}))
        code, so, se = run_cli(["--render", os.path.join(self.out_dir(), "analysis.json"), "--suggestions", sugg, "--out", self.out_dir("r"), "--format", "json", "--format", "html", "--format", "markdown"])
        self.assertEqual(code, 0, se)
        with open(os.path.join(self.out_dir("r"), "analysis.json"), encoding="utf-8") as fh:
            r = json.load(fh)
        self.assertEqual(r["status"]["model_refinement"]["applied"], 1)
        self.assertEqual(r["status"]["model_refinement"]["unknown_ids"], ["LT-000000000000"])
        g = next(g for g in r["groups"] if g["id"] == gid)
        self.assertEqual(g["investigation"]["status"], "model_refined")
        s = g["investigation"]["suggestions"][0]
        self.assertEqual(s["origin"], "model")
        self.assertEqual(s["kind"], "generic")  # model reference was not tool-verified -> cannot claim source_backed
        html = open(os.path.join(self.out_dir("r"), "report.html"), encoding="utf-8").read()
        self.assertNotIn("<b>bold</b>", html)
        self.assertIn("&lt;b&gt;bold&lt;/b&gt;", html)
        code, _, se = run_cli(["--suggestions", sugg, "--out", self.out_dir("q")] + [fixture("jvm", "jvm-classic.log")])
        self.assertEqual(code, 2)
        self.assertIn("--suggestions requires --render", se)


if __name__ == "__main__":
    unittest.main()


class InvocationEdgeTests(TriageTestCase):
    def test_only_excluded_inputs_is_a_processing_failure(self):
        path = self.write("photo.png", b"\x89PNG\r\n\x1a\n" + b"\x00" * 64, binary=True)
        doc = self.analyze([path], formats=["json"], expect_code=1)
        self.assertEqual(doc["status"]["completion"], "failed")
        self.assertEqual(doc["status"]["exit_code"], 1)
        self.assertTrue(any("excluded" in r for r in doc["status"]["reasons"]), doc["status"]["reasons"])
        self.assertEqual(doc["coverage"]["events_included"], 0)

    def test_empty_format_list_is_a_usage_error(self):
        path = self.write("a.log", "2026-09-13 12:00:00 ERROR boom\n")
        for value in (",", ""):
            code, so, se = run_cli([path, "--out", self.out_dir("fmt"), "--format", value, "--quiet"])
            self.assertEqual(code, 2, se)
            self.assertIn("format", se.lower())

    def test_generated_at_honours_now(self):
        path = self.write("a.log", "2026-09-13 12:00:00 ERROR boom\n")
        doc = self.analyze([path], formats=["json"])
        self.assertEqual(doc["generated_at"], "2026-09-14T00:00:00Z")

