#!/usr/bin/env python3
"""Publish the showcase disbursement runs as evidence records.

Reads the 14 committed showcase result files
(bench/showcase/disbursements/runs/<arm>/<label>.json) and emits one
``showcase`` evidence record per run in a single session,
``showcase-disbursements``. Run from the repository root::

    python3 bench/showcase/disbursements/produce-showcase.py [OUT]

Defaults to bench/showcase/disbursements/showcase-evidence.jsonl. Stdlib only.
No inference, no network, no key. Unknown stays null: a measure the source
row does not hold is emitted as null, never zero.

The records are sanitized like the frozen ones: only counts, verdicts, times,
costs, model names and committed file paths. No endpoint, no workspace, no
usage delta, no transcript content. The transcript files stay beside the
result files; the record carries their repo-relative paths only.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
RUNS = REPO / "bench" / "showcase" / "disbursements" / "runs"
DEFAULT_OUT = REPO / "bench" / "showcase" / "disbursements" / "showcase-evidence.jsonl"

SESSION = "showcase-disbursements"
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
IP_RE = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
SECRET_RES = [
    re.compile(r"(?i)api[_-]?key"),
    re.compile(r"(?i)bearer\s"),
    re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"),
]

# Filename stem prefix to (display name, model id). The result files carry no
# model field on some rows, so the stem is authoritative and the usage delta
# cross-checks it where one exists.
MODELS = {
    "glm": ("GLM 5.3 Flash", "glm-5.3-flash"),
    "qwen27b": ("Qwen3.8 27B", "qwen3.8-27b"),
    "muse": ("Muse Glimmer 30B", "muse-glimmer-30b"),
    "mimo": ("MiMo V2.6 Flash", "mimo-v2.6-flash"),
    "deepseek": ("DeepSeek V4.1 Flash", "deepseek-v4.1-flash-1017"),
}

IGNORE_USAGE = {"clef", "qwen3-embedding-4b"}


def fail(message: str) -> None:
    print(f"produce-showcase: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_row(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        fail(f"{path}: row is not a JSON object")
    return data


def model_of(stem: str, data: dict) -> tuple[str, str]:
    prefix = stem.split("-")[0]
    if prefix not in MODELS:
        fail(f"{stem}: unknown model prefix")
    display, model_id = MODELS[prefix]
    delta = data.get("usage_delta")
    seen: set[str] = set()
    if isinstance(delta, dict):
        for key, value in delta.items():
            if not isinstance(value, dict) or key in IGNORE_USAGE:
                continue
            if value.get("input") or value.get("output"):
                seen.add(key)
    elif isinstance(delta, list):
        for entry in delta:
            if not isinstance(entry, dict):
                continue
            key = entry.get("model")
            if key in IGNORE_USAGE or not isinstance(key, str):
                continue
            if entry.get("input") or entry.get("output"):
                seen.add(key)
    if seen and model_id not in seen:
        fail(f"{stem}: usage delta names {sorted(seen)}, expected {model_id}")
    return display, model_id


def differential_sequence(data: dict, transcript_path: Path) -> tuple[list[str], bool, bool]:
    """The differential check outcomes for a Kalari run, oldest first.

    Each trusted sandbox run reports a detail such as "0 missing, 0 extra,
    0 duplicates, 23 changed". The committed transcript carries one such
    output per trusted run, in order. Returns the changed counts, whether
    the check ever fired, and whether the session fixed it.
    """
    sequence: list[str] = []
    with transcript_path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            part = event.get("part") or {}
            if part.get("tool") != "kalari_run_in_sandbox":
                continue
            state = part.get("state") or {}
            if state.get("status") != "completed":
                continue
            try:
                output = json.loads(state.get("output") or "{}")
            except json.JSONDecodeError:
                continue
            checks = output.get("checks") or []
            detail = None
            for check in checks:
                if isinstance(check, dict) and check.get("check_id") == "differential-v1":
                    detail = check.get("detail")
            if not isinstance(detail, str):
                continue
            match = re.search(r"(\d+)\s+changed", detail)
            if match:
                sequence.append(f"{match.group(1)} changed")
            elif "sandbox artifact" in detail or "no successful artifact" in detail:
                continue
            elif detail == "consumer did not complete successfully":
                continue
            else:
                fail(f"{transcript_path.name}: unparseable differential detail: {detail!r}")
    if not sequence:
        fail(f"{transcript_path.name}: no differential outcome in the transcript")
    flagged = any(item != "0 changed" for item in sequence)
    fixed = sequence[-1] == "0 changed" and flagged
    return sequence, flagged, fixed


def build_record(arm: str, path: Path, data: dict) -> dict:
    stem = path.stem
    display, model_id = model_of(stem, data)
    run_id = f"showcase-{arm}-{stem}"
    if not ID_RE.match(run_id):
        fail(f"{stem}: derived id breaks the id rule")
    grade = data.get("grade") or {}
    if arm == "kalari":
        measures = data.get("measures") or {}
        verdict = measures.get("verdict")
        wall = measures.get("wall_time_s")
    else:
        verdict = grade.get("verdict")
        wall = data.get("wall_time_s")
    if verdict not in ("PASS", "FAIL"):
        fail(f"{stem}: verdict is not PASS or FAIL")
    lost = data.get("records_lost")
    duplicated = data.get("records_duplicated")
    changed = data.get("records_mismatched")
    cost = data.get("cost_usd")
    transcript = path.with_suffix(".transcript.jsonl")
    if not transcript.is_file():
        fail(f"{stem}: transcript is missing: {transcript}")
    payload: dict = {
        "schema": "kalari.showcase.v1",
        "arm": arm,
        "model": display,
        "model_id": model_id,
        "label": stem,
        "verdict": verdict,
        "records": grade.get("records"),
        "records_lost": lost,
        "records_duplicated": duplicated,
        "records_changed": changed,
        "wall_time_s": wall,
        "cost_usd": cost,
        "source": str(path.relative_to(REPO)),
        "transcript": str(transcript.relative_to(REPO)),
        "notes": "Manufactured disbursement scenario. Not part of the frozen comparison.",
    }
    if arm == "kalari":
        sequence, flagged, fixed = differential_sequence(data, transcript)
        payload["differential"] = sequence
        payload["flagged"] = flagged
        payload["fixed"] = fixed
    else:
        payload["differential"] = None
        payload["flagged"] = None
        payload["fixed"] = None
    record = {
        "kind": "showcase",
        "session_id": SESSION,
        "run_id": run_id,
        "change_kinds": ["pagination_changed"],
        "payload": payload,
    }
    text = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
    if "http://" in text or "https://" in text:
        fail(f"{stem}: record carries a URL")
    if IP_RE.search(text) or EMAIL_RE.search(text):
        fail(f"{stem}: record carries an address")
    for pattern in SECRET_RES:
        if pattern.search(text):
            fail(f"{stem}: record matches a secret pattern")
    return record


def collect() -> list[tuple[str, Path, dict]]:
    rows: list[tuple[str, Path, dict]] = []
    for arm in ("reference", "kalari"):
        directory = RUNS / arm
        for path in sorted(directory.glob("*.json")):
            if path.suffixes[-2:] == [".transcript", ".json"]:
                continue
            if path.name.endswith(".transcript.jsonl"):
                continue
            rows.append((arm, path, load_row(path)))
    return rows


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    rows = collect()
    records = [build_record(arm, path, data) for arm, path, data in rows]
    run_ids = [record["run_id"] for record in records]
    if len(records) != 14:
        print(f"expected 14 showcase runs, found {len(records)}", file=sys.stderr)
        return 1
    if len(set(run_ids)) != len(run_ids):
        print("duplicate run_id in produced records", file=sys.stderr)
        return 1
    lines = []
    for record in records:
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
        json.loads(line)
        lines.append(line + "\n")
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", encoding="utf-8", newline="\n") as handle:
        handle.writelines(lines)
    try:
        shown = str(out.relative_to(REPO))
    except ValueError:
        shown = str(out)
    print(f"wrote {len(records)} showcase records to {shown}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
