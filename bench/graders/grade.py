"""The hidden grader: is every record in the consumer's output exactly once, and right?

Usage: grade.py payouts|settlements <output.jsonl>
Prints one JSON verdict and exits 0 on PASS, 1 on FAIL. Never shown to an arm.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APIS = os.path.join(HERE, "..", "apis")


def truth(api):
    sys.path.insert(0, os.path.join(APIS, api))
    import data  # noqa: E402
    records = data.PAYOUTS if api == "payouts" else data.SETTLEMENTS
    return {r["id"]: r for r in records}


def grade(api, path):
    want = truth(api)
    got, unreadable = [], 0
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    got.append(json.loads(line))
                except ValueError:
                    unreadable += 1
    ids = [r.get("id") for r in got if isinstance(r, dict)]
    seen, duplicates = set(), 0
    for i in ids:
        duplicates += i in seen
        seen.add(i)
    missing = len(set(want) - seen)
    extra = len(seen - set(want))
    mismatched = sum(1 for r in got if isinstance(r, dict) and r.get("id") in want and r != want[r["id"]])
    ok = os.path.exists(path) and not (missing or extra or duplicates or mismatched or unreadable)
    return {
        "verdict": "PASS" if ok else "FAIL",
        "output_present": os.path.exists(path),
        "records": len(got),
        "unique": len(seen),
        "expected": len(want),
        "missing": missing,
        "extra": extra,
        "duplicates": duplicates,
        "mismatched": mismatched,
        "unreadable_lines": unreadable,
    }


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("payouts", "settlements"):
        sys.exit("usage: grade.py payouts|settlements <output.jsonl>")
    v = grade(sys.argv[1], sys.argv[2])
    print(json.dumps(v))
    sys.exit(0 if v["verdict"] == "PASS" else 1)
