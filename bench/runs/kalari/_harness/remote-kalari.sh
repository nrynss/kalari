#!/usr/bin/env bash
# One Kalari-arm session on the VM (conditions 4/5).
# The inference key is the first line of stdin. It is exported for OpenCode and
# never written to a file, a command line, or this script's stdout.
set -euo pipefail
umask 022

COND=""
UPGRADE=""
REPEAT=""
TIMEOUT=600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --condition) COND=${2:?}; shift 2 ;;
    --upgrade) UPGRADE=${2:?}; shift 2 ;;
    --repeat) REPEAT=${2:?}; shift 2 ;;
    --timeout) TIMEOUT=${2:?}; shift 2 ;;
    *) echo "unknown arg" >&2; exit 2 ;;
  esac
done
case "$COND" in
  4|5) ;;
  *) echo "condition must be 4 or 5" >&2; exit 2 ;;
esac
case "$UPGRADE" in
  payouts|settlements) ;;
  *) echo "upgrade must be payouts or settlements" >&2; exit 2 ;;
esac
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
T54=$HOME/kalari-t54
BIN=$T54/bin
STAGE=$T54/stage
HARNESS=$STAGE/bench/runs/kalari/_harness
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
if ps -eo pid=,args= | grep -E '[o]pencode run|[r]emote\.sh|[r]emote-kalari\.sh' | awk -v me="$$" '$1 != me' | grep -q .; then
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

if [[ "$UPGRADE" == payouts ]]; then
  LIVE_PORT=18080
  GRADE_PORT=18090
  WS_NAME=payout-sync
  LIVE_GUEST=api-payouts-live
  GRADE_GUEST=api-payouts-grading
else
  LIVE_PORT=18081
  GRADE_PORT=18091
  WS_NAME=settlement-reconcile
  LIVE_GUEST=api-settlements-live
  GRADE_GUEST=api-settlements-grading
fi
STORE=$T54/stores/c${COND}-r${REPEAT}
if [[ "$COND" == 4 || "$UPGRADE" == payouts ]]; then
  rm -rf "$STORE"
  mkdir -p "$STORE"
  FRESH_STORE=1
else
  if [[ ! -f "$STORE/lambo.db" ]]; then
    echo "condition 5 settlements needs repeat $REPEAT payouts store; none found" >&2
    exit 1
  fi
  FRESH_STORE=0
fi

msb_names() { msb list 2>/dev/null | awk 'NR>1 && $1 != "" {print $1}'; }
protected() {
  case "$1" in
    api-payouts-live|api-payouts-grading|api-settlements-live|api-settlements-grading) return 0 ;;
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
python3 - "$IP" "$UPGRADE" << 'PY'
import sys, urllib.request, urllib.error
ip, upgrade = sys.argv[1], sys.argv[2]
def status(url, data=None):
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        return type(e).__name__
if upgrade == "payouts":
    live, grade = 18080, 18090
    checks = [
        ("live_v2", status(f"http://{ip}:{live}/v2/payouts?limit=1"), 200),
        ("grade_v2", status(f"http://{ip}:{grade}/v2/payouts?limit=1"), 200),
        ("grade_v1", status(f"http://{ip}:{grade}/v1/payouts"), 410),
    ]
else:
    live, grade = 18081, 18091
    q = b'{"query":"{ __typename }"}'
    checks = [
        ("live_v2", status(f"http://{ip}:{live}/v2/graphql", q), 200),
        ("grade_v2", status(f"http://{ip}:{grade}/v2/graphql", q), 200),
        ("grade_v1", status(f"http://{ip}:{grade}/v1/graphql", q), 410),
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
  --workspace-source "$STAGE/bench/workspaces/$WS_NAME" \
  --api-host "$IP" --api-port "$LIVE_PORT" --grade-port "$GRADE_PORT" \
  --suite "$UPGRADE" --lambo-db "$STORE/lambo.db" --repo-scope "c${COND}-r${REPEAT}" \
  --retry-tool "$HARNESS/retry_journal.py" --retry-live "$LIVE_GUEST" --retry-grading "$GRADE_GUEST" \
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
protected = {"api-payouts-live", "api-payouts-grading", "api-settlements-live", "api-settlements-grading"}
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
PY

# Stdout is the run id only. The address stays on the VM.
python3 - "$RUN/result" "$COND" "$UPGRADE" "$REPEAT" "$RUN_ID" "$ver" "$LIVE_PORT" "$GRADE_PORT" "$TIMEOUT" << 'PY'
import json, sys
res, cond, upgrade, repeat, run_id, ver, live, grade, cap = sys.argv[1:10]
json.dump({"condition": int(cond), "upgrade": upgrade, "repeat": int(repeat),
           "run_id": run_id, "opencode_version": ver.strip(),
           "live_port": int(live), "grading_port": int(grade),
           "prompt": "upgrade.txt", "repo_scope": f"c{cond}-r{repeat}",
           "session_cap_s": int(cap)},
          open(res + "/meta.json", "w"), indent=2)
PY
echo "KALARI_RUN $RUN_ID"
