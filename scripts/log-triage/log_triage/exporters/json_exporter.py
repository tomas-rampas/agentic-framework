"""Authoritative JSON analysis document (schema: docs/log-triage/schema/analysis.schema.json)."""
from __future__ import annotations

import json
import os
from typing import List

from ..config import OUTPUT_FILENAMES
from .base import AtomicFile, Exporter, meta_for_output


class JsonExporter(Exporter):
    name = "json"
    filenames = [OUTPUT_FILENAMES["json"]]

    def write(self, analysis, out_dir: str) -> List[str]:
        path = os.path.join(out_dir, self.filenames[0])
        meta = meta_for_output(analysis.meta)
        head = json.dumps(meta, ensure_ascii=False, indent=1, sort_keys=True, default=str)
        assert head.endswith("\n}")
        with AtomicFile(path) as fh:
            fh.write(head[:-2])
            fh.write(',\n "groups": [')
            first = True
            for g in analysis.groups():
                fh.write("\n  " if first else ",\n  ")
                fh.write(json.dumps(g, ensure_ascii=False, sort_keys=True, default=str))
                first = False
            fh.write("\n ]\n}\n")
        return [path]
