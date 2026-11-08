#!/usr/bin/env bash
# Live first-run learning path: fresh store -> first run passes with no
# lessons -> record_lesson writes the retry lesson -> a second session
# recalls it as a required check and passes with it. Not part of the gate.
#
# Production `kalari serve` accepts a broker-backed observer (guest-alias
# endpoint, allowlisted, present server) and refuses every other observer
# with the isolation message. This rehearsal uses a harness-only entry point,
# tests/live/observer-harness.lean, that calls the same dispatcher with an
# observer setup. `kalari serve` cannot reach it.
#
# Budget: zero model calls. Clef calls are counted and redirected to a local
# fake. The Lambo store uses the fixture embedder. No inference key is read.
#
# Requires TOOL_BIN with: kalari, kalari-aashaan, msb, vimanam, lambo
# 0.9.x built with the embed-fixture feature, and lake on PATH (or LAKE set).
# Run after `lake build`:
#
#   TOOL_BIN=/absolute/tool/dir tests/live/first-run.sh
set -euo pipefail
umask 022
cd "$(dirname "$0")/../.."
repo=$(pwd -P)

: "${TOOL_BIN:?absolute directory with kalari, kalari-aashaan, msb, vimanam, lambo}"
[[ "$TOOL_BIN" = /* ]] || { echo 'TOOL_BIN must be absolute' >&2; exit 2; }
for bin in kalari kalari-aashaan msb vimanam lambo; do
  [[ -x "$TOOL_BIN/$bin" ]] || { echo "missing $bin in $TOOL_BIN" >&2; exit 2; }
done
LAKE=${LAKE:-lake}
command -v "$LAKE" >/dev/null || { echo 'lake not found; set LAKE' >&2; exit 2; }
LAKE=$(command -v "$LAKE")
unset VULTR_INFERENCE_API_KEY 2>/dev/null || true
# The service requires a non-empty key environment name at startup. This is a
# placeholder, not a key: no model call is made by this rehearsal.
export KALARI_LIVE_DUMMY=live-test-placeholder
vimanam_version=$("$TOOL_BIN/vimanam" --version)
lambo_version=$("$TOOL_BIN/lambo" --version)
[[ "$vimanam_version" == "vimanam 2.1.0" ]] || { echo "vimanam is $vimanam_version, want 2.1.0" >&2; exit 2; }
[[ "$lambo_version" == lambo\ 0.9.* ]] || { echo "lambo is $lambo_version, want 0.9.x" >&2; exit 2; }

work=$(mktemp -d)
transcript="tests/live/first-run-transcript.txt"
api_pids=()
sandbox_before="$work/sandboxes-before.json"
sandbox_after="$work/sandboxes-after.json"
sandbox_before_failed=0
known_sandboxes=()

say() {
  printf '%s\n' "$*"
}

sanitize() {
  python3 -I -c 'import os, re, sys
home = os.environ.get("HOME", "")
for line in sys.stdin:
    if home:
        line = line.replace(home, "<home>")
    line = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<ip>", line)
    line = re.sub(r"\d{4}-\d{2}-\d{2}(?:[T ][0-9:.+Z-]*)?", "<time>", line)
    sys.stdout.write(line)'
}

free_port() {
  python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

wait_api() {
  local port=$1 name=$2
  local _
  for _ in $(seq 1 100); do
    if curl -s -o /dev/null -m 1 "http://127.0.0.1:${port}/"; then
      return 0
    fi
    sleep 0.05
  done
  echo "API ${name} did not start" >&2
  sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g' "$work/${name}.log" >&2 || true
  return 1
}

start_api() {
  local name=$1 suite=$2 port=$3 v1=$4
  python3 -I "bench/apis/${suite}/server.py" --bind 127.0.0.1 --port "$port" --v1 "$v1" >"$work/${name}.log" 2>&1 &
  api_pids+=("$!")
  wait_api "$port" "$name"
}

observer_pids() {
  ps -eo pid,args | awk '$2 ~ /python/ && index($0, "bench/apis/payouts/server.py") && index($0, "--trace-client 127.0.0.1") { print $1 }'
}

remove_kalari_sandboxes() {
  local names name
  names=$("$TOOL_BIN/msb" list --format json 2>/dev/null | python3 -I -c 'import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for row in rows:
    name = row.get("name", "")
    if name.startswith("kalari-"):
        print(name)') || true
  for name in $names; do
    "$TOOL_BIN/msb" remove -f "$name" >/dev/null 2>&1 || true
    say "sandboxes: removed $name"
  done
}

cleanup() {
  local status=$?
  trap - EXIT
  local pid
  for pid in "${api_pids[@]+"${api_pids[@]}"}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [[ -n "${service_pid:-}" ]] && kill -0 "$service_pid" 2>/dev/null; then
    kill "$service_pid" 2>/dev/null || true
    wait "$service_pid" 2>/dev/null || true
  fi
  local pids
  pids=$(ps -eo pid,args | awk -v cfg="$work/config.json" '$2 ~ /kalari/ && index($0, "kalari serve") && index($0, cfg) { print $1 }')
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
  fi
  pids=$(ps -eo pid,args | awk -v cfg="$work/lambo.toml" '$2 ~ /lambo/ && index($0, cfg) { print $1 }')
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
    sleep 0.5
    pids=$(ps -eo pid,args | awk -v cfg="$work/lambo.toml" '$2 ~ /lambo/ && index($0, cfg) { print $1 }')
    [[ -z "$pids" ]] || kill -9 $pids 2>/dev/null || true
  fi
  pids=$(ps -eo pid,args | awk -v cfg="$work/config.json" '($2 ~ /lake/ || $2 ~ /lean/) && index($0, "observer-harness.lean") && index($0, cfg) { print $1 }')
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
    sleep 0.5
    pids=$(ps -eo pid,args | awk -v cfg="$work/config.json" '($2 ~ /lake/ || $2 ~ /lean/) && index($0, "observer-harness.lean") && index($0, cfg) { print $1 }')
    [[ -z "$pids" ]] || kill -9 $pids 2>/dev/null || true
  fi
  pids=$(observer_pids)
  if [[ -n "$pids" ]]; then
    kill $pids 2>/dev/null || true
    sleep 0.5
    pids=$(observer_pids)
    [[ -z "$pids" ]] || kill -9 $pids 2>/dev/null || true
  fi
  pids=$(observer_pids)
  if [[ -n "$pids" ]]; then
    echo "cleanup: observer process(es) remain:" >&2
    ps -eo pid,args | awk '$2 ~ /python/ && index($0, "bench/apis/payouts/server.py") && index($0, "--trace-client 127.0.0.1")' >&2
    status=1
  else
    say "cleanup: observers_remaining=0"
  fi
  if [[ "$sandbox_before_failed" == 1 ]]; then
    echo "cleanup: initial msb list failed; sandbox cleanup is unproven" >&2
    status=1
  elif [[ -f "$sandbox_before" ]]; then
    remove_kalari_sandboxes
    if ! "$TOOL_BIN/msb" list --format json >"$sandbox_after" 2>"$work/msb-list-after.err"; then
      echo "cleanup: msb list failed; sandbox cleanup is unproven" >&2
      status=1
    else
      left=$(python3 -I - "$sandbox_before" "$sandbox_after" <<'PY'
import json, sys
def names(path):
    try:
        with open(path) as stream:
            return {row.get("name", "") for row in json.load(stream)}
    except Exception as exc:
        print(f"cleanup: cannot read {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
print(len({name for name in names(sys.argv[2]) - names(sys.argv[1])
           if name.startswith("kalari-")}))
PY
)
      if [[ "$left" != 0 ]]; then
        echo "cleanup: ${left} kalari sandbox(es) remain" >&2
        status=1
      else
        say "cleanup: sandboxes_remaining=0"
      fi
    fi
  fi
  if [[ "${KEEP_WORK:-}" == 1 ]]; then
    echo "cleanup: kept work directory"
  else
    rm -rf "$work"
  fi
  exit "$status"
}
trap cleanup EXIT

exec > >(sanitize | tee "$transcript") 2>&1

say "first-run learning path: fresh store -> run -> lesson -> second-session recall"
say "versions: ${vimanam_version}, ${lambo_version}, msb $("$TOOL_BIN/msb" --version | head -1)"
say "embedder: fixture (local, no external model calls)"

# The local Lambo 0.9.x build must include the fixture embedder. Provision and
# derive one concept before any session starts.
preflight="$work/lambo-preflight"
mkdir -p "$preflight"
cat >"$preflight/lambo.toml" <<TOML
promotion_policy = "Solo"
[store]
kind = "sqlite"
path = "$preflight/lambo.db"
[embedder]
kind = "fixture"
[serve]
default_session = "preflight"
TOML
if ! "$TOOL_BIN/lambo" provision --config "$preflight/lambo.toml" >/dev/null 2>"$preflight/provision.err" ||
   ! "$TOOL_BIN/lambo" derive --config "$preflight/lambo.toml" --session preflight --agent preflight \
       --content preflight-kind --kind resource >/dev/null 2>"$preflight/derive.err"; then
  echo "preflight: lambo fixture embedder failed; rebuild lambo with embed-fixture" >&2
  sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g' "$preflight"/*.err >&2 || true
  exit 2
fi
say "preflight: lambo fixture embedder provisioned and derived one concept"

remove_kalari_sandboxes
if ! "$TOOL_BIN/msb" list --format json >"$sandbox_before" 2>"$work/msb-list-before.err"; then
  echo "first-run: initial msb list failed; sandbox cleanup is unproven" >&2
  sandbox_before_failed=1
  echo '[]' >"$sandbox_before"
else
  python3 -I - "$sandbox_before" <<'PY'
import json, sys
names = {row.get("name", "") for row in json.load(open(sys.argv[1]))}
left = sorted(name for name in names if name.startswith("kalari-"))
if left:
    raise SystemExit("kalari test sandboxes remain: " + ",".join(left))
PY
  say "sandboxes: before list has no kalari test sandboxes"
fi

payouts_live=$(free_port)
observer_port=$(free_port)
start_api payouts-live payouts "$payouts_live" on
say "apis: payouts live=loopback:${payouts_live}, payouts observer=loopback:${observer_port}"

# One private Lambo store with the fixture embedder. Fresh: nothing is
# seeded, so the first recall finds no concept and returns no lessons.
cat >"$work/lambo.toml" <<TOML
promotion_policy = "Solo"
[store]
kind = "sqlite"
path = "$work/lambo.db"
[embedder]
kind = "fixture"
[serve]
default_session = "kalari-live"
TOML
"$TOOL_BIN/lambo" provision --config "$work/lambo.toml" >/dev/null
say "lambo: private fixture store provisioned fresh, no change kinds seeded"

mkdir -p "$work/candidate" "$work/baseline"
cp "bench/apis/payouts/reference/correct.py" "$work/candidate/consumer.py"
cp "bench/apis/payouts/reference/v1_unchanged.py" "$work/baseline/consumer.py"
mkdir -p "$work/checks" "$work/evidence"
cp bench/workspaces/payout-sync/specs/openapi-v1.yaml "$work/old.yaml"
cp bench/workspaces/payout-sync/specs/openapi-v2.yaml "$work/new.yaml"

python3 -I - "$work" "$TOOL_BIN" "$repo" "$payouts_live" "$observer_port" "$LAKE" <<'PY'
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

work = Path(sys.argv[1])
tools = Path(sys.argv[2])
repo = Path(sys.argv[3])
payouts_live, observer_port = map(int, sys.argv[4:6])
lake = sys.argv[6]
msb = str(tools / "msb")
caps = {"timeout_ms": 30000, "output_cap_bytes": 65536, "memory_mib": 512}
alias = "host.microsandbox.internal"
endpoint = lambda port: {"host": alias, "port": port}
allowed = [endpoint(payouts_live), endpoint(observer_port)]
config = {
    "models": {"endpoint": "https://example.invalid", "model": "unused",
               "api_key_env": "KALARI_LIVE_DUMMY"},
    "decisions": {"endpoint": "https://api.vultrinference.com/v1/systemone", "model": "clef",
                  "api_key_env": "KALARI_LIVE_DUMMY"},
    "sandbox": {"backend": "microsandbox", "image": "python:3.13-slim",
                "caps": caps, "allowlist": allowed},
    "lambo": {"command": [str(tools / "lambo"), "serve"],
              "config_path": str(work / "lambo.toml")},
}
(work / "config.json").write_text(json.dumps(config, indent=2) + "\n")

def session(name, observer):
    setup = {
        "session_id": name, "repo_scope": "live",
        "workspace": str(work / "candidate"),
        "old_spec": str(work / "old.yaml"),
        "new_spec": str(work / "new.yaml"),
        "baseline": {
            "workspace": str(work / "baseline"),
            "command": ["python3", str(work / "baseline/consumer.py"),
                        "--base-url", f"http://{alias}:{payouts_live}", "--out", "payouts.jsonl"],
            "caps": caps, "allowlist": [endpoint(payouts_live)],
        },
        "check_workspace": str(work / "checks"),
        "evidence_workspace": str(work / "evidence"),
        "artifact": "payouts.jsonl",
        "aashaan": str((tools / "kalari-aashaan").resolve()),
        "tool_path": str(tools) + ":/usr/local/bin:/usr/bin:/bin",
    }
    if observer is not None:
        setup["observer"] = {
            "server": str((repo / "bench/apis/payouts/server.py").resolve()),
            "endpoint": endpoint(observer),
        }
    (work / f"{name}-session.json").write_text(json.dumps(setup, indent=2) + "\n")
    return setup

first_setup = session("first-a", observer_port)
second_setup = session("first-b", None)
bad = json.loads(json.dumps(first_setup))
bad["observer"]["endpoint"]["host"] = "127.0.0.1"
(work / "bad-session.json").write_text(json.dumps(bad, indent=2) + "\n")
missing = json.loads(json.dumps(first_setup))
missing["observer"]["server"] = str(work / "missing-server.py")
(work / "missing-server-session.json").write_text(json.dumps(missing, indent=2) + "\n")

env = {
    "PATH": str(tools) + ":/usr/local/bin:/usr/bin:/bin",
    "HOME": os.environ.get("HOME", ""),
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "KALARI_LIVE_DUMMY": "live-test-placeholder",
}

def line(text):
    print(text, flush=True)

def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port

def wait_port(port):
    for _ in range(200):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise SystemExit(f"port {port} did not open")

def lambo_children():
    listing = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout
    config = str(work / "lambo.toml")
    return [row for row in listing.splitlines() if config in row and "lambo" in row]

FAKE_DECISIONS = r"""
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        with open(sys.argv[2], "a") as stream:
            stream.write("call\n")
        self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"error":{"message":"harness blocks model calls"}}')
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
"""

class Service:
    def __init__(self, tag, setup_path):
        self.tag = tag
        self.index = 0
        self.model_calls = None
        self.count_path = work / f"model-calls-{tag}.txt"
        self.stderr = open(work / f"{tag}.stderr", "wb")
        service_env = dict(env)
        command = [lake, "env", "lean", "--run", "tests/live/observer-harness.lean",
                   str(work / "config.json"), str(setup_path)]
        service_env["KALARI_OBSERVER_HARNESS"] = "1"
        service_env["KALARI_HARNESS_COUNT_FILE"] = str(self.count_path)
        service_env["KALARI_HARNESS_DECISIONS_URL"] = fake_url
        self.proc = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            text=True, cwd=repo, env=service_env, start_new_session=True)

    def send(self, name, args):
        self.index += 1
        request = {"jsonrpc": "2.0", "id": self.index, "method": "tools/call",
                   "params": {"name": name, "arguments": args}}
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()

    def call(self, name, args):
        self.send(name, args)
        reply = self.proc.stdout.readline()
        if not reply:
            self.stderr.flush()
            detail = (work / f"{self.tag}.stderr").read_text(errors="replace")[-3000:]
            raise SystemExit(f"{self.tag}: service closed without a reply:\n{detail}")
        response = json.loads(reply)
        if "error" in response:
            raise SystemExit(f"{self.tag}: protocol error: {response['error']}")
        result = response["result"]
        text = result["content"][0]["text"]
        if result.get("isError"):
            raise SystemExit(f"{self.tag}: tool {name} failed: {text}")
        return json.loads(text)

    def close(self):
        self.proc.stdin.close()
        try:
            reply, _ = self.proc.communicate(timeout=120)
            status = self.proc.returncode
        except subprocess.TimeoutExpired:
            self.kill()
            reply, _ = self.proc.communicate()
            status = -1
        self.stderr.close()
        if reply.strip():
            raise SystemExit(f"{self.tag}: unexpected stdout after close: {reply[:200]}")
        if status != 0:
            raise SystemExit(f"{self.tag}: service exited {status}")
        if self.count_path.exists():
            text = self.count_path.read_text().strip()
            line(f"harness: {self.tag} {text} measured_clef_calls")
            self.model_calls = int(text.split("=", 1)[1])
        return status

    def kill(self):
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass

def check_names(report):
    return {item["check_id"]: item for item in report["checks"]}

def show_run(tag, report):
    checks = ", ".join(f"{k}={'pass' if v['passed'] else 'fail'}" for k, v in sorted(check_names(report).items()))
    line(f"{tag}: passed={str(report['passed']).lower()} verdict={report['verdict']['verdict']} "
         f"exit={report['verdict'].get('exit_code')} checks=[{checks}]")

def evidence(path):
    records = []
    with open(path) as stream:
        for raw in stream:
            if raw.strip():
                records.append(json.loads(raw))
    return records

def production_refusal(name, setup_path):
    result = subprocess.run(
        [str(tools / "kalari"), "serve", str(work / "config.json"), str(setup_path)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, cwd=repo, env=env)
    message = result.stderr.strip().splitlines()[-1] if result.stderr.strip() else ""
    if result.returncode == 0 or "observer requires verified exclusive guest source isolation" not in result.stderr:
        raise SystemExit(f"production service did not refuse {name}")
    line(f"refusal: {name} exit={result.returncode} message={message!r}")

def production_acceptance(name, setup_path):
    # A broker-backed observer (guest-alias endpoint, allowlisted, present
    # server) is accepted: the run path forces a fresh per-run broker on
    # loopback. stdin EOF ends the serve; anything else would refuse above.
    result = subprocess.run(
        [str(tools / "kalari"), "serve", str(work / "config.json"), str(setup_path)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, cwd=repo, env=env, timeout=120)
    if result.returncode != 0 or "observer requires verified exclusive guest source isolation" in result.stderr:
        raise SystemExit(f"production service did not accept {name}: "
                         f"exit={result.returncode} stderr={result.stderr[-500:]!r}")
    line(f"accept: {name} exit={result.returncode} no_refusal=1")

fake_log = work / "fake-decisions.jsonl"
fake_port = free_port()
fake = subprocess.Popen(["python3", "-I", "-c", FAKE_DECISIONS, str(fake_port), str(fake_log)],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
fake_url = f"http://127.0.0.1:{fake_port}/v1/systemone"
try:
    wait_port(fake_port)
    line(f"decisions: local_fake=loopback:{fake_port} real_endpoint=blocked")

    # 0. The production boundary for the observer config. The valid
    #    broker-backed first-a observer is accepted; anything else refuses
    #    closed with the isolation message.
    production_acceptance("first-a observer", work / "first-a-session.json")
    production_refusal("caller address", work / "bad-session.json")
    production_refusal("missing server", work / "missing-server-session.json")

    # 1. First session on a fresh store: recall is empty, the run still passes.
    first = Service("first-a", work / "first-a-session.json")
    try:
        changed = first.call("what_changed", {
            "old_spec": first_setup["old_spec"], "new_spec": first_setup["new_spec"]})
        kinds = sorted({change["kind"] for change in changed["changes"]})
        line(f"first-a what_changed: kinds={','.join(kinds)}")
        recalled = first.call("recall_lessons", {"change_kinds": kinds})
        if recalled:
            raise SystemExit(f"fresh store recall was not empty: {recalled}")
        line("first-a recall_lessons: [] (fresh store, no concept yet)")
        command = ["python3", str(work / "candidate/consumer.py"),
                   "--base-url", f"http://{alias}:{observer_port}", "--out", "payouts.jsonl"]
        report = first.call("run_in_sandbox", {
            "workspace": first_setup["workspace"], "command": command,
            "caps": caps, "allowlist": [endpoint(observer_port)]})
        show_run("first-a run_in_sandbox", report)
        if not report["passed"]:
            raise SystemExit("first run did not pass on the fresh store")
        first_run = report["run_id"]
        lessons = first.call("record_lesson", {"run_id": first_run})
        if not lessons:
            raise SystemExit("first run published no lesson")
        for lesson in lessons:
            observation = lesson["observation"]
            if "429" not in observation or "identical request" not in observation:
                raise SystemExit("lesson does not carry the retry observation")
            if lesson["check"]["id"] != "candidate-v1-truth-v1":
                raise SystemExit("lesson does not keep the candidate truth check")
            line(f"first-a record_lesson: observation={observation!r}")
            line(f"first-a record_lesson: check={lesson['check']['id']} command={lesson['check']['command']}")
            line(f"first-a record_lesson: memory_concept_id={lesson['memory_concept_id']}")
    finally:
        first.close()
    if lambo_children():
        raise SystemExit("first session left a Lambo child")

    # 2. Second session on the same store: the lesson is recalled as required,
    #    and its rebound check runs and passes.
    second = Service("first-b", work / "first-b-session.json")
    try:
        changed = second.call("what_changed", {
            "old_spec": second_setup["old_spec"], "new_spec": second_setup["new_spec"]})
        kinds = sorted({change["kind"] for change in changed["changes"]})
        recalled = second.call("recall_lessons", {"change_kinds": kinds})
        required = [entry for entry in recalled if entry["status"] == "required"]
        if not any(entry["lesson"]["check"]["id"] == "candidate-v1-truth-v1" and
                   entry["lesson"]["observation"] for entry in required):
            raise SystemExit(f"second session did not recall the lesson as required: {recalled}")
        for entry in required:
            if entry["lesson"]["check"]["id"] == "candidate-v1-truth-v1":
                line(f"first-b recall_lessons: status={entry['status']} check={entry['lesson']['check']['id']} "
                     f"command={entry['lesson']['check']['command']}")
                line(f"first-b recall_lessons: observation={entry['lesson']['observation']!r}")
        command = ["python3", str(work / "candidate/consumer.py"),
                   "--base-url", f"http://{alias}:{payouts_live}", "--out", "payouts.jsonl"]
        report = second.call("run_in_sandbox", {
            "workspace": second_setup["workspace"], "command": command,
            "caps": caps, "allowlist": [endpoint(payouts_live)]})
        show_run("first-b run_in_sandbox", report)
        if not report["passed"]:
            raise SystemExit("second session run did not pass with the recalled check")
        checks = check_names(report)
        truth = checks.get("candidate-v1-truth-v1")
        diff = checks.get("differential-v1")
        if truth is None or diff is None:
            raise SystemExit("second run is missing the recalled or differential check")
        if not (truth["passed"] and diff["passed"]):
            raise SystemExit("second run did not pass the recalled and differential checks")
        second_run = report["run_id"]
    finally:
        second.close()
    if lambo_children():
        raise SystemExit("second session left a Lambo child")

    # 3. The evidence store links the published lesson and the rebound check.
    store = evidence(work / "evidence/.kalari/evidence.jsonl")
    lesson_records = [r for r in store if r["kind"] == "lesson" and r["run_id"] == first_run]
    if not lesson_records or not lesson_records[0]["payload"]["observation"]:
        raise SystemExit("lesson evidence is empty")
    line(f"evidence: published lesson={lesson_records[0]['payload']['observation']!r}")
    run_records = {r["run_id"]: r for r in store if r["kind"] == "run"}
    record = run_records.get(second_run)
    if record is None:
        raise SystemExit("second run evidence missing")
    check = next((c for c in record["payload"]["checks"] if c["id"] == "candidate-v1-truth-v1"), None)
    if check is None:
        raise SystemExit("second run evidence has no candidate truth check")
    if "payouts.jsonl" not in check["command"]:
        raise SystemExit(f"second run check was not bound to payouts.jsonl: {check['command']}")
    line(f"evidence: second run check rebound command={check['command']}")

    # 4. No model calls anywhere.
    total = (first.model_calls or 0) + (second.model_calls or 0)
    if total != 0:
        raise SystemExit(f"model calls were made: {total}")
    fake_calls = len(fake_log.read_text().splitlines()) if fake_log.exists() else 0
    line(f"decisions: fake_requests={fake_calls} model_calls={total}")
    if fake_calls != 0:
        raise SystemExit(f"the blocked decision endpoint received {fake_calls} requests")
    if lambo_children():
        raise SystemExit("lambo child remains")
    line("first-run: fresh store -> run -> lesson -> visible second-session recall PASS")
finally:
    try:
        os.killpg(os.getpgid(fake.pid), signal.SIGKILL)
    except ProcessLookupError:
        pass
    fake.wait()
PY

say "rehearsal: first run on a fresh store, lesson, visible recall in the second session"
