"""Grade one output path for run.sh, and the null policy for missing output.

`missing` and `duplicates` are None when there is no fresh output: they are
unmeasurable, never zero. `run.sh` and the no-inference rehearsal call this
module so both use the same policy.
"""
import json
import os
import subprocess
import sys

GRADER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "graders", "grade.py")


def grade_missing():
    return {
        "verdict": "FAIL",
        "output_present": False,
        "records": 0,
        "unique": 0,
        "expected": None,
        "missing": None,
        "extra": None,
        "duplicates": None,
        "mismatched": None,
        "unreadable_lines": 0,
        "note": "no consumer output",
    }


def grade(upgrade, path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return grade_missing()
    proc = subprocess.run(
        [sys.executable, GRADER, upgrade, path],
        capture_output=True,
        text=True,
    )
    try:
        return json.loads(proc.stdout)
    except ValueError:
        return {
            "verdict": "FAIL",
            "note": "grader did not print JSON",
            "stdout": proc.stdout[-300:],
            "stderr": proc.stderr[-300:],
        }


def apply_meta(value, meta):
    if not meta:
        return value
    for field in ("consumer_exit", "output_present", "grade_status", "output_bytes",
                  "stale_output_ignored"):
        if field in meta:
            value[field] = meta[field]
    if meta.get("note"):
        value["note"] = meta["note"]
    if value.get("output_present") is False:
        value["verdict"] = "FAIL"
    return value


def condition1_evidence(analysis):
    """The condition-1 evidence fields that a published result carries."""
    return {
        "condition1_workspace": analysis.get("condition1_workspace"),
        "continuation_state_consumed": analysis.get("continuation_state_consumed"),
        "continuation_state_consumed_at": analysis.get("continuation_state_consumed_at"),
    }


def grading_evidence(grading):
    """The directory each grading pass checked for stale output."""
    return {
        "final": {"workspace_checked": (grading.get("final") or {}).get("workspace_checked")},
        "first": {"workspace_checked": (grading.get("first") or {}).get("workspace_checked")},
    }


def require_condition1_identity(cond, upgrade, analysis):
    """Exit without a result unless condition-1 settlements resumed the session."""
    if int(cond) == 1 and upgrade == "settlements":
        if analysis.get("session_continued") is not True:
            raise SystemExit(
                "condition-1 settlements: session_continued is not true; no result written"
            )
        if analysis.get("session_identity_ok") is not True:
            raise SystemExit(
                "condition-1 settlements: session_identity_ok is not true; no result written"
            )
