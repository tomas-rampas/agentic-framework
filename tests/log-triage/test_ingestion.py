import gzip
import os
import random
import unittest

from _helpers import TriageTestCase, fixture, parse_events


class ReaderTests(TriageTestCase):
    def test_chunk_boundaries_do_not_change_events(self):
        from log_triage.config import Limits
        from log_triage.reader import LineReader
        random.seed(3)
        lines = ["2026-09-13 12:00:%02d,123 - a - ERROR - line %d %s" % (i % 60, i, "x" * random.randint(0, 300)) for i in range(400)]
        path = self.write("chunk.log", "\n".join(lines) + "\n")
        ref = [t for t in LineReader(path, Limits())]
        for cs in (1, 3, 17, 256, 4096):
            lim = Limits()
            lim.read_chunk_bytes = cs
            got = [t for t in LineReader(path, lim)]
            self.assertEqual(got, ref, "chunk size %d" % cs)
        # multiline events survive tiny chunks
        for cs in (5, 64):
            events, ctx, name, conf = parse_events(fixture("jvm", "jvm-classic.log"), limits=self._limits(cs))
            self.assertEqual(len(events), 3)
            self.assertEqual(events[1].exceptions[0].type, "java.lang.IllegalStateException")

    def test_binary_heuristic_keeps_legacy_text_encodings(self):
        from log_triage.reader import detect_binary
        random.seed(11)
        noise = bytes(random.randrange(256) for _ in range(8192))
        self.assertEqual(detect_binary(noise, "payload.dat")[0], "binary")
        self.assertEqual(detect_binary(bytes(range(256)) * 4, "x.bin")[0], "binary")
        cyrillic = ("2026-09-13 12:00:00 ERROR Ошибка подключения к базе данных, повтор через 5 секунд\n" * 40).encode("cp1251")
        self.assertEqual(detect_binary(cyrillic, "app.log"), (None, None))
        latin1 = ("2026-09-13 12:00:00 ERROR Échec de connexion à la base de données\n" * 40).encode("latin-1")
        self.assertEqual(detect_binary(latin1, "app.log"), (None, None))
        utf16 = ("2026-09-13 12:00:00 ERROR boom\n" * 40).encode("utf-16-le")
        self.assertEqual(detect_binary(utf16, "app.log"), (None, None))
        self.assertEqual(detect_binary(b"ElfFile\x00" + b"\x00" * 64, "Security.evtx")[0], "evtx")

    @staticmethod
    def _limits(chunk):
        from log_triage.config import Limits
        lim = Limits()
        lim.read_chunk_bytes = chunk
        return lim

    def test_gzip_variants(self):
        doc = self.analyze([fixture("edge", "plain.log.gz")])
        f = doc["inputs"]["files"][0]
        self.assertEqual(f["compression"], "gzip")
        self.assertEqual(f["status"], "processed")
        self.assertEqual(doc["coverage"]["events_included"], 201)
        doc = self.analyze([fixture("edge", "multi-member.log.gz")], out=self.out_dir("m"))
        self.assertEqual(doc["coverage"]["events_included"], 2)
        doc = self.analyze([fixture("edge", "truncated.log.gz")], out=self.out_dir("t"), expect_code=3)
        f = doc["inputs"]["files"][0]
        self.assertEqual(f["status"], "partial")
        self.assertIn("truncated", f["reason"])
        self.assertGreater(doc["coverage"]["events_included"], 0)   # salvaged data before the truncation
        self.assertIn("input-truncated", doc["diagnostics"]["counts_by_code"])

    def test_decompression_limit(self):
        doc = self.analyze([fixture("edge", "plain.log.gz")], extra=["--limit", "max_decompressed_bytes=1000"], expect_code=3)
        f = doc["inputs"]["files"][0]
        self.assertEqual(f["status"], "partial")
        self.assertIn("max_decompressed_bytes", f["reason"])

    def test_unsupported_compression_and_binary_inputs(self):
        doc = self.analyze([fixture("edge", "bzip2-magic.log"), fixture("edge", "evtx-magic.evtx"), fixture("edge", "journal-magic.journal"),
                            fixture("edge", "binary.bin"), fixture("jvm", "jvm-classic.log")], expect_code=3)
        by = {os.path.basename(f["path"]): f for f in doc["inputs"]["files"]}
        self.assertEqual(by["bzip2-magic.log"]["reason"], "unsupported-compression:bzip2")
        self.assertEqual(by["evtx-magic.evtx"]["reason"], "binary-unsupported:evtx")
        self.assertEqual(by["journal-magic.journal"]["reason"], "binary-unsupported:journal")
        self.assertEqual(by["binary.bin"]["reason"], "binary-unsupported:binary")
        self.assertEqual(by["jvm-classic.log"]["status"], "processed")
        msgs = " ".join(d["message"] for d in doc["diagnostics"]["records"])
        self.assertIn("wevtutil", msgs)
        self.assertIn("journalctl", msgs)
        self.assertIn("bzip2 -dk", msgs)
        self.assertEqual(doc["status"]["completion"], "partial")

    def test_encodings(self):
        doc = self.analyze([fixture("edge", "utf8-bom.log"), fixture("edge", "latin1.log"), fixture("powershell", "transcript-utf16.txt")])
        by = {os.path.basename(f["path"]): f for f in doc["inputs"]["files"]}
        self.assertEqual(by["utf8-bom.log"]["events"], 2)
        self.assertEqual(by["utf8-bom.log"]["encoding"], "utf-8")
        self.assertEqual(by["latin1.log"]["events"], 1)
        self.assertGreaterEqual(doc["coverage"]["encoding_replacements"], 3)
        self.assertIn("encoding-replacement", doc["diagnostics"]["counts_by_code"])
        self.assertEqual(by["transcript-utf16.txt"]["encoding"], "utf-16-le")
        self.assertGreaterEqual(by["transcript-utf16.txt"]["events"], 1)
        templates = [g["template"] for g in doc["groups"]]
        self.assertTrue(any("with bom" in t for t in templates))
        self.assertTrue(any("caf" in t for t in templates))

    def test_oversized_lines_are_truncated_and_counted(self):
        doc = self.analyze([fixture("edge", "oversized-line.log")], extra=["--max-line-bytes", "500"])
        self.assertEqual(doc["coverage"]["events_included"], 3)      # the event is still counted
        self.assertEqual(doc["coverage"]["truncated_lines"], 1)
        self.assertGreater(doc["coverage"]["discarded_bytes"], 4000)
        self.assertIn("oversized-line", doc["diagnostics"]["counts_by_code"])
        long_group = [g for g in doc["groups"] if g["count"] == 1 and "x" in g["template"]]
        self.assertTrue(long_group)
        self.assertTrue(long_group[0]["examples"][0]["truncated"])

    def test_empty_and_mixed_inputs(self):
        doc = self.analyze([fixture("edge", "empty.log"), fixture("edge", "mixed-formats.log")])
        by = {os.path.basename(f["path"]): f for f in doc["inputs"]["files"]}
        self.assertEqual(by["empty.log"]["events"], 0)
        self.assertEqual(by["mixed-formats.log"]["events"], 4)   # python, json, syslog (+ garbage continuation), python
        templates = [g["template"] for g in doc["groups"]]
        self.assertTrue(any("json line in a text file" in t for t in templates))
        self.assertTrue(any("syslog line in a text file" in t for t in templates))
        syslog_group = next(g for g in doc["groups"] if "syslog line" in g["template"])
        self.assertIn("binary-ish garbage", syslog_group["examples"][0].get("body", ""))

    def test_input_changed_during_analysis_is_detected(self):
        from log_triage.inputs import resolve_inputs
        from log_triage.config import Limits
        path = self.write("live.log", "2026-09-13 12:00:00,123 - a - ERROR - one\n")
        inputs = resolve_inputs([path], Limits())
        f = inputs.files[0]
        self.assertFalse(f.check_changed())
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("2026-09-13 12:00:01,123 - a - ERROR - two\n")
        os.utime(path, (f.mtime_ns / 1e9 + 5, f.mtime_ns / 1e9 + 5))
        self.assertTrue(f.check_changed())

    def test_max_files_limit(self):
        for i in range(4):
            self.write("many/f%d.log" % i, "2026-09-13 12:00:00,123 - a - ERROR - x\n")
        doc = self.analyze([os.path.join(self.tmp, "many")], extra=["--limit", "max_files=2"], expect_code=3)
        self.assertEqual(len(doc["inputs"]["files"]), 2)
        self.assertEqual(doc["inputs"]["excluded_total"], 2)
        self.assertIn("limit-reached", doc["diagnostics"]["counts_by_code"])


if __name__ == "__main__":
    unittest.main()
