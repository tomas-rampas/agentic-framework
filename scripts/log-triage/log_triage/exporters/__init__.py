"""Exporter registry. Every exporter consumes the same Analysis (meta + ordered group stream)."""
from __future__ import annotations

from typing import Dict, Type

from .base import Exporter


def registry() -> Dict[str, Type[Exporter]]:
    from .json_exporter import JsonExporter
    from .ndjson_exporter import NdjsonExporter
    from .csv_exporter import CsvExporter
    from .sarif_exporter import SarifExporter
    from .html_exporter import HtmlExporter
    from .markdown_exporter import MarkdownExporter
    return {
        "json": JsonExporter, "ndjson": NdjsonExporter, "csv": CsvExporter, "sarif": SarifExporter,
        "html": HtmlExporter, "markdown": MarkdownExporter,
    }
