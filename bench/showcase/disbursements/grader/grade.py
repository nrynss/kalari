"""The hidden grader: is every record in the consumer's output exactly once, and right?

Usage: grade.py <output.jsonl>
Prints one JSON verdict and exits 0 on PASS, 1 on FAIL. Never shown to an arm.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
for _p in (os.path.dirname(HERE), HERE):
    sys.path.insert(0, _p)
import data  # noqa: E402


def grade(path):
    want = {r["id"]: r for r in data.FINAL}
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
    if len(sys.argv) != 2:
        sys.exit("usage: grade.py <output.jsonl>")
    v = grade(sys.argv[1])
    print(json.dumps(v))
    sys.exit(0 if v["verdict"] == "PASS" else 1)
