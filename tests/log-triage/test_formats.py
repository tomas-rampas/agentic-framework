"""One check per claimed layout / dialect / platform shape (the support matrix)."""
import os
import unittest

from _helpers import TriageTestCase, fixture, parse_events

# (fixture path, expected detected parser, expected event count, layout/dialect substring, checker)
CASES = [
    # .NET
    (("dotnet", "serilog-text.log"), "text", 5, "serilog-text", lambda e: e[1].exceptions[0].type == "System.InvalidOperationException" and e[1].exceptions[1].type == "System.IO.IOException" and e[4].ts is None),
    (("dotnet", "mel-console.log"), "text", 3, "mel-console", lambda e: e[1].level_text == "fail" and e[1].exceptions[0].type == "System.NullReferenceException" and e[1].message.startswith("Unhandled error")),
    (("dotnet", "nlog-default.log"), "text", 2, "nlog-default", lambda e: e[1].logger == "Acme.Orders.OrderService" and e[1].exceptions and e[1].exceptions[0].type == "System.TimeoutException"),
    (("dotnet", "log4net-default.log"), "text", 2, "log4net-default", lambda e: e[1].thread == "7" and e[1].exceptions[0].frames[0].line == 42),
    (("dotnet", "serilog-compact.ndjson"), "ndjson", 2, "serilog-compact", lambda e: e[0].message == "Failed to place order 42" and e[0].request_id == "0HN1" and e[0].exceptions[0].frames[0].file.endswith("OrderService.cs")),
    (("dotnet", "serilog-json.ndjson"), "ndjson", 1, "serilog-json", lambda e: e[0].logger == "Acme.Orders.PaymentClient" and e[0].exceptions[0].type == "System.TimeoutException"),
    (("dotnet", "log4net.xml"), "xml", 1, "xml", lambda e: e[0].layout == "log4net-xml" and e[0].exceptions[0].frames[0].line == 42 and e[0].app == "orders"),
    # JVM
    (("jvm", "jvm-classic.log"), "text", 3, "jvm-classic", lambda e: e[1].exceptions[1].type == "java.sql.SQLTransientConnectionException" and e[1].exceptions[0].frames[0].line == 42 and e[2].ts is None),
    (("jvm", "spring-boot.log"), "text", 2, "spring-boot", lambda e: e[1].app == "orders" and e[1].process == "1234" and e[1].exceptions[0].type == "java.lang.IllegalStateException"),
    (("jvm", "jul-simple.log"), "text", 2, "jul-simple", lambda e: e[0].level_text == "SEVERE" and e[0].message == "Failed to place order 42" and e[1].level_text == "INFO"),
    (("jvm", "kotlin-scala.log"), "text", 2, "jvm-classic", lambda e: e[0].exceptions[0].type == "kotlinx.coroutines.JobCancellationException" and e[0].exceptions[0].frames[1].file == "FeedViewModel.kt" and e[1].exceptions[0].type == "scala.MatchError"),
    (("jvm", "log4j2-json.ndjson"), "ndjson", 1, "log4j2-json", lambda e: e[0].exceptions[0].frames[0].function == "com.acme.orders.OrderService.place" and abs(e[0].ts - 1789000000.123) < 0.01),
    (("jvm", "logstash-logback.ndjson"), "ndjson", 1, "logstash-logback", lambda e: e[0].logger == "com.acme.orders.OrderService" and e[0].exceptions[0].frames[0].line == 42),
    (("jvm", "log4j.xml"), "xml", 2, "xml", lambda e: e[0].layout == "log4j-xml" and e[0].exceptions[0].type == "java.lang.IllegalStateException" and e[0].attrs.get("requestId") == "r1"),
    (("jvm", "jul.xml"), "xml", 1, "xml", lambda e: e[0].layout == "jul-xml" and e[0].level_text == "SEVERE" and e[0].exceptions[0].frames[0].line == 42),
    # Python
    (("python", "python-asctime.log"), "text", 3, "python-asctime", lambda e: [x.type for x in e[1].exceptions] == ["billing.errors.ChargeFailed", "requests.exceptions.ConnectionError"] and e[2].exceptions[0].frames[0].file.endswith("charge.py")),
    (("python", "python-basic.log"), "text", 3, "python-basic", lambda e: e[1].logger == "billing.worker" and e[1].level_text == "ERROR"),
    (("python", "loguru-default.log"), "text", 2, "loguru-default", lambda e: e[1].logger == "billing.worker" and e[1].exceptions[0].type == "requests.exceptions.ConnectionError"),
    (("python", "structlog-console.log"), "text", 2, "structlog-console", lambda e: e[1].attrs.get("order_id") == "42" and e[1].request_id == "req-1" and e[1].service == "billing"),
    (("python", "python-json-logger.ndjson"), "ndjson", 1, "python-json-logger", lambda e: e[0].exceptions[0].type == "requests.exceptions.ConnectionError" and e[0].logger == "billing.worker"),
    (("python", "structlog.ndjson"), "ndjson", 1, "structlog-json", lambda e: e[0].message == "charge failed" and e[0].exceptions[0].frames),
    (("python", "loguru.ndjson"), "ndjson", 1, "loguru-serialized", lambda e: e[0].exceptions[0].type == "ConnectionError" and e[0].exceptions[0].frames and e[0].attrs.get("order") == 42),
    # JavaScript / TypeScript
    (("node", "winston-simple.log"), "text", 2, "winston-simple", lambda e: e[1].exceptions[0].type == "TypeError" and e[1].exceptions[0].frames[0].file == "/app/src/users/service.js"),
    (("node", "console-error.log"), "text", 3, "headerless", lambda e: e[1].exceptions[0].type == "TypeError" and e[2].exceptions[0].type == "Error" and e[2].error_code == "ECONNREFUSED" and e[2].line_end == 9),
    (("node", "pino.ndjson"), "ndjson", 2, "pino", lambda e: e[0].level_num == 17 and e[0].http_status == 502 and e[0].request_id == "req-1" and e[1].level_text == "info"),
    (("node", "winston.ndjson"), "ndjson", 1, "winston-json", lambda e: e[0].service == "api" and e[0].exceptions[0].frames[0].line == 3),
    (("node", "bunyan.ndjson"), "ndjson", 1, "bunyan", lambda e: e[0].host == "web01" and e[0].exceptions[0].type == "Error"),
    # Go
    (("go", "go-std.log"), "text", 3, "go-std", lambda e: e[0].error_code is None and e[2].exceptions[0].type == "runtime error" and e[2].exceptions[0].frames[1].file == "/app/cmd/worker/main.go"),
    (("go", "zap-console.log"), "text", 2, "zap-console", lambda e: e[1].attrs.get("order") == 42 and e[1].level_text == "ERROR"),
    (("go", "zerolog-console.log"), "text", 2, "zerolog-console", lambda e: e[1].attrs.get("error") == "context deadline exceeded" and e[1].request_id == "req-1" and "time_only" in e[1].ts_flags),
    (("go", "slog-text.log"), "logfmt", 3, "logfmt", lambda e: e[1].exceptions[0].message == "context deadline exceeded" and e[1].service == "api"),
    (("go", "slog.ndjson"), "ndjson", 1, "slog-json", lambda e: e[0].exceptions[0].message == "context deadline exceeded"),
    (("go", "zap.ndjson"), "ndjson", 1, "zap-json", lambda e: e[0].exceptions[0].frames[0].function == "main.run" and e[0].exceptions[0].frames[0].line == 42),
    (("go", "zerolog.ndjson"), "ndjson", 1, "zerolog", lambda e: e[0].exceptions[0].message == "context deadline exceeded" and e[0].logger == "/app/main.go:42"),
    # Rust
    (("rust", "env-logger.log"), "text", 2, "env-logger", lambda e: e[1].logger == "myapp::worker" and e[1].level_text == "ERROR"),
    (("rust", "tracing-fmt.log"), "text", 2, "tracing-fmt", lambda e: e[1].logger == "myapp::worker" and e[1].attrs.get("err") == "timeout"),
    (("rust", "panic.log"), "text", 3, "tracing-fmt", lambda e: e[1].exceptions[0].type == "panic" and e[1].exceptions[0].message.startswith("index out of bounds") and any(f.file == "./src/worker.rs" for f in e[1].exceptions[0].frames) and e[2].exceptions[0].message.startswith("called")),
    (("rust", "tracing-json.ndjson"), "ndjson", 1, "tracing-json", lambda e: e[0].logger == "myapp::worker" and e[0].attrs.get("order") == 42),
    # C/C++
    (("cpp", "spdlog.log"), "text", 3, "spdlog-default", lambda e: e[1].logger == "worker" and e[1].level_text == "error" and e[2].level_text == "critical"),
    (("cpp", "boost-log.log"), "text", 2, "boost-log", lambda e: e[1].level_text == "error" and e[1].thread == "0x00007f1c"),
    (("cpp", "glog.log"), "text", 3, "glog", lambda e: e[1].level_text == "E" and "year_inferred" in e[1].ts_flags and e[2].level_num == 21),
    (("cpp", "assert-sanitizer.log"), "text", 5, "headerless", lambda e: e[0].exceptions[0].type == "AssertionFailure" and e[1].exceptions[0].type == "AddressSanitizer: heap-buffer-overflow" and e[1].exceptions[0].frames[0].file == "/src/lib/items.cc" and e[2].exceptions[0].type == "AssertionFailure" and e[3].exceptions[0].type.startswith("UndefinedBehaviorSanitizer") and e[4].exceptions[0].type.startswith("ThreadSanitizer")),
    # PHP
    (("php", "monolog-line.log"), "text", 3, "monolog-line", lambda e: e[1].logger == "app" and e[1].level_text == "ERROR" and e[2].logger == "laravel"),
    (("php", "php-error-log.log"), "text", 2, "php-error-log", lambda e: e[0].exceptions[0].type == "RuntimeException" and e[0].exceptions[0].frames[1].file == "/var/www/app/src/Billing/Charger.php" and e[1].exceptions[0].type == "PHP Warning"),
    (("php", "monolog-json.ndjson"), "ndjson", 1, "monolog-json", lambda e: e[0].exceptions[0].type == "RuntimeException" and e[0].exceptions[0].frames and e[0].level_num == 17),
    # Ruby
    (("ruby", "ruby-logger.log"), "text", 2, "ruby-logger", lambda e: e[1].exceptions[0].type == "NoMethodError" and e[1].exceptions[0].frames[0].file == "/app/lib/billing.rb" and not e[1].exceptions[0].frames[2].in_app),
    (("ruby", "rails.log"), "text", 2, "rails-request", lambda e: e[0].http_status == 500 and e[0].exceptions[0].type == "ActiveRecord::RecordNotFound" and e[1].http_status == 200 and e[0].http_path == "/orders/42"),
    # Swift / Objective-C
    (("apple", "log-show.log"), "text", 2, "apple-log-show", lambda e: e[1].level_text == "Error" and e[1].process == "MyApp"),
    (("apple", "log-show-syslog.log"), "syslog", 2, "syslog", lambda e: e[1].service == "MyApp" and e[1].host == "localhost"),
    (("apple", "crash.crash"), "apple-crash", 1, "apple-crash", lambda e: e[0].exceptions[0].type == "EXC_BAD_ACCESS (SIGSEGV)" and e[0].exceptions[0].frames[0].file == "ViewController.m" and e[0].process == "MyApp" and e[0].category_hint == "application_crash"),
    (("apple", "crash.ips"), "apple-ips", 1, "apple-ips", lambda e: e[0].exceptions[0].type == "EXC_BAD_ACCESS (SIGSEGV)" and e[0].exceptions[0].frames[0].file == "ViewController.m" and not e[0].exceptions[0].frames[1].in_app),
    # Erlang / Elixir
    (("erlang", "elixir-logger.log"), "text", 3, "elixir-logger", lambda e: e[1].exceptions[0].type == "RuntimeError" and e[1].exceptions[0].frames[0].file == "lib/my_app/worker.ex" and e[1].request_id == "abc" and e[1].category_hint == "application_crash" and e[2].ts is not None),
    (("erlang", "otp-reports.log"), "text", 4, "erlang-report", lambda e: e[0].level_text == "CRASH" and "initial call" in e[0].message and e[1].level_text == "SUPERVISOR" and e[2].exceptions[0].type == "exit" and e[3].layout == "erlang-logger"),
    # PowerShell
    (("powershell", "error-records.txt"), "text", 2, "ps-error-records", lambda e: e[0].exceptions[0].type == "ItemNotFoundException" and e[0].exceptions[0].frames[0].file == "C:\\scripts\\deploy.ps1" and e[1].exceptions[0].type == "System.Net.WebException" and any(f.line == 40 for f in e[1].exceptions[0].frames)),
    (("powershell", "transcript.txt"), "text", 2, "ps-transcript", lambda e: e[0].message == "Get-Item C:\\nope" and e[0].exceptions[0].type == "ItemNotFoundException" and e[1].message == "Write-Host done"),
    # infrastructure formats
    (("syslog", "rfc3164.log"), "syslog", 4, "syslog", lambda e: e[0].service == "sshd" and e[0].process == "999" and "year_inferred" in e[0].ts_flags and e[2].level_text == "notice" and e[3].ts is not None),
    (("syslog", "rfc5424.log"), "syslog", 2, "syslog", lambda e: e[0].level_text == "crit" and e[0].attrs.get("exampleSDID.iut") == "3" and e[0].attrs.get("syslog.msgid") == "ID47" and e[0].service == "orders"),
    (("web", "access-combined.log"), "access-log", 4, "apache-nginx-access", lambda e: e[0].http_status == 502 and e[0].http_method == "POST" and e[0].http_path == "/api/orders/42" and e[1].level_text == "info" and e[2].http_status == 404),
    (("web", "nginx-error.log"), "access-log", 2, "nginx-error", lambda e: e[0].attrs.get("nginx.upstream") == "http://10.0.0.5:8080/x" and e[0].http_path == "/x" and e[1].level_text == "warn"),
    (("web", "apache-error.log"), "access-log", 2, "apache-error", lambda e: e[0].error_code == "AH00898" and e[0].logger == "proxy" and e[1].exceptions[0].type == "Exception"),
    (("web", "iis-w3c.log"), "iis-w3c", 3, "iis-w3c", lambda e: e[0].http_status == 500 and e[0].http_path == "/api/orders/42" and e[0].attrs.get("time-taken") == "1234" and e[2].http_status == 404 and e[2].http_method == "GET"),
    (("docker", "docker-json-file.log"), "docker-json", 3, "docker-json-file", lambda e: e[0].exceptions[0].type == "ValueError" and e[0].attrs.get("stream") == "stderr" and e[1].message == "json inside docker" and e[2].attrs.get("tag") == "orders"),
    (("cri", "cri.log"), "cri", 4, "cri", lambda e: e[0].exceptions[0].type == "ValueError" and e[1].message == "long json record split" and e[3].attrs.get("cri.unterminated") is True),
    (("journal", "journal.json"), "journal-json", 2, "journal-json", lambda e: e[0].service == "app.service" and e[0].exceptions[0].type == "ValueError" and e[0].level_text == "err" and e[1].message == "Hi"),
    (("winevt", "events.xml"), "winevt-xml", 2, "xml", lambda e: e[0].error_code == "EventID:1000" and e[0].host == "BUILD01" and e[0].level_text == "Error" and e[1].attrs.get("param1") == "Orders Service"),
    (("winevt", "wevtutil-fragment.xml"), "winevt-xml", 2, "xml", lambda e: e[0].level_text == "Information" and e[1].error_code == "EventID:2"),
    (("xml", "generic.xml"), "xml", 2, "xml", lambda e: e[0].exceptions[0].type == "java.lang.RuntimeException" and e[0].logger == "svc"),
    (("ecs", "ecs.ndjson"), "ecs-json", 2, "ecs", lambda e: e[0].service == "orders" and e[0].env == "prod" and e[0].trace_id == "abc" and e[0].http_status == 500 and e[0].exceptions[0].type == "OrderError" and e[1].service == "orders"),
    (("otlp", "otlp-logs.json"), "otlp-json", 2, "otlp", lambda e: e[0].service == "orders" and e[0].logger == "acme.orders" and e[0].level_num == 17 and e[0].exceptions[0].type == "OrderError" and e[0].http_status == 500 and e[0].trace_id == "5b8efff798038103d269b633813fc60c" and e[0].ts_observed is not None),
    (("json", "array.json"), "json", 2, "array", lambda e: e[0].service == "orders" and e[0].level_text == "error"),
    (("json", "pretty-concatenated.json"), "json", 2, "root-objects", lambda e: e[1].message == "b"),
    (("json", "es-hits.json"), "ecs-json", 1, "envelope", lambda e: e[0].service == "orders" and e[0].level_text == "error"),
    (("cloudwatch", "get-log-events.json"), "cloudwatch-json", 2, "envelope", lambda e: e[0].exceptions[0].type == "requests.exceptions.ConnectionError" and e[0].ts_observed is None and e[1].level_text == "warn"),
    (("cloudwatch", "lambda-python.log"), "text", 5, "aws-lambda-python", lambda e: e[0].layout == "aws-lambda-lifecycle" and e[0].level_text == "INFO" and e[0].request_id == "8f1c2c3d-1111-2222-3333-444455556666" and e[2].level_text == "ERROR" and e[2].exceptions[0].type == "ValueError" and e[2].exceptions[0].frames[0].file == "/var/task/billing/charge.py" and e[3].message.startswith("END RequestId") and e[4].message.startswith("REPORT RequestId")),
    (("cloudwatch", "subscription-data-message.json"), "cloudwatch-json", 3, "envelope", lambda e: e[0].service == "orders" and e[0].attrs.get("logGroup") == "/aws/lambda/orders" and e[1].level_text == "ERROR" and e[1].request_id == "8f1c2c3d-1111-2222-3333-444455556666" and e[1].message.startswith("Invoke Error") and e[1].layout == "aws-lambda-node" and e[2].level_text == "warning" and "timed out" in e[2].message),
    (("cloudwatch", "insights-results.json"), "cloudwatch-json", 1, "envelope", lambda e: e[0].message.startswith("charge failed") and e[0].level_text == "ERROR" and e[0].attrs.get("logStreamName") == "s1"),
    (("azure", "query-tables.json"), "azure-json", 2, "envelope", lambda e: e[0].level_text == "Error" and e[0].service == "orders" and e[0].request_id == "op1" and e[1].level_text == "Information"),
    (("azure", "diagnostic-export.json"), "azure-json", 1, "envelope", lambda e: e[0].level_text == "Error" and e[0].service == "orders" and e[0].logger == "AppServiceConsoleLogs"),
    (("gcp", "logentries.json"), "gcp-json", 2, "array", lambda e: {x.service for x in e} == {"orders"} and any(x.trace_id == "abc" for x in e) and any(x.http_status == 200 for x in e)),
    (("gcp", "logentries.ndjson"), "gcp-json", 1, "ndjson", lambda e: e[0].level_text == "ERROR" and e[0].host == "i-1"),
    (("loki", "query-range.json"), "loki-json", 2, "envelope", lambda e: e[0].service == "orders" and e[0].exceptions[0].type == "ValueError" and e[1].service == "api" and e[1].message == "hello"),
    (("loki", "logcli.jsonl"), "loki-json", 1, "ndjson", lambda e: e[0].service == "orders" and e[0].attrs.get("order") == "42"),
    (("tabular", "events.csv"), "csv", 4, "csv", lambda e: e[0].message == "charge failed, order 42" and e[0].exceptions[0].type == "ValueError" and e[0].line == 2 and e[2].message == "multi" and e[3].line == 7),
    (("tabular", "events.tsv"), "tsv", 3, "tsv", lambda e: e[0].level_text == "ERROR" and e[0].line == 1 and e[2].line == 3),
    (("logfmt", "logfmt.log"), "logfmt", 4, "logfmt", lambda e: e[0].exceptions[0].message == "context deadline exceeded" and e[2].trace_id == "abc" and e[3].message == "garbage line here"),
]


class FormatMatrixTests(TriageTestCase):
    def test_every_claimed_layout(self):
        failures = []
        for parts, expected_parser, count, layout_sub, check in CASES:
            path = fixture(*parts)
            try:
                events, ctx, name, conf = parse_events(path)
                if name != expected_parser:
                    failures.append("%s: detected %s (%.2f), expected %s" % ("/".join(parts), name, conf, expected_parser))
                    continue
                if len(events) != count:
                    failures.append("%s: %d events, expected %d: %s" % ("/".join(parts), len(events), count, [x.message[:40] for x in events]))
                    continue
                layout = (ctx.layout or "") + " " + (ctx.dialect or "") + " " + (events[0].layout or "")
                if layout_sub not in layout:
                    failures.append("%s: layout %r lacks %r" % ("/".join(parts), layout, layout_sub))
                    continue
                if not check(events):
                    failures.append("%s: field check failed: %s" % ("/".join(parts), [(x.message[:40], x.level_text, [(y.type, len(y.frames)) for y in x.exceptions]) for x in events]))
            except Exception as exc:  # noqa: BLE001
                import traceback
                failures.append("%s: raised %s: %s\n%s" % ("/".join(parts), type(exc).__name__, exc, traceback.format_exc()[-800:]))
        self.assertEqual(failures, [], "\n".join(failures))

    def test_support_matrix_claims_are_exercised(self):
        """Every text layout and structured dialect published in the support matrix is produced by a fixture."""
        from log_triage.parsers.structured import DIALECTS
        from log_triage.parsers.text import LAYOUTS
        covered = set()
        for parts, _parser, _count, _sub, _check in CASES:
            events, ctx, _name, _conf = parse_events(fixture(*parts))
            covered.update((ctx.layout or "").split("+"))
            if ctx.dialect:
                covered.add(ctx.dialect)
            for ev in events:
                covered.update((ev.layout or "").replace("json-in-text:", "").split("+"))
        fallback = {"generic-ts", "generic-level", "generic-json"}   # exercised by the fallback tests
        self.assertEqual([l.id for l in LAYOUTS if l.id not in covered and l.id not in fallback], [])
        self.assertEqual([d.id for d in DIALECTS if d.id not in covered and d.id not in fallback], [])

    def test_xml_entities_rejected(self):
        for name in ("xxe.xml", "billion-laughs.xml"):
            events, ctx, pname, conf = parse_events(fixture("xml", name))
            self.assertEqual(events, [], name)
            self.assertIn("xml-entity-rejected", ctx.diagnostics.counts, name)

    def test_truncated_json_document_keeps_prior_items(self):
        events, ctx, name, conf = parse_events(fixture("json", "truncated.json"))
        self.assertEqual(len(events), 1)
        self.assertIn("json-structure-error", ctx.diagnostics.counts)

    def test_malformed_ndjson_lines_are_reported_not_dropped(self):
        events, ctx, name, conf = parse_events(fixture("json", "generic.ndjson"))
        self.assertEqual(len(events), 3)
        self.assertEqual(ctx.diagnostics.counts.get("non-json-line"), 1)
        self.assertEqual(ctx.diagnostics.counts.get("malformed-json-line"), 1)
        self.assertEqual(ctx.parse_failures, 2)

    def test_detection_confidence_reported(self):
        doc = self.analyze([fixture("node", "pino.ndjson"), fixture("edge", "no-timestamps.log"), fixture("edge", "prose.log")])
        by = {os.path.basename(f["path"]): f for f in doc["inputs"]["files"]}
        self.assertEqual(by["pino.ndjson"]["format"], "ndjson")
        self.assertGreaterEqual(by["pino.ndjson"]["detection_confidence"], 0.8)
        self.assertTrue(by["no-timestamps.log"]["format"].startswith("text"))
        self.assertTrue(by["prose.log"]["format"].startswith("text"))
        self.assertLess(by["prose.log"]["detection_confidence"], 0.3)
        self.assertEqual(by["prose.log"]["events"], 3)
        self.assertIn("unknown-text-layout", doc["diagnostics"]["counts_by_code"])
        self.assertIn("low-detection-confidence", doc["diagnostics"]["counts_by_code"])

    def test_oversized_json_record_is_skipped_with_diagnostic(self):
        big = '{"time":"2026-09-13T12:00:00Z","level":"error","msg":"' + "x" * 5000 + '"}\n'
        path = self.write("big.ndjson", big + '{"time":"2026-09-13T12:00:01Z","level":"error","msg":"small"}\n')
        doc = self.analyze([path], extra=["--max-line-bytes", "1000"])
        self.assertEqual(doc["coverage"]["events_included"], 1)
        self.assertIn("oversized-record", doc["diagnostics"]["counts_by_code"])


if __name__ == "__main__":
    unittest.main()
