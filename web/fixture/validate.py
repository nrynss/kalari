#!/usr/bin/env python3
"""Validate evidence records against the kalari.benchmark.v1 contract.

    python3 web/fixture/validate.py

The check imports the same functions. The producer must use them before it
writes a record. The envelope session_id is authoritative. The payload
session_id must equal it. A source is a repo-relative path to a file that
exists, and the payload measures must match that file. A run_id is unique
across benchmark records. A run or session id uses only A-Z, a-z, 0-9, dot,
underscore and hyphen. The API routes use the same rule.
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
EVIDENCE = Path(__file__).resolve().parent / "evidence.jsonl"

ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
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
GRADE_COUNT_FIELDS = (
    "records",
    "unique",
    "expected",
    "missing",
    "extra",
    "duplicates",
    "mismatched",
    "unreadable_lines",
)
MEASURE_FIELDS = (
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
SOURCE_FIELDS = (
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


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_count(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def is_bool_or_null(value: Any) -> bool:
    return value is None or isinstance(value, bool)


def id_errors(value: Any, label: str) -> list[str]:
    if not isinstance(value, str) or not value:
        return [f"{label} is empty"]
    if not ID_RE.match(value):
        return [f"{label} may use only A-Z, a-z, 0-9, dot, underscore and hyphen: {value!r}"]
    return []


def envelope_errors(record: Any) -> list[str]:
    """Check the envelope every evidence record carries."""
    if not isinstance(record, dict):
        return ["an evidence record is not an object"]
    errors: list[str] = []
    kind = record.get("kind")
    if not isinstance(kind, str) or not kind:
        errors.append("kind is empty")
    errors.extend(id_errors(record.get("session_id"), "session_id"))
    errors.extend(id_errors(record.get("run_id"), "run_id"))
    change_kinds = record.get("change_kinds")
    if not isinstance(change_kinds, list):
        errors.append("change_kinds is not an array")
    else:
        for item in change_kinds:
            if not isinstance(item, str) or not item:
                errors.append("change_kinds holds a value that is not a non-empty string")
                break
    if not isinstance(record.get("payload"), dict):
        errors.append("payload is not an object")
    return errors


def looks_like_benchmark(record: Any) -> bool:
    if not isinstance(record, dict):
        return False
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return False
    if payload.get("schema") == "kalari.benchmark.v1":
        return True
    return "condition" in payload and "upgrade" in payload


def source_path(source: Any) -> tuple[Path | None, str]:
    if not isinstance(source, str) or not source.strip():
        return None, "source is empty"
    path = Path(source)
    if path.is_absolute():
        return None, "source is absolute"
    if ".." in path.parts:
        return None, "source leaves the repository"
    candidate = (REPO / path).resolve()
    root = REPO.resolve()
    if root not in candidate.parents and candidate != root:
        return None, "source leaves the repository"
    if not candidate.is_file():
        return None, "source file does not exist"
    return candidate, ""


def source_errors(payload: dict[str, Any]) -> list[str]:
    """The named source file must agree with the payload it produced."""
    path, message = source_path(payload.get("source"))
    if path is None:
        return [message]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return ["source is not readable JSON"]
    if not isinstance(data, dict):
        return ["source is not a JSON object"]

    errors: list[str] = []
    for key in ("condition", "upgrade", "arm"):
        if payload.get(key) != data.get(key):
            errors.append(f"{key} does not match the source")
    measures = data.get("measures")
    if not isinstance(measures, dict):
        return errors + ["source has no measures object"]
    for key in MEASURE_FIELDS:
        if payload.get(key) != measures.get(key):
            errors.append(f"{key} does not match the source measure")
    for key in SOURCE_FIELDS:
        if payload.get(key) != data.get(key):
            errors.append(f"{key} does not match the source")
    for key in ("grade", "first_v2_grade", "grader_runs"):
        if payload.get(key) != data.get(key):
            errors.append(f"{key} does not match the source")
    return errors


def grade_errors(grade: Any, label: str = "grade") -> list[str]:
    if grade is None:
        return []
    if not isinstance(grade, dict):
        return [f"{label} is not an object or null"]
    errors = []
    verdict = grade.get("verdict")
    if verdict is not None and verdict not in VERDICTS:
        errors.append(f"{label}.verdict is not PASS or FAIL")
    if not is_bool_or_null(grade.get("output_present")):
        errors.append(f"{label}.output_present is not a boolean or null")
    for key in GRADE_COUNT_FIELDS:
        value = grade.get(key)
        if value is not None and not is_count(value):
            errors.append(f"{label}.{key} is not a count or null")
    note = grade.get("note")
    if note is not None and not isinstance(note, str):
        errors.append(f"{label}.note is not a string or null")
    return errors


def grader_runs_errors(grader_runs: Any) -> list[str]:
    if grader_runs is None:
        return []
    if not isinstance(grader_runs, dict):
        return ["grader_runs is not an object or null"]
    errors = []
    for stage, value in grader_runs.items():
        if not isinstance(stage, str) or not stage:
            errors.append("grader_runs has a stage name that is not a non-empty string")
            continue
        if not isinstance(value, dict):
            errors.append(f"grader_runs.{stage} is not an object")
            continue
        if not isinstance(value.get("status"), str):
            errors.append(f"grader_runs.{stage}.status is not a string")
        if not isinstance(value.get("log_excerpt"), str):
            errors.append(f"grader_runs.{stage}.log_excerpt is not a string")
    return errors


def validate_benchmark_record(record: dict[str, Any], run_ids: set[str]) -> list[str]:
    """Validate one benchmark payload. The caller checks the envelope once."""
    errors: list[str] = []
    if record.get("kind") != "benchmark":
        errors.append("kind is not benchmark")

    run_id = record.get("run_id")
    if isinstance(run_id, str) and run_id and run_id not in run_ids:
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
    if payload.get("provenance") == "frozen" and payload.get("status") != "valid":
        errors.append("a frozen record must be a valid comparison record")
    if payload.get("status") == "diagnostic" and payload.get("provenance") != "pilot":
        errors.append("a diagnostic row must be a pilot row")
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

    errors.extend(grade_errors(payload.get("first_v2_grade"), "first_v2_grade"))
    errors.extend(grader_runs_errors(payload.get("grader_runs")))
    if payload.get("opencode_exit") is not None and not is_count(payload.get("opencode_exit")):
        errors.append("opencode_exit is not a count or null")
    if not isinstance(payload.get("notes"), str):
        errors.append("notes is not a string")

    errors.extend(source_errors(payload))

    return errors


def validate_benchmark_records(records: list[dict[str, Any]], run_ids: set[str]) -> list[str]:
    """Validate the envelope of every record and the payload of every benchmark."""
    errors: list[str] = []
    benchmark: list[dict[str, Any]] = []
    for record in records:
        label = record.get("run_id") if isinstance(record, dict) else None
        prefix = f"{label}: " if isinstance(label, str) and label else ""
        if not isinstance(record, dict):
            errors.append("an evidence record is not an object")
            continue
        if looks_like_benchmark(record) and record.get("kind") != "benchmark":
            errors.append(f"{prefix}a benchmark-shaped record has kind {record.get('kind')!r}")
        for message in envelope_errors(record):
            errors.append(f"{prefix}{message}")
        if record.get("kind") == "benchmark":
            benchmark.append(record)
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
            print(f"invalid evidence record: {message}", file=sys.stderr)
        return 1
    print(f"{sum(1 for record in records if record.get('kind') == 'benchmark')} benchmark records valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
