"""Entry point: ``python3 scripts/log-triage <args>``.

Running a directory executes its ``__main__.py`` with that directory on
``sys.path``, so the ``log_triage`` package next to this file is importable.
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from log_triage.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
