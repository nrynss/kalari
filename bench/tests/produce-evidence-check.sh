#!/usr/bin/env bash
# Validate the frozen benchmark evidence file. Stdlib only.
# Run from the repository root: bench/tests/produce-evidence-check.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

EVIDENCE="bench/frozen-evidence.jsonl"
fail=0
say() { printf '%s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

[[ -f "$EVIDENCE" ]] || { bad "missing $EVIDENCE"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "-- producer is fresh"
python3 bench/produce-evidence.py "$tmp/frozen-evidence.jsonl" >/dev/null
cmp -s "$tmp/frozen-evidence.jsonl" "$EVIDENCE" || bad "committed $EVIDENCE differs from producer output"

say "-- benchmark contract"
python3 web/fixture/validate.py "$EVIDENCE" || bad "contract validator rejected $EVIDENCE"

say "-- frozen content"
python3 - "$EVIDENCE" <<'EOF' || exit 1
import json, re, sys
from pathlib import Path

path = Path(sys.argv[1])
records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
fails = []
def check(cond, msg):
    if not cond:
        fails.append(msg)

check(len(records) == 60, f"expected 60 records, found {len(records)}")
id_re = re.compile(r"^[A-Za-z0-9._-]+$")
run_ids = [r.get("run_id") for r in records]
check(len(set(run_ids)) == len(run_ids), "duplicate run_id")
for r in records:
    p = r.get("payload", {})
    check(r.get("kind") == "benchmark", f"{r.get('run_id')}: kind is not benchmark")
    check(p.get("provenance") == "frozen", f"{r.get('run_id')}: provenance is not frozen")
    check(p.get("status") == "valid", f"{r.get('run_id')}: status is not valid")
    check("synthetic" not in p, f"{r.get('run_id')}: producer must not write synthetic")
    check(not id_re.match(r.get("session_id", "")) is None, f"{r.get('run_id')}: bad session_id")
    check(not id_re.match(r.get("run_id", "")) is None, f"{r.get('run_id')}: bad run_id")
    check(p.get("session_id") == r.get("session_id"), f"{r.get('run_id')}: session mismatch")
    check(p.get("behaviour") is None, f"{r.get('run_id')}: frozen rows have null behaviour")
    want_arm = {4: "kalari", 5: "kalari"}.get(p.get("condition"), "reference")
    check(p.get("arm") == want_arm, f"{r.get('run_id')}: condition/arm mismatch")
    if p.get("arm") == "kalari":
        check(p.get("sandbox_runs_against_v1") is None, f"{r.get('run_id')}: kalari v1 split must stay null")
        check(p.get("sandbox_runs_against_v2") is None, f"{r.get('run_id')}: kalari v2 split must stay null")

# Aggregates trace to bench/RESULTS.md section 2 (rounded display values).
groups = {}
for r in records:
    p = r["payload"]
    groups.setdefault((p["arm"], p["condition"], p["upgrade"]), []).append(p)
EXPECTED = {
    ("kalari", 4, "payouts"): {"cost": 0.082421, "wall": 110.3, "sb": 10, "tin": 53341, "tout": 13062, "rft": 5},
    ("kalari", 4, "settlements"): {"cost": 0.088106, "wall": 125.7, "sb": 12, "tin": 59629, "tout": 11431, "rft": 5},
    ("kalari", 5, "payouts"): {"cost": 0.085910, "wall": 107.8, "sb": 12, "tin": 52242, "tout": 14414, "rft": 3},
    ("kalari", 5, "settlements"): {"cost": 0.127732, "wall": 168.0, "sb": 24, "tin": 66039, "tout": 14994, "rft": 3},
    ("reference", 1, "payouts"): {"cost": 0.342783, "wall": 262.3, "sb": 12, "tin": 2102650, "tout": 45641, "rft": 5},
    ("reference", 1, "settlements"): {"cost": 0.527650, "wall": 241.6, "sb": 8, "tin": 3312903, "tout": 51191, "rft": 5},
    ("reference", 2, "payouts"): {"cost": 0.378525, "wall": 260.0, "sb": 9, "tin": 2321297, "tout": 50551, "rft": 5},
    ("reference", 2, "settlements"): {"cost": 0.457714, "wall": 355.6, "sb": 13, "tin": 2777453, "tout": 68492, "rft": 5},
    ("reference", 3, "payouts"): {"cost": 0.411307, "wall": 914.9, "sb": 13, "tin": 2530422, "tout": 52906, "rft": 5},
    ("reference", 3, "settlements"): {"cost": 0.327196, "wall": 246.9, "sb": 9, "tin": 1965002, "tout": 54075, "rft": 5},
    ("reference", 6, "payouts"): {"cost": 0.360117, "wall": 526.4, "sb": 9, "tin": 2171304, "tout": 57370, "rft": 5},
    ("reference", 6, "settlements"): {"cost": 0.454941, "wall": 570.6, "sb": 12, "tin": 2773696, "tout": 64810, "rft": 5},
}
check(set(groups) == set(EXPECTED), f"expected 12 groups of 5, found {sorted(str(k) for k in groups)}")
for key, want in EXPECTED.items():
    items = groups.get(key, [])
    check(len(items) == 5, f"{key}: expected 5 repeats, found {len(items)}")
    check(round(sum(p["cost_usd"] for p in items), 6) == want["cost"], f"{key}: cost aggregate")
    check(round(sum(p["wall_time_s"] for p in items), 1) == want["wall"], f"{key}: wall aggregate")
    check(sum(p["sandbox_runs"] for p in items) == want["sb"], f"{key}: sandbox aggregate")
    check(sum(p["tokens_input"] for p in items) == want["tin"], f"{key}: tokens-in aggregate")
    check(sum(p["tokens_output"] for p in items) == want["tout"], f"{key}: tokens-out aggregate")
    check(sum(1 for p in items if p["right_first_time"]) == want["rft"], f"{key}: right-first-time aggregate")
    check(all(p["verdict"] == "PASS" for p in items), f"{key}: verdict aggregate")

if fails:
    for line in fails:
        print("FAIL " + line)
    sys.exit(1)
print(f"frozen content ok: {len(records)} records, 12 groups, aggregates match RESULTS.md")
EOF
[[ $? -eq 0 ]] || fail=1

say "-- no secret or address patterns"
python3 - "$EVIDENCE" <<'EOF' || exit 1
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
pats = {
    "IP address": re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])"),
    "email": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    "api key": re.compile(r"(?i)api[_-]?key"),
    "bearer": re.compile(r"(?i)bearer\s"),
    "private key": re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"),
    "ssh key": re.compile(r"ssh-(?:rsa|ed25519)"),
}
fails = [name for name, pat in pats.items() if pat.search(text)]
if fails:
    print("FAIL evidence file holds: " + ", ".join(fails))
    sys.exit(1)
print("no IP, email or key patterns")
EOF
[[ $? -eq 0 ]] || fail=1

say "-- sources resolve"
python3 - "$EVIDENCE" <<'EOF' || exit 1
import sys
from pathlib import Path
repo = Path(".").resolve()
fails = []
import json
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    source = json.loads(line)["payload"]["source"]
    p = Path(source)
    if p.is_absolute() or ".." in p.parts:
        fails.append(f"{source}: not repo-relative")
    elif not (repo / p).is_file():
        fails.append(f"{source}: file does not exist")
if fails:
    for line in fails:
        print("FAIL " + line)
    sys.exit(1)
print("all 60 sources are repo-relative and exist")
EOF
[[ $? -eq 0 ]] || fail=1

if [[ $fail -ne 0 ]]; then
  say "produce-evidence check FAILED"
  exit 1
fi
say "produce-evidence check passed"
