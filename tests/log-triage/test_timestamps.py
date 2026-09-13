import unittest

from _helpers import TriageTestCase, fixture
from log_triage.timestamps import format_iso, parse_offset_spec, parse_timestamp

NOW = 1789000000.0


class TimestampTests(unittest.TestCase):
    def test_formats(self):
        cases = {
            "2026-09-13T12:00:00Z": ("2026-09-13T12:00:00Z", ()),
            "2026-09-13 12:00:00,123": ("2026-09-13T12:00:00.123Z", ("naive",)),
            "2026-09-13T14:00:00.123456+02:00": ("2026-09-13T12:00:00.123Z", ()),
            "2026/09/13 12:00:00": ("2026-09-13T12:00:00Z", ("naive",)),
            "13/Sep/2026:12:00:00 +0000": ("2026-09-13T12:00:00Z", ()),
            "[Sun Sep 13 12:00:00.123456 2026]": ("2026-09-13T12:00:00.123Z", ("naive",)),
            "13-Sep-2026 12:00:00 UTC": ("2026-09-13T12:00:00Z", ()),
            "13-Sep-2026::12:00:00.123456": ("2026-09-13T12:00:00.123Z", ("naive",)),
            "2026-Sep-13 12:00:00.123456": ("2026-09-13T12:00:00.123Z", ("naive",)),
            "Sep 13, 2026 12:00:00 PM": ("2026-09-13T12:00:00Z", ("naive",)),
            "20260913120000": ("2026-09-13T12:00:00Z", ("naive",)),
            "1694606400": ("2023-09-13T12:00:00Z", ("epoch_unit:s",)),
            "1694606400123": ("2023-09-13T12:00:00.123Z", ("epoch_unit:ms",)),
            "1694606400123456": ("2023-09-13T12:00:00.123Z", ("epoch_unit:us",)),
            "1694606400123456789": ("2023-09-13T12:00:00.123Z", ("epoch_unit:ns",)),
        }
        for text, (expected, flags) in cases.items():
            ts, fl = parse_timestamp(text, 0, NOW)
            self.assertEqual(format_iso(ts), expected, text)
            self.assertEqual(fl, flags, text)

    def test_assumed_offset_applies_to_naive_only(self):
        ts_naive, _ = parse_timestamp("2026-09-13 12:00:00", 7200, NOW)
        ts_utc, _ = parse_timestamp("2026-09-13T12:00:00Z", 7200, NOW)
        self.assertEqual(format_iso(ts_naive), "2026-09-13T10:00:00Z")
        self.assertEqual(format_iso(ts_utc), "2026-09-13T12:00:00Z")
        self.assertEqual(parse_offset_spec("+02:00"), 7200)
        self.assertEqual(parse_offset_spec("-0530"), -19800)
        self.assertEqual(parse_offset_spec("UTC"), 0)
        with self.assertRaises(ValueError):
            parse_offset_spec("Mars/Olympus")

    def test_missing_year_inference(self):
        # now = 2026-09-10; "Sep 13" is in the future -> previous year
        ts, fl = parse_timestamp("Sep 13 12:00:00", 0, NOW)
        self.assertIn("year_inferred", fl)
        self.assertTrue(format_iso(ts).startswith("2025-09-13"))
        ts, fl = parse_timestamp("Sep 09 12:00:00", 0, NOW)
        self.assertTrue(format_iso(ts).startswith("2026-09-09"))

    def test_time_only_and_garbage(self):
        self.assertEqual(parse_timestamp("12:00:00.123", 0, NOW), (None, ("time_only",)))
        self.assertEqual(parse_timestamp("not a date", 0, NOW), (None, ("unparsed",)))
        self.assertEqual(parse_timestamp("", 0, NOW), (None, ("missing",)))
        self.assertEqual(parse_timestamp("2026-13-45T99:99:99Z", 0, NOW)[0], None)


class SinceFilterTests(TriageTestCase):
    def test_since_with_zones_and_untimed(self):
        doc = self.analyze([fixture("edge", "timezones.log")], extra=["--since", "2026-09-13T11:00:00Z"])
        # utc explicit + offset explicit (same instant 12:00Z) + naive (assumed UTC 12:00) + "missing year" (inferred 2026 from
        # --now, 11:59:59Z) are >= 11:00Z; time-only -> untimed -> excluded by default
        self.assertEqual(doc["coverage"]["events_included"], 4)
        self.assertEqual(doc["coverage"]["events_filtered_by_since"], 0)
        self.assertEqual(doc["coverage"]["events_untimed_excluded_by_since"], 1)
        doc = self.analyze([fixture("edge", "timezones.log")], extra=["--since", "2026-09-13T11:00:00Z", "--keep-untimed"], out=self.out_dir("k"))
        self.assertEqual(doc["coverage"]["events_included"], 5)
        self.assertEqual(doc["coverage"]["events_untimed_included"], 1)
        # naive log timestamps interpreted in +02:00 -> "2026-09-13 12:00:00" becomes 10:00Z and drops below --since 11:00Z
        doc = self.analyze([fixture("edge", "timezones.log")], extra=["--since", "2026-09-13T11:00:00Z", "--assume-tz", "+02:00"], out=self.out_dir("tz"))
        self.assertEqual(doc["coverage"]["events_included"], 2)
        self.assertEqual(doc["configuration"]["assume_tz"], "+02:00")

    def test_since_naive_uses_assumed_zone(self):
        doc = self.analyze([fixture("edge", "timezones.log")], extra=["--since", "2026-09-13 13:00:00", "--assume-tz", "+02:00"])
        # --since 13:00 +02:00 == 11:00Z -> same as the explicit case with assume-tz
        self.assertEqual(doc["coverage"]["events_included"], 2)
        self.assertEqual(doc["filtering"]["since_epoch_utc"], parse_timestamp("2026-09-13T11:00:00Z", 0)[0])

    def test_untimed_events_disclosed(self):
        doc = self.analyze([fixture("edge", "no-timestamps.log")])
        self.assertEqual(doc["coverage"]["events_without_timestamp"], doc["coverage"]["events_included"])
        self.assertEqual(doc["timeline"]["events_without_timestamp"], doc["coverage"]["events_included"])
        self.assertIsNone(doc["coverage"]["time_range"]["first"])
        for g in doc["groups"]:
            self.assertIsNone(g["first_seen"])
            self.assertEqual(g["untimed_count"], g["count"])


if __name__ == "__main__":
    unittest.main()
