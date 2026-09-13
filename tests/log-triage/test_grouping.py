import json
import os
import unittest

from _helpers import TriageTestCase, fixture, groups_by_template


class GroupingTests(TriageTestCase):
    def test_equivalence_and_meaningful_distinctions(self):
        doc = self.analyze([fixture("edge", "grouping-equivalence.log")])
        groups = doc["groups"]
        # 30 equivalent lines (different uuid/user/ip/port/duration/attempt/request id) -> one group of 30
        big = [g for g in groups if g["count"] == 30]
        self.assertEqual(len(big), 1, [(g["template"], g["count"]) for g in groups])
        self.assertIn("<uuid>", big[0]["template"])
        self.assertIn("<ip>", big[0]["template"])
        self.assertIn("<dur>", big[0]["template"])
        self.assertIn("order-service", big[0]["services"])
        # status codes 500 vs 503 are meaningful -> separate groups, each of count 1
        statuses = sorted((g.get("http") or {}).get("status") for g in groups if g.get("http"))
        self.assertEqual(statuses, [500, 503])
        # a different service identity is a distinct group even with the same template
        svc = {tuple(g["services"].keys()) for g in groups}
        self.assertIn(("payment-service",), svc)
        self.assertEqual(sum(g["count"] for g in groups), doc["coverage"]["events_included"])
        self.assertEqual(doc["coverage"]["events_included"], 33)

    def test_fingerprints_are_stable_and_pinned(self):
        """Pinned group ids: changing templating, frame normalization or key components must bump
        FINGERPRINT_VERSION (see docs/log-triage/canonical-model.md)."""
        doc = self.analyze([fixture("jvm", "jvm-classic.log")])
        ids = sorted(g["id"] for g in doc["groups"])
        self.assertEqual(len(ids), 3)
        doc2 = self.analyze([fixture("jvm", "jvm-classic.log")], out=self.out_dir("b"))
        self.assertEqual([g["id"] for g in doc["groups"]], [g["id"] for g in doc2["groups"]])
        self.assertEqual([g["fingerprint"] for g in doc["groups"]], [g["fingerprint"] for g in doc2["groups"]])
        for g in doc["groups"]:
            self.assertRegex(g["id"], r"^LT-[0-9a-f]{12}$")
            self.assertEqual(g["fingerprint_version"], "1")
            self.assertEqual(g["id"], "LT-" + g["fingerprint"][:12])
        # pinned value for the exception group (guards accidental fingerprint drift)
        exc_group = next(g for g in doc["groups"] if g["exception"])
        self.assertEqual(exc_group["id"], "LT-" + exc_group["fingerprint"][:12])
        self.assertIn("exc=java.lang.IllegalStateException>java.sql.SQLTransientConnectionException", exc_group["grouping"]["key_components"])
        self.assertEqual(exc_group["fingerprint"], "3852f6e44e77626e85a00a93549fc7716852030753cd75c17978cea3b2859a5c")

    def test_spill_to_disk_matches_in_memory(self):
        inputs = [fixture("edge", "grouping-equivalence.log"), fixture("jvm", "jvm-classic.log"), fixture("web", "access-combined.log")]
        mem = self.analyze(inputs)
        spill = self.analyze(inputs, extra=["--limit", "max_groups_in_memory=2"], out=self.out_dir("s"))
        self.assertFalse(mem["aggregation"]["spilled_to_disk"])
        self.assertTrue(spill["aggregation"]["spilled_to_disk"])
        self.assertGreater(spill["aggregation"]["spill_count"], 0)
        self.assertGreater(spill["aggregation"]["temp_bytes_peak"], 0)
        key = lambda g: (g["id"], g["count"], g["first_seen"], g["last_seen"], g["severity"], g["category"], len(g["examples"]))  # noqa: E731
        self.assertEqual([key(g) for g in mem["groups"]], [key(g) for g in spill["groups"]])
        self.assertEqual(mem["filtering"], spill["filtering"])

    def test_ordering_is_deterministic(self):
        doc = self.analyze([fixture("edge", "grouping-equivalence.log"), fixture("web", "access-combined.log")])
        from log_triage.config import SEVERITY_RANK
        ranks = [(-SEVERITY_RANK[g["severity"]], -g["count"], g["first_seen"] is None, g["first_seen"] or "", g["fingerprint"]) for g in doc["groups"]]
        self.assertEqual(ranks, sorted(ranks))

    def test_exception_chain_and_frames_distinguish(self):
        content = ("2026-09-13 12:00:00,123 [main] ERROR c.a.X - failed\njava.lang.IllegalStateException: a\n\tat com.acme.A.run(A.java:1)\n"
                   "2026-09-13 12:00:01,123 [main] ERROR c.a.X - failed\njava.lang.IllegalStateException: a\n\tat com.acme.B.run(B.java:1)\n"
                   "2026-09-13 12:00:02,123 [main] ERROR c.a.X - failed\njava.lang.IllegalArgumentException: a\n\tat com.acme.A.run(A.java:1)\n"
                   "2026-09-13 12:00:03,123 [main] ERROR c.a.X - failed\njava.lang.IllegalStateException: a\n\tat com.acme.A.run(A.java:99)\n")
        path = self.write("frames.log", content)
        doc = self.analyze([path])
        # different top frame -> different group; different exception type -> different group; line number only -> same group
        self.assertEqual(sorted(g["count"] for g in doc["groups"]), [1, 1, 2])

    def test_correlation_ids_are_not_grouping_keys(self):
        content = "".join("2026-09-13T12:00:%02dZ ERROR svc failed trace_id=%s request_id=req-%d\n" % (i, "a" * 8 + str(i), i) for i in range(8))
        content += "2026-09-13T12:01:00Z ERROR svc other failure trace_id=aaaaaaaa1\n"
        path = self.write("corr.log", content)
        doc = self.analyze([path])
        self.assertEqual(sorted(g["count"] for g in doc["groups"]), [1, 8])
        g = next(g for g in doc["groups"] if g["count"] == 8)
        self.assertEqual(len(g["correlation"]["request_ids"]), 5)   # bounded
        self.assertTrue(g["correlation"]["truncated"])

    def test_exact_counts_with_many_events(self):
        n = 5000
        content = "".join("2026-09-13T12:%02d:%02dZ ERROR svc failed to process order %d\n" % ((i // 60) % 60, i % 60, i) for i in range(n))
        path = self.write("many.log", content)
        doc = self.analyze([path], extra=["--limit", "max_groups_in_memory=50", "--limit", "fingerprint_cache_size=10"])
        self.assertEqual(doc["coverage"]["events_included"], n)
        self.assertEqual(doc["groups"][0]["count"], n)
        self.assertEqual(len(doc["groups"][0]["examples"]), 4)   # 3 retained + last seen
        self.assertTrue(doc["groups"][0]["examples"][-1]["is_last_seen"])


if __name__ == "__main__":
    unittest.main()
