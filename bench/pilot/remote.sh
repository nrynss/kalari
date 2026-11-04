#!/usr/bin/env bash
# One reference-arm session on the VM.
# The inference key is the first line of stdin. It is exported for OpenCode and
# never written to a file, a command line, or this script's stdout.
set -euo pipefail
umask 022

COND=""
UPGRADE=""
BEHAVIOUR=""
PREFLIGHT_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --condition) COND=${2:?}; shift 2 ;;
    --upgrade) UPGRADE=${2:?}; shift 2 ;;
    --behaviour) BEHAVIOUR=${2:?}; shift 2 ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    *) echo "unknown arg" >&2; exit 2 ;;
  esac
done
case "$COND" in
  1|2|3|6) ;;
  *) echo "condition must be 1, 2, 3, or 6" >&2; exit 2 ;;
esac
case "$UPGRADE" in
  payouts|settlements) ;;
  *) echo "upgrade must be payouts or settlements" >&2; exit 2 ;;
esac

case "$UPGRADE:$BEHAVIOUR" in
  payouts:B1|payouts:B2|payouts:B4|settlements:B1|settlements:B2|settlements:B3) ;;
  *) echo "invalid variant" >&2; exit 2 ;;
esac
[[ "$COND" == 3 ]] || { echo "variants require condition 3" >&2; exit 2; }
IFS= read -r VULTR_INFERENCE_API_KEY || true
if [[ ${#VULTR_INFERENCE_API_KEY} -lt 8 ]]; then
  echo "missing inference key on stdin" >&2
  exit 1
fi
export VULTR_INFERENCE_API_KEY

export PATH="$HOME/.local/bin:$PATH"
ROOT=$HOME/kalari-pilot-isolated
STAGE=$ROOT/stage
RUN_ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
RUN=$ROOT/runs/$RUN_ID
mkdir -p "$RUN"

ver=$(opencode --version 2>/dev/null || true)
if [[ "$ver" != *2.2.5* ]]; then
  echo "opencode is not 2.2.5" >&2
  exit 1
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
  LIVE_PORT=19121
  GRADE_PORT=19122
  CONSUMER=payout_sync.py
  WS_NAME=payout-sync
  OUT_NAME=payouts.jsonl
else
  LIVE_PORT=19121
  GRADE_PORT=19122
  CONSUMER=settlement_reconcile.py
  WS_NAME=settlement-reconcile
  OUT_NAME=settlements.jsonl
fi

# Only these unique names are ever removed by this run.
API_LIVE=kalari-pilot-live${RUN_ID}
API_GRADE=kalari-pilot-grade${RUN_ID}
GUEST=kalari-pilot-${RUN_ID}
SESSION_PID=""
SCOPE="kalari-pilot-${RUN_ID}.scope"
SCOPE_STARTED=0
SCOPE_GROUP=""
OWNED=()
stop_scope() {
  [[ "$SCOPE_STARTED" == 1 ]] || return 0
  local group
  group=${SCOPE_GROUP:-$(systemctl --user show "$SCOPE" -p ControlGroup --value 2>/dev/null || true)}
  if ! systemctl --user stop "$SCOPE" >/dev/null 2>&1; then
    local state
    state=$(systemctl --user show "$SCOPE" -p LoadState --value 2>/dev/null) || return 1
    [[ "$state" == not-found ]] || return 1
  fi
  if [[ -n "$group" && -s "/sys/fs/cgroup${group}/cgroup.procs" ]]; then
    echo "owned process scope survived" >&2
    return 1
  fi
  SCOPE_STARTED=0
}
cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  stop_scope || echo "scope cleanup failed" >&2
  for n in "${OWNED[@]}"; do msb remove -f "$n" >/dev/null 2>&1 || true; done
  unset VULTR_INFERENCE_API_KEY KALARI_REDACT_KEY KALARI_PUBLIC_IP
  exit "$rc"
}
trap cleanup EXIT
for n in "$GUEST" "$API_LIVE" "$API_GRADE"; do
  if msb list | awk 'NR>1 {print $1}' | grep -Fxq "$n"; then echo "sandbox name collision" >&2; exit 1; fi
done
if [[ $(systemctl --user show "$SCOPE" -p LoadState --value 2>/dev/null || true) == loaded ]]; then
  echo "scope name collision" >&2; exit 1
fi
for port in "$LIVE_PORT" "$GRADE_PORT"; do
  if ss -ltn | awk '{print $4}' | grep -q ":${port}$"; then echo "pilot port occupied" >&2; exit 1; fi
done
start_api() {
  local name=$1 port=$2 v1=$3
  msb create --name "$name" --cpus 1 --memory 256M --pull never --net-default-egress deny -p "$IP:$port:8080" python >/dev/null
  OWNED+=("$name")
  msb exec "$name" -- mkdir -p /srv
  msb copy -q "$STAGE/apis/$UPGRADE/server.py" "$name:/srv/server.py"
  msb copy -q "$STAGE/apis/$UPGRADE/data.py" "$name:/srv/data.py"
  if [[ "$UPGRADE" == settlements ]]; then
    msb copy -q "$STAGE/apis/vendor/graphql_core-3.3.1-py3-none-any.whl" "$name:/srv/graphql_core-3.3.1-py3-none-any.whl"
  fi
  msb exec "$name" -- sh -c "nohup python3 -I /srv/server.py --bind 0.0.0.0 --port 8080 --v1 $v1 --behaviours $BEHAVIOUR >/srv/server.log 2>&1 </dev/null &"
}
start_api "$API_LIVE" "$LIVE_PORT" on
start_api "$API_GRADE" "$GRADE_PORT" off
msb create --name "$GUEST" --cpus 1 --memory 256M --pull never --no-net \
  --net-rule "allow@${IP}/32:tcp:${LIVE_PORT}" python >/dev/null
OWNED+=("$GUEST")
msb exec "$GUEST" -- mkdir -p /workspace
export KALARI_PILOT_GUEST="$GUEST"

echo "status=api" >&2
# Readiness polling is bounded; no inference is performed here.
for _ in $(seq 1 50); do
  if curl -s --max-time 2 "http://$IP:$LIVE_PORT/" >/dev/null && curl -s --max-time 2 "http://$IP:$GRADE_PORT/" >/dev/null; then break; fi
  sleep .2
done
python3 - "$IP" "$UPGRADE" "$LIVE_PORT" "$GRADE_PORT" << 'PY'
import sys, urllib.request, urllib.error
ip, upgrade, live, grade = sys.argv[1:5]

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
    checks = [
        ("live_v2", status(f"http://{ip}:{live}/v2/payouts?limit=1"), 200),
        ("grade_v2", status(f"http://{ip}:{grade}/v2/payouts?limit=1"), 200),
        ("grade_v1", status(f"http://{ip}:{grade}/v1/payouts"), 410),
    ]
else:
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

# Condition 1 reuses one OpenCode session and one data directory across upgrades.
SESSION_ID=""
SESSION_CONTINUED=0
XDG_BASE=$RUN/xdg
if [[ "$COND" == 1 && "$UPGRADE" == payouts ]]; then
  rm -rf "$ROOT/state/condition-1-xdg" "$ROOT/state/condition-1.json"
  XDG_BASE=$ROOT/state/condition-1-xdg
elif [[ "$COND" == 1 && "$UPGRADE" == settlements && -f "$ROOT/state/condition-1.json" ]]; then
  XDG_BASE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["xdg"])' "$ROOT/state/condition-1.json")
  SESSION_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["session_id"])' "$ROOT/state/condition-1.json")
  SESSION_CONTINUED=1
fi
export XDG_DATA_HOME=$XDG_BASE/data
export XDG_STATE_HOME=$XDG_BASE/state
export XDG_CACHE_HOME=$XDG_BASE/cache
export XDG_CONFIG_HOME=$XDG_BASE/config
mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"

WS=$RUN/workspace
rm -rf "$WS"
mkdir -p "$WS"
cp -a "$STAGE/workspaces/$WS_NAME/." "$WS/"
python3 - "$STAGE/opencode.jsonc" "$WS/opencode.jsonc" "$STAGE/mcp_shim.py" <<'PYCONFIG'
import json, sys
src, dst, shim = sys.argv[1:]
s = open(src).read().replace('["npx", "-y", "microsandbox-mcp@0.7.13"]', json.dumps(["env", "-u", "VULTR_INFERENCE_API_KEY", "-u", "KALARI_REDACT_KEY", "python3", shim]))
if s == open(src).read(): raise SystemExit('MCP configuration mismatch')
open(dst, 'w').write(s)
PYCONFIG
export KALARI_PILOT_WORKSPACE="$WS"
NOTES_ATTACHED=0
if [[ "$COND" == 2 && "$UPGRADE" == settlements && -d "$ROOT/state/condition-2-notes" ]]; then
  if find "$ROOT/state/condition-2-notes" -type f | grep -q .; then
    mkdir -p "$WS/notes-from-upgrade-one"
    cp -a "$ROOT/state/condition-2-notes/." "$WS/notes-from-upgrade-one/"
    NOTES_ATTACHED=1
  fi
fi
git -C "$WS" init -q
git -C "$WS" config user.email kalari-bench@localhost
git -C "$WS" config user.name kalari-bench
git -C "$WS" add -A
git -C "$WS" commit -qm "v1 consumer"

PROMPT_NAME=upgrade.txt
if [[ "$COND" == 6 ]]; then PROMPT_NAME=condition-6.txt; fi
python3 - "$STAGE/prompts/$PROMPT_NAME" "$RUN/prompt.txt" "http://$IP:$LIVE_PORT" "$NOTES_ATTACHED" << 'PY'
import sys
src, dest, base, notes = sys.argv[1:5]
text = open(src).read().replace("{BASE_URL}", base)
if notes == "1":
    text = text.rstrip() + "\n\nNotes from the earlier upgrade are in notes-from-upgrade-one/.\n"
open(dest, "w").write(text)
PY

echo "status=preflight" >&2
# Same network shape as the hidden grader: no default egress, one allow rule for the grading API.
# A guest that runs the aashaan would also need vm.overcommit_memory=1. This probe does not.
PRE=kalari-preflight-$RUN_ID
msb create --name "$PRE" --cpus 1 --memory 256M --pull never --no-net \
  --net-rule "allow@${IP}/32:tcp:${GRADE_PORT}" python >/dev/null
cat > "$RUN/preflight.py" << 'PY'
import sys, time, urllib.request, urllib.error
ip, upgrade, port = sys.argv[1], sys.argv[2], sys.argv[3]
if upgrade == "payouts":
    url = f"http://{ip}:{port}/v2/payouts?limit=1"
    data = None
    headers = {}
else:
    url = f"http://{ip}:{port}/v2/graphql"
    data = b'{"query":"{ __typename }"}'
    headers = {"Content-Type": "application/json"}
last = "none"
for _ in range(20):
    try:
        req = urllib.request.Request(url, data=data, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as r:
            print("STATUS", r.status)
            sys.exit(0 if r.status == 200 else 1)
    except urllib.error.HTTPError as e:
        print("STATUS", e.code)
        sys.exit(1)
    except Exception as e:
        last = type(e).__name__
        time.sleep(0.4)
print("FAIL", last)
sys.exit(1)
PY
OWNED+=("$PRE")
msb exec "$PRE" -- mkdir -p /w
msb copy -q "$RUN/preflight.py" "$PRE:/w/preflight.py"
set +e
msb exec "$PRE" -- python3 /w/preflight.py "$IP" "$UPGRADE" "$GRADE_PORT" > "$RUN/preflight.out" 2> "$RUN/preflight.err"
pre_rc=$?
set -e
msb remove -f "$PRE" >/dev/null 2>&1 || true
if [[ "$pre_rc" != 0 ]] || ! grep -q "STATUS 200" "$RUN/preflight.out"; then
  echo "status=preflight_failed" >&2
  exit 1
fi
echo "status=preflight_ok" >&2
if [[ "$PREFLIGHT_ONLY" == 1 ]]; then
  # Check both dedicated endpoints against their characteristic consumer.
  case "$UPGRADE:$BEHAVIOUR" in
    payouts:B1|settlements:B1) ref=cursor_loop; expected=TIMEOUT ;;
    payouts:B2|settlements:B2) ref=no_dedupe; expected=FAIL ;;
    payouts:B4) ref=short_page_stop; expected=FAIL ;;
    settlements:B3) ref=empty_page_stop; expected=FAIL ;;
  esac
  for port in "$LIVE_PORT" "$GRADE_PORT"; do
    rc=0
    timeout 8 python3 -I "$STAGE/apis/$UPGRADE/reference/$ref.py" --base-url "http://$IP:$port" --out "$RUN/variant.jsonl" >/dev/null 2>&1 || rc=$?
    if [[ "$expected" == TIMEOUT ]]; then
      [[ "$rc" == 124 ]] || { echo "variant check failed" >&2; exit 1; }
    else
      [[ "$rc" == 0 ]] || { echo "variant consumer crashed" >&2; exit 1; }
      python3 - "$STAGE/graders/grade.py" "$UPGRADE" "$RUN/variant.jsonl" "$BEHAVIOUR" <<'PYVAR'
import json, subprocess, sys
grader, upgrade, output, behaviour = sys.argv[1:]
p = subprocess.run([sys.executable, '-I', grader, upgrade, output], capture_output=True, text=True)
d = json.loads(p.stdout)
expected = {('payouts','B2'):(0,24,0), ('payouts','B4'):(2331,0,0), ('settlements','B2'):(0,19,19), ('settlements','B3'):(1473,0,0)}
assert d['verdict'] == 'FAIL' and tuple(d[k] for k in ('missing','duplicates','mismatched')) == expected[(upgrade,behaviour)]
PYVAR
    fi
  done
  python3 - "$STAGE/mcp_shim.py" "$WS" "$IP" <<'PYSHIM'
import json, os, subprocess, sys
shim, workspace, ip = sys.argv[1:]
env = dict(os.environ); env.pop('VULTR_INFERENCE_API_KEY', None); env.pop('KALARI_REDACT_KEY', None)
commands = [
 {'name':'sandbox_create','arguments':{'name':'test','volumes':[{'kind':'bind','guestPath':'/workspace','hostPath':workspace}]}},
 {'name':'sandbox_exec','arguments':{'name':'test','command':'python3','args':['-c', 'import os,socket,sys; assert not os.getenv("VULTR_INFERENCE_API_KEY"); assert os.path.isfile("/workspace/README.md"); s=socket.socket(); s.settimeout(2); assert s.connect_ex((sys.argv[1],18080)) != 0; print("isolated")',ip]}},
 {'name':'sandbox_exec','arguments':{'name':'not-owned','command':'true'}},
 {'name':'sandbox_restore','arguments':{'name':'not-owned'}},
]
requests = [{'jsonrpc':'2.0','id':i,'method':'tools/call','params':c} for i,c in enumerate(commands)]
p = subprocess.run([sys.executable,shim], env=env, input=''.join(json.dumps(x)+'\n' for x in requests), capture_output=True, text=True, timeout=60, check=True)
responses = [json.loads(line)['result'] for line in p.stdout.splitlines()]
assert len(responses)==4 and responses[1]['structuredContent']['exitCode']==0
assert 'isolated' in responses[1]['structuredContent']['stdout']
assert responses[2]['isError'] and responses[3]['isError']
PYSHIM
  # Verify this user scope contains and stops a detached descendant.
  systemd-run --user --scope --unit "$SCOPE" --quiet sh -c 'setsid sleep 300 & wait' > "$RUN/scope-probe.log" 2>&1 &
  SESSION_PID=$!
  SCOPE_STARTED=1
  group=""
  for _ in $(seq 1 50); do
    group=$(systemctl --user show "$SCOPE" -p ControlGroup --value 2>/dev/null || true)
    [[ -n "$group" && -s "/sys/fs/cgroup${group}/cgroup.procs" ]] && [[ $(wc -l < "/sys/fs/cgroup${group}/cgroup.procs") -ge 2 ]] && break
    sleep .1
  done
  [[ -n "$group" ]] && [[ $(wc -l < "/sys/fs/cgroup${group}/cgroup.procs") -ge 2 ]] || { echo "scope preflight failed" >&2; exit 1; }
  SCOPE_GROUP="$group"
  stop_scope
  wait "$SESSION_PID" 2>/dev/null || true
  SESSION_PID=""
  echo "status=variant_checks_ok scope_ok" >&2
  exit 0
fi

# The API and hidden grader sources are staged only to provision/check the
# dedicated API guests. Remove those private copies before the arm starts.
rm -rf -- "$STAGE/apis" "$STAGE/graders"
[[ ! -e "$STAGE/apis" && ! -e "$STAGE/graders" ]] || { echo "server staging cleanup failed" >&2; exit 1; }
echo "status=source_staging_removed" >&2
echo "status=session" >&2
cd "$WS"
args=(opencode run --standalone --format json --auto --title "bench-c${COND}-${UPGRADE}")
if [[ -n "$SESSION_ID" ]]; then
  args+=(--session "$SESSION_ID")
fi
# Quoted expansion: a semicolon in the prompt stays one argument.
args+=("$(cat "$RUN/prompt.txt")")
start=$(date +%s)
set +e
systemd-run --user --scope --unit "$SCOPE" --quiet timeout --kill-after=15 1200 "${args[@]}" > "$RUN/events.jsonl" 2> "$RUN/opencode.stderr" &
SESSION_PID=$!
SCOPE_STARTED=1
for _ in $(seq 1 50); do
  SCOPE_GROUP=$(systemctl --user show "$SCOPE" -p ControlGroup --value 2>/dev/null || true)
  [[ -n "$SCOPE_GROUP" ]] && break
  kill -0 "$SESSION_PID" 2>/dev/null || break
  sleep .1
done
if [[ -z "$SCOPE_GROUP" ]]; then
  echo "failed to verify session scope" >&2
  kill "$SESSION_PID" 2>/dev/null || true
  wait "$SESSION_PID" 2>/dev/null || true
  exit 1
fi
wait "$SESSION_PID"
rc=$?
set -e
stop_scope
SESSION_PID=""
[[ -s "$RUN/events.jsonl" ]] || { echo "session produced no events" >&2; exit 1; }
end=$(date +%s)
elapsed=$((end - start))
echo "status=session_exit:$rc elapsed:$elapsed" >&2

# Drop the key from the environment before grading. measures still redacts with the copy.
export KALARI_REDACT_KEY
unset VULTR_INFERENCE_API_KEY

NOTES_DIR=""
if [[ "$COND" == 2 && "$UPGRADE" == payouts ]]; then
  NOTES_DIR=$ROOT/state/condition-2-notes
fi
echo "status=measures" >&2
measure_args=(
  --events "$RUN/events.jsonl"
  --upgrade "$UPGRADE"
  --workspace "$WS"
  --xdg "$XDG_DATA_HOME"
  --elapsed "$elapsed"
  --exit-code "$rc"
  --stderr "$RUN/opencode.stderr"
  --out "$RUN/analysis.json"
  --materialize "$RUN/first-v2-src"
)
if [[ -n "$NOTES_DIR" ]]; then
  measure_args+=(--notes-dir "$NOTES_DIR")
fi
python3 "$STAGE/measures.py" "${measure_args[@]}"

if [[ "$COND" == 1 && "$UPGRADE" == payouts ]]; then
  python3 - "$RUN/analysis.json" "$ROOT/state/condition-1.json" "$XDG_BASE" << 'PY'
import json, sys
analysis, dest, xdg = sys.argv[1:4]
sid = json.load(open(analysis)).get("session_id") or ""
if sid:
    json.dump({"session_id": sid, "xdg": xdg}, open(dest, "w"))
PY
fi

grade_one() { # $1 source dir, $2 basename. Failures are recorded; they must not drop the session.
  local src=$1 base=$2
  local name="kalari-grade-${base}-${RUN_ID}"
  echo "status=grade:$base" >&2
  umask 022
  if ! msb create --name "$name" --cpus 1 --memory 512M --pull never --no-net \
    --net-rule "allow@${IP}/32:tcp:${GRADE_PORT}" python >/dev/null; then
    echo "EXIT create" > "$RUN/${base}.status"
    return 0
  fi
  OWNED+=("$name")
  msb exec "$name" -- mkdir -p /w/src || { echo "EXIT mkdir" > "$RUN/${base}.status"; msb remove -f "$name" >/dev/null 2>&1 || true; return 0; }
  tar -C "$src" --exclude .git -czf "$RUN/${base}.tgz" . || { echo "EXIT tar" > "$RUN/${base}.status"; msb remove -f "$name" >/dev/null 2>&1 || true; return 0; }
  msb copy -q "$RUN/${base}.tgz" "$name:/w/src.tgz" || { echo "EXIT copy" > "$RUN/${base}.status"; msb remove -f "$name" >/dev/null 2>&1 || true; return 0; }
  msb copy -q "$STAGE/grade_runner.py" "$name:/w/grade_runner.py" || { echo "EXIT copy-runner" > "$RUN/${base}.status"; msb remove -f "$name" >/dev/null 2>&1 || true; return 0; }
  msb exec "$name" -- tar -C /w/src -xzf /w/src.tgz || { echo "EXIT untar" > "$RUN/${base}.status"; msb remove -f "$name" >/dev/null 2>&1 || true; return 0; }
  timeout 150 msb exec "$name" -- python3 /w/grade_runner.py "/w/src/${CONSUMER}" "http://${IP}:${GRADE_PORT}" "/w/out.jsonl" \
    > "$RUN/${base}.status" 2> "$RUN/${base}.err" || true
  msb copy -q "$name:/w/out.jsonl" "$RUN/${base}.jsonl" 2>/dev/null || true
  if [[ ! -s "$RUN/${base}.jsonl" ]]; then
    msb copy -q "$name:/w/src/${OUT_NAME}" "$RUN/${base}.jsonl" 2>/dev/null || true
  fi
  msb copy -q "$name:/w/consumer.log" "$RUN/${base}.consumer.log" 2>/dev/null || true
  msb remove -f "$name" >/dev/null 2>&1 || true
  python3 - "$RUN/${base}.consumer.log" "$RUN/${base}.log-excerpt" << 'PY'
import os, re, sys
src, dest = sys.argv[1], sys.argv[2]
key = os.environ.get("KALARI_REDACT_KEY", "")
ip = os.environ.get("KALARI_PUBLIC_IP", "")
text = ""
if os.path.exists(src):
    text = open(src, errors="replace").read()[-1500:]
if key:
    text = text.replace(key, "[redacted]")
if ip:
    text = text.replace(ip, "the VM's public address")
text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "the VM's public address", text)
text = re.sub(r"/home/[^/\s]+", "~", text)
open(dest, "w").write(text)
PY
}

grade_one "$WS" final
if [[ -f "$RUN/first-v2-src/$CONSUMER" ]]; then
  grade_one "$RUN/first-v2-src" first
fi

echo "status=cleanup" >&2
stop_scope
SESSION_PID=""
for n in "${OWNED[@]}"; do msb remove -f "$n" >/dev/null 2>&1 || true; done
python3 - "$RUN/cleanup.json" "${OWNED[@]}" <<'PYCLEAN'
import json, subprocess, sys
names = set(sys.argv[2:])
r = subprocess.run(['msb','list'], capture_output=True, text=True)
if r.returncode: raise SystemExit('could not verify cleanup')
left = [line.split()[0] for line in r.stdout.splitlines()[1:] if line.split() and line.split()[0] in names]
json.dump({'sandboxes_left':left, 'processes_left':[], 'owned_names': sorted(names), 'scope_verified': True}, open(sys.argv[1], 'w'))
if left: raise SystemExit('owned sandbox cleanup failed')
PYCLEAN

python3 - "$RUN/analysis.json" "$COND" "$UPGRADE" "$SESSION_CONTINUED" "$NOTES_ATTACHED" "$PROMPT_NAME" "$ver" "$LIVE_PORT" "$GRADE_PORT" << 'PY'
import json, os, sys
analysis, cond, upgrade, continued, notes, prompt, ver, live, grade = sys.argv[1:10]
doc = json.load(open(analysis))
doc["condition"] = int(cond)
doc["upgrade"] = upgrade
doc["session_continued"] = continued == "1"
doc["notes_attached"] = notes == "1"
doc["prompt"] = prompt
doc["opencode_version"] = ver.strip()
doc["live_port"] = int(live)
doc["grading_port"] = int(grade)
doc["api_base"] = "the VM's public address"
run = os.path.dirname(analysis)
clean = json.load(open(os.path.join(run, "cleanup.json")))
doc["cleanup"] = clean
excerpts = {}
for base in ("final", "first"):
    status = os.path.join(run, base + ".status")
    excerpt = os.path.join(run, base + ".log-excerpt")
    if os.path.exists(status):
        excerpts[base] = {
            "status": open(status, errors="replace").read().strip()[:200],
            "log_excerpt": open(excerpt, errors="replace").read() if os.path.exists(excerpt) else "",
        }
doc["grader_runs"] = excerpts
json.dump(doc, open(analysis, "w"), indent=2)
open(analysis, "a").write("\n")
PY

# Stdout is the run id only. The address stays on the VM.
echo "KALARI_RUN $RUN_ID"
