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

# Condition 1 reuses one OpenCode session, one data directory and one absolute
# workspace. The workspace and XDG decisions live in condition1.sh so the
# no-inference rehearsal calls the same function this script calls.
. "$STAGE/condition1.sh"
. "$STAGE/grade_one.sh"
# Trusted retry measurement: the API servers' journals, truncated at each phase
# start and read at each phase end. Agent activity and grading activity never
# share a window. A missing journal stays unknown. The grading read also rejects
# a live API that saw traffic and a grading API with more than one client.
RETRY_JOURNAL=/srv/retry-journal.jsonl
retry_api() { printf 'api-%s-%s\n' "$UPGRADE" "$1"; }
retry_truncate() { # $1 phase
  python3 "$STAGE/retry_journal.py" truncate \
    --remote "$(retry_api live)=$RETRY_JOURNAL" \
    --remote "$(retry_api grading)=$RETRY_JOURNAL" \
    --out "$RUN/retry-$1-start.json" >/dev/null || true
}
retry_read() { # $1 phase
  local extra=()
  if [[ "$1" == grading ]]; then
    extra=(--grading-live "$(retry_api live)" --grading-grade "$(retry_api grading)")
  fi
  python3 "$STAGE/retry_journal.py" read --phase "$1" \
    --truncated "$RUN/retry-$1-start.json" \
    --remote "$(retry_api live)=$RETRY_JOURNAL" \
    --remote "$(retry_api grading)=$RETRY_JOURNAL" \
    "${extra[@]}" \
    --out "$RUN/retry-$1.json" >/dev/null || true
}
STATE=$(condition1_state_path "$ROOT")
SESSION_ID=""
SESSION_CONTINUED=0
WORKSPACE_DIGEST=""
STAGE_DIGEST=""
STATE_CONSUMED=0
NOTES_ATTACHED=0
STAGE_WS=$STAGE/workspaces/$WS_NAME
if [[ "$COND" != 1 ]]; then
  XDG_BASE=$RUN/xdg
  WS=$RUN/workspace
else
  echo "status=condition1:$UPGRADE" >&2
  # prepare_condition1 sets WS, XDG_BASE, SESSION_ID, SESSION_CONTINUED,
  # STAGE_DIGEST and WORKSPACE_DIGEST. For settlements it also consumes the
  # continuation state before this script can start the session.
  prepare_condition1 "$ROOT" "$STAGE" "$STAGE_WS" "$UPGRADE"
fi
export XDG_DATA_HOME=$XDG_BASE/data
export XDG_STATE_HOME=$XDG_BASE/state
export XDG_CACHE_HOME=$XDG_BASE/cache
export XDG_CONFIG_HOME=$XDG_BASE/config

if [[ "$COND" != 1 ]]; then
  mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
  rm -rf "$WS"
  mkdir -p "$WS"
  cp -a "$STAGE_WS/." "$WS/"
  cp "$STAGE/opencode.jsonc" "$WS/opencode.jsonc"
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

  # The fresh workspace must be exactly the staged tree: `.git`, the OpenCode
  # configuration and attached notes are added by the harness and excluded.
  STAGE_DIGEST=$(python3 "$STAGE/tree_digest.py" "$STAGE_WS")
  WORKSPACE_DIGEST=$(python3 "$STAGE/tree_digest.py" "$WS")
  if [[ "$STAGE_DIGEST" != "$WORKSPACE_DIGEST" ]]; then
    echo "status=workspace_identity_failed" >&2
    echo "staged workspace digest $STAGE_DIGEST != workspace digest $WORKSPACE_DIGEST" >&2
    exit 1
  fi
fi

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
retry_truncate agent
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
retry_read agent

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
  --workspace-digest "$WORKSPACE_DIGEST"
  --stage-digest "$STAGE_DIGEST"
)
if [[ "$SESSION_CONTINUED" == 1 ]]; then
  measure_args+=(--session-id-expected "$SESSION_ID")
fi
if [[ -n "$NOTES_DIR" ]]; then
  measure_args+=(--notes-dir "$NOTES_DIR")
fi
python3 "$STAGE/measures.py" "${measure_args[@]}"

if [[ "$COND" == 1 && "$UPGRADE" == payouts ]]; then
  sid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session_id") or "")' "$RUN/analysis.json")
  if [[ -z "$sid" ]]; then
    echo "status=condition1_session_missing" >&2
    echo "payouts session produced no session id; cannot save continuation state" >&2
    exit 1
  fi
  python3 "$STAGE/continuation.py" save \
    --state "$STATE" \
    --workspace "$WS" \
    --xdg "$XDG_BASE" \
    --session-id "$sid" \
    --start-digest "$WORKSPACE_DIGEST"
  # `payouts_start_digest` records the payouts tree at the start of the
  # session. The agent then edits the workspace, so it is informational and is
  # never compared with anything.
fi

# The arm has finished. Stop the arm's sandboxes and the processes they left
# before the grading window opens, so grading traffic is only the grader's.
# remove_ours keeps the four API guests.
remove_ours
kill_new_procs
retry_truncate grading
grade_one "$WS" final
if [[ -f "$RUN/first-v2-src/$CONSUMER" ]]; then
  grade_one "$RUN/first-v2-src" first
fi
retry_read grading

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

python3 - "$RUN/analysis.json" "$COND" "$UPGRADE" "$SESSION_CONTINUED" "$NOTES_ATTACHED" "$PROMPT_NAME" "$ver" "$LIVE_PORT" "$GRADE_PORT" "$STATE_CONSUMED" << 'PY'
import json, os, sys
analysis, cond, upgrade, continued, notes, prompt, ver, live, grade, consumed = sys.argv[1:11]
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
if int(cond) == 1:
    doc["condition1_workspace"] = doc.get("workspace")
    doc["continuation_state_consumed"] = consumed == "1"
    doc["continuation_state_consumed_at"] = (
        "condition1_prepare" if consumed == "1" else ""
    )
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
# The observed id from the event log, never the expected one.
doc["resumed_session_id"] = (doc.get("session_id") or "") if doc["session_continued"] else ""
grading = {}
for base in ("final", "first"):
    path = os.path.join(run, base + ".grade.json")
    if os.path.exists(path):
        grading[base] = json.load(open(path))
doc["grading"] = grading
final = grading.get("final") or {}
doc["consumer_exit"] = final.get("consumer_exit")
doc["output_present"] = final.get("output_present")
doc["grade_status"] = final.get("grade_status")
retry = {}
for phase in ("agent", "grading"):
    path = os.path.join(run, "retry-%s.json" % phase)
    if os.path.exists(path):
        try:
            retry[phase] = json.load(open(path))
        except ValueError:
            retry[phase] = {"phase": phase, "status": "unknown", "reason": "unreadable retry summary",
                            "b5_429_responses": None, "matching_retry_attempts": None,
                            "successful_matching_retries": None}
    else:
        retry[phase] = {"phase": phase, "status": "unknown", "reason": "no retry summary",
                        "b5_429_responses": None, "matching_retry_attempts": None,
                        "successful_matching_retries": None}
doc["retry_measure"] = {
    "source": "API retry journals, truncated at each phase start and read at each phase end",
    "note": "an HTTP retry inside one consumer process is not a sandbox run",
    "phases": retry,
}
json.dump(doc, open(analysis, "w"), indent=2)
open(analysis, "a").write("\n")
PY

# Stdout is the run id only. The address stays on the VM.
echo "KALARI_RUN $RUN_ID"
