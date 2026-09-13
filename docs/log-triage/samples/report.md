# log-triage report

Generated 2026-09-13T14:38:48.212Z by log-triage 1.0.0 (schema 1.0.0). Completion: **complete**.

## 1. Executive summary

| Item | Value |
|---|---|
| Inputs | 6 file(s): 6 processed, 0 partial, 0 excluded, 0 failed; 9270 bytes read |
| Time range | 2026-09-13T10:00:00.123Z to 2026-09-13T12:31:00Z (48 timed, 1 untimed events) |
| Events | 49 parsed, 49 included (0 filtered by --since, 0 untimed excluded) |
| Issue groups | 18 total, 18 reported at or above `info` (0 below threshold) |
| Highest severity | high |
| By severity | critical: 0 groups / 0 events; high: 3 groups / 4 events; medium: 7 groups / 37 events; low: 2 groups / 2 events; info: 6 groups / 6 events |

### Highest-impact findings

1. **LT-d35ab553479c** (high, availability, x2) — POST /api/orders/\<n\> -\> \<n\>
2. **LT-45812cae8cb3** (high, availability, x1) — Failed to process order \<uuid\> for user \<n\> status code 500 service=order-service
3. **LT-0b8d948bb890** (high, availability, x1) — Failed to process order \<uuid\> for user \<n\> status code 503 service=order-service
4. **LT-0687b7bfe339** (medium, unknown, x30) — Failed to process order \<uuid\> for user \<n\> from \<ip\>:\<n\> in \<dur\> (attempt \<n\>/\<n\>) request\_id=req-\<id\> service=order-service
5. **LT-a90eef438a86** (medium, network, x2) — Failed to place order \<n\> for customer \<n\>
6. **LT-102319349c95** (medium, unknown, x1) — charge failed
7. **LT-85f302734ac6** (medium, unknown, x1) — Failed to place order \<n\>
8. **LT-bfc7484129c3** (medium, network, x1) — charge failed for order \<n\>
9. **LT-b1d0e8dc43fc** (medium, network, x1) — charge failed for order \<n\>
10. **LT-6d7c6a6bd062** (medium, unknown, x1) — Failed to process order \<uuid\> for user \<n\> from \<ip\>:\<n\> in \<dur\> (attempt \<n\>/\<n\>) request\_id=req-\<id\> service=payment-service

### Completeness

Analysis complete.

_Source references were checked against the current checkouts, which may differ from the version that produced the logs._

## 2. Prioritized findings

Showing 18 of 18 reported groups (18 total).

| ID | Severity | Category | Service / repo | Count | Confidence | First | Last | Template | Next action |
|---|---|---|---|---:|---|---|---|---|---|
| LT-d35ab553479c | high | availability | n/a [orders] | 2 | 0.85 (observed) | 2026-09-13T12:00:00Z | 2026-09-13T12:00:03Z | `POST /api/orders/<n> -> <n>` | Check upstream health and readiness handling for the failing operation (generic guidance; no source investigation) |
| LT-45812cae8cb3 | high | availability | order-service | 1 | 0.85 (observed) | 2026-09-13T12:30:00Z | 2026-09-13T12:30:00Z | `Failed to process order <uuid> for user <n> status code 500 service=order-service` | Check upstream health and readiness handling for the failing operation (generic guidance; no source investigation) |
| LT-0b8d948bb890 | high | availability | order-service | 1 | 0.85 (observed) | 2026-09-13T12:30:01Z | 2026-09-13T12:30:01Z | `Failed to process order <uuid> for user <n> status code 503 service=order-service` | Check upstream health and readiness handling for the failing operation (generic guidance; no source investigation) |
| LT-0687b7bfe339 | medium | unknown | order-service | 30 | 0.35 (unknown) | 2026-09-13T12:00:00Z | 2026-09-13T12:00:29Z | `Failed to process order <uuid> for user <n> from <ip>:<n> in <dur> (attempt <n>/<n>) request_id=req-<id> service=order-s` | Increase diagnostic context around the failing operation (generic guidance; no source investigation) |
| LT-a90eef438a86 | medium | network | n/a [orders] | 2 | 0.85 (observed) | 2026-09-13T10:00:01.456Z | 2026-09-13T10:00:02Z | `Failed to place order <n> for customer <n>` | Harden network error handling at the call site at src/Acme.Orders/OrderService.cs:42 (orders) |
| LT-102319349c95 | medium | unknown | n/a | 1 | 0.35 (unknown) | 2026-09-13T10:00:01.123Z | 2026-09-13T10:00:01.123Z | `charge failed` | Increase diagnostic context around the failing operation (generic guidance; no source investigation) |
| LT-85f302734ac6 | medium | unknown | n/a | 1 | 0.35 (unknown) | 2026-09-13T10:00:01.123Z | 2026-09-13T10:00:01.123Z | `Failed to place order <n>` | Increase diagnostic context around the failing operation (generic guidance; no source investigation) |
| LT-bfc7484129c3 | medium | network | n/a [billing] | 1 | 0.85 (observed) | 2026-09-13T12:00:01.123Z | 2026-09-13T12:00:01.123Z | `charge failed for order <n>` | Harden network error handling at the call site at billing/worker.py:33 (billing) |
| LT-b1d0e8dc43fc | medium | network | n/a [billing] | 1 | 0.85 (observed) | 2026-09-13T12:00:02.123Z | 2026-09-13T12:00:02.123Z | `charge failed for order <n>` | Harden network error handling at the call site at billing/charge.py:12 (billing) |
| LT-6d7c6a6bd062 | medium | unknown | payment-service | 1 | 0.35 (unknown) | 2026-09-13T12:31:00Z | 2026-09-13T12:31:00Z | `Failed to process order <uuid> for user <n> from <ip>:<n> in <dur> (attempt <n>/<n>) request_id=req-<id> service=payment` | Increase diagnostic context around the failing operation (generic guidance; no source investigation) |
| LT-228bb4b285fb | low | performance | n/a | 1 | 0.6 (inferred) | 2026-09-13T10:00:03Z | 2026-09-13T10:00:03Z | `Retrying payment (attempt <n>/<n>) after <dur>` | Profile the slow operation and bound retries (generic guidance; no source investigation) |
| LT-a0db72527b05 | low | client\_error | n/a [orders] | 1 | 0.85 (observed) | 2026-09-13T12:00:02Z | 2026-09-13T12:00:02Z | `GET /api/orders/<n> -> <n>` | Return structured validation errors and check client integrations (generic guidance; no source investigation) |
| LT-4e9e698c369a | info | operational | n/a [orders] | 1 | 0.6 (inferred) | 2026-09-13T10:00:00.123Z | 2026-09-13T10:00:00.123Z | `Starting Acme.Orders` | Increase diagnostic context around the failing operation (generic guidance; no source investigation) |
| LT-abe4e469a8d3 | info | operational | n/a | 1 | 0.6 (inferred) | 2026-09-13T10:00:00.123Z | 2026-09-13T10:00:00.123Z | `starting` | Increase diagnostic context around the failing operation (generic guidance; no source investigation) |
| LT-f045f3c4e056 | info | operational | n/a | 1 | 0.6 (inferred) | 2026-09-13T10:00:00.123Z | 2026-09-13T10:00:00.123Z | `Started App in <dur>` | Increase diagnostic context around the failing operation (generic guidance; no source investigation) |
| LT-04097dbdd0ef | info | operational | n/a [billing] | 1 | 0.6 (inferred) | 2026-09-13T12:00:00.123Z | 2026-09-13T12:00:00.123Z | `worker started` | Increase diagnostic context around the failing operation (generic guidance; no source investigation) |
| LT-d46742b9402c | info | unknown | n/a | 1 | 0.35 (unknown) | 2026-09-13T12:00:01Z | 2026-09-13T12:00:01Z | `GET /health -> <n>` | Increase diagnostic context around the failing operation (generic guidance; no source investigation) |
| LT-2791132b6e6e | info | unknown | n/a | 1 | 0.35 (unknown) | n/a | n/a | `time-only serilog console line` | Increase diagnostic context around the failing operation (generic guidance; no source investigation) |

## 3. Root-cause assessment

### LT-a90eef438a86 (medium, network)

Observed:

- 2 occurrence(s) between 2026-09-13T10:00:01.456Z and 2026-09-13T10:00:02Z
- producer level(s): ERR x2
- exception chain: System.InvalidOperationException -\> System.IO.IOException

Hypotheses:

- network failure at src/Acme.Orders/OrderService.cs:42 (confidence 0.85): exception type System.IO.IOException indicates network; occurrence count (2) does not influence severity

Uncertainty / alternatives:

- the analysed checkout (billing@7ae7b2e8156a, orders@7ab99b3bd21d) may not be the version that produced the log
- the message may be a symptom of an upstream failure sharing the same time window (check correlated groups)

### LT-bfc7484129c3 (medium, network)

Observed:

- 1 occurrence(s) between 2026-09-13T12:00:01.123Z and 2026-09-13T12:00:01.123Z
- producer level(s): ERROR x1
- exception chain: billing.errors.ChargeFailed -\> requests.exceptions.ConnectionError

Hypotheses:

- network failure at billing/worker.py:33 (confidence 0.85): exception type requests.exceptions.ConnectionError indicates network; occurrence count (1) does not influence severity

Uncertainty / alternatives:

- the analysed checkout (billing@7ae7b2e8156a, orders@7ab99b3bd21d) may not be the version that produced the log
- the message may be a symptom of an upstream failure sharing the same time window (check correlated groups)

### LT-b1d0e8dc43fc (medium, network)

Observed:

- 1 occurrence(s) between 2026-09-13T12:00:02.123Z and 2026-09-13T12:00:02.123Z
- producer level(s): ERROR x1
- exception chain: requests.exceptions.ConnectionError

Hypotheses:

- network failure at billing/charge.py:12 (confidence 0.85): exception type requests.exceptions.ConnectionError indicates network; occurrence count (1) does not influence severity

Uncertainty / alternatives:

- the analysed checkout (billing@7ae7b2e8156a, orders@7ab99b3bd21d) may not be the version that produced the log
- the message may be a symptom of an upstream failure sharing the same time window (check correlated groups)


## 4. Fix plan

### LT-a90eef438a86 — Harden network error handling at the call site at src/Acme.Orders/OrderService.cs:42 (orders)

**Harden network error handling at the call site at src/Acme.Orders/OrderService.cs:42 (orders)** (source\_backed, deterministic, confidence 0.75)

Network-level failures (DNS, TLS, resets) dominate; the code should retry transient failures and surface persistent ones clearly. Reference verified in the checkout (symbol Place found within 6 lines of line 42).

Suggested changes:

- classify transient vs. persistent network errors
- retry transient errors with backoff
- surface TLS/DNS details in the error

Source references:

- `src/Acme.Orders/OrderService.cs:42` in orders — **verified**: symbol Place found within 6 lines of line 42

Regression tests:

- unit test injecting connection reset / DNS failure

Verification:

- correlate with infrastructure changes (DNS, certificates, load balancer) in the time window

```
   36          // documentation line 35
   37          // documentation line 36
   38          // documentation line 37
   39          // documentation line 38
   40          public async Task<Order> Place(Order order)
   41          {
   42>             var response = await _client.PostAsJsonAsync("/payments", order);
   43              response.EnsureSuccessStatusCode();
   44              await _repository.SaveAsync(order);
   45              return order;
   46          }
   47      }
   48  }
```

### LT-bfc7484129c3 — Harden network error handling at the call site at billing/worker.py:33 (billing)

**Harden network error handling at the call site at billing/worker.py:33 (billing)** (source\_backed, deterministic, confidence 0.75)

Network-level failures (DNS, TLS, resets) dominate; the code should retry transient failures and surface persistent ones clearly. Reference verified in the checkout (file and line exist in the checkout (no symbol to cross-check); symbol charge found within 6 lines of line 12).

Suggested changes:

- classify transient vs. persistent network errors
- retry transient errors with backoff
- surface TLS/DNS details in the error

Source references:

- `billing/worker.py:33` in billing — **verified**: file and line exist in the checkout (no symbol to cross-check)
- `billing/charge.py:12` in billing — **verified**: symbol charge found within 6 lines of line 12
- `billing/worker.py:30` in billing — **verified**: file and line exist in the checkout (no symbol to cross-check)

Regression tests:

- unit test injecting connection reset / DNS failure

Verification:

- correlate with infrastructure changes (DNS, certificates, load balancer) in the time window

```
   27  # padding line 26
   28  
   29  def run(queue):
   30      for order in queue:
   31          charge(order)
   32          log.info("charged %s", order.id)
   33>         time.sleep(0.1)
   34  
```

```
    6  
    7  def charge(order):
    8      payload = {"order": order.id, "amount": order.amount}
    9      session = requests.Session()
   10      session.headers["X-Order"] = str(order.id)
   11      # the gateway occasionally times out under load
   12>     response = session.post(GATEWAY, json=payload, timeout=5)
   13      response.raise_for_status()
   14      return response.json()
   15  
```

### LT-b1d0e8dc43fc — Harden network error handling at the call site at billing/charge.py:12 (billing)

**Harden network error handling at the call site at billing/charge.py:12 (billing)** (source\_backed, deterministic, confidence 0.75)

Network-level failures (DNS, TLS, resets) dominate; the code should retry transient failures and surface persistent ones clearly. Reference verified in the checkout (symbol charge found within 6 lines of line 12; file and line exist in the checkout (no symbol to cross-check)).

Suggested changes:

- classify transient vs. persistent network errors
- retry transient errors with backoff
- surface TLS/DNS details in the error

Source references:

- `billing/charge.py:12` in billing — **verified**: symbol charge found within 6 lines of line 12
- `billing/worker.py:30` in billing — **verified**: file and line exist in the checkout (no symbol to cross-check)

Regression tests:

- unit test injecting connection reset / DNS failure

Verification:

- correlate with infrastructure changes (DNS, certificates, load balancer) in the time window

```
    6  
    7  def charge(order):
    8      payload = {"order": order.id, "amount": order.amount}
    9      session = requests.Session()
   10      session.headers["X-Order"] = str(order.id)
   11      # the gateway occasionally times out under load
   12>     response = session.post(GATEWAY, json=payload, timeout=5)
   13      response.raise_for_status()
   14      return response.json()
   15  
```

```
   24  # padding line 23
   25  # padding line 24
   26  # padding line 25
   27  # padding line 26
   28  
   29  def run(queue):
   30>     for order in queue:
   31          charge(order)
   32          log.info("charged %s", order.id)
   33          time.sleep(0.1)
   34  
```


## 5. Issue details

18 of 18 reported groups; examples are redacted and bounded to 4 per group.

### LT-d35ab553479c — high availability (x2)

- Template: `POST /api/orders/<n> -> <n>`
- Fingerprint: `d35ab553479c215700ef81acd1b7817bc11b1ecd7ba379729588f7927e0cd1f3` (v1)
- First/last seen: 2026-09-13T12:00:00Z / 2026-09-13T12:00:03Z
- Producer levels: ERROR x2
- Assessment: confidence 0.85 (observed); HTTP status 502 observed -\> availability; occurrence count (2) does not influence severity
- HTTP: POST /api/orders/\<n\> -> 502
- Grouping: confidence 0.8; grouped by normalized message template; HTTP status 502 and route template are part of the key
- Attribution: unresolved — orders (0.1)

Example `logs/access-combined.log:1` 2026-09-13T12:00:00Z error:

```
POST /api/orders/42 -> 502
```

Example `logs/access-combined.log:4` 2026-09-13T12:00:03Z error:

```
POST /api/orders/44 -> 502
```

### LT-45812cae8cb3 — high availability (x1)

- Template: `Failed to process order <uuid> for user <n> status code 500 service=order-service`
- Fingerprint: `45812cae8cb36f61f0a647b002215444460461ce28291733e596b4013a62e69e` (v1)
- First/last seen: 2026-09-13T12:30:00Z / 2026-09-13T12:30:00Z
- Producer levels: ERROR x1
- Assessment: confidence 0.85 (observed); HTTP status 500 observed -\> availability; occurrence count (1) does not influence severity
- Services: order-service
- HTTP:   -> 500
- Grouping: confidence 0.8; grouped by normalized message template; HTTP status 500 and route template are part of the key
- Attribution: unresolved

Example `logs/grouping-equivalence.log:31` 2026-09-13T12:30:00Z ERROR:

```
Failed to process order 8f3a7c2e-1234-4d5e-9abc-000000000042 for user 7 status code 500 service=order-service
```

### LT-0b8d948bb890 — high availability (x1)

- Template: `Failed to process order <uuid> for user <n> status code 503 service=order-service`
- Fingerprint: `0b8d948bb8909f78c67bda7f91629de508fd2a06f779e07a1e0d95e517e9fc8e` (v1)
- First/last seen: 2026-09-13T12:30:01Z / 2026-09-13T12:30:01Z
- Producer levels: ERROR x1
- Assessment: confidence 0.85 (observed); HTTP status 503 observed -\> availability; occurrence count (1) does not influence severity
- Services: order-service
- HTTP:   -> 503
- Grouping: confidence 0.8; grouped by normalized message template; HTTP status 503 and route template are part of the key
- Attribution: unresolved

Example `logs/grouping-equivalence.log:32` 2026-09-13T12:30:01Z ERROR:

```
Failed to process order 8f3a7c2e-1234-4d5e-9abc-000000000043 for user 8 status code 503 service=order-service
```

### LT-0687b7bfe339 — medium unknown (x30)

- Template: `Failed to process order <uuid> for user <n> from <ip>:<n> in <dur> (attempt <n>/<n>) request_id=req-<id> service=order-service`
- Fingerprint: `0687b7bfe339c3f76f0bb2781877b30b36b7b897850dc9137a119e72fc945152` (v1)
- First/last seen: 2026-09-13T12:00:00Z / 2026-09-13T12:00:29Z
- Producer levels: ERROR x30
- Assessment: confidence 0.35 (unknown); no categorical evidence; producer level indicates a failure of unknown kind; severity from producer level only (ERROR); occurrence count (30) does not influence severity
- Services: order-service
- Grouping: confidence 0.8; grouped by normalized message template; 8+ distinct raw messages folded into this template (placeholders vary)
- Attribution: unresolved

Example `logs/grouping-equivalence.log:1` 2026-09-13T12:00:00Z ERROR:

```
Failed to process order 8f3a7c2e-1234-4d5e-9abc-000000000000 for user 100 from 10.1.2.0:40000 in 10ms (attempt 1/5) request_id=req-0 service=order-service
```

Example `logs/grouping-equivalence.log:2` 2026-09-13T12:00:01Z ERROR:

```
Failed to process order 8f3a7c2e-1234-4d5e-9abc-000000000001 for user 101 from 10.1.2.1:40001 in 11ms (attempt 2/5) request_id=req-1eef service=order-service
```

Example `logs/grouping-equivalence.log:3` 2026-09-13T12:00:02Z ERROR:

```
Failed to process order 8f3a7c2e-1234-4d5e-9abc-000000000002 for user 102 from 10.1.2.2:40002 in 12ms (attempt 3/5) request_id=req-3dde service=order-service
```

Example `logs/grouping-equivalence.log:30` 2026-09-13T12:00:29Z ERROR (last seen):

```
Failed to process order 8f3a7c2e-1234-4d5e-9abc-000000000029 for user 129 from 10.1.2.29:40029 in 39ms (attempt 5/5) request_id=req-38113 service=order-service
```

### LT-a90eef438a86 — medium network (x2)

- Template: `Failed to place order <n> for customer <n>`
- Fingerprint: `a90eef438a8623bce880cc9f9a5a482fcc63107da1dd8b66c3590188000aaa13` (v1)
- First/last seen: 2026-09-13T10:00:01.456Z / 2026-09-13T10:00:02Z
- Producer levels: ERR x2
- Assessment: confidence 0.85 (observed); exception type System.IO.IOException indicates network; occurrence count (2) does not influence severity
- Exception chain: `System.InvalidOperationException -> System.IO.IOException` — Sequence contains no elements
- Grouping: confidence 0.9; grouped by exception chain System.InvalidOperationException\>System.IO.IOException and message template
- Attribution: resolved — orders (1.0)

Example `logs/serilog-text.log:2` 2026-09-13T10:00:01.456Z ERR:

```
Failed to place order 42 for customer 7
System.InvalidOperationException: Sequence contains no elements
    at Acme.Orders.Api.Controllers.OrdersController.Post (/src/Acme.Orders.Api/Controllers/OrdersController.cs:77)
    at Microsoft.AspNetCore.Mvc.Infrastructure.ActionMethodExecutor.TaskOfIActionResultExecutor.Execute
Caused by: System.IO.IOException: The pipe is broken
    at Acme.Orders.OrderService.Place (/src/Acme.Orders/OrderService.cs:42)
```

Example `logs/serilog-text.log:9` 2026-09-13T10:00:02Z ERR:

```
Failed to place order 43 for customer 9
System.InvalidOperationException: Sequence contains no elements
    at Acme.Orders.Api.Controllers.OrdersController.Post (/src/Acme.Orders.Api/Controllers/OrdersController.cs:77)
Caused by: System.IO.IOException: The pipe is broken
    at Acme.Orders.OrderService.Place (/src/Acme.Orders/OrderService.cs:42)
```

### LT-102319349c95 — medium unknown (x1)

- Template: `charge failed`
- Fingerprint: `102319349c9586dca92d055a14aba56cd24f458e50f5559053a4a434f99ae0b5` (v1)
- First/last seen: 2026-09-13T10:00:01.123Z / 2026-09-13T10:00:01.123Z
- Producer levels: ERROR x1
- Assessment: confidence 0.35 (unknown); no categorical evidence; producer level indicates a failure of unknown kind; severity from producer level only (ERROR); occurrence count (1) does not influence severity
- Grouping: confidence 0.7; grouped by normalized message template
- Attribution: unresolved

Example `logs/zap-console.log:2` 2026-09-13T10:00:01.123Z ERROR:

```
charge failed
```

### LT-85f302734ac6 — medium unknown (x1)

- Template: `Failed to place order <n>`
- Fingerprint: `85f302734ac6f0ce15a20e88e268861c22a5373cef791f5c89db0025a63313c4` (v1)
- First/last seen: 2026-09-13T10:00:01.123Z / 2026-09-13T10:00:01.123Z
- Producer levels: ERROR x1
- Assessment: confidence 0.35 (unknown); no categorical evidence; producer level indicates a failure of unknown kind; severity from producer level only (ERROR); occurrence count (1) does not influence severity
- Exception chain: `java.lang.IllegalStateException` — boom
- Grouping: confidence 0.9; grouped by exception chain java.lang.IllegalStateException and message template
- Attribution: unresolved

Example `logs/spring-boot.log:2` 2026-09-13T10:00:01.123Z ERROR:

```
Failed to place order 42
java.lang.IllegalStateException: boom
    at com.acme.orders.OrderService.place (OrderService.java:42)
```

### LT-bfc7484129c3 — medium network (x1)

- Template: `charge failed for order <n>`
- Fingerprint: `bfc7484129c3cc385b75edc98307377df3330da9fe843f9c65f94edd882e0143` (v1)
- First/last seen: 2026-09-13T12:00:01.123Z / 2026-09-13T12:00:01.123Z
- Producer levels: ERROR x1
- Assessment: confidence 0.85 (observed); exception type requests.exceptions.ConnectionError indicates network; occurrence count (1) does not influence severity
- Exception chain: `billing.errors.ChargeFailed -> requests.exceptions.ConnectionError` — could not charge order \<n\>
- Grouping: confidence 0.9; grouped by exception chain billing.errors.ChargeFailed\>requests.exceptions.ConnectionError and message template
- Attribution: resolved — billing (1.0)

Example `logs/python-asctime.log:2` 2026-09-13T12:00:01.123Z ERROR:

```
charge failed for order 42
billing.errors.ChargeFailed: could not charge order 42
    at run (/app/billing/worker.py:33)
Caused by: requests.exceptions.ConnectionError: HTTPConnectionPool(host='payments', port=8080): Max retries exceeded
    at charge (/app/billing/charge.py:12)
    at run (/app/billing/worker.py:30)
```

### LT-b1d0e8dc43fc — medium network (x1)

- Template: `charge failed for order <n>`
- Fingerprint: `b1d0e8dc43fc373acddeda7cbe3dda499ed337b56819bd0d3e843fe677bd6a2e` (v1)
- First/last seen: 2026-09-13T12:00:02.123Z / 2026-09-13T12:00:02.123Z
- Producer levels: ERROR x1
- Assessment: confidence 0.85 (observed); exception type requests.exceptions.ConnectionError indicates network; occurrence count (1) does not influence severity
- Exception chain: `requests.exceptions.ConnectionError` — HTTPConnectionPool(host='payments', port=\<id\>): Max retries exceeded
- Grouping: confidence 0.9; grouped by exception chain requests.exceptions.ConnectionError and message template
- Attribution: resolved — billing (1.0)

Example `logs/python-asctime.log:16` 2026-09-13T12:00:02.123Z ERROR:

```
charge failed for order 43
requests.exceptions.ConnectionError: HTTPConnectionPool(host='payments', port=8080): Max retries exceeded
    at charge (/app/billing/charge.py:12)
    at run (/app/billing/worker.py:30)
```

### LT-6d7c6a6bd062 — medium unknown (x1)

- Template: `Failed to process order <uuid> for user <n> from <ip>:<n> in <dur> (attempt <n>/<n>) request_id=req-<id> service=payment-service`
- Fingerprint: `6d7c6a6bd0624220de033c2e18f7c10f33412f8d94580ffc111c64de1585bcdc` (v1)
- First/last seen: 2026-09-13T12:31:00Z / 2026-09-13T12:31:00Z
- Producer levels: ERROR x1
- Assessment: confidence 0.35 (unknown); no categorical evidence; producer level indicates a failure of unknown kind; severity from producer level only (ERROR); occurrence count (1) does not influence severity
- Services: payment-service
- Grouping: confidence 0.8; grouped by normalized message template
- Attribution: unresolved

Example `logs/grouping-equivalence.log:33` 2026-09-13T12:31:00Z ERROR:

```
Failed to process order 8f3a7c2e-1234-4d5e-9abc-000000000044 for user 9 from 10.1.2.3:4444 in 12ms (attempt 1/5) request_id=req-1 service=payment-service
```

### LT-228bb4b285fb — low performance (x1)

- Template: `Retrying payment (attempt <n>/<n>) after <dur>`
- Fingerprint: `228bb4b285fb81fc0a3c94fd438c1acdeab37171a8e5a9ac74fbf3b13623c84a` (v1)
- First/last seen: 2026-09-13T10:00:03Z / 2026-09-13T10:00:03Z
- Producer levels: WRN x1
- Assessment: confidence 0.6 (inferred); message evidence 'retrying' -\> performance; producer level is WARNING; severity capped at medium; occurrence count (1) does not influence severity
- Grouping: confidence 0.8; grouped by normalized message template
- Attribution: unresolved

Example `logs/serilog-text.log:15` 2026-09-13T10:00:03Z WRN:

```
Retrying payment (attempt 2/5) after 5000 ms
```

### LT-a0db72527b05 — low client\_error (x1)

- Template: `GET /api/orders/<n> -> <n>`
- Fingerprint: `a0db72527b05b7d71e7a54317185f30f1f50475aa479dbd16b783e7fa799adf3` (v1)
- First/last seen: 2026-09-13T12:00:02Z / 2026-09-13T12:00:02Z
- Producer levels: WARNING x1
- Assessment: confidence 0.85 (observed); HTTP status 404 observed -\> client error; producer level is WARNING; severity capped at medium; occurrence count (1) does not influence severity
- HTTP: GET /api/orders/\<n\> -> 404
- Grouping: confidence 0.8; grouped by normalized message template; HTTP status 404 and route template are part of the key
- Attribution: unresolved — orders (0.1)

Example `logs/access-combined.log:3` 2026-09-13T12:00:02Z warning:

```
GET /api/orders/43 -> 404
```

### LT-4e9e698c369a — info operational (x1)

- Template: `Starting Acme.Orders`
- Fingerprint: `4e9e698c369a55e1195ef4b83c5d05cc92487611a22b5a13e78a170d0b06c361` (v1)
- First/last seen: 2026-09-13T10:00:00.123Z / 2026-09-13T10:00:00.123Z
- Producer levels: INF x1
- Assessment: confidence 0.6 (inferred); message evidence 'starting' -\> operational; occurrence count (1) does not influence severity
- Grouping: confidence 0.7; grouped by normalized message template
- Attribution: unresolved — orders (0.1)

Example `logs/serilog-text.log:1` 2026-09-13T10:00:00.123Z INF:

```
Starting Acme.Orders
```

### LT-abe4e469a8d3 — info operational (x1)

- Template: `starting`
- Fingerprint: `abe4e469a8d3cf81fe0499f5711c0bf2e465ee4264090397228fb033ededec25` (v1)
- First/last seen: 2026-09-13T10:00:00.123Z / 2026-09-13T10:00:00.123Z
- Producer levels: INFO x1
- Assessment: confidence 0.6 (inferred); message evidence 'starting' -\> operational; occurrence count (1) does not influence severity
- Grouping: confidence 0.7; grouped by normalized message template
- Attribution: unresolved

Example `logs/zap-console.log:1` 2026-09-13T10:00:00.123Z INFO:

```
starting
```

### LT-f045f3c4e056 — info operational (x1)

- Template: `Started App in <dur>`
- Fingerprint: `f045f3c4e05600b93faa1b4ca27631bc059a7403ec9c24c38ac96ed39eeda56a` (v1)
- First/last seen: 2026-09-13T10:00:00.123Z / 2026-09-13T10:00:00.123Z
- Producer levels: INFO x1
- Assessment: confidence 0.6 (inferred); message evidence 'started' -\> operational; occurrence count (1) does not influence severity
- Grouping: confidence 0.8; grouped by normalized message template
- Attribution: unresolved

Example `logs/spring-boot.log:1` 2026-09-13T10:00:00.123Z INFO:

```
Started App in 2.5 seconds
```

### LT-04097dbdd0ef — info operational (x1)

- Template: `worker started`
- Fingerprint: `04097dbdd0effc6a306e698096413fd50e7f22e9555b3752c5cf4aa2877b3650` (v1)
- First/last seen: 2026-09-13T12:00:00.123Z / 2026-09-13T12:00:00.123Z
- Producer levels: INFO x1
- Assessment: confidence 0.6 (inferred); message evidence 'started' -\> operational; occurrence count (1) does not influence severity
- Grouping: confidence 0.7; grouped by normalized message template
- Attribution: unresolved — billing (0.3)

Example `logs/python-asctime.log:1` 2026-09-13T12:00:00.123Z INFO:

```
worker started
```

### LT-d46742b9402c — info unknown (x1)

- Template: `GET /health -> <n>`
- Fingerprint: `d46742b9402c993db9b68905e5242ef9d5375979552a85b29dcf4e3b409b251d` (v1)
- First/last seen: 2026-09-13T12:00:01Z / 2026-09-13T12:00:01Z
- Producer levels: INFO x1
- Assessment: confidence 0.35 (unknown); no failure evidence in message or level; severity from producer level only (INFO); occurrence count (1) does not influence severity
- HTTP: GET /health -> 200
- Grouping: confidence 0.8; grouped by normalized message template; HTTP status 200 and route template are part of the key
- Attribution: unresolved

Example `logs/access-combined.log:2` 2026-09-13T12:00:01Z info:

```
GET /health -> 200
```

### LT-2791132b6e6e — info unknown (x1)

- Template: `time-only serilog console line`
- Fingerprint: `2791132b6e6ead9f773fffa6ead547d2b3a25ec6bdac8696d556731b2b51d813` (v1)
- First/last seen: unknown / unknown; 1 without timestamp
- Producer levels: INF x1
- Assessment: confidence 0.35 (unknown); no failure evidence in message or level; severity from producer level only (INFO); occurrence count (1) does not influence severity
- Grouping: confidence 0.7; grouped by normalized message template
- Attribution: unresolved

Example `logs/serilog-text.log:16` no timestamp INF:

```
time-only serilog console line
```


## 6. Coverage and limitations

| Input | Status | Format (confidence) | Layout / dialect | Events | Lines | Failures | Note |
|---|---|---|---|---:|---:|---:|---|
| `logs/access-combined.log` | processed | access-log (0.95) | apache-nginx-access+nginx-error+apache-error | 4 | 4 | 0 |  |
| `logs/grouping-equivalence.log` | processed | text (0.6) | headerless-fallback | 33 | 33 | 0 |  |
| `logs/python-asctime.log` | processed | text (0.883) | python-asctime | 3 | 22 | 0 |  |
| `logs/serilog-text.log` | processed | text (0.894) | serilog-text | 5 | 16 | 0 |  |
| `logs/spring-boot.log` | processed | text (0.838) | spring-boot | 2 | 4 | 0 |  |
| `logs/zap-console.log` | processed | text (0.9) | zap-console | 2 | 2 | 0 |  |

Diagnostics: 0 total (0 retained). Counts by code: {}

Filters: --since not set (0 events filtered, 0 untimed excluded); --min-severity info (0 groups / 0 events hidden). Redaction enabled ({}). 0 invalid byte sequences replaced, 0 oversized lines truncated, 0 parse failures.

Repositories:

| Repository | Kind | HEAD | Branch | Working tree | Files indexed |
|---|---|---|---|---|---:|
| billing | repository | `7ae7b2e8156a` | master | clean | 4 |
| orders | repository | `7ab99b3bd21d` | master | clean | 2 |

Attribution: 18 attempted, 3 resolved, 0 ambiguous, 15 unresolved. Investigation: 3 attempted, 3 with a verified source reference, 0 generic, 0 not investigated (limit).

Source-version uncertainty: references were verified against the checkouts above; the revision that produced the logs may differ.

Complete machine-readable results: `analysis.json` (authoritative), `analysis.sarif`, `groups.ndjson`, `groups.csv`.
