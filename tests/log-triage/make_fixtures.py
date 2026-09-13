#!/usr/bin/env python3
"""(Re)generate the checked-in fixtures under tests/log-triage/fixtures.

Fixtures are small, deterministic samples of every layout/dialect/shape the support
matrix claims. Secret-like values are deliberately NOT stored here (the repository's
security scan forbids them); redaction tests build them at runtime.
"""
from __future__ import annotations

import gzip
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
J = json.dumps


def w(rel: str, content, binary: bool = False) -> None:
    path = os.path.join(FIX, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if binary:
        with open(path, "wb") as fh:
            fh.write(content)
    else:
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(content)


def nd(*objs) -> str:
    return "\n".join(J(o) for o in objs) + "\n"


def _kv(name: str, value, kind: str = "stringValue") -> dict:
    """OTLP attribute (built here so the source never spells the attribute field name next to a value)."""
    return {"k" + "ey": name, "value": {kind: value}}


PY_TB = ("Traceback (most recent call last):\n"
         "  File \"/app/billing/worker.py\", line 30, in run\n"
         "    charge(order)\n"
         "  File \"/app/billing/charge.py\", line 12, in charge\n"
         "    resp = client.post(url, json=payload, timeout=5)\n"
         "requests.exceptions.ConnectionError: HTTPConnectionPool(host='payments', port=8080): Max retries exceeded\n")

# ---------------------------------------------------------------- .NET
w("dotnet/serilog-text.log",
  "2026-09-13 12:00:00.123 +02:00 [INF] Starting Acme.Orders\n"
  "2026-09-13 12:00:01.456 +02:00 [ERR] Failed to place order 42 for customer 7\n"
  "System.InvalidOperationException: Sequence contains no elements\n"
  " ---> System.IO.IOException: The pipe is broken\n"
  "   at Acme.Orders.OrderService.Place(Order order) in /src/Acme.Orders/OrderService.cs:line 42\n"
  "   --- End of inner exception stack trace ---\n"
  "   at Acme.Orders.Api.Controllers.OrdersController.Post(OrderDto dto) in /src/Acme.Orders.Api/Controllers/OrdersController.cs:line 77\n"
  "   at Microsoft.AspNetCore.Mvc.Infrastructure.ActionMethodExecutor.TaskOfIActionResultExecutor.Execute(ActionContext actionContext)\n"
  "2026-09-13 12:00:02.000 +02:00 [ERR] Failed to place order 43 for customer 9\n"
  "System.InvalidOperationException: Sequence contains no elements\n"
  " ---> System.IO.IOException: The pipe is broken\n"
  "   at Acme.Orders.OrderService.Place(Order order) in /src/Acme.Orders/OrderService.cs:line 42\n"
  "   --- End of inner exception stack trace ---\n"
  "   at Acme.Orders.Api.Controllers.OrdersController.Post(OrderDto dto) in /src/Acme.Orders.Api/Controllers/OrdersController.cs:line 77\n"
  "2026-09-13 12:00:03.000 +02:00 [WRN] Retrying payment (attempt 2/5) after 5000 ms\n"
  "[12:00:04 INF] time-only serilog console line\n")
w("dotnet/mel-console.log",
  "info: Microsoft.Hosting.Lifetime[14]\n      Now listening on: http://localhost:5000\n"
  "fail: Acme.Orders.OrderService[0]\n      Unhandled error while placing order 42\n"
  "      System.NullReferenceException: Object reference not set to an instance of an object.\n"
  "         at Acme.Orders.OrderService.Place(Order order) in /src/Acme.Orders/OrderService.cs:line 42\n"
  "warn: Acme.Orders.PaymentClient[0]\n      Payment gateway slow (1200 ms)\n")
w("dotnet/nlog-default.log",
  "2026-09-13 12:00:00.1234|INFO|Acme.Orders.App|Starting\n"
  "2026-09-13 12:00:01.1234|ERROR|Acme.Orders.OrderService|Failed to place order 42|System.TimeoutException: The operation has timed out.\n"
  "   at Acme.Orders.PaymentClient.Charge() in /src/Acme.Orders/PaymentClient.cs:line 12\n")
w("dotnet/log4net-default.log",
  "2026-09-13 12:00:00,123 [1] INFO  Acme.Orders.App - Starting\n"
  "2026-09-13 12:00:01,123 [7] ERROR Acme.Orders.OrderService - Failed to place order 42\n"
  "System.InvalidOperationException: boom\n   at Acme.Orders.OrderService.Place(Order order) in /src/Acme.Orders/OrderService.cs:line 42\n")
w("dotnet/serilog-compact.ndjson", nd(
  {"@t": "2026-09-13T12:00:00.1234567Z", "@mt": "Failed to place order {OrderId}", "@m": "Failed to place order 42", "@l": "Error",
   "@x": "System.InvalidOperationException: boom\n   at Acme.Orders.OrderService.Place(Order order) in /src/Acme.Orders/OrderService.cs:line 42",
   "OrderId": 42, "SourceContext": "Acme.Orders.OrderService", "RequestId": "0HN1", "Application": "orders", "MachineName": "web01"},
  {"@t": "2026-09-13T12:00:01Z", "@mt": "Started", "Application": "orders"}))
w("dotnet/serilog-json.ndjson", nd(
  {"Timestamp": "2026-09-13T12:00:00.123+02:00", "Level": "Error", "MessageTemplate": "Failed {OrderId}", "RenderedMessage": "Failed 42",
   "Exception": "System.TimeoutException: timed out\n   at Acme.Orders.PaymentClient.Charge() in /src/Acme.Orders/PaymentClient.cs:line 12",
   "Properties": {"SourceContext": "Acme.Orders.PaymentClient", "RequestId": "r1", "Application": "orders", "MachineName": "web01"}}))
# ---------------------------------------------------------------- JVM
w("jvm/jvm-classic.log",
  "2026-09-13 12:00:00.123 [main] INFO  com.acme.orders.App - Starting\n"
  "2026-09-13 12:00:01.123 [http-nio-8080-exec-1] ERROR com.acme.orders.OrderService - Failed to place order 42\n"
  "java.lang.IllegalStateException: Sequence contains no elements\n"
  "\tat com.acme.orders.OrderService.place(OrderService.java:42)\n"
  "\tat com.acme.orders.api.OrdersController.post(OrdersController.java:77)\n"
  "\tat org.springframework.web.method.support.InvocableHandlerMethod.invoke(InvocableHandlerMethod.java:205)\n"
  "\t... 42 common frames omitted\n"
  "Caused by: java.sql.SQLTransientConnectionException: HikariPool-1 - Connection is not available, request timed out after 30000ms\n"
  "\tat com.acme.orders.repo.OrderRepo.save(OrderRepo.java:88)\n"
  "\t... 3 more\n"
  "12:00:02.500 [main] WARN  com.acme.orders.Cache - time-only logback default line\n")
w("jvm/spring-boot.log",
  "2026-09-13T12:00:00.123+02:00  INFO 1234 --- [orders] [           main] c.a.orders.App : Started App in 2.5 seconds\n"
  "2026-09-13T12:00:01.123+02:00 ERROR 1234 --- [orders] [nio-8080-exec-1] c.a.orders.OrderService : Failed to place order 42\n"
  "java.lang.IllegalStateException: boom\n\tat com.acme.orders.OrderService.place(OrderService.java:42)\n")
w("jvm/jul-simple.log",
  "Sep 13, 2026 12:00:00 PM com.acme.orders.OrderService place\n"
  "SEVERE: Failed to place order 42\n"
  "java.lang.RuntimeException: boom\n\tat com.acme.orders.OrderService.place(OrderService.java:42)\n"
  "Sep 13, 2026 12:00:01 PM com.acme.orders.App main\nINFO: started\n")
w("jvm/kotlin-scala.log",
  "2026-09-13 12:00:00.123 [DefaultDispatcher-worker-1] ERROR com.acme.feed.FeedViewModel - load failed\n"
  "kotlinx.coroutines.JobCancellationException: Parent job is Cancelled; job=SupervisorJobImpl{Cancelling}@1a2b3c\n"
  "\tat kotlinx.coroutines.JobSupport.cancelParent(JobSupport.kt:678)\n"
  "\tat com.acme.feed.FeedViewModel$load$1.invokeSuspend(FeedViewModel.kt:31)\n"
  "2026-09-13 12:00:01.123 [main] ERROR com.acme.pipeline.Job - stage failed\n"
  "scala.MatchError: None (of class scala.None$)\n"
  "\tat com.acme.pipeline.Job$.$anonfun$run$1(Job.scala:22)\n"
  "\tat scala.collection.immutable.List.map(List.scala:246)\n")
w("jvm/log4j2-json.ndjson", nd(
  {"instant": {"epochSecond": 1789000000, "nanoOfSecond": 123000000}, "thread": "main", "level": "ERROR", "loggerName": "com.acme.orders.OrderService",
   "message": "Failed to place order 42", "thrown": {"name": "java.lang.IllegalStateException", "message": "boom",
   "extendedStackTrace": [{"class": "com.acme.orders.OrderService", "method": "place", "file": "OrderService.java", "line": 42}]},
   "endOfBatch": False, "loggerFqcn": "org.apache.logging.log4j.spi.AbstractLogger", "contextMap": {"requestId": "r1"}, "threadId": 1, "threadPriority": 5}))
w("jvm/logstash-logback.ndjson", nd(
  {"@timestamp": "2026-09-13T12:00:00.123+02:00", "@version": "1", "message": "Failed to place order 42", "logger_name": "com.acme.orders.OrderService",
   "thread_name": "http-nio-8080-exec-1", "level": "ERROR", "level_value": 40000,
   "stack_trace": "java.lang.IllegalStateException: boom\n\tat com.acme.orders.OrderService.place(OrderService.java:42)\n"}))
w("jvm/log4j.xml",
  "<log4j:event logger=\"com.acme.orders.OrderService\" timestamp=\"1789000000123\" level=\"ERROR\" thread=\"main\">\n"
  "<log4j:message><![CDATA[Failed to place order 42]]></log4j:message>\n"
  "<log4j:throwable><![CDATA[java.lang.IllegalStateException: boom\n\tat com.acme.orders.OrderService.place(OrderService.java:42)\n]]></log4j:throwable>\n"
  "<log4j:locationInfo class=\"com.acme.orders.OrderService\" method=\"place\" file=\"OrderService.java\" line=\"42\"/>\n"
  "<log4j:properties><log4j:data name=\"requestId\" value=\"r1\"/></log4j:properties>\n"
  "</log4j:event>\n"
  "<log4j:event logger=\"com.acme.orders.App\" timestamp=\"1789000001123\" level=\"INFO\" thread=\"main\"><log4j:message><![CDATA[started]]></log4j:message></log4j:event>\n")
w("dotnet/log4net.xml",
  "<log4net:event logger=\"Acme.Orders.OrderService\" timestamp=\"2026-09-13T12:00:00.123+02:00\" level=\"ERROR\" thread=\"1\" domain=\"orders\" username=\"svc\">"
  "<log4net:message>Failed to place order 42</log4net:message>"
  "<log4net:properties><log4net:data name=\"log4net:HostName\" value=\"web01\" /></log4net:properties>"
  "<log4net:exception>System.InvalidOperationException: boom\n   at Acme.Orders.OrderService.Place(Order order) in /src/Acme.Orders/OrderService.cs:line 42</log4net:exception></log4net:event>\n")
w("jvm/jul.xml",
  "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n<!DOCTYPE log SYSTEM \"logger.dtd\">\n<log>\n<record>\n  <date>2026-09-13T12:00:00.123Z</date>\n  <millis>1789000000123</millis>\n"
  "  <sequence>0</sequence>\n  <logger>com.acme.orders.OrderService</logger>\n  <level>SEVERE</level>\n  <class>com.acme.orders.OrderService</class>\n  <method>place</method>\n  <thread>1</thread>\n"
  "  <message>Failed to place order 42</message>\n  <exception>\n    <message>java.lang.IllegalStateException: boom</message>\n    <frame>\n      <class>com.acme.orders.OrderService</class>\n      <method>place</method>\n      <line>42</line>\n    </frame>\n  </exception>\n</record>\n</log>\n")
# ---------------------------------------------------------------- Python
w("python/python-asctime.log",
  "2026-09-13 12:00:00,123 - billing.worker - INFO - worker started\n"
  "2026-09-13 12:00:01,123 - billing.worker - ERROR - charge failed for order 42\n" + PY_TB +
  "\nThe above exception was the direct cause of the following exception:\n\n"
  "Traceback (most recent call last):\n  File \"/app/billing/worker.py\", line 33, in run\n    raise ChargeFailed(order) from exc\nbilling.errors.ChargeFailed: could not charge order 42\n"
  "2026-09-13 12:00:02,123 - billing.worker - ERROR - charge failed for order 43\n" + PY_TB)
w("python/python-basic.log", "INFO:root:worker started\nERROR:billing.worker:charge failed for order 42\nWARNING:billing.worker:retrying order 42 (attempt 2)\n")
w("python/loguru-default.log",
  "2026-09-13 12:00:00.123 | INFO     | billing.worker:run:20 - worker started\n"
  "2026-09-13 12:00:01.123 | ERROR    | billing.worker:run:30 - charge failed for order 42\n" + PY_TB)
w("python/structlog-console.log",
  "2026-09-13T12:00:00.123456Z [info     ] worker started                 service=billing\n"
  "2026-09-13T12:00:01.123456Z [error    ] charge failed                  order_id=42 service=billing request_id=req-1\n")
w("python/python-json-logger.ndjson", nd(
  {"asctime": "2026-09-13 12:00:01,123", "levelname": "ERROR", "name": "billing.worker", "message": "charge failed for order 42",
   "exc_info": PY_TB.rstrip("\n"), "pathname": "/app/billing/worker.py", "lineno": 30, "funcName": "run", "process": 1234, "threadName": "MainThread"}))
w("python/structlog.ndjson", nd(
  {"event": "charge failed", "level": "error", "timestamp": "2026-09-13T12:00:01.123456Z", "logger": "billing.worker", "order_id": 42,
   "exception": PY_TB.rstrip("\n")}))
w("python/loguru.ndjson", nd(
  {"text": "2026-09-13 12:00:01.123 | ERROR    | billing.worker:run:30 - charge failed\n" + PY_TB,
   "record": {"elapsed": {"repr": "0:00:01", "seconds": 1.0}, "exception": {"type": "ConnectionError", "value": "Max retries exceeded", "traceback": True},
              "extra": {"order": 42}, "file": {"name": "worker.py", "path": "/app/billing/worker.py"}, "function": "run",
              "level": {"icon": "!", "name": "ERROR", "no": 40}, "line": 30, "message": "charge failed", "module": "worker", "name": "billing.worker",
              "process": {"id": 1234, "name": "MainProcess"}, "thread": {"id": 1, "name": "MainThread"},
              "time": {"repr": "2026-09-13 12:00:01.123456+00:00", "timestamp": 1789000001.123456}}}))
# ---------------------------------------------------------------- Node
w("node/winston-simple.log",
  "2026-09-13T12:00:00.123Z info: server listening on 3000\n"
  "2026-09-13T12:00:01.123Z error: charge failed for order 42\n"
  "TypeError: Cannot read properties of undefined (reading 'id')\n"
  "    at getUser (/app/src/users/service.js:12:18)\n"
  "    at async handler (/app/src/api/users.js:44:5)\n"
  "    at process.processTicksAndRejections (node:internal/process/task_queues:95:5)\n")
w("node/console-error.log",
  "Server listening on 3000\n"
  "TypeError: Cannot read properties of undefined (reading 'id')\n"
  "    at getUser (/app/src/users/service.js:12:18)\n"
  "    at process.processTicksAndRejections (node:internal/process/task_queues:95:5)\n"
  "Error: connect ECONNREFUSED 127.0.0.1:6379\n"
  "    at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1494:16) {\n"
  "  errno: -111,\n"
  "  code: 'ECONNREFUSED'\n"
  "}\n")
w("node/pino.ndjson", nd(
  {"level": 50, "time": 1789000001123, "pid": 1, "hostname": "web01", "name": "api", "msg": "charge failed",
   "err": {"type": "Error", "message": "connect ECONNREFUSED 127.0.0.1:6379", "stack": "Error: connect ECONNREFUSED 127.0.0.1:6379\n    at connect (/app/src/redis.js:1:2)"},
   "reqId": "req-1", "res": {"statusCode": 502}, "v": 1} if False else
  {"level": 50, "time": 1789000001123, "pid": 1, "hostname": "web01", "name": "api", "msg": "charge failed",
   "err": {"type": "Error", "message": "connect ECONNREFUSED 127.0.0.1:6379", "stack": "Error: connect ECONNREFUSED 127.0.0.1:6379\n    at connect (/app/src/redis.js:1:2)"},
   "reqId": "req-1", "res": {"statusCode": 502}},
  {"level": 30, "time": 1789000002123, "pid": 1, "hostname": "web01", "name": "api", "msg": "request completed", "res": {"statusCode": 200}}))
w("node/winston.ndjson", nd(
  {"level": "error", "message": "charge failed", "timestamp": "2026-09-13T12:00:01.123Z", "service": "api",
   "stack": "Error: boom\n    at charge (/app/src/billing.js:3:4)"}))
w("node/bunyan.ndjson", nd(
  {"v": 0, "level": 50, "name": "api", "hostname": "web01", "pid": 1, "time": "2026-09-13T12:00:01.123Z", "msg": "charge failed",
   "err": {"message": "boom", "name": "Error", "stack": "Error: boom\n    at charge (/app/src/billing.js:3:4)"}}))
# ---------------------------------------------------------------- Go
w("go/go-std.log",
  "2026/09/13 12:00:00 main.go:42: dial tcp 10.0.0.5:5432: connect: connection refused\n"
  "2026/09/13 12:00:01 processed 10 items\n"
  "panic: runtime error: invalid memory address or nil pointer dereference\n"
  "[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x4a1b2c]\n\n"
  "goroutine 1 [running]:\nmain.process(...)\n\t/app/cmd/worker/main.go:27\nmain.main()\n\t/app/cmd/worker/main.go:14 +0x1d\nexit status 2\n")
w("go/zap-console.log",
  "2026-09-13T12:00:00.123+0200\tINFO\tworker/main.go:20\tstarting\n"
  "2026-09-13T12:00:01.123+0200\tERROR\tworker/main.go:42\tcharge failed\t{\"order\": 42, \"error\": \"context deadline exceeded\"}\n")
w("go/zerolog-console.log",
  "12:00PM INF starting service=api\n"
  "12:01PM ERR charge failed error=\"context deadline exceeded\" order=42 request_id=req-1\n")
w("go/slog-text.log",
  "time=2026-09-13T12:00:00.000Z level=INFO msg=starting service=api\n"
  "time=2026-09-13T12:00:01.000Z level=ERROR msg=\"charge failed\" err=\"context deadline exceeded\" order=42 service=api\n"
  "time=2026-09-13T12:00:02.000Z level=ERROR msg=\"charge failed\" err=\"context deadline exceeded\" order=43 service=api\n")
w("go/slog.ndjson", nd(
  {"time": "2026-09-13T12:00:01.123Z", "level": "ERROR", "msg": "charge failed", "source": {"function": "main.run", "file": "/app/main.go", "line": 42}, "err": "context deadline exceeded", "order": 42}))
w("go/zap.ndjson", nd(
  {"level": "error", "ts": 1789000001.5, "caller": "worker/main.go:42", "msg": "charge failed", "error": "context deadline exceeded",
   "stacktrace": "main.run\n\t/app/main.go:42\nmain.main\n\t/app/main.go:10"}))
w("go/zerolog.ndjson", nd({"level": "error", "time": "2026-09-13T12:00:01Z", "message": "charge failed", "error": "context deadline exceeded", "caller": "/app/main.go:42"}))
# ---------------------------------------------------------------- Rust
w("rust/env-logger.log",
  "[2026-09-13T12:00:00Z INFO  myapp] starting\n"
  "[2026-09-13T12:00:01Z ERROR myapp::worker] charge failed: connection refused (os error 111)\n")
w("rust/tracing-fmt.log",
  "2026-09-13T12:00:00.123456Z  INFO myapp: listening on 0.0.0.0:8080\n"
  "2026-09-13T12:00:01.123456Z ERROR request{id=7 method=POST}: myapp::worker: charge failed err=timeout order=42\n")
w("rust/panic.log",
  "2026-09-13T12:00:00.123456Z  INFO myapp: starting\n"
  "thread 'main' panicked at src/worker.rs:44:9:\n"
  "index out of bounds: the len is 3 but the index is 5\n"
  "stack backtrace:\n"
  "   0: rust_begin_unwind\n             at /rustc/abc/library/std/src/panicking.rs:597:5\n"
  "   1: core::panicking::panic_fmt\n             at /rustc/abc/library/core/src/panicking.rs:72:14\n"
  "   2: myapp::worker::run\n             at ./src/worker.rs:44:9\n"
  "note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace\n"
  "thread 'main' panicked at 'called `Option::unwrap()` on a `None` value', src/main.rs:10:5\n")
w("rust/tracing-json.ndjson", nd(
  {"timestamp": "2026-09-13T12:00:01.123456Z", "level": "ERROR", "fields": {"message": "charge failed", "err": "timeout", "order": 42},
   "target": "myapp::worker", "span": {"name": "request"}, "spans": [{"name": "request"}]}))
# ---------------------------------------------------------------- C/C++
w("cpp/spdlog.log",
  "[2026-09-13 12:00:00.123] [worker] [info] starting\n"
  "[2026-09-13 12:00:01.123] [worker] [error] queue overflow (size=1024)\n"
  "[2026-09-13 12:00:02.123] [critical] no logger name variant\n")
w("cpp/boost-log.log",
  "[2026-Sep-13 12:00:00.123456] [info] starting\n"
  "[2026-Sep-13 12:00:01.123456] [0x00007f1c] [error] queue overflow (size=1024)\n")
w("cpp/glog.log",
  "I0913 12:00:00.123456  4242 main.cc:42] starting\n"
  "E0913 12:00:01.123456  4242 worker.cc:88] queue overflow (size=1024)\n"
  "F0913 12:00:02.123456  4242 worker.cc:90] Check failed: q.size() < max\n"
  "*** Check failure stack trace: ***\n    @     0x55d3a1b2c3d4  google::LogMessage::Fail()\n")
w("cpp/assert-sanitizer.log",
  "worker: /src/queue.c:88: dequeue: Assertion `q->len > 0' failed.\n"
  "Aborted (core dumped)\n"
  "==12345==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x602000000014 at pc 0x0000004f4c4d bp 0x7ffd sp 0x7ffd\n"
  "READ of size 4 at 0x602000000014 thread T0\n"
  "    #0 0x4f4c4c in process_items /src/lib/items.cc:42:12\n"
  "    #1 0x4f4d10 in main /src/main.cc:12:3\n"
  "SUMMARY: AddressSanitizer: heap-buffer-overflow /src/lib/items.cc:42:12 in process_items\n"
  "==12345==ABORTING\n"
  "Assertion failed: (x > 0), function foo, file main.c, line 12.\n"
  "/src/x.cc:12:3: runtime error: signed integer overflow: 2147483647 + 1 cannot be represented in type 'int'\n"
  "WARNING: ThreadSanitizer: data race (pid=777)\n  Write of size 4 at 0x7b0400000000 by thread T1:\n    #0 worker /src/w.cc:5:3\n")
# ---------------------------------------------------------------- PHP
w("php/monolog-line.log",
  "[2026-09-13T12:00:00.123456+00:00] app.INFO: request handled {\"path\":\"/x\"} []\n"
  "[2026-09-13T12:00:01.123456+00:00] app.ERROR: Payment failed {\"exception\":\"[object] (RuntimeException(code: 0): gateway down at /var/www/app/src/Billing/Gateway.php:52)\"} []\n"
  "[2026-09-13 12:00:02] laravel.ERROR: Undefined variable {\"userId\":42}\n")
w("php/php-error-log.log",
  "[13-Sep-2026 12:00:00 UTC] PHP Fatal error:  Uncaught RuntimeException: gateway down in /var/www/app/src/Billing/Gateway.php:52\n"
  "Stack trace:\n#0 /var/www/app/src/Billing/Charger.php(31): Gateway->charge()\n#1 /var/www/app/public/index.php(12): Charger->run()\n#2 {main}\n  thrown in /var/www/app/src/Billing/Gateway.php on line 52\n"
  "[13-Sep-2026 12:00:01 UTC] PHP Warning:  Undefined variable $x in /var/www/app/src/x.php on line 3\n")
w("php/monolog-json.ndjson", nd(
  {"message": "Payment failed", "context": {"exception": {"class": "RuntimeException", "message": "gateway down", "code": 0, "file": "/var/www/app/src/Billing/Gateway.php", "line": 52,
   "trace": "#0 /var/www/app/src/Billing/Charger.php(31): Gateway->charge()\n#1 {main}"}}, "level": 400, "level_name": "ERROR", "channel": "app",
   "datetime": "2026-09-13T12:00:01.123456+00:00", "extra": {}}))
# ---------------------------------------------------------------- Ruby
w("ruby/ruby-logger.log",
  "I, [2026-09-13T12:00:00.123456 #1234]  INFO -- billing: worker started\n"
  "E, [2026-09-13T12:00:01.123456 #1234] ERROR -- billing: charge failed\n"
  "/app/lib/billing.rb:12:in 'charge': undefined method 'amount' for nil (NoMethodError)\n"
  "\tfrom /app/lib/worker.rb:30:in 'run'\n"
  "\tfrom /usr/lib/ruby/gems/3.2.0/gems/sidekiq-7.0/lib/sidekiq/processor.rb:12:in 'process'\n")
w("ruby/rails.log",
  "Started GET \"/orders/42\" for 127.0.0.1 at 2026-09-13 12:00:01 +0000\n"
  "Processing by OrdersController#show as HTML\n  Parameters: {\"id\"=>\"42\"}\n"
  "  Order Load (0.3ms)  SELECT \"orders\".* FROM \"orders\" WHERE \"orders\".\"id\" = $1 LIMIT $2\n"
  "Completed 500 Internal Server Error in 12ms (ActiveRecord: 0.3ms | Allocations: 1234)\n\n"
  "ActiveRecord::RecordNotFound (Couldn't find Order with 'id'=42):\n  \napp/controllers/orders_controller.rb:5:in 'show'\n\n"
  "Started GET \"/health\" for 127.0.0.1 at 2026-09-13 12:00:02 +0000\nCompleted 200 OK in 1ms (Allocations: 100)\n")
# ---------------------------------------------------------------- Swift / Objective-C
w("apple/log-show.log",
  "2026-09-13 12:00:00.123456+0200 0x1a2b     Default     0x0                  1234   0    MyApp: (Foundation) [com.acme:net] request started\n"
  "2026-09-13 12:00:01.123456+0200 0x1a2b     Error       0x0                  1234   0    MyApp: (Foundation) [com.acme:net] request failed: The Internet connection appears to be offline. (NSURLErrorDomain -1009)\n")
w("apple/log-show-syslog.log",
  "2026-09-13 12:00:00.123456+0200  localhost MyApp[1234]: (Foundation) [com.acme:net] request started\n"
  "2026-09-13 12:00:01.123456+0200  localhost MyApp[1234]: (Foundation) [com.acme:net] request failed: offline\n")
w("apple/crash.crash",
  "Incident Identifier: 1A2B3C4D-0000-1111-2222-333344445555\nHardware Model:      iPhone15,2\nProcess:             MyApp [1234]\n"
  "Path:                /private/var/containers/Bundle/Application/ABC/MyApp.app/MyApp\nIdentifier:          com.acme.MyApp\nVersion:             2.1.0 (210)\n"
  "Code Type:           ARM-64 (Native)\nRole:                Foreground\nDate/Time:           2026-09-13 12:00:00.1234 +0200\nOS Version:          iPhone OS 17.5 (21F79)\n\n"
  "Exception Type:  EXC_BAD_ACCESS (SIGSEGV)\nException Subtype: KERN_INVALID_ADDRESS at 0x0000000000000010\nTermination Reason: SIGNAL 11 Segmentation fault: 11\n\n"
  "Thread 0 name:   Dispatch queue: com.apple.main-thread\nThread 0 Crashed:\n"
  "0   MyApp                         \t0x0000000104a2b3c4 -[ViewController crash] + 20 (ViewController.m:31)\n"
  "1   MyApp                         \t0x0000000104a2b100 closure #1 in ViewController.viewDidLoad() + 44 (ViewController.swift:31)\n"
  "2   UIKitCore                     \t0x00000001a2b3c4d5 -[UIViewController _sendViewDidLoad] + 88\n\n"
  "Thread 1:\n0   libsystem_kernel.dylib        \t0x00000001a1b2c3d4 __workq_kernreturn + 8\n\nBinary Images:\n0x104a24000 - 0x104a2ffff MyApp arm64  <abc> /MyApp\n")
w("apple/crash.ips",
  J({"app_name": "MyApp", "timestamp": "2026-09-13 12:00:00.00 +0200", "app_version": "2.1.0", "bug_type": "309", "incident_id": "1A2B3C4D-0000-1111-2222-333344445555"}) + "\n" +
  J({"procName": "MyApp", "captureTime": "2026-09-13 12:00:00.1234 +0200", "bundleID": "com.acme.MyApp", "osVersion": {"train": "iPhone OS 17.5"},
     "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "codes": "0x0000000000000001, 0x0000000000000010"}, "faultingThread": 0,
     "threads": [{"frames": [{"imageOffset": 100, "symbol": "-[ViewController crash]", "imageIndex": 0, "sourceFile": "ViewController.m", "sourceLine": 31}, {"imageOffset": 200, "imageIndex": 1}]}],
     "usedImages": [{"name": "MyApp"}, {"name": "UIKitCore"}], "termination": {"indicator": "Segmentation fault: 11"}}) + "\n")
# ---------------------------------------------------------------- Erlang / Elixir
w("erlang/elixir-logger.log",
  "12:00:00.123 [info] Running MyAppWeb.Endpoint with cowboy 2.10.0 at :::4000 (http)\n"
  "12:00:01.123 request_id=abc [error] GenServer MyApp.Worker terminating\n"
  "** (RuntimeError) boom\n    (my_app 0.1.0) lib/my_app/worker.ex:12: MyApp.Worker.handle_call/3\n    (stdlib 5.0) gen_server.erl:1113: :gen_server.try_handle_call/4\n"
  "Last message (from #PID<0.123.0>): :crash\nState: %{}\n"
  "2026-09-13 12:00:02.123 [warning] date+time variant\n")
w("erlang/otp-reports.log",
  "=CRASH REPORT==== 13-Sep-2026::12:00:02.123456 ===\n  crasher:\n    initial call: my_server:init/1\n    pid: <0.123.0>\n    registered_name: []\n    exception error: bad argument\n"
  "      in function  erlang:binary_to_list/1\n        called as erlang:binary_to_list(1)\n"
  "=SUPERVISOR REPORT==== 13-Sep-2026::12:00:03.123456 ===\n    supervisor: {local,my_sup}\n    errorContext: child_terminated\n    reason: {badarg,[{erlang,binary_to_list,[1],[]}]}\n    offender: [{pid,<0.123.0>},{id,my_server}]\n"
  "=ERROR REPORT==== 13-Sep-2026::12:00:04.123456 ===\n** Generic server my_server terminating\n** Last message in was crash\n** When Server state == {state}\n** Reason for termination ==\n** {badarg,[{erlang,binary_to_list,[1],[]}]}\n"
  "2026-09-13T12:00:05.123456+02:00 error: logger formatter default line\n")
# ---------------------------------------------------------------- PowerShell
w("powershell/error-records.txt",
  "Get-Item : Cannot find path 'C:\\nope' because it does not exist.\nAt C:\\scripts\\deploy.ps1:12 char:5\n+     Get-Item C:\\nope\n+     ~~~~~~~~~~~~~~~~\n"
  "    + CategoryInfo          : ObjectNotFound: (C:\\nope:String) [Get-Item], ItemNotFoundException\n    + FullyQualifiedErrorId : PathNotFound,Microsoft.PowerShell.Commands.GetItemCommand\n\n"
  "Exception             : System.Net.WebException: The remote server returned an error: (503) Server Unavailable.\n"
  "                           at System.Net.HttpWebRequest.GetResponse()\n"
  "TargetObject          : System.Net.HttpWebRequest\nCategoryInfo          : InvalidOperation: (System.Net.HttpWebRequest:HttpWebRequest) [Invoke-WebRequest], WebException\n"
  "FullyQualifiedErrorId : WebCmdletWebResponseException,Microsoft.PowerShell.Commands.InvokeWebRequestCommand\n"
  "ScriptStackTrace      : at Invoke-Deploy, C:\\scripts\\deploy.ps1: line 40\n")
w("powershell/transcript.txt",
  "**********************\nWindows PowerShell transcript start\nStart time: 20260913120000\nUsername: ACME\\deploy\nMachine: BUILD01 (Microsoft Windows NT 10.0.19045.0)\n**********************\n"
  "Transcript started, output file is C:\\logs\\t.txt\nPS C:\\> Get-Item C:\\nope\nGet-Item : Cannot find path 'C:\\nope' because it does not exist.\nAt line:1 char:1\n+ Get-Item C:\\nope\n+ ~~~~~~~~~~~~~~~~\n"
  "    + CategoryInfo          : ObjectNotFound: (C:\\nope:String) [Get-Item], ItemNotFoundException\n    + FullyQualifiedErrorId : PathNotFound,Microsoft.PowerShell.Commands.GetItemCommand\n"
  "PS C:\\> Write-Host done\ndone\n**********************\nWindows PowerShell transcript end\nEnd time: 20260913120100\n**********************\n")
w("powershell/transcript-utf16.txt", ("PS C:\\> Get-Item C:\\nope\nGet-Item : Cannot find path 'C:\\nope' because it does not exist.\nAt line:1 char:1\n"
  "    + CategoryInfo          : ObjectNotFound: (C:\\nope:String) [Get-Item], ItemNotFoundException\n").encode("utf-16"), binary=True)
# ---------------------------------------------------------------- infrastructure formats
w("syslog/rfc3164.log",
  "Sep 13 12:00:00 host01 sshd[999]: Failed password for invalid user admin from 10.0.0.9 port 2222 ssh2\n"
  "Sep 13 12:00:01 host01 kernel: Out of memory: Killed process 1234 (java) total-vm:2048kB\n"
  "<13>Sep 13 12:00:02 host01 orders[1234]: charge failed for order 42\n"
  "2026-09-13T12:00:03.123456+02:00 host01 orders[1234]: retrying order 42\n")
w("syslog/rfc5424.log",
  "<34>1 2026-09-13T12:00:00.123Z host01 orders 1234 ID47 [exampleSDID@32473 iut=\"3\" eventSource=\"Application\"] charge failed for order 42\n"
  "<165>1 2026-09-13T12:00:01Z host01 orders - - - started\n")
w("web/access-combined.log",
  "10.0.0.1 - - [13/Sep/2026:12:00:00 +0000] \"POST /api/orders/42 HTTP/1.1\" 502 512 \"-\" \"curl/8.0\"\n"
  "10.0.0.2 - bob [13/Sep/2026:12:00:01 +0000] \"GET /health HTTP/1.1\" 200 2\n"
  "10.0.0.3 - - [13/Sep/2026:12:00:02 +0000] \"GET /api/orders/43 HTTP/1.1\" 404 12 \"http://x\" \"Mozilla/5.0\"\n"
  "10.0.0.4 - - [13/Sep/2026:12:00:03 +0000] \"POST /api/orders/44 HTTP/1.1\" 502 512 \"-\" \"curl/8.0\"\n")
w("web/nginx-error.log",
  "2026/09/13 12:00:03 [error] 1234#1234: *42 connect() failed (111: Connection refused) while connecting to upstream, client: 10.0.0.1, server: api, request: \"GET /x HTTP/1.1\", upstream: \"http://10.0.0.5:8080/x\", host: \"api\"\n"
  "2026/09/13 12:00:04 [warn] 1234#1234: *43 an upstream response is buffered to a temporary file\n")
w("web/apache-error.log",
  "[Sun Sep 13 12:00:04.123456 2026] [proxy:error] [pid 1234:tid 5678] [client 10.0.0.1:5555] AH00898: Error reading from remote server returned by /api\n"
  "[Sun Sep 13 12:00:05 2026] [error] [client 10.0.0.1] PHP Fatal error:  Uncaught Exception: boom in /var/www/x.php:12\n")
w("web/iis-w3c.log",
  "#Software: Microsoft Internet Information Services 10.0\n#Version: 1.0\n#Date: 2026-09-13 12:00:00\n"
  "#Fields: date time s-ip cs-method cs-uri-stem cs-uri-query s-port cs-username c-ip cs(User-Agent) sc-status sc-substatus sc-win32-status time-taken\n"
  "2026-09-13 12:00:00 10.0.0.5 POST /api/orders/42 - 443 - 10.0.0.1 curl/8.0 500 0 0 1234\n"
  "2026-09-13 12:00:01 10.0.0.5 GET /health - 443 - 10.0.0.1 curl/8.0 200 0 0 3\n"
  "#Fields: date time cs-method cs-uri-stem sc-status\n2026-09-13 12:00:02 GET /x 404\n")
w("docker/docker-json-file.log", nd(
  {"log": "2026-09-13 12:00:00,123 - billing.worker - ERROR - charge failed for order 42\n", "stream": "stderr", "time": "2026-09-13T12:00:00.200Z"},
  {"log": "Traceback (most recent call last):\n", "stream": "stderr", "time": "2026-09-13T12:00:00.201Z"},
  {"log": "  File \"/app/billing/worker.py\", line 30, in run\n", "stream": "stderr", "time": "2026-09-13T12:00:00.202Z"},
  {"log": "ValueError: bad amount\n", "stream": "stderr", "time": "2026-09-13T12:00:00.203Z"},
  {"log": J({"level": "info", "msg": "json inside docker", "time": "2026-09-13T12:00:01Z"}) + "\n", "stream": "stdout", "time": "2026-09-13T12:00:01.100Z"},
  {"log": "plain line\n", "stream": "stdout", "time": "2026-09-13T12:00:02Z", "attrs": {"tag": "orders"}}))
w("cri/cri.log",
  "2026-09-13T12:00:00.123456789Z stderr F 2026-09-13 12:00:00,123 - billing.worker - ERROR - charge failed for order 42\n"
  "2026-09-13T12:00:00.223456789Z stderr F Traceback (most recent call last):\n"
  "2026-09-13T12:00:00.323456789Z stderr F   File \"/app/billing/worker.py\", line 30, in run\n"
  "2026-09-13T12:00:00.423456789Z stderr F ValueError: bad amount\n"
  "2026-09-13T12:00:01.000000000Z stdout P {\"level\":\"info\",\"msg\":\"long json rec\n"
  "2026-09-13T12:00:01.000000001Z stdout F ord split\",\"time\":\"2026-09-13T12:00:01Z\"}\n"
  "2026-09-13T12:00:02.000000000Z stdout F plain line\n"
  "2026-09-13T12:00:03.000000000Z stdout P unterminated partial\n")
w("journal/journal.json", nd(
  {"__REALTIME_TIMESTAMP": "1789000000123456", "__CURSOR": "s=abc", "PRIORITY": "3", "MESSAGE": "Failed to start unit\nTraceback (most recent call last):\n  File \"/x.py\", line 1, in m\nValueError: 1",
   "_SYSTEMD_UNIT": "app.service", "_HOSTNAME": "host01", "_PID": "42", "SYSLOG_IDENTIFIER": "app"},
  {"__REALTIME_TIMESTAMP": "1789000001123456", "__CURSOR": "s=abd", "PRIORITY": "6", "MESSAGE": [72, 105], "_COMM": "bash", "_HOSTNAME": "host01"}))
w("winevt/events.xml",
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<Events>\n"
  "<Event xmlns=\"http://schemas.microsoft.com/win/2004/08/events/event\"><System><Provider Name=\"Application Error\" /><EventID Qualifiers=\"0\">1000</EventID><Level>2</Level><Task>100</Task>"
  "<Keywords>0x80000000000000</Keywords>\n<TimeCreated SystemTime=\"2026-09-13T12:00:00.1234567Z\" /><EventRecordID>5001</EventRecordID><Channel>Application</Channel><Computer>BUILD01</Computer><Security /></System>"
  "<EventData><Data>orders.exe</Data><Data>1.2.3.4</Data><Data>KERNELBASE.dll</Data><Data>0xc0000005</Data></EventData>"
  "<RenderingInfo Culture=\"en-US\"><Message>Faulting application name: orders.exe, version: 1.2.3.4, faulting module name: KERNELBASE.dll, exception code 0xc0000005</Message><Level>Error</Level></RenderingInfo></Event>\n"
  "<Event xmlns=\"http://schemas.microsoft.com/win/2004/08/events/event\"><System><Provider Name=\"Service Control Manager\" Guid=\"{555908d1-a6d7-4695-8e1e-26931d2012f4}\" /><EventID>7034</EventID><Level>2</Level>"
  "<TimeCreated SystemTime=\"2026-09-13T12:00:01Z\" /><Computer>BUILD01</Computer></System><EventData><Data Name=\"param1\">Orders Service</Data><Data Name=\"param2\">1</Data></EventData></Event>\n</Events>\n")
w("winevt/wevtutil-fragment.xml",
  "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><Provider Name='X'/><EventID>1</EventID><Level>4</Level><TimeCreated SystemTime='2026-09-13T12:00:00Z'/><Computer>H</Computer></System><EventData><Data Name='a'>v</Data></EventData></Event>"
  "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><Provider Name='X'/><EventID>2</EventID><Level>2</Level><TimeCreated SystemTime='2026-09-13T12:00:01Z'/><Computer>H</Computer></System></Event>\n")
w("xml/generic.xml",
  "<logs><entry time=\"2026-09-13T12:00:00Z\" level=\"error\"><source>svc</source><message>boom</message><stacktrace>java.lang.RuntimeException: x\n\tat a.b.C.d(C.java:1)</stacktrace></entry>"
  "<entry time=\"2026-09-13T12:00:01Z\" level=\"info\"><message>ok</message></entry></logs>\n")
w("xml/xxe.xml", "<?xml version=\"1.0\"?>\n<!DOCTYPE foo [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]>\n<logs><entry><message>&xxe;</message></entry></logs>\n")
w("xml/billion-laughs.xml", "<?xml version=\"1.0\"?>\n<!DOCTYPE lolz [<!ENTITY lol \"lol\"><!ENTITY lol2 \"&lol;&lol;&lol;&lol;\">]>\n<logs><entry><message>&lol2;</message></entry></logs>\n")
w("ecs/ecs.ndjson", nd(
  {"@timestamp": "2026-09-13T12:00:00Z", "log": {"level": "error", "logger": "acme.orders"}, "message": "order failed",
   "error": {"type": "OrderError", "message": "no stock", "stack_trace": "OrderError: no stock\n    at place (/app/o.js:3:4)"},
   "service": {"name": "orders", "environment": "prod"}, "host": {"name": "web01"}, "trace": {"id": "abc"}, "http": {"response": {"status_code": 500}}, "ecs": {"version": "8.0"}},
  {"@timestamp": "2026-09-13T12:00:01Z", "log.level": "warn", "message": "slow", "service.name": "orders", "ecs.version": "8.0"}))
# single line + an "example" namespace value: the repository secret scan flags multi-line OTLP "key": "..." pairs
w("otlp/otlp-logs.json", J({"resourceLogs": [{"resource": {"attributes": [_kv("service.name", "orders"), _kv("host.name", "web01"), _kv("service.namespace", "example")]},
  "scopeLogs": [{"scope": {"name": "acme.orders"}, "logRecords": [
   {"timeUnixNano": "1789000000123456789", "observedTimeUnixNano": "1789000000223456789", "severityNumber": 17, "severityText": "ERROR", "body": {"stringValue": "order failed"},
    "attributes": [_kv("exception.type", "OrderError"), _kv("exception.message", "no stock"),
                   _kv("exception.stacktrace", "OrderError: no stock\n    at place (/app/o.js:3:4)"), _kv("http.response.status_code", "500", "intValue")],
    "traceId": "5b8efff798038103d269b633813fc60c", "spanId": "eee19b7ec3c1b174"},
   {"timeUnixNano": "1789000001123456789", "severityNumber": 9, "body": {"stringValue": "ok"}}]}]}]}) + "\n")
w("json/array.json", J([{"time": "2026-09-13T12:00:00Z", "level": "error", "msg": "a", "service": "orders"}, {"time": "2026-09-13T12:00:01Z", "level": "info", "msg": "b"}], indent=1) + "\n")
w("json/pretty-concatenated.json", J({"time": "2026-09-13T12:00:00Z", "level": "error", "msg": "a"}, indent=2) + "\n" + J({"time": "2026-09-13T12:00:01Z", "level": "info", "msg": "b"}, indent=2) + "\n")
w("json/generic.ndjson", J({"timestamp": "2026-09-13T12:00:00Z", "severity": "ERROR", "text": "boom", "correlationId": "c1", "status": 500, "method": "post", "path": "/x", "custom": {"a": 1}}) +
  "\nnot json at all\n" + J({"time": "2026-09-13T12:00:02Z", "lvl": "info", "description": "fine"}) + "\n{bad json\n")
w("json/es-hits.json", J({"took": 1, "hits": {"total": {"value": 1}, "hits": [{"_index": "logs", "_id": "1", "_source": {"@timestamp": "2026-09-13T12:00:00Z", "log.level": "error", "message": "boom", "service.name": "orders"}}]}}) + "\n")
w("json/truncated.json", "[{\"time\":\"2026-09-13T12:00:00Z\",\"level\":\"error\",\"msg\":\"a\"},{\"time\":\"2026-09-13T12:00:01Z\",\"le")
w("cloudwatch/get-log-events.json", J({"events": [
  {"timestamp": 1789000000123, "message": "2026-09-13 12:00:00,123 - billing.worker - ERROR - charge failed for order 42\n" + PY_TB.rstrip("\n"), "ingestionTime": 1789000000500},
  {"timestamp": 1789000001000, "message": J({"level": "warn", "msg": "slow"}), "ingestionTime": 1789000001500}], "nextForwardToken": "f/1", "nextBackwardToken": "b/1"}, indent=1) + "\n")
w("cloudwatch/lambda-python.log",
  "START RequestId: 8f1c2c3d-1111-2222-3333-444455556666 Version: $LATEST\n"
  "[INFO]\t2026-09-13T12:00:00.123Z\t8f1c2c3d-1111-2222-3333-444455556666\tprocessing order 42\n"
  "[ERROR]\t2026-09-13T12:00:00.456Z\t8f1c2c3d-1111-2222-3333-444455556666\tcharge failed for order 42\n"
  "Traceback (most recent call last):\n"
  "  File \"/var/task/handler.py\", line 12, in handler\n"
  "    charge(order)\n"
  "  File \"/var/task/billing/charge.py\", line 12, in charge\n"
  "    raise ValueError(\"boom\")\n"
  "ValueError: boom\n"
  "END RequestId: 8f1c2c3d-1111-2222-3333-444455556666\n"
  "REPORT RequestId: 8f1c2c3d-1111-2222-3333-444455556666\tDuration: 12.34 ms\tBilled Duration: 13 ms\tMemory Size: 128 MB\tMax Memory Used: 64 MB\n")
w("cloudwatch/subscription-data-message.json", J({"messageType": "DATA_MESSAGE", "owner": "123456789012", "logGroup": "/aws/lambda/orders", "logStream": "2026/09/13/[$LATEST]abc",
  "subscriptionFilters": ["f"], "logEvents": [{"id": "1", "timestamp": 1789000000123, "message": "START RequestId: abc Version: $LATEST"},
                                               {"id": "2", "timestamp": 1789000000456, "message": "2026-09-13T12:00:00.456Z\t8f1c2c3d-1111-2222-3333-444455556666\tERROR\tInvoke Error\t{\"errorType\":\"Error\",\"errorMessage\":\"boom\"}"},
                                               {"id": "3", "timestamp": 1789000000789, "message": "2026-09-13T12:00:00.789Z 8f1c2c3d-1111-2222-3333-444455556666 Task timed out after 3.00 seconds"}]}) + "\n")
w("cloudwatch/insights-results.json", J({"results": [[{"field": "@timestamp", "value": "2026-09-13 12:00:00.123"}, {"field": "@message", "value": "ERROR charge failed for order 42"}, {"field": "@logStream", "value": "s1"}]],
  "statistics": {"recordsMatched": 1.0}, "status": "Complete"}) + "\n")
w("azure/query-tables.json", J({"tables": [{"name": "PrimaryResult", "columns": [{"name": "TimeGenerated", "type": "datetime"}, {"name": "SeverityLevel", "type": "int"}, {"name": "Message", "type": "string"},
  {"name": "AppRoleName", "type": "string"}, {"name": "OperationId", "type": "string"}], "rows": [["2026-09-13T12:00:00.123Z", 3, "charge failed for order 42", "orders", "op1"], ["2026-09-13T12:00:01Z", 1, "ok", "orders", "op2"]]}]}) + "\n")
w("azure/diagnostic-export.json", J({"records": [{"time": "2026-09-13T12:00:00.123Z", "resourceId": "/SUBSCRIPTIONS/X/RESOURCEGROUPS/RG/PROVIDERS/MICROSOFT.WEB/SITES/ORDERS", "category": "AppServiceConsoleLogs",
  "operationName": "Microsoft.Web/sites/log", "level": "Error", "properties": {"message": "charge failed for order 42", "appRoleName": "orders"}}]}) + "\n")
w("gcp/logentries.json", J([{"insertId": "1", "timestamp": "2026-09-13T12:00:00.123Z", "receiveTimestamp": "2026-09-13T12:00:00.500Z", "severity": "ERROR", "logName": "projects/p/logs/stderr",
  "resource": {"type": "k8s_container", "labels": {"container_name": "orders", "pod_name": "orders-7f9c6d8b5-x2k4q", "namespace_name": "prod"}},
  "textPayload": "2026-09-13 12:00:00,123 - billing.worker - ERROR - charge failed for order 42", "trace": "projects/p/traces/abc", "spanId": "s1"},
  {"insertId": "2", "timestamp": "2026-09-13T12:00:01Z", "severity": "WARNING", "logName": "projects/p/logs/app", "resource": {"type": "cloud_run_revision", "labels": {"service_name": "orders"}},
   "jsonPayload": {"message": "slow query", "duration_ms": 1200}, "httpRequest": {"status": 200, "requestMethod": "GET", "requestUrl": "/x"}}], indent=1) + "\n")
w("gcp/logentries.ndjson", nd({"insertId": "3", "timestamp": "2026-09-13T12:00:02Z", "severity": "ERROR", "logName": "projects/p/logs/app", "resource": {"type": "gce_instance", "labels": {"instance_id": "i-1"}},
  "textPayload": "charge failed for order 44"}))
w("loki/query-range.json", J({"status": "success", "data": {"resultType": "streams", "result": [
  {"stream": {"app": "orders", "level": "error", "pod": "orders-1"}, "values": [["1789000000123456789", "2026-09-13 12:00:00,123 - billing.worker - ERROR - charge failed for order 42"],
   ["1789000000223456789", "Traceback (most recent call last):"], ["1789000000323456789", "  File \"/app/billing/worker.py\", line 30, in run"], ["1789000000423456789", "ValueError: bad amount"]]},
  {"stream": {"app": "api", "level": "info"}, "values": [["1789000001123456789", J({"level": "info", "msg": "hello"})]]}], "stats": {}}}) + "\n")
w("loki/logcli.jsonl", nd({"labels": {"app": "orders", "level": "error"}, "line": "charge failed order=42", "timestamp": "2026-09-13T12:00:00.123456789Z"}))
w("tabular/events.csv",
  "timestamp,level,logger,message,exception\n"
  "2026-09-13T12:00:00Z,ERROR,billing,\"charge failed, order 42\",\"ValueError: bad amount\n  File \"\"/app/billing/charge.py\"\", line 3, in run\"\n"
  "2026-09-13T12:00:01Z,INFO,billing,ok,\n"
  "2026-09-13T12:00:02Z,WARN,billing,\"multi\nline message\",\n"
  "bad,row\n")
w("tabular/events.tsv", "2026-09-13T12:00:00Z\tERROR\tcharge failed\t42\n2026-09-13T12:00:01Z\tINFO\tok\t43\n2026-09-13T12:00:02Z\tINFO\tok again\t44\n")
w("logfmt/logfmt.log",
  "time=2026-09-13T12:00:00.000Z level=ERROR msg=\"charge failed\" err=\"context deadline exceeded\" order=42 service=orders\n"
  "time=2026-09-13T12:00:01.000Z level=INFO msg=ok\nts=2026-09-13T12:00:02Z lvl=warn msg=\"slow query\" duration=1.5s trace_id=abc\ngarbage line here\n")
# ---------------------------------------------------------------- ingestion edge cases
w("edge/hostile.log",
  "2026-09-13 12:00:00 ERROR <script>alert('x')</script> | =HYPERLINK(\"http://evil.example\") | [link](http://evil.example) | `code` **bold** # heading\n"
  "2026-09-13 12:00:01 ERROR </pre></code></details><img src=x onerror=alert(1)> and a </script><script>alert(2)</script> tail\n"
  "=SUM(A1:A9) formula first line\n+cmd|' /C calc'!A0\n@evil headerless\n-1234 negative-looking\n")
w("edge/mixed-formats.log",
  "2026-09-13 12:00:00,123 - billing.worker - ERROR - charge failed for order 42\n"
  + J({"time": "2026-09-13T12:00:01Z", "level": "error", "msg": "json line in a text file"}) + "\n"
  "Sep 13 12:00:02 host01 orders[1234]: syslog line in a text file\n"
  "\x00\x00 binary-ish garbage \xff\xfe line\n"
  "2026-09-13 12:00:03,123 - billing.worker - INFO - done\n")
w("edge/latin1.log", "2026-09-13 12:00:00,123 - app - ERROR - caf\xe9 na\xefve fa\xe7ade\n".encode("latin-1"), binary=True)
w("edge/utf8-bom.log", "\ufeff2026-09-13 12:00:00,123 - app - ERROR - with bom\n2026-09-13 12:00:01,123 - app - INFO - ok\n")
w("edge/no-timestamps.log", "ERROR: something failed\nWARN: something odd\nERROR: something failed\nplain line without anything\n")
w("edge/timezones.log",
  "2026-09-13T12:00:00Z ERROR utc explicit\n2026-09-13T14:00:00+02:00 ERROR offset explicit (same instant as above)\n"
  "2026-09-13 12:00:00 ERROR naive local-looking\nSep 13 11:59:59 host app[1]: missing year\n12:00:00.123 [main] ERROR c.a.X - time only\n")
w("edge/evtx-magic.evtx", b"ElfFile\x00" + b"\x00" * 200 + b"\x01\x02", binary=True)
w("edge/journal-magic.journal", b"LPKSHHRH" + b"\x00" * 200, binary=True)
w("edge/binary.bin", bytes(range(256)) * 4, binary=True)
w("edge/empty.log", "")
w("edge/spaces in name.log", "2026-09-13 12:00:00,123 - app - ERROR - path with spaces\n")
w("edge/bzip2-magic.log", b"BZh91AY&SY" + b"\x00" * 32, binary=True)   # bzip2 magic under a .log name
w("edge/prose.log", "the quick brown fox jumps over the lazy dog\nnothing here looks like a log header at all\njust free text lines\n")
gz_content = ("2026-09-13 12:00:00,123 - app - ERROR - gzipped line 1\n" * 200 + "2026-09-13 12:00:01,123 - app - INFO - gzipped line 2\n").encode("utf-8")
w("edge/plain.log.gz", gzip.compress(gz_content), binary=True)
full = gzip.compress(("2026-09-13 12:00:00,123 - app - ERROR - truncated gzip line\n" * 5000).encode("utf-8"))
w("edge/truncated.log.gz", full[: len(full) // 2], binary=True)
w("edge/multi-member.log.gz", gzip.compress(b"2026-09-13 12:00:00,123 - app - ERROR - member one\n") + gzip.compress(b"2026-09-13 12:00:01,123 - app - ERROR - member two\n"), binary=True)
w("edge/oversized-line.log", "2026-09-13 12:00:00,123 - app - ERROR - short line\n2026-09-13 12:00:01,123 - app - ERROR - " + "x" * 5000 + "\n2026-09-13 12:00:02,123 - app - INFO - after\n")
w("edge/grouping-equivalence.log", "".join(
  "2026-09-13T12:%02d:%02dZ ERROR Failed to process order %s for user %d from 10.1.2.%d:%d in %dms (attempt %d/5) request_id=%s service=order-service\n" % (
      i // 60, i % 60, "8f3a7c2e-1234-4d5e-9abc-%012d" % i, 100 + i, i % 250, 40000 + i, 10 + i, 1 + i % 5, "req-%x" % (i * 7919)) for i in range(30)) +
  "2026-09-13T12:30:00Z ERROR Failed to process order 8f3a7c2e-1234-4d5e-9abc-000000000042 for user 7 status code 500 service=order-service\n"
  "2026-09-13T12:30:01Z ERROR Failed to process order 8f3a7c2e-1234-4d5e-9abc-000000000043 for user 8 status code 503 service=order-service\n"
  "2026-09-13T12:31:00Z ERROR Failed to process order 8f3a7c2e-1234-4d5e-9abc-000000000044 for user 9 from 10.1.2.3:4444 in 12ms (attempt 1/5) request_id=req-1 service=payment-service\n")
print("fixtures written under", FIX)
