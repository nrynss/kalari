#!/usr/bin/env python3
"""Produce frozen benchmark evidence records for the live demo.

Reads the 60 frozen rows (bench/runs/kalari/*.json and
bench/runs/reference/*.json) and emits one ``benchmark`` evidence record
per row in the web/README.md contract (kalari.benchmark.v1). Run from the
repository root:

    python3 bench/produce-evidence.py [OUT]

Defaults to bench/frozen-evidence.jsonl. Stdlib only. No inference, no
network, no key. Unknown stays null: a measure the source row does not
hold (Kalari rows have no per-endpoint sandbox split, no first-v2 grade
and no grader runs) is emitted as null, never zero.
"""

from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
KALARI_DIR = REPO / "bench" / "runs" / "kalari"
REFERENCE_DIR = REPO / "bench" / "runs" / "reference"
DEFAULT_OUT = REPO / "bench" / "frozen-evidence.jsonl"

ROW_RE = re.compile(r"^condition-(\d+)-(payouts|settlements)-r(\d+)\.json$")
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")

MEASURE_KEYS = (
    "verdict",
    "right_first_time",
    "sandbox_runs",
    "wall_time_s",
    "time_stuck_s",
    "tokens_input",
    "tokens_output",
    "records_lost",
    "records_duplicated",
)

SOURCE_KEYS = (
    "session_continued",
    "notes_attached",
    "session_capped",
    "session_cap_s",
    "sandbox_runs_against_v1",
    "sandbox_runs_against_v2",
    "records_extra",
    "records_mismatched",
    "cost_usd",
    "opencode_exit",
    "process_elapsed_s",
    "right_first_time_basis",
)


def load_row(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: row is not a JSON object")
    return data


def is_finite_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def build_record(path: Path, data: dict) -> dict:
    match = ROW_RE.match(path.name)
    if not match:
        raise ValueError(f"{path}: name does not encode a frozen row")
    condition = int(match.group(1))
    upgrade = match.group(2)
    repeat = int(match.group(3))
    if data.get("condition") != condition:
        raise ValueError(f"{path}: condition does not match the file name")
    if data.get("upgrade") != upgrade:
        raise ValueError(f"{path}: upgrade does not match the file name")
    arm = data.get("arm")
    if arm not in ("kalari", "reference"):
        raise ValueError(f"{path}: arm is not kalari or reference")

    measures = data.get("measures")
    if not isinstance(measures, dict):
        raise ValueError(f"{path}: no measures object")

    session_id = f"frozen-c{condition}-{upgrade}"
    run_id = f"frozen-c{condition}-{upgrade}-r{repeat}"
    if not ID_RE.match(session_id) or not ID_RE.match(run_id):
        raise ValueError(f"{path}: derived id breaks the id rule")

    payload = {
        "schema": "kalari.benchmark.v1",
        "provenance": "frozen",
        "status": "valid",
        "arm": arm,
        "model": "DeepSeek V4.1 Flash",
        "model_id": "deepseek-v4.1-flash-1017",
        "condition": condition,
        "upgrade": upgrade,
        "repeat": repeat,
        "behaviour": None,
        "session_id": session_id,
    }
    for key in SOURCE_KEYS:
        payload[key] = data.get(key)
    for key in MEASURE_KEYS:
        payload[key] = measures.get(key)
    payload["grade"] = copy.deepcopy(data.get("grade"))
    payload["first_v2_grade"] = copy.deepcopy(data.get("first_v2_grade"))
    payload["grader_runs"] = copy.deepcopy(data.get("grader_runs"))
    source = str(path.relative_to(REPO))
    payload["source"] = source
    transcript = source[:-5] + ".transcript.jsonl" if source.endswith(".json") else None
    if transcript is not None and not (REPO / transcript).is_file():
        transcript = None
    payload["transcript"] = transcript
    payload["notes"] = "Frozen comparison run."

    return {
        "kind": "benchmark",
        "session_id": session_id,
        "run_id": run_id,
        "change_kinds": ["pagination_changed"],
        "payload": payload,
    }


def collect_rows() -> list[tuple[Path, dict]]:
    rows: list[tuple[Path, dict]] = []
    for directory in (KALARI_DIR, REFERENCE_DIR):
        for path in sorted(directory.glob("condition-*.json")):
            rows.append((path, load_row(path)))
    return rows


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    rows = collect_rows()
    records = [build_record(path, data) for path, data in rows]
    run_ids = [record["run_id"] for record in records]
    if len(records) != 60:
        print(f"expected 60 frozen rows, found {len(records)}", file=sys.stderr)
        return 1
    if len(set(run_ids)) != len(run_ids):
        print("duplicate run_id in produced records", file=sys.stderr)
        return 1
    text_lines = []
    for record in records:
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
        json.loads(line)  # must round-trip
        text_lines.append(line + "\n")
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8", newline="\n") as handle:
        handle.writelines(text_lines)
    kalari = sum(1 for record in records if record["payload"]["arm"] == "kalari")
    reference = len(records) - kalari
    try:
        shown = str(out.relative_to(REPO))
    except ValueError:
        shown = str(out)
    print(f"wrote {len(records)} frozen benchmark records to {shown}")
    print(f"kalari rows: {kalari}, reference rows: {reference}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
