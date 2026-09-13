import unittest

from _helpers import TriageTestCase
from log_triage.classify import classify
from log_triage.model import LEVEL_ERROR, LEVEL_FATAL, LEVEL_INFO, LEVEL_WARN


class ClassifyTests(unittest.TestCase):
    def test_optional_literal_suffix_does_not_break_triggers(self):
        from log_triage.classify import classify
        a = classify("connection time out after <dur>", [], None, 13, None, None, None, 1)
        self.assertEqual(a.category, "timeout")
        a = classify("request timed out", [], None, 13, None, None, None, 1)
        self.assertEqual(a.category, "timeout")

    def test_observed_crash_is_critical(self):
        a = classify("Unhandled exception. System.NullReferenceException: x", ["System.NullReferenceException"], "", LEVEL_FATAL, None, None, "application_crash")
        self.assertEqual((a.category, a.severity, a.basis), ("application_crash", "critical", "observed"))
        self.assertIn("process_termination", a.signals)

    def test_error_level_without_evidence_is_medium_unknown(self):
        a = classify("charge failed for order <n>", [], "", LEVEL_ERROR, None, None, None)
        self.assertEqual((a.category, a.severity, a.basis), ("unknown", "medium", "unknown"))
        self.assertLess(a.confidence, 0.5)

    def test_frequency_does_not_change_severity(self):
        a1 = classify("connection refused to db:<n>", [], "", LEVEL_ERROR, None, None, None, count=1)
        a2 = classify("connection refused to db:<n>", [], "", LEVEL_ERROR, None, None, None, count=10_000_000)
        self.assertEqual((a1.severity, a1.category, a1.confidence), (a2.severity, a2.category, a2.confidence))

    def test_info_level_with_alarming_words_is_not_high(self):
        a = classify("error rate is <pct>, no outage detected, everything healthy", [], "", LEVEL_INFO, None, None, None)
        self.assertIn(a.severity, ("info", "low"))
        a = classify("failed password for invalid user root from <ip>", [], "", LEVEL_INFO, None, None, None)
        self.assertIn(a.severity, ("info", "low"))

    def test_http_status_mapping(self):
        self.assertEqual(classify("GET /x -> 503", [], "", LEVEL_ERROR, 503, None, None).category, "availability")
        self.assertEqual(classify("GET /x -> 401", [], "", LEVEL_WARN, 401, None, None).category, "auth")
        self.assertEqual(classify("GET /x -> 504", [], "", LEVEL_ERROR, 504, None, None).category, "timeout")
        self.assertEqual(classify("GET /x -> 404", [], "", LEVEL_WARN, 404, None, None).category, "client_error")
        self.assertEqual(classify("GET /x -> 429", [], "", LEVEL_WARN, 429, None, None).category, "resource_exhaustion")
        a = classify("GET /x -> 500", [], "", LEVEL_ERROR, 500, None, None)
        self.assertEqual((a.category, a.severity, a.basis), ("availability", "high", "observed"))
        self.assertIn("failed_requests", a.signals)

    def test_exception_type_evidence(self):
        self.assertEqual(classify("x", ["java.lang.OutOfMemoryError"], "", LEVEL_ERROR, None, None, None).category, "resource_exhaustion")
        self.assertEqual(classify("x", ["java.net.SocketTimeoutException"], "", LEVEL_ERROR, None, None, None).category, "timeout")
        self.assertEqual(classify("x", ["System.IO.FileNotFoundException"], "", LEVEL_ERROR, None, None, None).category, "configuration")
        self.assertEqual(classify("x", ["org.postgresql.util.PSQLException"], "", LEVEL_ERROR, None, None, None).category, "dependency_failure")
        a = classify("x", ["java.lang.IllegalStateException", "java.sql.SQLTransientConnectionException"], "", LEVEL_ERROR, None, None, None)
        self.assertEqual(a.category, "dependency_failure")
        self.assertTrue(any("java.sql.SQLTransientConnectionException" in r for r in a.rationale))

    def test_data_loss_and_oom_are_critical_even_at_warn(self):
        self.assertEqual(classify("checksum mismatch on segment <n>, data corrupt", [], "", LEVEL_WARN, None, None, None).severity, "critical")
        self.assertEqual(classify("Out of memory: Killed process <n> (java)", [], "", None, None, None, None).severity, "critical")

    def test_warn_level_caps_at_medium(self):
        a = classify("connection refused to upstream db", [], "", LEVEL_WARN, None, None, None)
        self.assertEqual(a.category, "dependency_failure")
        self.assertEqual(a.severity, "medium")
        self.assertTrue(any("capped" in r for r in a.rationale))

    def test_uncertainty_labels_present(self):
        for text, lvl in (("something odd", LEVEL_ERROR), ("timeout after <dur>", LEVEL_WARN), ("Started App in <dur>", LEVEL_INFO)):
            a = classify(text, [], "", lvl, None, None, None)
            self.assertIn(a.basis, ("observed", "inferred", "unknown"))
            self.assertTrue(0.1 <= a.confidence <= 0.95)
            self.assertTrue(a.rationale)
            d = a.to_dict()
            self.assertEqual(set(d), {"severity", "category", "confidence", "basis", "rationale", "impact_signals"})

    def test_trigger_gating_is_lossless(self):
        import re
        from log_triage import classify as c
        self.assertEqual([k for k, v in c._TRIGGERS.items() if v is None], [])
        corpus = []
        for cat, pat, sig in c.RULES:
            for alt in c._split_alternatives(pat.pattern):
                a = alt.strip().replace("\\b", "")
                a = re.sub(r"\(\?:([^()|]+)\|[^()]*\)", r"\1", a)
                a = re.sub(r"\(\?:([^()]*)\)\??", r"\1", a)
                a = re.sub(r"\\[sdw]\+?", " 1", a).replace("\\.", ".").replace("?", "").replace("\\", "")
                a = re.sub(r"\[[^\]]+\]", "5", a).replace(".{0,30}", " x ").replace(".{0,20}", " x ")
                corpus.append("prefix text " + a + " suffix")
        for text in corpus:
            low = text.lower()
            full = {cat for cat, pat, sig in c.RULES if pat.search(low)}
            self.assertEqual(full, set(c._scan_rules(low)), text)


if __name__ == "__main__":
    unittest.main()
