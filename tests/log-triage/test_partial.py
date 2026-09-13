import json
import os
import unittest

from _helpers import TriageTestCase, fixture


class PartialProcessingTests(TriageTestCase):
    def test_interruption_preserves_partial_results(self):
        inputs = [fixture("edge", "grouping-equivalence.log"), fixture("jvm", "jvm-classic.log")]
        doc = self.analyze(inputs, env={"LOG_TRIAGE_TEST_INTERRUPT_AFTER": "10"}, expect_code=3, formats=["json", "html", "markdown", "sarif"])
        self.assertEqual(doc["status"]["completion"], "partial")
        self.assertTrue(doc["status"]["interrupted"])
        self.assertIn("interrupted", doc["status"]["reasons"])
        self.assertEqual(doc["coverage"]["events_included"], 10)
        self.assertEqual(sum(g["count"] for g in doc["groups"]), 10)
        statuses = {os.path.basename(f["path"]): f["status"] for f in doc["inputs"]["files"]}
        self.assertEqual(statuses["grouping-equivalence.log"], "partial")
        self.assertEqual(statuses["jvm-classic.log"], "pending")
        for name in ("analysis.json", "report.html", "report.md", "analysis.sarif"):
            self.assertTrue(os.path.exists(os.path.join(self.out_dir(), name)))
        html = open(os.path.join(self.out_dir(), "report.html"), encoding="utf-8").read()
        self.assertIn("Analysis partial", html)
        sarif = json.load(open(os.path.join(self.out_dir(), "analysis.sarif"), encoding="utf-8"))
        self.assertEqual(sarif["runs"][0]["invocations"][0]["properties"]["completion"], "partial")

    def test_output_disk_exhaustion_is_reported(self):
        doc = self.analyze([fixture("jvm", "jvm-classic.log")], formats=["json", "csv"], env={"LOG_TRIAGE_TEST_ENOSPC_AT": "groups.csv"}, expect_code=3)
        self.assertTrue(os.path.exists(os.path.join(self.out_dir(), "analysis.json")))
        self.assertFalse(os.path.exists(os.path.join(self.out_dir(), "groups.csv")))
        self.assertFalse(os.path.exists(os.path.join(self.out_dir(), "groups.csv.tmp")))
        self.assertIn("No space left", doc["_stderr"])
        # when every output fails the run is a processing failure
        doc = self.analyze([fixture("jvm", "jvm-classic.log")], formats=["json"], env={"LOG_TRIAGE_TEST_ENOSPC_AT": "analysis.json"}, expect_code=1, out=self.out_dir("b"))
        self.assertFalse(os.path.exists(os.path.join(self.out_dir("b"), "analysis.json")))

    def test_failed_input_makes_run_partial_not_failed(self):
        doc = self.analyze([fixture("edge", "binary.bin"), fixture("jvm", "jvm-classic.log")], expect_code=3)
        self.assertEqual(doc["status"]["completion"], "partial")
        self.assertEqual(doc["inputs"]["summary"]["excluded"], 1)
        self.assertEqual(doc["inputs"]["summary"]["processed"], 1)

    def test_all_inputs_unusable_is_failure(self):
        doc = self.analyze([fixture("edge", "binary.bin")], expect_code=1)
        self.assertEqual(doc["status"]["completion"], "failed")

    def test_spill_disk_full_is_reported(self):
        from log_triage.config import Limits
        from log_triage.aggregate import GroupStore
        from log_triage.model import Event
        from log_triage.redact import Redactor
        from log_triage.timeline import Timeline
        import sqlite3
        lim = Limits()
        lim.max_groups_in_memory = 2
        store = GroupStore(lim, self.tmp, Redactor(salt="x"), Timeline(10), {1: "a"})

        def boom():
            raise sqlite3.OperationalError("database or disk is full")
        store._spill = boom
        with self.assertRaises(sqlite3.OperationalError):
            for i in range(5):
                e = Event()
                e.message = "unique %s" % ("word" * (i + 1))
                e.input_id = 1
                store.add(e)
        from log_triage.engine import _is_disk_full
        self.assertTrue(_is_disk_full(sqlite3.OperationalError("database or disk is full")))
        self.assertTrue(_is_disk_full(OSError(28, "no space")))
        self.assertFalse(_is_disk_full(ValueError("x")))


if __name__ == "__main__":
    unittest.main()
