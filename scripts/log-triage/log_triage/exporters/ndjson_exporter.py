"""Streamable issue-group export: one group per line plus a companion metadata document."""
from __future__ import annotations

import json
import os
from typing import List

from ..config import OUTPUT_FILENAMES
from .base import AtomicFile, Exporter, meta_for_output


class NdjsonExporter(Exporter):
    name = "ndjson"
    filenames = [OUTPUT_FILENAMES["ndjson"], OUTPUT_FILENAMES["ndjson_meta"]]

    def write(self, analysis, out_dir: str) -> List[str]:
        groups_path = os.path.join(out_dir, self.filenames[0])
        meta_path = os.path.join(out_dir, self.filenames[1])
        n = 0
        with AtomicFile(groups_path) as fh:
            for g in analysis.groups():
                fh.write(json.dumps(g, ensure_ascii=False, sort_keys=True, default=str))
                fh.write("\n")
                n += 1
        meta = meta_for_output(analysis.meta)
        meta = dict(meta, ndjson={"groups_file": self.filenames[0], "groups_written": n, "record_kind": "issue-group",
                                  "note": "one JSON object per line; the same group objects as analysis.json"})
        with AtomicFile(meta_path) as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=1, sort_keys=True, default=str)
            fh.write("\n")
        return [groups_path, meta_path]
