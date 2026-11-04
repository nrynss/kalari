#!/usr/bin/env bash
# One reference-arm session on the VM.
# The inference key is the first line of stdin. It is exported for OpenCode and
# never written to a file, a command line, or this script's stdout.
set -euo pipefail
umask 022

COND=""
UPGRADE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --condition) COND=${2:?}; shift 2 ;;
    --upgrade) UPGRADE=${2:?}; shift 2 ;;
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

IFS= read -r VULTR_INFERENCE_API_KEY || true
if [[ ${#VULTR_INFERENCE_API_KEY} -lt 8 ]]; then
  echo "missing inference key on stdin" >&2
  exit 1
fi
export VULTR_INFERENCE_API_KEY

export PATH="$HOME/.local/bin:$PATH"
ROOT=$HOME/kalari-harness
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
  LIVE_PORT=18080
  GRADE_PORT=18090
  CONSUMER=payout_sync.py
  WS_NAME=payout-sync
  OUT_NAME=payouts.jsonl
else
  LIVE_PORT=18081
  GRADE_PORT=18091
  CONSUMER=settlement_reconcile.py
  WS_NAME=settlement-reconcile
  OUT_NAME=settlements.jsonl
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
    # Plain msb remove fails while a sandbox is running. -f stops, then removes.
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
cp "$STAGE/opencode.jsonc" "$WS/opencode.jsonc"
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
remove_ours
kill_new_procs
# What is still running that was not running before we started.
python3 - "$RUN" << 'PY'
import json, os, subprocess, sys
run = sys.argv[1]
before = set(open(os.path.join(run, "sandboxes-before")).read().split())
protected = {"api-payouts-live", "api-payouts-grading", "api-settlements-live", "api-settlements-grading"}
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
        kind = "microsandbox-mcp" if "microsandbox-mcp" in args else "opencode"
        procs.append(kind)
removed = []
path = os.path.join(run, "sandboxes-removed")
if os.path.exists(path):
    removed = [n for n in open(path).read().split() if n]
# The list can mention a name twice (explicit cleanup and the trap). Unique it.
seen = []
for n in removed:
    if n not in seen:
        seen.append(n)
json.dump({
    "sandboxes_removed": seen,
    "sandboxes_left": left,
    "processes_left": procs,
}, open(os.path.join(run, "cleanup.json"), "w"))
PY

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
