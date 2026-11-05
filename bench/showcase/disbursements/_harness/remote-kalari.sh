#!/usr/bin/env bash
# One Kalari-arm showcase session on the VM.
# An adapted copy of bench/runs/kalari/_harness/remote-kalari.sh: the suite is fixed to
# disbursements (ports 18082/18092, guests api-disbursements-*), the Lambo store is always
# fresh, and there is no retry-journal plumbing (the showcase API has no B5).
# The inference key is the first line of stdin. It is exported for OpenCode and
# never written to a file, a command line, or this script's stdout.
set -euo pipefail
umask 022

REPEAT=""
TIMEOUT=600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeat) REPEAT=${2:?}; shift 2 ;;
    --timeout) TIMEOUT=${2:?}; shift 2 ;;
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
T54=$HOME/kalari-showcase
BIN=$T54/bin
STAGE=$T54/stage
HARNESS=$STAGE/bench/showcase/disbursements/_harness
RUN_ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
RUN=$T54/runs/$RUN_ID
mkdir -p "$RUN"

ver=$(opencode --version 2>/dev/null || true)
if [[ "$ver" != *2.2.5* ]]; then
  echo "opencode is not 2.2.5" >&2
  exit 1
fi
for bin in kalari kalari-aashaan msb vimanam lambo rg; do
  [[ -x "$BIN/$bin" ]] || { echo "missing $bin in $BIN" >&2; exit 1; }
done
[[ -f "$HARNESS/runner.py" ]] || { echo "harness not staged" >&2; exit 1; }

# Mutual exclusion: never start while another benchmark session runs.
# (ps prints pid,args so our own line can be dropped by PID.)
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
WS_NAME=disbursement-sync
LIVE_GUEST=api-disbursements-live
GRADE_GUEST=api-disbursements-grading
STORE=$T54/stores/r${REPEAT}
rm -rf "$STORE"
mkdir -p "$STORE"

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

echo "status=session" >&2
set +e
printf '%s\n' "$VULTR_INFERENCE_API_KEY" | python3 "$HARNESS/runner.py" --live \
  --tools "$BIN" \
  --opencode "$(command -v opencode)" \
  --workspace-source "$STAGE/bench/showcase/disbursements/workspace/$WS_NAME" \
  --api-host "$IP" --api-port "$LIVE_PORT" --grade-port "$GRADE_PORT" \
  --suite disbursements --lambo-db "$STORE/lambo.db" --repo-scope "showcase-r${REPEAT}" \
  --result "$RUN/result" --timeout "$TIMEOUT" \
  > "$RUN/runner.out" 2> "$RUN/runner.err"
runner_rc=$?
set -e
echo "status=runner_exit:$runner_rc" >&2
unset VULTR_INFERENCE_API_KEY

remove_ours
kill_new_procs

echo "status=result" >&2
python3 - "$RUN/result" << 'PY'
import json, sys
res = sys.argv[1]
try:
    doc = json.load(open(res + "/measures.json"))
except Exception as e:
    print(f"no measures: {e}", file=sys.stderr)
    raise SystemExit(1)
PY

python3 - "$RUN" << 'PY'
import json, subprocess, sys
run = sys.argv[1]
before = set(open(run + "/sandboxes-before").read().split())
protected = {"api-payouts-live", "api-payouts-grading", "api-settlements-live", "api-settlements-grading",
             "api-disbursements-live", "api-disbursements-grading"}
now = subprocess.run(["msb", "list"], capture_output=True, text=True).stdout.splitlines()[1:]
names = [line.split()[0] for line in now if line.split()]
left = [n for n in names if n not in before and n not in protected]
pids_before = set(open(run + "/pids-before").read().split())
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
import os
path = os.path.join(run, "sandboxes-removed")
if os.path.exists(path):
    removed = [n for n in open(path).read().split()]
seen = []
for n in removed:
    if n not in seen:
        seen.append(n)
json.dump({"sandboxes_removed": seen, "sandboxes_left": left, "processes_left": procs},
          open(run + "/cleanup.json", "w"))
import shutil
shutil.copyfile(run + "/cleanup.json", run + "/result/cleanup.json")
PY

# Stdout is the run id only. The address stays on the VM.
python3 - "$RUN/result" "4" "disbursements" "$REPEAT" "$RUN_ID" "$ver" "$LIVE_PORT" "$GRADE_PORT" "$TIMEOUT" << 'PY'
import json, sys
res, cond, upgrade, repeat, run_id, ver, live, grade, cap = sys.argv[1:10]
json.dump({"condition": int(cond), "upgrade": upgrade, "repeat": int(repeat),
           "run_id": run_id, "opencode_version": ver.strip(),
           "live_port": int(live), "grading_port": int(grade),
           "prompt": "upgrade.txt", "repo_scope": f"showcase-r{repeat}",
           "session_cap_s": int(cap)},
          open(res + "/meta.json", "w"), indent=2)
PY
echo "KALARI_RUN $RUN_ID"
