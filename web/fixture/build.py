#!/usr/bin/env python3
"""Build web/fixture/evidence.jsonl from the published 0.2.3 evidence.

The 0.2.3 evidence lives in bench/evidence-023.jsonl, produced by
bench/produce-evidence-023.py from the sanitised rows in bench/rows-0.2.3/.
This script copies it into the fixture store and validates it. Run from the
repository root:

    python3 web/fixture/build.py
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SOURCE = REPO / "bench" / "evidence-023.jsonl"
OUT = HERE / "evidence.jsonl"


def main() -> int:
    sys.path.insert(0, str(HERE))
    from validate import load_evidence, validate_benchmark_records

    records = load_evidence(SOURCE)
    if not records:
        print(f"no records in {SOURCE}", file=sys.stderr)
        return 1
    run_ids = {record["run_id"] for record in records if isinstance(record.get("run_id"), str)}
    errors = validate_benchmark_records(records, run_ids)
    if errors:
        for message in errors:
            print(f"invalid evidence record: {message}", file=sys.stderr)
        return 1
    shutil.copyfile(SOURCE, OUT)
    repeats = sum(1 for r in records if (r.get("payload") or {}).get("schema") == "kalari.repeat.v1")
    print(f"wrote {len(records)} records ({repeats} repeats) to {OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
