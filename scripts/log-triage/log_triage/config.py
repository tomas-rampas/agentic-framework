"""Effective configuration: resource limits and report-detail limits.

Precedence (lowest to highest): built-in defaults < ``--config <file.json>``
< ``--limit KEY=VALUE`` / first-class CLI flags. Every key is documented in
docs/log-triage/README.md ("Configuration"). Unknown keys are rejected so a
typo cannot silently leave a limit at its default.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field, fields
from typing import Any, Dict, List, Optional

SEVERITIES = ("info", "low", "medium", "high", "critical")
SEVERITY_RANK = {name: i for i, name in enumerate(SEVERITIES)}

CATEGORIES = (
    "availability",
    "application_crash",
    "dependency_failure",
    "timeout",
    "auth",
    "configuration",
    "resource_exhaustion",
    "data_integrity",
    "network",
    "security",
    "performance",
    "client_error",
    "operational",
    "unknown",
)

REPORT_FORMATS = ("json", "sarif", "html", "markdown", "csv", "ndjson")
AUTO_FORMATS = ("json", "sarif", "html", "markdown")

OUTPUT_FILENAMES = {
    "json": "analysis.json",
    "sarif": "analysis.sarif",
    "html": "report.html",
    "markdown": "report.md",
    "csv": "groups.csv",
    "ndjson": "groups.ndjson",
    "ndjson_meta": "groups.meta.json",
}


@dataclass
class Limits:
    """All bounded resources. Units are bytes unless the name says otherwise."""

    # --- ingestion --------------------------------------------------------
    max_line_bytes: int = 1_048_576          # physical line; longer lines are truncated (counted)
    max_record_bytes: int = 1_048_576        # logical (multiline) record retained text
    max_multiline_lines: int = 500           # continuation lines folded into one event
    max_decompressed_bytes: int = 17_179_869_184  # 16 GiB per compressed input
    max_compression_ratio: int = 2000        # decompressed/compressed guard (bomb detection)
    max_files: int = 10_000                  # inputs after glob/directory expansion
    detect_sample_bytes: int = 65_536        # bounded sample for format detection
    detect_sample_lines: int = 256
    read_chunk_bytes: int = 1_048_576
    # --- canonical model bounds -----------------------------------------
    max_message_chars: int = 2_000           # retained message text per event/example
    max_exception_chars: int = 4_000         # retained exception/stack text per example
    max_attributes_per_event: int = 64
    max_attribute_value_chars: int = 512
    max_frames: int = 50
    # --- aggregation ------------------------------------------------------
    max_groups_in_memory: int = 20_000       # spill threshold (groups kept in RAM before SQLite flush)
    max_examples_per_group: int = 3
    max_correlation_ids_per_group: int = 5
    max_levels_per_group: int = 8
    max_services_per_group: int = 10
    max_inputs_per_group: int = 20
    fingerprint_cache_size: int = 20_000     # exact-message memo (speeds up repetitive logs)
    # --- timeline / diagnostics -------------------------------------------
    max_timeline_buckets: int = 200
    max_diagnostics: int = 1_000             # retained diagnostic records (counts are always exact)
    # --- reports ------------------------------------------------------------
    max_report_groups: int = 500             # groups rendered in detail in HTML/Markdown
    max_findings_rows: int = 500             # rows in the prioritized findings tables
    max_output_groups: int = 100_000         # groups written to JSON/SARIF/CSV/NDJSON (canonical order; omission disclosed)
    max_report_example_chars: int = 1_200
    # --- repositories ---------------------------------------------------------
    max_repos: int = 200
    max_repo_depth: int = 6                  # directory depth under --repos-dir
    max_repo_dirs_visited: int = 50_000
    max_repo_files_indexed: int = 50_000     # per repository
    max_repo_file_bytes: int = 524_288       # source files larger than this are not scanned
    max_attributed_groups: int = 200         # top groups that receive repository attribution
    max_investigations: int = 50             # top groups that receive deterministic source investigation
    max_snippet_lines: int = 12
    max_literal_search_files: int = 5_000    # files scanned per message-literal search
    max_literal_search_hits: int = 5
    # --- model assistance -----------------------------------------------------
    max_model_queue_groups: int = 20         # groups placed in investigation_queue for the model
    max_model_context_chars: int = 2_000     # per-group compact context handed to the model

    def as_dict(self) -> Dict[str, int]:
        return {f.name: getattr(self, f.name) for f in fields(self)}

    @classmethod
    def keys(cls) -> List[str]:
        return [f.name for f in fields(cls)]

    def apply(self, updates: Dict[str, Any], source: str) -> None:
        known = set(self.keys())
        for key, value in updates.items():
            if key not in known:
                raise ValueError(
                    "unknown limit %r in %s (known: %s)" % (key, source, ", ".join(sorted(known)))
                )
            try:
                ivalue = int(value)
            except (TypeError, ValueError):
                raise ValueError("limit %r in %s must be an integer, got %r" % (key, source, value))
            if ivalue < 0:
                raise ValueError("limit %r in %s must be >= 0" % (key, source))
            setattr(self, key, ivalue)


@dataclass
class Options:
    """Effective run options (everything that is not a numeric limit)."""

    inputs: List[str] = field(default_factory=list)
    repo: Optional[str] = None
    repos_dir: Optional[str] = None
    formats: List[str] = field(default_factory=lambda: list(AUTO_FORMATS))
    formats_explicit: bool = False
    out_dir: str = "log-triage-out"
    since: Optional[str] = None
    since_epoch: Optional[float] = None
    min_severity: str = "info"
    input_format: Optional[str] = None
    fallback_format: str = "text"
    assume_tz: str = "UTC"
    assume_tz_offset_seconds: int = 0
    keep_untimed: bool = False
    redact: bool = True
    redact_ips: bool = False
    redaction_salt: Optional[str] = None
    temp_dir: Optional[str] = None
    keep_temp: bool = False
    fail_on_severity: Optional[str] = None
    follow_symlinks: bool = False
    include_nested_repos: bool = False
    now_epoch: Optional[float] = None
    render_from: Optional[str] = None
    suggestions_file: Optional[str] = None
    quiet: bool = False
    verbose: bool = False
    limits: Limits = field(default_factory=Limits)

    def public_dict(self) -> Dict[str, Any]:
        """Configuration as recorded in the analysis document."""
        return {
            "inputs": list(self.inputs),
            "repo": self.repo,
            "repos_dir": self.repos_dir,
            "formats": list(self.formats),
            "out_dir": self.out_dir,
            "since": self.since,
            "min_severity": self.min_severity,
            "input_format": self.input_format,
            "fallback_format": self.fallback_format,
            "assume_tz": self.assume_tz,
            "keep_untimed": self.keep_untimed,
            "redact": self.redact,
            "redact_ips": self.redact_ips,
            "redaction_salt_provided": self.redaction_salt is not None,
            "temp_dir": self.temp_dir,
            "keep_temp": self.keep_temp,
            "fail_on_severity": self.fail_on_severity,
            "follow_symlinks": self.follow_symlinks,
            "include_nested_repos": self.include_nested_repos,
            "limits": self.limits.as_dict(),
        }


def load_config_file(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("config file %s must contain a JSON object" % path)
    return data
