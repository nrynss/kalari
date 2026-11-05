#!/usr/bin/env bash
# Publish the deliberate containment demonstration to the demo deployment.
#
# This changes the public deployment. It is run by whoever approves that change,
# never by a test or by the gate. It does two things and nothing else:
#
#   1. appends this directory's evidence.jsonl (the sanitised run, check and
#      containment records, session containment-demo) to the VM's evidence store,
#      once: a second run finds the run id and appends nothing;
#   2. refreshes the static site from web/site/ so the judges page can draw the
#      containment panel and the run page can show its evidence.
#
# It does not restart a service, touch the Lambo store, the benchmark sandboxes
# or any key, and it deletes nothing but files that left web/site/.
#
#   tests/live/containment-evidence/publish.sh --check    validate the evidence file; no network
#   tests/live/containment-evidence/publish.sh --apply    do steps 1 and 2 over ssh
#
# HOST is the ssh alias of the VM (default: kalari). SITE, when set to the
# public base address, makes --apply finish by fetching the run page's API route
# and the judges page; leave it unset to skip that.
set -euo pipefail
umask 022
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../../.." && pwd)
evidence="${EVIDENCE:-$here/evidence.jsonl}"
: "${HOST:=kalari}"
store=/var/lib/kalari/evidence/.kalari/evidence.jsonl
mode=${1:-}

check_evidence() {
  [[ -f "$evidence" ]] || { echo "no evidence file: $evidence" >&2; return 1; }
  python3 -I - "$evidence" <<'PY'
import json, re, sys
ip = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
bad = [re.compile(p) for p in (r"https?://", r"(?i)api[_-]?key", r"(?i)bearer\s", r"BEGIN [A-Z ]*PRIVATE KEY")]
kinds, runs = [], set()
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    if not line.endswith("\n"):
        raise SystemExit(f"line {n} is not newline-terminated")
    r = json.loads(line)
    if r.get("session_id") != "containment-demo":
        raise SystemExit(f"line {n}: session is not containment-demo")
    if r.get("kind") not in ("run", "check", "containment"):
        raise SystemExit(f"line {n}: unexpected kind {r.get('kind')!r}")
    if ip.search(line) or any(p.search(line) for p in bad):
        raise SystemExit(f"line {n}: an address, URL or key pattern is present")
    kinds.append(r["kind"]); runs.add(r["run_id"])
if kinds.count("containment") != 1 or kinds.count("run") != 1 or len(runs) != 1:
    raise SystemExit("expected one run, one or more check and one containment record for one run id")
print("evidence ok:", ", ".join(sorted(set(kinds))), "for run", runs.pop())
PY
}

case "$mode" in
  --check) check_evidence ;;
  --apply)
    check_evidence
    run_id=$(python3 -I -c 'import json,sys; print(next(json.loads(l)["run_id"] for l in open(sys.argv[1])))' "$evidence")
    echo "== append the evidence to the store, once"
    # shellcheck disable=SC2029
    ssh "$HOST" "set -euo pipefail
      sudo test -f $store
      if [ -n \"\$(sudo tail -c1 $store)\" ]; then echo 'store does not end with a newline; stopping' >&2; exit 1; fi
      if sudo grep -q '\"run_id\":\"$run_id\"' $store; then echo 'run already in the store; appending nothing'; exit 0; fi"
    if ! ssh "$HOST" "sudo grep -q '\"run_id\":\"$run_id\"' $store"; then
      ssh "$HOST" "sudo -u kalari tee -a $store >/dev/null" <"$evidence"
      echo "appended $(wc -l <"$evidence") records"
    fi
    echo "== refresh the static site"
    rsync -az --delete "$repo/web/site/" "$HOST:kalari-site/"
    ssh "$HOST" 'set -euo pipefail; sudo rsync -a --delete "$HOME/kalari-site/" /srv/kalari/www/; sudo chmod -R a+rX /srv/kalari/www'
    if [[ -n "${SITE:-}" ]]; then
      echo "== reachability"
      curl -fsS "$SITE/api/runs/$run_id" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print("run route:", sorted({x["kind"] for x in r}))'
      curl -fsS "$SITE/api/sessions/containment-demo" >/dev/null && echo "session route: ok"
      curl -fsS -o /dev/null -w 'run page shell: %{http_code}\n' "$SITE/run.html?id=$run_id"
      curl -fsS "$SITE/" | grep -c 'app/judges.mjs' >/dev/null && echo "judges page shell: ok"
    else
      echo "SITE not set; fetch /api/runs/$run_id, /api/sessions/containment-demo and the judges and run pages yourself."
    fi
    ;;
  *) echo 'usage: publish.sh --check | --apply' >&2; exit 2 ;;
esac
