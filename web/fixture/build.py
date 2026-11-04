#!/usr/bin/env python3
"""Build web/fixture/evidence.jsonl from the committed pilot results.

The pilot files are read-only inputs. This script copies only fields the web
app shows, drops host details and port numbers, and adds the illustrative
records that exercise the session view. Run it from the repository root:

    python3 web/fixture/build.py

The output is committed so the fixture server needs no benchmark run time.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
RESULTS = REPO / "bench" / "pilot" / "results"
OUT = HERE / "evidence.jsonl"

CONDITION_RE = re.compile(r"^condition-(\d+)-(payouts|settlements)-r(\d+)\.json$")
BEHAVIOUR_RE = re.compile(r"^behaviour-(payouts|settlements)-(B\d)-r(\d+)\.json$")

CONDITION_NOTES = {
    1: (
        "Condition one resumed the OpenCode session but graded a separate, untouched "
        "workspace. The repair is tracked in T5.1a, so these rows cannot count."
    ),
}
DIAGNOSTIC_NOTE = (
    "Ran with the isolated pilot adapter. It restricts the tool surface and network "
    "more than the condition rows, so these sessions are diagnostic and are not "
    "compared with them."
)


def load(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def clean_grade(grade: dict[str, Any] | None) -> dict[str, Any] | None:
    if grade is None:
        return None
    keep = (
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
    return {key: grade.get(key) for key in keep if key in grade}


def clean_grader_runs(runs: dict[str, Any] | None) -> dict[str, Any] | None:
    if not runs:
        return None
    cleaned: dict[str, Any] = {}
    for key, value in runs.items():
        if not isinstance(value, dict):
            continue
        cleaned[key] = {
            "status": value.get("status", ""),
            "log_excerpt": value.get("log_excerpt", ""),
        }
    return cleaned


def measures_of(data: dict[str, Any]) -> dict[str, Any]:
    measures = data.get("measures", {})
    return {
        "verdict": measures.get("verdict"),
        "right_first_time": measures.get("right_first_time"),
        "sandbox_runs": measures.get("sandbox_runs"),
        "wall_time_s": measures.get("wall_time_s"),
        "time_stuck_s": measures.get("time_stuck_s"),
        "tokens_input": measures.get("tokens_input"),
        "tokens_output": measures.get("tokens_output"),
        "records_lost": measures.get("records_lost"),
        "records_duplicated": measures.get("records_duplicated"),
    }


def benchmark_payload(
    data: dict[str, Any],
    *,
    provenance: str,
    status: str,
    condition: int,
    upgrade: str,
    repeat: int,
    behaviour: str | None,
    source: str,
    notes: str,
) -> dict[str, Any]:
    measures = measures_of(data)
    return {
        "schema": "kalari.benchmark.v1",
        "provenance": provenance,
        "status": status,
        "arm": data.get("arm", "reference"),
        "condition": condition,
        "upgrade": upgrade,
        "repeat": repeat,
        "behaviour": behaviour,
        "session_id": data.get("session_id"),
        "session_continued": data.get("session_continued"),
        "notes_attached": data.get("notes_attached"),
        "session_capped": data.get("session_capped"),
        "session_cap_s": data.get("session_cap_s"),
        "verdict": measures["verdict"],
        "right_first_time": measures["right_first_time"],
        "right_first_time_basis": data.get("right_first_time_basis"),
        "sandbox_runs": measures["sandbox_runs"],
        "sandbox_runs_against_v1": data.get("sandbox_runs_against_v1"),
        "sandbox_runs_against_v2": data.get("sandbox_runs_against_v2"),
        "wall_time_s": measures["wall_time_s"],
        "time_stuck_s": measures["time_stuck_s"],
        "tokens_input": measures["tokens_input"],
        "tokens_output": measures["tokens_output"],
        "records_lost": measures["records_lost"],
        "records_duplicated": measures["records_duplicated"],
        "records_extra": data.get("records_extra"),
        "records_mismatched": data.get("records_mismatched"),
        "cost_usd": data.get("cost_usd"),
        "grade": clean_grade(data.get("grade")),
        "first_v2_grade": clean_grade(data.get("first_v2_grade")),
        "grader_runs": clean_grader_runs(data.get("grader_runs")),
        "opencode_exit": data.get("opencode_exit"),
        "process_elapsed_s": data.get("process_elapsed_s"),
        "source": source,
        "notes": notes,
    }


def record(kind: str, session: str, run: str, changes: list[str], payload: Any) -> dict[str, Any]:
    return {
        "kind": kind,
        "session_id": session,
        "run_id": run,
        "change_kinds": changes,
        "payload": payload,
    }


def pilot_records() -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    condition_files: list[tuple[int, str, int, Path]] = []
    behaviour_files: list[tuple[str, str, int, Path]] = []

    for path in sorted(RESULTS.glob("*.json")):
        match = CONDITION_RE.match(path.name)
        if match:
            condition_files.append((int(match.group(1)), match.group(2), int(match.group(3)), path))
            continue
        match = BEHAVIOUR_RE.match(path.name)
        if match:
            behaviour_files.append((match.group(1), match.group(2), int(match.group(3)), path))

    condition_files.sort(key=lambda item: (item[0], item[1], item[2]))
    behaviour_files.sort(key=lambda item: (item[0], item[1], item[2]))

    for condition, upgrade, repeat, path in condition_files:
        data = load(path)
        run_id = f"pilot-c{condition}-{upgrade}-r{repeat}"
        session_id = f"pilot-c{condition}-{upgrade}"
        status = "invalid" if condition == 1 else "valid"
        notes = CONDITION_NOTES.get(condition, "")
        payload = benchmark_payload(
            data,
            provenance="pilot",
            status=status,
            condition=condition,
            upgrade=upgrade,
            repeat=repeat,
            behaviour=None,
            source=f"bench/pilot/results/{path.name}",
            notes=notes,
        )
        payload["session_id"] = session_id
        records.append(record("benchmark", session_id, run_id, ["pagination_changed"], payload))

    for upgrade, behaviour, repeat, path in behaviour_files:
        data = load(path)
        run_id = f"pilot-b-{upgrade}-{behaviour}-r{repeat}"
        session_id = f"pilot-b-{upgrade}-{behaviour}"
        payload = benchmark_payload(
            data,
            provenance="pilot",
            status="diagnostic",
            condition=3,
            upgrade=upgrade,
            repeat=repeat,
            behaviour=behaviour,
            source=f"bench/pilot/results/{path.name}",
            notes=DIAGNOSTIC_NOTE,
        )
        payload["session_id"] = session_id
        records.append(record("benchmark", session_id, run_id, ["pagination_changed"], payload))

    return records


# The walkthrough session is assembled from recorded pieces. The change facts
# and IDs come from testdata/vimanam/2.1.0/payouts.json, the call site from the
# benchmark workspace, and the Clef answer from testdata/clef. Timings and log
# excerpts are illustrative and the session says so.
CHANGES = [
    {
        "id": "vc2_ff47bb628a187fbe4f28e53ef03a6231e2b22188bc0e84446306104ba37029d8",
        "kind": "pagination_changed",
        "severity": "review",
        "title": "Pagination changed",
        "summary": (
            "The export returns a window with a cursor and a drained flag. The cursor "
            "is still present on the last page."
        ),
        "endpoint": "GET /v2/payouts",
        "source": "testdata/vimanam/2.1.0/payouts.json",
    },
    {
        "id": "vc2_a604d335c9ac1b47b192a9f46eca61773f4ccd1db93a772f71808fbdb36b933c",
        "kind": "operation_moved",
        "severity": "breaking",
        "title": "The payout operation moved",
        "summary": "The list endpoint moved from the old path to the export path.",
        "endpoint": "GET /v2/payouts",
        "source": "testdata/vimanam/2.1.0/payouts.json",
    },
    {
        "id": "vc2_d8282cabd333c4d00b5de7fbe69a338b833da23fa89718141a662b13382b0d1f",
        "kind": "operation_renamed",
        "severity": "breaking",
        "title": "The operation ID changed",
        "summary": "The operation ID changed from listPayouts to exportPayouts.",
        "endpoint": "GET /v2/payouts",
        "source": "testdata/vimanam/2.1.0/payouts.json",
    },
    {
        "id": "vc2_150d90fdebc8ce0aa01c80cd471367977988f70b0562b06ccafc56abd0012c52",
        "kind": "argument_added",
        "severity": "non_breaking",
        "title": "Two query arguments were added",
        "summary": "The export accepts a cursor and a limit. Both are optional.",
        "endpoint": "GET /v2/payouts",
        "source": "testdata/vimanam/2.1.0/payouts.json",
    },
]

CALL_SITE = {
    "path": "bench/workspaces/payout-sync/payout_sync.py",
    "detail": '8:     with urllib.request.urlopen(f"{base_url}/v1/payouts", timeout=30) as resp:',
}
PAGINATION_SITE = {
    "path": "bench/workspaces/payout-sync/payout_sync.py",
    "detail": '9:         return json.load(resp)["payouts"]',
}

CHECK = {
    "id": "exact-once",
    "assertion": "Every payout exactly once, none missing, none extra, each equal to its old version.",
    "command": ["python3", "check_exact_once.py", "payouts.jsonl"],
}

LESSON_OBSERVATION = (
    "The stream carried a cursor on its last page and repeated records at window "
    "boundaries. The passing loop followed the end flag, keyed records by id, and kept "
    "the last delivery. The check compares the output with the old endpoint."
)

CLEF_ANSWER = {
    "question": "Why did the first run fail?",
    "question_set": "failure-api-change-truncated",
    "model": "clef",
    "answer": {
        "type": "choice",
        "choice": "api_change",
        "probabilities": {
            "api_change": 0.9785093665122986,
            "test_setup": 0.004290240351110697,
            "flaky": 0.004786109551787376,
            "unrelated_bug": 0.012414224445819855,
        },
        "confidence": 0.9713458220163981,
    },
}


def caps() -> dict[str, Any]:
    return {"timeout_ms": 120000, "output_cap_bytes": 65536, "memory_mib": 512}


def request() -> dict[str, Any]:
    return {
        "workspace": "bench/workspaces/payout-sync",
        "command": [
            "python3",
            "payout_sync.py",
            "--base-url",
            "ENDPOINT",
            "--out",
            "payouts.jsonl",
        ],
        "caps": caps(),
        "allowlist": [{"host": "api.test", "port": 18080}],
    }


def verdict(stdout: str, wall_ms: int) -> dict[str, Any]:
    return {
        "verdict": "exited",
        "exit_code": 0,
        "wall_ms": wall_ms,
        "stdout": stdout,
        "stdout_truncated": False,
        "stderr": "",
        "pipe_held_open": False,
        "supervisor_peak_rss_kb": 5488,
        "cgroup_memory_limit": 536870912,
    }


def run_payload(stdout: str, wall_ms: int, passed: bool, detail: str) -> dict[str, Any]:
    return {
        "request": request(),
        "verdict": verdict(stdout, wall_ms),
        "checks": [CHECK],
        "check_results": [{"check_id": CHECK["id"], "passed": passed, "detail": detail}],
        "timings": {"wall_ms": wall_ms},
        "tokens": None,
        "illustrative": True,
    }


def illustrative_records() -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    session = "payouts-upgrade"
    earlier = "payouts-earlier"
    attempts = ["payouts-attempt-1", "payouts-attempt-2", "payouts-attempt-3"]
    first = attempts[0]
    passing = attempts[2]

    records.append(
        record(
            "session",
            session,
            passing,
            ["pagination_changed", "operation_moved", "operation_renamed", "argument_added"],
            {
                "title": "Upgrading the payout ledger",
                "summary": (
                    "A coding agent moves the payout consumer from the old list endpoint "
                    "to the windowed export. The first two attempts fail their checks. The "
                    "third passes, and the lesson is written."
                ),
                "arm": "kalari",
                "illustrative": True,
                "notes": (
                    "Assembled from recorded change facts, the recorded Clef answer, and "
                    "the benchmark workspaces. Run timings and log excerpts are illustrative."
                ),
            },
        )
    )
    records.append(
        record(
            "session",
            earlier,
            "payouts-earlier-pass",
            ["pagination_changed"],
            {
                "title": "The lesson that came before",
                "summary": "An earlier payout upgrade left the lesson this session recalls.",
                "arm": "kalari",
                "illustrative": True,
                "notes": "Illustrative. The lesson text is the rule the product records.",
            },
        )
    )

    for change in CHANGES:
        records.append(
            record("change", session, first, [change["kind"]], change)
        )

    radius = [
        ("operation_moved", CALL_SITE),
        ("pagination_changed", PAGINATION_SITE),
        ("operation_renamed", None),
        ("argument_added", None),
    ]
    for kind, site in radius:
        change = next(item for item in CHANGES if item["kind"] == kind)
        payload: dict[str, Any] = {
            "change_id": change["id"],
            "call_sites": [site] if site else [],
        }
        if kind == "operation_renamed":
            payload["note"] = "The consumer uses the path, not the operation ID."
        if kind == "argument_added":
            payload["note"] = "The consumer does not pass either argument."
        records.append(record("blast-radius", session, first, [kind], payload))

    details = [
        (
            attempts[0],
            "synced 100 payouts\n",
            1500,
            False,
            "100 of 2431 records. 2331 missing. 0 duplicated.",
        ),
        (
            attempts[1],
            "synced 2455 payouts\n",
            1810,
            False,
            "2455 records. 0 missing. 24 duplicated.",
        ),
        (
            passing,
            "synced 2431 payouts\n",
            1699,
            True,
            "2431 records. 0 missing. 0 extra. 0 duplicated. Every record equal to v1.",
        ),
    ]
    for run_id, stdout, wall_ms, passed, detail in details:
        records.append(
            record("run", session, run_id, ["pagination_changed"], run_payload(stdout, wall_ms, passed, detail))
        )
        records.append(
            record(
                "check",
                session,
                run_id,
                ["pagination_changed"],
                {"check_id": CHECK["id"], "passed": passed, "detail": detail},
            )
        )

    records.append(record("decision", session, first, ["pagination_changed"], CLEF_ANSWER))

    records.append(
        record(
            "page-observation",
            session,
            passing,
            ["pagination_changed"],
            {"source": "payouts-api", "behaviors": ["boundary_overlap_one", "final_page_token"]},
        )
    )
    records.append(
        record(
            "verified-behavior",
            session,
            passing,
            ["pagination_changed"],
            {
                "change_kind": "pagination_changed",
                "check": CHECK,
                "behaviors": ["boundary_overlap_one", "final_page_token"],
                "failed_run_id": attempts[1],
            },
        )
    )

    records.append(
        record(
            "lesson",
            session,
            passing,
            ["pagination_changed"],
            {
                "change_kind": "pagination_changed",
                "observation": LESSON_OBSERVATION,
                "run_id": passing,
                "check": CHECK,
                "memory_concept_id": "concept-payout-exactly-once",
            },
        )
    )

    earlier_run = run_payload(
        "synced 2431 payouts\n",
        1640,
        True,
        "2431 records. 0 missing. 0 extra. 0 duplicated. Every record equal to v1.",
    )
    records.append(
        record("run", earlier, "payouts-earlier-pass", ["pagination_changed"], earlier_run)
    )
    records.append(
        record(
            "check",
            earlier,
            "payouts-earlier-pass",
            ["pagination_changed"],
            {
                "check_id": CHECK["id"],
                "passed": True,
                "detail": "2431 records. 0 missing. 0 extra. 0 duplicated. Every record equal to v1.",
            },
        )
    )
    records.append(
        record(
            "lesson",
            earlier,
            "payouts-earlier-pass",
            ["pagination_changed"],
            {
                "change_kind": "pagination_changed",
                "observation": LESSON_OBSERVATION,
                "run_id": "payouts-earlier-pass",
                "check": CHECK,
                "memory_concept_id": "concept-payout-exactly-once",
            },
        )
    )

    return records


def main() -> None:
    records = pilot_records() + illustrative_records()
    with OUT.open("w", encoding="utf-8", newline="\n") as handle:
        for item in records:
            handle.write(json.dumps(item, ensure_ascii=False, separators=(",", ":")))
            handle.write("\n")
    print(f"wrote {len(records)} records to {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
