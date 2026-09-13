# Sample outputs

One run of the engine over six fixtures, in all six formats, with repository attribution:

* inputs: copies of `tests/log-triage/fixtures/{dotnet/serilog-text.log, python/python-asctime.log,
  web/access-combined.log, jvm/spring-boot.log, go/zap-console.log, edge/grouping-equivalence.log}` placed in a
  `logs/` directory;
* repositories: two throwaway Git repositories under `repos/` — `orders` (`src/Acme.Orders/OrderService.cs` with
  `Place` at line 42, a `.csproj` with `RootNamespace` `Acme.Orders`) and `billing` (`billing/worker.py` with `run`
  at line 30, `billing/charge.py` with `charge` at line 12) — so that the .NET and Python stack traces in the
  fixtures resolve to verified source references;
* command (run from the directory holding `logs/` and `repos/`):

```
python3 <repo>/scripts/log-triage logs --repos-dir repos --format json,sarif,html,markdown,csv,ndjson \
    --out <repo>/docs/log-triage/samples --now 2026-09-14T00:00:00Z --redaction-salt sample --quiet
```

Absolute paths inside the outputs (`inputs.files[].real_path`, repository paths, SARIF artifact URIs) are those of
the machine that produced them. The files are illustrative; the authoritative behaviour is defined by the tests.
