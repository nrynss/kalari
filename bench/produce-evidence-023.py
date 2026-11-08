#!/usr/bin/env python3
"""Publish the Kalari 0.2.3 repeat evidence.

Reads the 105 raw session rows (measures.json) from outside the repository,
sanitises them the way the frozen rows were sanitised (no /home path, no IP,
no host name, no instance ID, no key), and writes:

  bench/rows-0.2.3/<project>--<session>.json   one sanitised row per session
  bench/evidence-023.jsonl                     evidence records for the API
  tests/live/containment-0.2.3/                sanitised containment bundle

Run from the repository root:

    python3 bench/produce-evidence-023.py [RAW_DIR]

RAW_DIR defaults to ~/work/demo-shoot/kalari/rows-0.2.3. Stdlib only. No
inference, no network, no key. Unknown stays null: a measure the source row
does not hold is emitted as null, never zero.
"""

from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ROWS_DIR = REPO / "bench" / "rows-0.2.3"
DEFAULT_RAW = Path.home() / "work" / "demo-shoot" / "kalari" / "rows-0.2.3"
OUT = REPO / "bench" / "evidence-023.jsonl"
CONTAINMENT_OUT = REPO / "tests" / "live" / "containment-0.2.3"

ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
PROJECT_RE = re.compile(r"^r([1-5])-(glm|ds|mimo|qwen|muse)-(learn|ref)$")

MODEL_NAMES = {
    "deepseek-v4.1-flash-1017": "DeepSeek V4.1 Flash",
    "glm-5.3-flash": "GLM 5.3 Flash",
    "mimo-v2.6-flash": "MiMo V2.6 Flash",
    "muse-glimmer-30b": "Muse Glimmer 30b",
    "qwen3.8-27b": "Qwen3.8 27B",
}

# Raw row fields that are published. Everything else is dropped: paths
# (/home/...), ports, prompt text, usage deltas, token cross-checks and the
# pricing endpoint URL never leave the raw directory.
ROW_KEYS = (
    "arm",
    "scenario",
    "upgrade",
    "project",
    "model",
    "model_name",
    "setup",
    "session_capped",
    "session_cap_s",
    "cutoff_reason",
    "consumer_exit",
    "output_present",
    "sandbox_runs_against_v2",
    "sandbox_runs_detail",
    "evidence_runs",
    "evidence_first_run_id",
    "evidence_run_verdicts",
    "evidence_run_passed",
    "evidence_run_wall_ms",
    "evidence_run_checks",
    "evidence_request_caps",
    "killed_timeout_runs",
    "http_retries",
    "retry_measure",
    "grade",
    "grader_status",
    "right_first_time_basis",
    "lessons_published",
    "lessons_written",
    "lessons_confirmed",
    "lessons_recalled",
    "lesson_records_in_session",
    "page_observations",
    "recall_required_checks",
    "recall_advice_checks",
    "checks_enforced",
    "records_lost",
    "records_duplicated",
    "records_extra",
    "records_mismatched",
    "cost_usd",
    "opencode_tokens",
    "tool_calls",
    "completed_steps",
    "exit_code",
    "opencode_exit",
    "process_elapsed_s",
    "cleanup",
    "cleanup_error",
    "definition_notes",
)

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

GRADE_KEYS = (
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
)


def sanitise_host(value: object) -> object:
    """Replace anything that names a host with a plain placeholder."""
    if isinstance(value, str):
        if "microsandbox.internal" in value:
            return "the guest API alias"
        if value == "the VM's public address":
            return value
        return value
    if isinstance(value, list):
        return [sanitise_host(item) for item in value]
    if isinstance(value, dict):
        return {key: sanitise_host(item) for key, item in value.items()}
    return value


def clean_grade(grade) -> dict | None:
    if grade is None:
        return None
    if not isinstance(grade, dict):
        raise ValueError("grade is not an object")
    return {key: grade.get(key) for key in GRADE_KEYS if key in grade}


def clean_cleanup(value: object) -> object:
    """Keep the cleanup proof, scrub the runner-internal sandbox names."""
    if isinstance(value, str):
        return value.replace("kfilm:", "agent:")
    if isinstance(value, list):
        return [clean_cleanup(item) for item in value]
    if isinstance(value, dict):
        return {key: clean_cleanup(item) for key, item in value.items()}
    return value


def build_row(session: str, data: dict) -> dict:
    row: dict = {"session": session}
    for key in ROW_KEYS:
        if key in data:
            row[key] = copy.deepcopy(data[key])
    measures = data.get("measures")
    if not isinstance(measures, dict):
        raise ValueError(f"{session}: no measures object")
    row["measures"] = {key: measures.get(key) for key in MEASURE_KEYS}
    # The raw rows carry loss and duplication at the top level, not in
    # measures; the published row keeps them in both places.
    for key in ("records_lost", "records_duplicated"):
        if row["measures"].get(key) is None:
            row["measures"][key] = data.get(key)
    row["grade"] = clean_grade(data.get("grade"))
    model = data.get("model")
    name = data.get("model_name") or MODEL_NAMES.get(model, model)
    row["cost_note"] = (
        f"{name} list price, cached input counted as input, no cache discount"
    )
    row["cleanup"] = clean_cleanup(copy.deepcopy(data.get("cleanup")))
    allowlist = copy.deepcopy(data.get("evidence_request_allowlist"))
    row["evidence_request_allowlist"] = sanitise_host(allowlist)
    # Canonical repeat and headline membership from the project name.
    project = data.get("project", "")
    match = PROJECT_RE.match(project)
    if match and match.group(2) in ("glm", "ds", "mimo"):
        row["repeat"] = int(match.group(1))
        row["headline"] = True
    else:
        row["repeat"] = 1 if project.startswith("r1-") else None
        row["headline"] = False
    row["chain"] = "glm3" if project == "glm3-learn" else None
    if data.get("arm") not in ("kalari", "reference"):
        raise ValueError(f"{session}: arm is not kalari or reference")
    if data.get("scenario") not in ("payouts", "settlements", "disbursements"):
        raise ValueError(f"{session}: scenario is not a known upgrade")
    return row


def repeat_record(session: str, row: dict, source: str) -> dict:
    if not ID_RE.match(session):
        raise ValueError(f"{session}: session id breaks the id rule")
    payload = {
        "schema": "kalari.repeat.v1",
        "provenance": "repeat023",
        "status": "valid",
        "arm": row["arm"],
        "model": row["model_name"],
        "model_id": row["model"],
        "scenario": row["scenario"],
        "project": row["project"],
        "repeat": row["repeat"],
        "headline": row["headline"],
        "chain": row["chain"],
        "session_id": session,
        "session_capped": row.get("session_capped"),
        "session_cap_s": row.get("session_cap_s"),
        "verdict": row["measures"]["verdict"],
        "right_first_time": row["measures"]["right_first_time"],
        "sandbox_runs": row["measures"]["sandbox_runs"],
        "wall_time_s": row["measures"]["wall_time_s"],
        "time_stuck_s": row["measures"]["time_stuck_s"],
        "tokens_input": row["measures"]["tokens_input"],
        "tokens_output": row["measures"]["tokens_output"],
        "records_lost": row["measures"]["records_lost"],
        "records_duplicated": row["measures"]["records_duplicated"],
        "records_extra": row.get("records_extra"),
        "records_mismatched": row.get("records_mismatched"),
        "cost_usd": row.get("cost_usd"),
        "grade": copy.deepcopy(row.get("grade")),
        "lessons_written": len(row.get("lessons_published") or []),
        "lessons_recalled": len(row.get("lessons_recalled") or []),
        "tool_calls": copy.deepcopy(row.get("tool_calls")),
        "source": source,
        "notes": "One Kalari 0.2.3 repeat session.",
    }
    return {
        "kind": "benchmark",
        "session_id": session,
        "run_id": session,
        "change_kinds": ["pagination_changed"],
        "payload": payload,
    }


def baseline_record() -> dict:
    """The demoted earlier baseline: per-session cost over the 60 frozen rows."""
    frozen = REPO / "bench" / "frozen-evidence.jsonl"
    kalari: list[float] = []
    reference: list[float] = []
    for line in frozen.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        payload = record.get("payload") or {}
        cost = payload.get("cost_usd")
        if not isinstance(cost, (int, float)):
            raise ValueError("frozen record has no cost_usd")
        if payload.get("arm") == "kalari":
            kalari.append(cost)
        elif payload.get("arm") == "reference":
            reference.append(cost)
    if len(kalari) != 20 or len(reference) != 40:
        raise ValueError(f"frozen evidence holds {len(kalari)} kalari and {len(reference)} reference rows")
    payload = {
        "schema": "kalari.baseline.v1",
        "provenance": "baseline",
        "status": "valid",
        "sessions": 60,
        "kalari_sessions": len(kalari),
        "reference_sessions": len(reference),
        "kalari_cost_usd": round(sum(kalari) / len(kalari), 4),
        "reference_cost_usd": round(sum(reference) / len(reference), 4),
        "source": "bench/RESULTS.md",
        "notes": "The earlier frozen comparison, kept as a baseline only.",
    }
    return {
        "kind": "benchmark",
        "session_id": "baseline-frozen",
        "run_id": "baseline-frozen",
        "change_kinds": ["pagination_changed"],
        "payload": payload,
    }


def collect_raw(raw: Path) -> list[tuple[str, str, dict]]:
    """Collect the raw session rows."""
    found: list[tuple[str, str, dict]] = []
    for path in sorted(raw.glob("*/runs/*/measures.json")):
        project = path.parts[-4]
        session = path.parts[-2]
        with path.open(encoding="utf-8") as handle:
            data = json.load(handle)
        if not isinstance(data, dict):
            raise ValueError(f"{path}: row is not a JSON object")
        found.append((project, session, data))
    return found


def write_containment(raw: Path) -> list[dict]:
    bundle = raw / "containment-0.2.3"
    evidence = (bundle / "evidence.jsonl").read_text(encoding="utf-8")
    transcript = (bundle / "transcript.txt").read_text(encoding="utf-8")
    CONTAINMENT_OUT.mkdir(parents=True, exist_ok=True)
    records: list[dict] = []
    for line in evidence.splitlines():
        if not line.strip():
            continue
        record = json.loads(line)
        record["session_id"] = "containment-023"
        records.append(record)
    with (CONTAINMENT_OUT / "evidence.jsonl").open("w", encoding="utf-8", newline="\n") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    fixed = transcript.replace("containment-runs", "containment-023")
    (CONTAINMENT_OUT / "transcript.txt").write_text(fixed, encoding="utf-8")
    return records


def main() -> int:
    raw = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_RAW
    items = collect_raw(raw)
    if len(items) != 105:
        print(f"expected 105 raw rows, found {len(items)}", file=sys.stderr)
        return 1
    ROWS_DIR.mkdir(parents=True, exist_ok=True)
    records: list[dict] = []
    for project, session, data in items:
        row = build_row(session, data)
        name = f"{project}--{session}.json"
        with (ROWS_DIR / name).open("w", encoding="utf-8", newline="\n") as handle:
            json.dump(row, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        records.append(repeat_record(session, row, f"bench/rows-0.2.3/{name}"))
    records.extend(write_containment(raw))
    records.append(baseline_record())
    bench_ids = [r["run_id"] for r in records if r.get("kind") == "benchmark"]
    if len(set(bench_ids)) != len(bench_ids):
        print("duplicate benchmark run_id in produced records", file=sys.stderr)
        return 1
    with OUT.open("w", encoding="utf-8", newline="\n") as handle:
        for record in records:
            line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
            json.loads(line)
            handle.write(line + "\n")
    repeats = sum(1 for r in records if (r.get("payload") or {}).get("schema") == "kalari.repeat.v1")
    print(f"wrote {len(items)} sanitised rows and {len(records)} evidence records to {OUT}")
    print(f"repeat records: {repeats}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
