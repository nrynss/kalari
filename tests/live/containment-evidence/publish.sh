#!/usr/bin/env bash
# Publish the two containment runs to the public deployment.
#
# This changes the public deployment. It is run by whoever approves that change,
# never by a test or by the gate. It does two things and nothing else:
#
#   1. appends each run's records (run-1.jsonl, run-2.jsonl in this directory:
#      the run, check and containment records, session containment-runs) to the
#      VM's evidence store. Idempotent by run id: a run already in the store is
#      skipped, so a second --apply appends nothing;
#   2. refreshes the static site from web/site/ so the judges page can draw the
#      containment panel and the run pages can show their evidence.
#
# It does not restart a service, touch the Lambo store, the benchmark sandboxes
# or any key, and it deletes nothing but files that left web/site/.
#
# NEVER run it at the same moment as deploy/vultr/ship-evidence.sh. Both change
# the store: ship-evidence.sh reads it and replaces the whole file, keeping every
# non-benchmark record, so an append made between its read and its replace is
# lost. Run one, wait for it to finish, then the other. In either order the
# result is the same: the 60 benchmark records and these records, nothing else
# disturbed.
#
#   tests/live/containment-evidence/publish.sh --check    validate the evidence; no network
#   tests/live/containment-evidence/publish.sh --apply    do steps 1 and 2 over ssh
#
# HOST is the ssh alias of the VM (default: kalari). SITE, when set to the
# public base address, makes --apply finish by fetching each run's API route.
set -euo pipefail
umask 022
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
: "${HOST:=kalari}"
store=/var/lib/kalari/evidence/.kalari/evidence.jsonl
mode=${1:-}
files=("$here"/run-*.jsonl)
[[ -n "${EVIDENCE_FILES:-}" ]] && read -r -a files <<<"$EVIDENCE_FILES"

check_evidence() {
  python3 -I - "${files[@]}" <<'PY'
import json, re, sys
ip = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
bad = [re.compile(p) for p in (r"https?://", r"(?i)api[_-]?key", r"(?i)bearer\s", r"BEGIN [A-Z ]*PRIVATE KEY", r"(?i)demonstration|deliberate")]
all_runs, stopped = set(), 0
for path in sys.argv[1:]:
    kinds, runs = [], set()
    try:
        lines = open(path, encoding="utf-8").readlines()
    except OSError:
        raise SystemExit(f"cannot read {path}")
    for n, line in enumerate(lines, 1):
        if not line.endswith("\n"):
            raise SystemExit(f"{path} line {n} is not newline-terminated")
        r = json.loads(line)
        if r.get("session_id") != "containment-runs":
            raise SystemExit(f"{path} line {n}: session is not containment-runs")
        if r.get("kind") not in ("run", "check", "containment"):
            raise SystemExit(f"{path} line {n}: unexpected kind {r.get('kind')!r}")
        if ip.search(line) or any(p.search(line) for p in bad):
            raise SystemExit(f"{path} line {n}: an address, URL, key pattern or label this test does not use")
        kinds.append(r["kind"]); runs.add(r["run_id"])
        if r["kind"] == "containment" and r["payload"]["result"]["verdict"] == "killed_timeout":
            stopped += 1
    if kinds.count("containment") != 1 or kinds.count("run") != 1 or len(runs) != 1:
        raise SystemExit(f"{path}: expected one run, its checks and one containment record for one run id")
    if runs & all_runs:
        raise SystemExit(f"{path}: run id repeated across files")
    all_runs |= runs
if len(sys.argv) < 3:
    raise SystemExit("expected two runs (run-1.jsonl and run-2.jsonl)")
if stopped != 1:
    raise SystemExit("exactly one run must have been stopped by the time cap")
print("evidence ok:", len(sys.argv) - 1, "runs,", ", ".join(sorted(all_runs)))
PY
}

case "$mode" in
  --check) check_evidence ;;
  --apply)
    check_evidence
    ssh "$HOST" "set -euo pipefail
      sudo test -f $store
      if [ -n \"\$(sudo tail -c1 $store)\" ]; then echo 'store does not end with a newline; stopping' >&2; exit 1; fi"
    run_ids=()
    for f in "${files[@]}"; do
      run_id=$(python3 -I -c 'import json,sys; print(next(json.loads(l)["run_id"] for l in open(sys.argv[1])))' "$f")
      run_ids+=("$run_id")
      echo "== $run_id: append once"
      if ssh "$HOST" "sudo grep -q '\"run_id\":\"$run_id\"' $store"; then
        echo "already in the store; appending nothing"
      else
        ssh "$HOST" "sudo -u kalari tee -a $store >/dev/null" <"$f"
        echo "appended $(wc -l <"$f") records"
      fi
    done
    echo "== refresh the static site"
    rsync -az --delete "$repo/web/site/" "$HOST:kalari-site/"
    ssh "$HOST" 'set -euo pipefail; sudo rsync -a --delete "$HOME/kalari-site/" /srv/kalari/www/; sudo chmod -R a+rX /srv/kalari/www'
    if [[ -n "${SITE:-}" ]]; then
      echo "== reachability"
      for run_id in "${run_ids[@]}"; do
        curl -fsS "$SITE/api/runs/$run_id" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print("run route:", sorted({x["kind"] for x in r}))'
        curl -fsS -o /dev/null -w "run page shell: %{http_code}\n" "$SITE/run.html?id=$run_id"
      done
      curl -fsS "$SITE/api/sessions/containment-runs" >/dev/null && echo "session route: ok"
      curl -fsS "$SITE/api/benchmark" | python3 -I -c 'import json,sys; print("benchmark records still served:", len(json.load(sys.stdin)))'
    else
      echo "SITE not set; fetch each run's /api/runs/<id>, /api/sessions/containment-runs and the judges page yourself."
    fi
    ;;
  *) echo 'usage: publish.sh --check | --apply' >&2; exit 2 ;;
esac
