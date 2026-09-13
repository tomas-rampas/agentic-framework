"""log-triage: deterministic, bounded-memory log triage engine (stdlib only).

Versioning:
  TOOL_VERSION        - version of this implementation.
  SCHEMA_VERSION      - version of the JSON analysis document (docs/log-triage/schema).
  FINGERPRINT_VERSION - version of the grouping fingerprint algorithm. Any change to
                        message templating, frame normalization, or the fingerprint
                        components bumps this value; group ids are only comparable
                        between runs that share it.
"""

TOOL_NAME = "log-triage"
TOOL_VERSION = "1.0.0"
SCHEMA_VERSION = "1.0.0"
FINGERPRINT_VERSION = "1"
INFORMATION_URI = "https://github.com/tomas-rampas/agentic-framework/blob/main/docs/log-triage/README.md"

MIN_PYTHON = (3, 8)
