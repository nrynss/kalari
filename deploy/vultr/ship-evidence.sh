#!/usr/bin/env bash
# Ship frozen benchmark evidence to the demo VM and verify it live.
#
#   deploy/vultr/ship-evidence.sh [--host kalari]
#       [--evidence bench/frozen-evidence.jsonl]
#       [--public-url https://kalari.nryn.dev]
#
# Merges the evidence file into /var/lib/kalari/evidence/.kalari/evidence.jsonl
# on the VM. The merge preserves every non-benchmark record (in particular the
# existing lesson-policy provenance record) and is idempotent: previously
# shipped benchmark records are replaced by run id, never duplicated. Then it
# restarts kalari-api and verifies every shipped record over the loopback API
# on the VM and over the public demo URL from here.
#
# No inference, no spend, no key: SSH uses the existing Tailscale auth only.
# Output is sanitized by construction (counts and statuses only).
set -euo pipefail
umask 022

HOST="kalari"
EVIDENCE=""
PUBLIC_URL="https://kalari.nryn.dev"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST=${2:?--host needs a value}; shift 2;;
    --evidence) EVIDENCE=${2:?--evidence needs a value}; shift 2;;
    --public-url) PUBLIC_URL=${2:?--public-url needs a value}; shift 2;;
    *) echo "usage: ship-evidence.sh [--host SSH_TARGET] [--evidence FILE] [--public-url URL]" >&2; exit 2;;
  esac
done
[[ -z "$EVIDENCE" ]] && EVIDENCE="$REPO/bench/frozen-evidence.jsonl"
[[ -f "$EVIDENCE" ]] || { echo "evidence file not found: $EVIDENCE" >&2; exit 1; }

SSH="ssh -o BatchMode=yes -o ConnectTimeout=15 $HOST"
SCP="scp -o BatchMode=yes -o ConnectTimeout=15"

say() { printf '%s\n' "$*"; }

SHIPPED=$(python3 -c "import json;print(sum(1 for l in open('$EVIDENCE') if l.strip()))")
say "== $HOST: shipping $SHIPPED frozen benchmark records"
[[ "$SHIPPED" -eq 60 ]] || { echo "expected 60 records, found $SHIPPED" >&2; exit 1; }

say "== upload"
$SCP "$EVIDENCE" "$HOST:/tmp/frozen-evidence-upload.jsonl"
$SSH 'chmod 644 /tmp/frozen-evidence-upload.jsonl'

say "== merge (preserve lesson-policy, replace shipped run ids)"
$SSH 'sudo -u kalari python3 - /tmp/frozen-evidence-upload.jsonl' <<'EOF'
import json
import os
import sys
upload = sys.argv[1]
store = "/var/lib/kalari/evidence/.kalari/evidence.jsonl"
with open(upload, encoding="utf-8") as handle:
    new_records = [json.loads(line) for line in handle if line.strip()]
new_ids = {r["run_id"] for r in new_records if r.get("kind") == "benchmark"}
assert len(new_ids) == len(new_records) == 60, "upload must hold 60 unique benchmark run ids"
try:
    with open(store, "rb") as handle:
        raw = handle.read()
except FileNotFoundError:
    raw = b""
committed = raw.split(b"\n")[:-1] if raw else []
kept = []
for line in committed:
    if not line.strip():
        continue
    try:
        record = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        continue
    if not isinstance(record, dict):
        continue
    if record.get("kind") == "benchmark" and record.get("run_id") in new_ids:
        continue
    kept.append(line)
out = kept + [json.dumps(r, ensure_ascii=False, separators=(",", ":")).encode("utf-8") for r in new_records]
tmp = store + ".tmp"
with open(tmp, "wb") as handle:
    handle.write(b"\n".join(out) + b"\n")
os.replace(tmp, store)
with open(store, encoding="utf-8") as handle:
    kinds = {}
    for line in handle:
        if line.strip():
            kind = json.loads(line).get("kind")
            kinds[kind] = kinds.get(kind, 0) + 1
print(f"store now holds: {kinds}")
assert kinds.get("benchmark") == 60, "store must hold 60 benchmark records"
assert kinds.get("lesson-policy", 0) >= 1, "lesson-policy provenance record must survive"
EOF

say "== restart kalari-api"
$SSH 'sudo systemctl restart kalari-api'
for _ in $(seq 1 12); do
  if [[ "$($SSH 'sudo systemctl is-active kalari-api')" == "active" ]]; then
    break
  fi
  sleep 1
done
$SSH 'sudo systemctl is-active kalari-api'

say "== verify on the VM (loopback API)"
$SSH 'python3 - /tmp/frozen-evidence-upload.jsonl' <<'EOF'
import json
import sys
import urllib.request
with open(sys.argv[1], encoding="utf-8") as handle:
    shipped = [json.loads(line) for line in handle if line.strip()]
base = "http://127.0.0.1:18001"
def get(path):
    with urllib.request.urlopen(base + path, timeout=15) as resp:
        assert resp.status == 200, path
        return json.load(resp)
bench = get("/api/benchmark")
assert len(bench) == len(shipped) == 60, f"benchmark count {len(bench)}"
live_ids = {r["run_id"] for r in bench}
assert live_ids == {r["run_id"] for r in shipped}, "benchmark run ids differ from shipped"
assert all(r["payload"]["provenance"] == "frozen" for r in bench), "provenance must be frozen"
bad = []
for r in shipped:
    run = get(f"/api/runs/{r['run_id']}")
    if not any(x.get("run_id") == r["run_id"] for x in run):
        bad.append(r["run_id"])
assert not bad, f"runs missing: {bad}"
print(f"loopback ok: benchmark {len(bench)}, runs 60/60 resolve")
EOF

say "== verify from here (public demo URL)"
python3 - "$EVIDENCE" "$PUBLIC_URL" <<'EOF'
import json
import sys
import urllib.request
with open(sys.argv[1], encoding="utf-8") as handle:
    shipped = [json.loads(line) for line in handle if line.strip()]
base = sys.argv[2].rstrip("/")
def get(path):
    with urllib.request.urlopen(base + path, timeout=30) as resp:
        assert resp.status == 200, path
        return json.load(resp)
bench = get("/api/benchmark")
assert len(bench) == 60, f"public benchmark count {len(bench)}"
live = {r["run_id"]: r for r in bench}
assert set(live) == {r["run_id"] for r in shipped}, "public run ids differ from shipped"
bad = [rid for rid in live if not get(f"/api/runs/{rid}")]
assert not bad, f"public runs missing: {bad}"
nulls = sum(1 for r in bench if r["payload"]["arm"] == "kalari"
            and r["payload"]["sandbox_runs_against_v1"] is None
            and r["payload"]["sandbox_runs_against_v2"] is None)
assert nulls == 20, f"kalari unknown windows: {nulls}"
pairs = {(r["payload"]["upgrade"]) for r in bench
         if r["payload"]["provenance"] == "frozen" and r["payload"]["condition"] == 5} & \
        {(r["payload"]["upgrade"]) for r in bench
         if r["payload"]["provenance"] == "frozen" and r["payload"]["condition"] == 3}
assert pairs == {"payouts", "settlements"}, "frozen pair must cover both upgrades"
print(f"public ok: benchmark 60, runs 60/60 resolve, kalari unknown windows 20/20 null, frozen pairs: {sorted(pairs)}")
EOF

say "== cleanup upload"
$SSH 'rm -f /tmp/frozen-evidence-upload.jsonl'

say "shipped $SHIPPED frozen benchmark records; live checks passed"
