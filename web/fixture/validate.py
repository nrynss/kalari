#!/usr/bin/env python3
"""Validate benchmark records against the kalari.benchmark.v1 contract.

    python3 web/fixture/validate.py

The check imports the same functions. The producer must use them before it
writes a record. The envelope session_id is authoritative. The payload
session_id must equal it. A source is a repo-relative path to a file that
exists. A run_id is unique across benchmark records.
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
EVIDENCE = Path(__file__).resolve().parent / "evidence.jsonl"

PROVENANCE = {"pilot", "frozen"}
STATUS = {"valid", "invalid", "diagnostic"}
ARMS = {"reference", "kalari"}
UPGRADES = {"payouts", "settlements"}
BEHAVIOURS = {"B1", "B2", "B3", "B4", "B5"}
VERDICTS = {"PASS", "FAIL"}
CONDITION_ARMS = {1: "reference", 2: "reference", 3: "reference", 4: "kalari", 5: "kalari", 6: "reference"}
GRADE_FIELDS = (
    "verdict",
    "output_present",
    "records",
    "unique",
    "expected",
    "missing",
    "extra",
    "duplicates",
    "mismatched",
    "unreadable_lines",
    "note",
)


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_count(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def is_bool_or_null(value: Any) -> bool:
    return value is None or isinstance(value, bool)


def source_is_valid(source: Any) -> tuple[bool, str]:
    if not isinstance(source, str) or not source.strip():
        return False, "source is empty"
    path = Path(source)
    if path.is_absolute():
        return False, "source is absolute"
    if ".." in path.parts:
        return False, "source leaves the repository"
    candidate = (REPO / path).resolve()
    root = REPO.resolve()
    if root not in candidate.parents and candidate != root:
        return False, "source leaves the repository"
    if not candidate.is_file():
        return False, "source file does not exist"
    return True, ""


def grade_errors(grade: Any) -> list[str]:
    if grade is None:
        return []
    if not isinstance(grade, dict):
        return ["grade is not an object or null"]
    errors = []
    verdict = grade.get("verdict")
    if verdict is not None and verdict not in VERDICTS:
        errors.append("grade.verdict is not PASS or FAIL")
    for key in ("records", "unique", "expected", "missing", "extra", "duplicates", "mismatched", "unreadable_lines"):
        value = grade.get(key)
        if value is not None and not is_count(value):
            errors.append(f"grade.{key} is not a count or null")
    note = grade.get("note")
    if note is not None and not isinstance(note, str):
        errors.append("grade.note is not a string or null")
    return errors


def validate_benchmark_record(record: dict[str, Any], run_ids: set[str]) -> list[str]:
    errors: list[str] = []
    run_id = record.get("run_id")
    if not isinstance(run_id, str) or not run_id:
        errors.append("run_id is empty")
    elif run_id not in run_ids:
        errors.append("run_id is not in the run index")

    payload = record.get("payload")
    if not isinstance(payload, dict):
        return errors + ["payload is not an object"]

    if payload.get("schema") != "kalari.benchmark.v1":
        errors.append("schema is not kalari.benchmark.v1")
    if payload.get("provenance") not in PROVENANCE:
        errors.append("provenance is not pilot or frozen")
    if payload.get("status") not in STATUS:
        errors.append("status is not valid, invalid or diagnostic")
    if payload.get("arm") not in ARMS:
        errors.append("arm is not reference or kalari")
    if payload.get("upgrade") not in UPGRADES:
        errors.append("upgrade is not payouts or settlements")

    condition = payload.get("condition")
    if not is_count(condition) or not 1 <= condition <= 6:
        errors.append("condition is not 1 to 6")
    else:
        expected_arm = CONDITION_ARMS[condition]
        if payload.get("arm") != expected_arm:
            errors.append(f"condition {condition} needs arm {expected_arm}")

    repeat = payload.get("repeat")
    if not is_count(repeat) or not 1 <= repeat <= 5:
        errors.append("repeat is not 1 to 5")

    behaviour = payload.get("behaviour")
    if behaviour is not None and behaviour not in BEHAVIOURS:
        errors.append("behaviour is not B1 to B5 or null")
    if payload.get("status") == "diagnostic" and behaviour is None:
        errors.append("a diagnostic row needs a behaviour")
    if payload.get("status") != "diagnostic" and behaviour is not None:
        errors.append("a non-diagnostic row must have behaviour null")

    envelope_session = record.get("session_id")
    if not isinstance(envelope_session, str) or not envelope_session:
        errors.append("envelope session_id is empty")
    if payload.get("session_id") != envelope_session:
        errors.append("payload session_id does not equal the envelope session_id")

    for key in ("session_continued", "notes_attached", "session_capped"):
        if not is_bool_or_null(payload.get(key)):
            errors.append(f"{key} is not a boolean or null")

    cap = payload.get("session_cap_s")
    if cap is not None and (not is_number(cap) or cap < 0):
        errors.append("session_cap_s is not a non-negative number or null")
    if payload.get("session_capped") is True and not is_number(cap):
        errors.append("a capped session needs session_cap_s")

    if payload.get("verdict") not in VERDICTS:
        errors.append("verdict is not PASS or FAIL")
    if not is_bool_or_null(payload.get("right_first_time")):
        errors.append("right_first_time is not a boolean or null")
    if not isinstance(payload.get("right_first_time_basis"), str):
        errors.append("right_first_time_basis is not a string")

    for key in ("sandbox_runs", "sandbox_runs_against_v1", "sandbox_runs_against_v2"):
        value = payload.get(key)
        if value is not None and not is_count(value):
            errors.append(f"{key} is not a count or null")
    sandbox = payload.get("sandbox_runs")
    against = (payload.get("sandbox_runs_against_v1"), payload.get("sandbox_runs_against_v2"))
    if is_count(sandbox) and all(is_count(value) for value in against):
        if sandbox != against[0] + against[1]:
            errors.append("sandbox_runs is not the sum of the against counts")

    for key in ("wall_time_s", "time_stuck_s", "cost_usd", "process_elapsed_s"):
        value = payload.get(key)
        if value is not None and (not is_number(value) or value < 0):
            errors.append(f"{key} is not a non-negative number or null")
    for key in ("tokens_input", "tokens_output", "records_lost", "records_duplicated", "records_extra", "records_mismatched"):
        value = payload.get(key)
        if value is not None and not is_count(value):
            errors.append(f"{key} is not a count or null")

    grade = payload.get("grade")
    errors.extend(grade_errors(grade))
    if isinstance(grade, dict) and grade.get("verdict") is not None:
        if grade.get("verdict") != payload.get("verdict"):
            errors.append("grade.verdict does not equal verdict")
    if isinstance(grade, dict):
        for payload_key, grade_key in (("records_lost", "missing"), ("records_duplicated", "duplicates")):
            left = payload.get(payload_key)
            right = grade.get(grade_key)
            if left is not None and right is not None and left != right:
                errors.append(f"{payload_key} does not equal grade.{grade_key}")

    if payload.get("first_v2_grade") is not None and not isinstance(payload.get("first_v2_grade"), dict):
        errors.append("first_v2_grade is not an object or null")
    if payload.get("grader_runs") is not None and not isinstance(payload.get("grader_runs"), dict):
        errors.append("grader_runs is not an object or null")
    if payload.get("opencode_exit") is not None and not is_count(payload.get("opencode_exit")):
        errors.append("opencode_exit is not a count or null")
    if not isinstance(payload.get("notes"), str):
        errors.append("notes is not a string")

    ok, message = source_is_valid(payload.get("source"))
    if not ok:
        errors.append(message)

    return errors


def validate_benchmark_records(records: list[dict[str, Any]], run_ids: set[str]) -> list[str]:
    benchmark = [record for record in records if record.get("kind") == "benchmark"]
    errors: list[str] = []
    counts = Counter(record.get("run_id") for record in benchmark)
    for run_id, count in counts.items():
        if count > 1:
            errors.append(f"duplicate benchmark run_id: {run_id}")
    for record in benchmark:
        run_id = record.get("run_id") or "unknown"
        for message in validate_benchmark_record(record, run_ids):
            errors.append(f"{run_id}: {message}")
    return errors


def load_evidence(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    if not path.is_file():
        return records
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            records.append(value)
    return records


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else EVIDENCE
    records = load_evidence(path)
    run_ids = {record["run_id"] for record in records if isinstance(record.get("run_id"), str)}
    errors = validate_benchmark_records(records, run_ids)
    if errors:
        for message in errors:
            print(f"invalid benchmark record: {message}", file=sys.stderr)
        return 1
    print(f"{sum(1 for record in records if record.get('kind') == 'benchmark')} benchmark records valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
