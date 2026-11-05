#!/usr/bin/env bash
# One reference-arm showcase session on the VM: OpenCode 2.2.5 with Microsandbox through
# microsandbox-mcp, exactly the frozen reference setup (same opencode.jsonc, same prompt file,
# fresh session, no notes). A lean adaptation of bench/harness/remote.sh for the showcase:
# no condition machinery and no retry journals (the showcase API has no B5).
# The inference key is the first line of stdin. It is exported for OpenCode and
# never written to a file, a command line, or this script's stdout.
set -euo pipefail
umask 022

REPEAT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeat) REPEAT=${2:?}; shift 2 ;;
    *) echo "unknown arg" >&2; exit 2 ;;
  esac
done
case "$REPEAT" in
  1|2|3|4|5) ;;
  *) echo "repeat must be 1..5" >&2; exit 2 ;;
esac

IFS= read -r VULTR_INFERENCE_API_KEY || true
if [[ ${#VULTR_INFERENCE_API_KEY} -lt 8 ]]; then
  echo "missing inference key on stdin" >&2
  exit 1
fi
export VULTR_INFERENCE_API_KEY

export PATH="$HOME/.local/bin:$PATH"
ROOT=$HOME/kalari-showcase-ref
STAGE=$ROOT/stage
RUN_ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
RUN=$ROOT/runs/$RUN_ID
mkdir -p "$RUN"

ver=$(opencode --version 2>/dev/null || true)
if [[ "$ver" != *2.2.5* ]]; then
  echo "opencode is not 2.2.5" >&2
  exit 1
fi

if ps -eo pid=,args= | grep -E '[o]pencode run|[r]emote\.sh|[r]emote-kalari\.sh|[r]emote-reference\.sh' | awk -v me="$$" '$1 != me' | grep -q .; then
  echo "another benchmark session is active; refusing to start" >&2
  exit 3
fi

IP=$(python3 - << 'PY'
import json, urllib.request
d = json.load(urllib.request.urlopen("http://169.254.169.254/v1.json", timeout=3))
print(d["interfaces"][0]["ipv4"]["address"])
PY
)
export KALARI_PUBLIC_IP=$IP
export KALARI_REDACT_KEY=$VULTR_INFERENCE_API_KEY

LIVE_PORT=18082
GRADE_PORT=18092
CONSUMER=disbursement_sync.py
WS_NAME=disbursement-sync

msb_names() { msb list 2>/dev/null | awk 'NR>1 && $1 != "" {print $1}'; }
protected() {
  case "$1" in
    api-payouts-live|api-payouts-grading|api-settlements-live|api-settlements-grading|api-disbursements-live|api-disbursements-grading) return 0 ;;
  esac
  return 1
}
remove_ours() {
  local n
  [[ -f "$RUN/sandboxes-before" ]] || return 0
  while read -r n; do
    [[ -z "$n" ]] && continue
    if grep -qx -- "$n" "$RUN/sandboxes-before"; then continue; fi
    if protected "$n"; then continue; fi
    echo "$n" >> "$RUN/sandboxes-removed"
    msb remove -f "$n" >/dev/null 2>&1 || echo "$n" >> "$RUN/sandboxes-remove-failed"
  done < <(msb_names)
}
proc_lines() { ps -eo pid=,args= | grep -E '[o]pencode|[m]icrosandbox-mcp' || true; }
kill_new_procs() {
  local pid killed=0
  [[ -f "$RUN/pids-before" ]] || return 0
  while read -r pid _; do
    [[ -z "${pid:-}" ]] && continue
    if grep -qx -- "$pid" "$RUN/pids-before"; then continue; fi
    echo "$pid" >> "$RUN/pids-killed"
    kill "$pid" 2>/dev/null || true
    killed=1
  done < <(proc_lines)
  [[ "$killed" == 1 ]] || return 0
  sleep 1
  while read -r pid _; do
    [[ -z "${pid:-}" ]] && continue
    if grep -qx -- "$pid" "$RUN/pids-before"; then continue; fi
    kill -9 "$pid" 2>/dev/null || true
  done < <(proc_lines)
}

cleanup() {
  local rc=$?
  set +e
  remove_ours
  kill_new_procs
  unset VULTR_INFERENCE_API_KEY
  unset KALARI_REDACT_KEY
  unset KALARI_PUBLIC_IP
  exit "$rc"
}
trap cleanup EXIT

msb_names > "$RUN/sandboxes-before"
proc_lines | awk '{print $1}' > "$RUN/pids-before"

echo "status=api" >&2
python3 - "$IP" << 'PY'
import sys, urllib.request, urllib.error
ip = sys.argv[1]
def status(url):
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        return type(e).__name__
checks = [
    ("live_v2", status(f"http://{ip}:18082/v2/disbursements?limit=1"), 200),
    ("grade_v2", status(f"http://{ip}:18092/v2/disbursements?limit=1"), 200),
    ("grade_v1", status(f"http://{ip}:18092/v1/disbursements"), 410),
]
print("status=api " + " ".join(f"{n}={got}" for n, got, _want in checks), file=sys.stderr)
bad = [n for n, got, want in checks if got != want]
sys.exit(1 if bad else 0)
PY

# Fresh session: its own XDG directories and its own workspace copy.
XDG_BASE=$RUN/xdg
WS=$RUN/workspace
export XDG_DATA_HOME=$XDG_BASE/data
export XDG_STATE_HOME=$XDG_BASE/state
export XDG_CACHE_HOME=$XDG_BASE/cache
export XDG_CONFIG_HOME=$XDG_BASE/config
mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
rm -rf "$WS"
mkdir -p "$WS"
cp -a "$STAGE/workspaces/$WS_NAME/." "$WS/"
cp "$STAGE/opencode.jsonc" "$WS/opencode.jsonc"
git -C "$WS" init -q
git -C "$WS" config user.email kalari-bench@localhost
git -C "$WS" config user.name kalari-bench
git -C "$WS" add -A
git -C "$WS" commit -qm "v1 consumer"

python3 - "$STAGE/prompts/upgrade.txt" "$RUN/prompt.txt" "http://$IP:$LIVE_PORT" << 'PY'
import sys
src, dest, base = sys.argv[1:4]
open(dest, "w").write(open(src).read().replace("{BASE_URL}", base))
PY

echo "status=session" >&2
cd "$WS"
args=(opencode run --standalone --format json --auto --title "showcase-reference")
args+=("$(cat "$RUN/prompt.txt")")
start=$(date +%s)
set +e
if command -v stdbuf >/dev/null; then
  stdbuf -oL -eL timeout --kill-after=15 1200 "${args[@]}" > "$RUN/events.jsonl" 2> "$RUN/opencode.stderr"
else
  timeout --kill-after=15 1200 "${args[@]}" > "$RUN/events.jsonl" 2> "$RUN/opencode.stderr"
fi
rc=$?
set -e
end=$(date +%s)
elapsed=$((end - start))
echo "status=session_exit:$rc elapsed:$elapsed" >&2

# Drop the key from the environment before grading.
export KALARI_REDACT_KEY
unset VULTR_INFERENCE_API_KEY

# Stop the arm's sandboxes and processes before the grading window opens,
# so grading traffic is only the grader's. remove_ours keeps the six API guests.
remove_ours
kill_new_procs

echo "status=grade:final" >&2
# One hidden-grader pass, as bench/harness/grade_one.sh runs it: only the output the
# consumer writes inside the fresh grading guest is copied out and graded.
GNAME="kalari-grade-final-$RUN_ID"
grade_failed=""
rm -f "$RUN/final.jsonl" "$RUN/final.status" "$RUN/final.consumer.log"
if ! msb create --name "$GNAME" --cpus 1 --memory 512M --pull never --no-net \
  --net-rule "allow@${IP}/32:tcp:${GRADE_PORT}" python >/dev/null; then
  grade_failed=create
elif ! msb exec "$GNAME" -- mkdir -p /w/src; then
  grade_failed=mkdir
elif ! tar -C "$WS" --exclude .git -czf "$RUN/final.tgz" .; then
  grade_failed=tar
elif ! msb copy -q "$RUN/final.tgz" "$GNAME:/w/src.tgz"; then
  grade_failed=copy
elif ! msb copy -q "$STAGE/grade_runner.py" "$GNAME:/w/grade_runner.py"; then
  grade_failed=copy-runner
elif ! msb exec "$GNAME" -- tar -C /w/src -xzf /w/src.tgz; then
  grade_failed=untar
fi
if [[ -n "$grade_failed" ]]; then
  echo "EXIT $grade_failed" > "$RUN/final.status"
else
  set +e
  timeout 150 msb exec "$GNAME" -- python3 /w/grade_runner.py "/w/src/${CONSUMER}" "http://${IP}:${GRADE_PORT}" "/w/out.jsonl" \
    > "$RUN/final.status" 2> "$RUN/final.err"
  set -e
  msb copy -q "$GNAME:/w/out.jsonl" "$RUN/final.jsonl" 2>/dev/null || true
  msb copy -q "$GNAME:/w/consumer.log" "$RUN/final.consumer.log" 2>/dev/null || true
fi
msb remove -f "$GNAME" >/dev/null 2>&1 || true
rm -f "$RUN/final.tgz"

python3 - "$STAGE/grader/grade.py" "$RUN/final.jsonl" "$RUN/final.grade.json" << 'PY' || true
import json, subprocess, sys
grader, out_path, dest = sys.argv[1:4]
proc = subprocess.run(["python3", grader, out_path], capture_output=True, text=True)
try:
    doc = json.loads(proc.stdout)
except ValueError:
    doc = {"verdict": "ERROR", "stderr": proc.stderr[-500:]}
open(dest, "w").write(json.dumps(doc, indent=2) + "\n")
PY

echo "status=cleanup" >&2
remove_ours
kill_new_procs
python3 - "$RUN" << 'PY'
import json, os, subprocess, sys
run = sys.argv[1]
before = set(open(os.path.join(run, "sandboxes-before")).read().split())
protected = {"api-payouts-live", "api-payouts-grading", "api-settlements-live", "api-settlements-grading",
             "api-disbursements-live", "api-disbursements-grading"}
now = subprocess.run(["msb", "list"], capture_output=True, text=True).stdout.splitlines()[1:]
names = [line.split()[0] for line in now if line.split()]
left = [n for n in names if n not in before and n not in protected]
pids_before = set(open(os.path.join(run, "pids-before")).read().split())
ps = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True, text=True).stdout.splitlines()
procs = []
for line in ps:
    parts = line.split(None, 1)
    if len(parts) < 2:
        continue
    pid, args = parts
    if pid in pids_before:
        continue
    if "opencode" in args or "microsandbox-mcp" in args:
        procs.append("microsandbox-mcp" if "microsandbox-mcp" in args else "opencode")
removed = []
path = os.path.join(run, "sandboxes-removed")
if os.path.exists(path):
    removed = [n for n in open(path).read().split() if n]
seen = []
for n in removed:
    if n not in seen:
        seen.append(n)
json.dump({"sandboxes_removed": seen, "sandboxes_left": left, "processes_left": procs},
          open(os.path.join(run, "cleanup.json"), "w"))
PY

python3 - "$RUN" "$REPEAT" "$ver" "$LIVE_PORT" "$GRADE_PORT" "$elapsed" "$rc" << 'PY'
import json, os, sys
run, repeat, ver, live, grade, elapsed, rc = sys.argv[1:8]
doc = {
    "arm": "reference",
    "upgrade": "disbursements",
    "repeat": int(repeat),
    "setup": "OpenCode 2.2.5 with Microsandbox through microsandbox-mcp (the frozen reference setup), no Kalari",
    "api_base": "the VM's public address",
    "live_port": int(live),
    "grading_port": int(grade),
    "prompt": "upgrade.txt",
    "opencode_version": ver.strip(),
    "session_cap_s": 1200,
    "wall_time_s": int(elapsed),
    "opencode_exit": int(rc),
}
grade_path = os.path.join(run, "final.grade.json")
if os.path.exists(grade_path):
    doc["grade"] = json.load(open(grade_path))
else:
    doc["grade"] = {"verdict": "NOT_RUN"}
status_path = os.path.join(run, "final.status")
if os.path.exists(status_path):
    doc["grader_status"] = open(status_path, errors="replace").read().strip()[:200]
log_path = os.path.join(run, "final.consumer.log")
if os.path.exists(log_path):
    text = open(log_path, errors="replace").read()[-1500:]
    key = os.environ.get("KALARI_REDACT_KEY", "")
    ip = os.environ.get("KALARI_PUBLIC_IP", "")
    if key:
        text = text.replace(key, "[redacted]")
    if ip:
        text = text.replace(ip, "the VM's public address")
    doc["consumer_log_excerpt"] = text
cleanup_path = os.path.join(run, "cleanup.json")
if os.path.exists(cleanup_path):
    doc["cleanup"] = json.load(open(cleanup_path))
open(os.path.join(run, "analysis.json"), "w").write(json.dumps(doc, indent=2) + "\n")
PY

# Stdout is the run id only. The address stays on the VM.
echo "KALARI_RUN $RUN_ID"
