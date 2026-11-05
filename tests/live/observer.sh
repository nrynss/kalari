#!/usr/bin/env bash
# Live observer rehearsal: payouts page observation -> retry lesson ->
# settlements recall -> trusted-check enforcement. Not part of the gate.
#
# Production `kalari serve` refuses every observer. This rehearsal uses a
# harness-only entry point, tests/live/observer-harness.lean, that calls the
# same dispatcher with an observer setup. `kalari serve` cannot reach it.
#
# The alias egress rule is the msb pool (172.16.0.0/12), not a /32. The runtime
# allocates the /30 at create and has no post-create rule change. A second
# sandbox reaches the observer because the msb gateway proxy presents every
# sandbox as 127.0.0.1. A host firewall on the observer port cannot tell them
# apart. The test prints that result and does not claim isolation.
#
# Budget: zero model calls. Clef calls are counted and redirected to a local
# fake. The Lambo store uses the fixture embedder. No inference key is read.
#
# Requires TOOL_BIN with: kalari, kalari-aashaan, msb, vimanam 2.1.0, lambo
# 0.9.x built with the embed-fixture feature, and lake on PATH (or LAKE set).
# Run after `lake build`:
#
#   TOOL_BIN=/absolute/tool/dir tests/live/observer.sh
set -euo pipefail
umask 022
cd "$(dirname "$0")/../.."
repo=$(pwd -P)

: "${TOOL_BIN:?absolute directory with kalari, kalari-aashaan, msb, vimanam, lambo}"
[[ "$TOOL_BIN" = /* ]] || { echo 'TOOL_BIN must be absolute' >&2; exit 2; }
for bin in kalari kalari-aashaan msb vimanam lambo; do
  [[ -x "$TOOL_BIN/$bin" ]] || { echo "missing $bin in TOOL_BIN" >&2; exit 2; }
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
transcript="tests/live/observer-transcript.txt"
api_pids=()
sandbox_before="$work/sandboxes-before.json"
sandbox_after="$work/sandboxes-after.json"
sandbox_before_failed=0
known_sandboxes=(probe-a probe-b peer-a peer-b peer-c kalari-observer-probe-a kalari-observer-probe-b)

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
  local -a args=(python3 -I "bench/apis/${suite}/server.py" --bind 127.0.0.1 --port "$port" --v1 "$v1")
  if [[ "$name" == settlements-grading ]]; then
    args+=(--retry-journal "$work/settlements-grading-journal.jsonl")
  fi
  "${args[@]}" >"$work/${name}.log" 2>&1 &
  api_pids+=("$!")
  wait_api "$port" "$name"
}

# An observer is a payouts server with a trusted trace filter. A killed service
# can leave one behind, so kill by its unique arguments and fail if one remains.
observer_pids() {
  ps -eo pid,args | awk '$2 ~ /python/ && index($0, "bench/apis/payouts/server.py") && index($0, "--trace-client 127.0.0.1") { print $1 }'
}

# Known observer test names from this test and earlier reproductions. Remove
# them by name so a clean before-list is possible.
remove_known_sandboxes() {
  local name
  for name in "${known_sandboxes[@]}"; do
    "$TOOL_BIN/msb" remove -f "$name" >/dev/null 2>&1 || true
  done
}

# The observer test owns the kalari- namespace. Remove every sandbox in it,
# including a stray one from an earlier run.
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
    remove_known_sandboxes
    remove_kalari_sandboxes
    if ! "$TOOL_BIN/msb" list --format json >"$sandbox_after" 2>"$work/msb-list-after.err"; then
      echo "cleanup: msb list failed; sandbox cleanup is unproven" >&2
      status=1
    else
      python3 -I - "$sandbox_before" "$sandbox_after" "$TOOL_BIN/msb" "$work/sandboxes-left.json" "${known_sandboxes[@]}" <<'PY'
import json, subprocess, sys
before_path, after_path, msb, left_path = sys.argv[1:5]
known = set(sys.argv[5:])
def names(path):
    try:
        with open(path) as stream:
            return {row.get("name", "") for row in json.load(stream)}
    except Exception as exc:
        print(f"cleanup: cannot read {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
removed = sorted(name for name in names(after_path) - names(before_path)
                 if name.startswith("kalari-") or name in known)
for name in removed:
    subprocess.run([msb, "remove", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
json.dump(removed, open(left_path, "w"))
if removed:
    print("cleanup: removed leftover sandboxes:", ",".join(removed))
PY
      if ! "$TOOL_BIN/msb" list --format json >"$sandbox_after" 2>>"$work/msb-list-after.err"; then
        echo "cleanup: msb list failed; sandbox cleanup is unproven" >&2
        status=1
      else
        left=$(python3 -I - "$sandbox_before" "$sandbox_after" "${known_sandboxes[@]}" <<'PY'
import json, sys
known = set(sys.argv[3:])
def names(path):
    try:
        with open(path) as stream:
            return {row.get("name", "") for row in json.load(stream)}
    except Exception as exc:
        print(f"cleanup: cannot read {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
print(len({name for name in names(sys.argv[2]) - names(sys.argv[1])
           if name.startswith("kalari-") or name in known}))
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

say "observer rehearsal: no inference; Clef calls are counted and blocked by a local fake"
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

# A stray kalari-extra sandbox must not survive. Create one when possible,
# then remove every kalari- entry before the before-list.
stray_created=0
if ! "$TOOL_BIN/msb" list --format json 2>/dev/null | grep -q '"name": "kalari-extra"'; then
  if "$TOOL_BIN/msb" create --name kalari-extra --cpus 1 --memory 256M --no-net \
      --pull never python:3.13-slim >/dev/null 2>&1; then
    stray_created=1
  fi
fi
if [[ "$stray_created" == 1 ]]; then
  say "sandboxes: stray kalari-extra created"
fi
remove_known_sandboxes
remove_kalari_sandboxes
if ! "$TOOL_BIN/msb" list --format json >"$sandbox_before" 2>"$work/msb-list-before.err"; then
  echo "observer rehearsal: initial msb list failed; sandbox cleanup is unproven" >&2
  sandbox_before_failed=1
  echo '[]' >"$sandbox_before"
else
  python3 -I - "$sandbox_before" "${known_sandboxes[@]}" <<'PY'
import json, sys
names = {row.get("name", "") for row in json.load(open(sys.argv[1]))}
known = set(sys.argv[2:])
left = sorted(name for name in names if name.startswith("kalari-") or name in known)
if left:
    raise SystemExit("observer test sandboxes remain: " + ",".join(left))
PY
  say "sandboxes: before list has no observer test sandboxes"
fi

payouts_live=$(free_port)
observer_port=$(free_port)
settlements_live=$(free_port)
settlements_grading=$(free_port)
start_api payouts-live payouts "$payouts_live" on
start_api settlements-live settlements "$settlements_live" on
start_api settlements-grading settlements "$settlements_grading" off
say "apis: payouts live=loopback:${payouts_live}, payouts observer=loopback:${observer_port}, settlements live=loopback:${settlements_live}, settlements grading=loopback:${settlements_grading}"

# One private Lambo store with the fixture embedder. Seed every change kind
# from both real Vimanam diffs. No semantic lesson exists before the run.
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
"$TOOL_BIN/vimanam" diff --format json \
  bench/workspaces/payout-sync/specs/openapi-v1.yaml \
  bench/workspaces/payout-sync/specs/openapi-v2.yaml >"$work/payouts-diff.json"
"$TOOL_BIN/vimanam" diff --format json \
  bench/workspaces/settlement-reconcile/specs/schema-v1.graphql \
  bench/workspaces/settlement-reconcile/specs/schema-v2.graphql >"$work/settlements-diff.json"
python3 -I - "$work/payouts-diff.json" "$work/settlements-diff.json" >"$work/kinds.txt" <<'PY'
import json, sys
kinds = set()
for path in sys.argv[1:]:
    kinds.update(change["kind"] for change in json.load(open(path))["changes"])
for kind in sorted(kinds):
    print(kind)
PY
while IFS= read -r kind; do
  "$TOOL_BIN/lambo" derive --config "$work/lambo.toml" --session kalari-live \
    --agent kalari-live --content "$kind" --kind resource >/dev/null
done <"$work/kinds.txt"
say "lambo: private fixture store provisioned, change kinds seeded: $(tr '\n' ',' <"$work/kinds.txt" | sed 's/,$//')"

for suite in payouts settlements; do
  mkdir -p "$work/$suite/candidate" "$work/$suite/baseline"
  cp "bench/apis/$suite/reference/correct.py" "$work/$suite/candidate/consumer.py"
  cp "bench/apis/$suite/reference/v1_unchanged.py" "$work/$suite/baseline/consumer.py"
done
cp bench/apis/settlements/reference/partial_output.py "$work/settlements/candidate/partial_output.py"
mkdir -p "$work/checks" "$work/evidence"
cp bench/workspaces/payout-sync/specs/openapi-v1.yaml "$work/payouts/old.yaml"
cp bench/workspaces/payout-sync/specs/openapi-v2.yaml "$work/payouts/new.yaml"
cp bench/workspaces/settlement-reconcile/specs/schema-v1.graphql "$work/settlements/old.graphql"
cp bench/workspaces/settlement-reconcile/specs/schema-v2.graphql "$work/settlements/new.graphql"

python3 -I - "$work" "$TOOL_BIN" "$repo" "$payouts_live" "$observer_port" \
  "$settlements_live" "$settlements_grading" "$LAKE" <<'PY'
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

work = Path(sys.argv[1])
tools = Path(sys.argv[2])
repo = Path(sys.argv[3])
payouts_live, observer_port, settlements_live, settlements_grading = map(int, sys.argv[4:8])
lake = sys.argv[8]
msb = str(tools / "msb")
known_sandboxes = ["probe-a", "probe-b", "peer-a", "peer-b", "peer-c",
                   "kalari-observer-probe-a", "kalari-observer-probe-b"]
caps = {"timeout_ms": 30000, "output_cap_bytes": 65536, "memory_mib": 512}
alias = "host.microsandbox.internal"
endpoint = lambda port: {"host": alias, "port": port}
allowed = [endpoint(payouts_live), endpoint(observer_port), endpoint(settlements_live), endpoint(settlements_grading)]
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

def session(name, suite, live_port, artifact):
    root = work / suite
    return {
        "session_id": name, "repo_scope": "live",
        "workspace": str(root / "candidate"),
        "old_spec": str(root / ("old.yaml" if suite == "payouts" else "old.graphql")),
        "new_spec": str(root / ("new.yaml" if suite == "payouts" else "new.graphql")),
        "baseline": {
            "workspace": str(root / "baseline"),
            "command": ["python3", str(root / "baseline/consumer.py"),
                        "--base-url", f"http://{alias}:{live_port}", "--out", artifact],
            "caps": caps, "allowlist": [endpoint(live_port)],
        },
        "check_workspace": str(work / "checks"),
        "evidence_workspace": str(work / "evidence"),
        "artifact": artifact,
        "aashaan": str((tools / "kalari-aashaan").resolve()),
        "tool_path": str(tools) + ":/usr/local/bin:/usr/bin:/bin",
    }

payouts_setup = session("live-payouts", "payouts", payouts_live, "payouts.jsonl")
payouts_setup["observer"] = {
    "server": str((repo / "bench/apis/payouts/server.py").resolve()),
    "endpoint": endpoint(observer_port),
}
settlements_setup = session("live-settlements", "settlements", settlements_live, "settlements.jsonl")
(work / "payouts-session.json").write_text(json.dumps(payouts_setup, indent=2) + "\n")
(work / "settlements-session.json").write_text(json.dumps(settlements_setup, indent=2) + "\n")
bad = json.loads(json.dumps(payouts_setup))
bad["observer"]["endpoint"]["host"] = "127.0.0.1"
(work / "bad-session.json").write_text(json.dumps(bad, indent=2) + "\n")
missing = json.loads(json.dumps(payouts_setup))
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

def observer_rows(port=None):
    listing = subprocess.run(["ps", "-eo", "pid,args"], capture_output=True, text=True).stdout
    found = []
    for row in listing.splitlines():
        if "bench/apis/payouts/server.py" not in row:
            continue
        if "--trace-client 127.0.0.1" not in row:
            continue
        if port is not None and f"--port {port}" not in row:
            continue
        found.append(row.strip())
    return found

def observer_pids(port=None):
    return [int(row.split(None, 1)[0]) for row in observer_rows(port)]

def lambo_children():
    listing = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout
    config = str(work / "lambo.toml")
    return [row for row in listing.splitlines() if config in row and "lambo" in row]

def harness_processes():
    listing = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout
    return [row for row in listing.splitlines() if "observer-harness.lean" in row]

class Service:
    def __init__(self, tag, setup_path, harness=True):
        self.tag = tag
        self.index = 0
        self.model_calls = None
        self.count_path = work / f"model-calls-{tag}.txt"
        self.stderr = open(work / f"{tag}.stderr", "wb")
        service_env = dict(env)
        if harness:
            command = [lake, "env", "lean", "--run", "tests/live/observer-harness.lean",
                       str(work / "config.json"), str(setup_path)]
            service_env["KALARI_OBSERVER_HARNESS"] = "1"
            service_env["KALARI_HARNESS_COUNT_FILE"] = str(self.count_path)
            service_env["KALARI_HARNESS_DECISIONS_URL"] = fake_url
        else:
            command = [str(tools / "kalari"), "serve", str(work / "config.json"), str(setup_path)]
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

HEADER_PROBE = r"""
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        row = {"peer": self.client_address[0], "xff": self.headers.get("X-Forwarded-For")}
        with open(sys.argv[2], "a") as stream:
            stream.write(json.dumps(row) + "\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
"""

def apply_firewall(port, gateway):
    # Allow the observed gateway on the observer port, then drop the rest of
    # the pool. -I inserts the last rule first, so the ACCEPT stays above DROP.
    drop = ["iptables", "-w", "-I", "INPUT", "-p", "tcp", "--dport", str(port),
            "-s", "172.16.0.0/12", "-j", "DROP"]
    allow = ["iptables", "-w", "-I", "INPUT", "-p", "tcp", "--dport", str(port),
             "-s", gateway, "-j", "ACCEPT"]
    rules = [drop, allow]
    installed = []
    try:
        for rule in rules:
            result = subprocess.run(rule, capture_output=True, text=True)
            if result.returncode != 0:
                for done in reversed(installed):
                    subprocess.run(["iptables", "-w", "-D"] + done[3:], capture_output=True, text=True)
                detail = (result.stderr or result.stdout).strip().splitlines()
                reason = detail[-1] if detail else f"exit {result.returncode}"
                return rules, f"unavailable: {reason}"
            installed.append(rule)
    except FileNotFoundError:
        for done in reversed(installed):
            subprocess.run(["iptables", "-w", "-D"] + done[3:], capture_output=True, text=True)
        return rules, "unavailable: iptables not found"
    return rules, "installed"

def sandbox_names():
    result = subprocess.run([msb, "list", "--format", "json"], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit("msb list failed")
    return {row.get("name", "") for row in json.loads(result.stdout)}

def sandbox_request(name, port, limit):
    run = subprocess.run([msb, "exec", name, "--", "python3", "-c",
        f"import urllib.request; print(urllib.request.urlopen('http://host.microsandbox.internal:{port}/v2/payouts?limit={limit}', timeout=5).status)"],
        capture_output=True, text=True)
    return run.stdout.strip() or f"exit={run.returncode}"

def header_request(name, port):
    run = subprocess.run([msb, "exec", name, "--", "python3", "-c",
        f"import urllib.request; print(urllib.request.urlopen('http://host.microsandbox.internal:{port}/x', timeout=5).status)"],
        capture_output=True, text=True)
    return run.stdout.strip() or f"exit={run.returncode}"

def process_args(pid):
    result = subprocess.run(["ps", "-o", "args=", "-p", str(pid)], capture_output=True, text=True)
    return result.stdout.strip()

def lean_child(parent):
    listing = subprocess.run(["ps", "-eo", "pid,ppid,args"], capture_output=True, text=True).stdout
    for row in listing.splitlines():
        fields = row.split(None, 2)
        if len(fields) == 3 and fields[1] == str(parent) and "lean" in fields[2]:
            return int(fields[0])
    return None

def second_sandbox_test():
    observer_probe = free_port()
    header_port = free_port()
    trace = work / "observer-probe-trace.jsonl"
    header_log = work / "observer-probe-headers.jsonl"
    observer = subprocess.Popen(["python3", "-I", str(repo / "bench/apis/payouts/server.py"),
        "--bind", "127.0.0.1", "--port", str(observer_probe), "--v1", "off",
        "--trace", str(trace), "--trace-client", "127.0.0.1"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    header = subprocess.Popen(["python3", "-I", "-c", HEADER_PROBE, str(header_port), str(header_log)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    names = ["kalari-observer-probe-a", "kalari-observer-probe-b"]
    before = sandbox_names()
    rules, firewall = [], "not attempted"
    try:
        wait_port(observer_probe)
        wait_port(header_port)
        for name in names:
            subprocess.run([msb, "remove", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run([msb, "create", "--name", name, "--cpus", "1", "--memory", "256M", "--no-net",
                "--net-rule", f"allow@172.16.0.0/12:tcp:{observer_probe}",
                "--net-rule", f"allow@172.16.0.0/12:tcp:{header_port}",
                "--pull", "never", "python:3.13-slim"],
                check=True, stdout=subprocess.DEVNULL)
        gateway = subprocess.run([msb, "exec", names[0], "--", "sh", "-c",
            "grep 'host.microsandbox' /etc/hosts | head -1 | cut -f1"],
            capture_output=True, text=True, check=True).stdout.strip()
        if not gateway:
            raise SystemExit("probe sandbox has no host gateway")
        first = sandbox_request(names[0], observer_probe, 1)
        header_request(names[0], header_port)
        rules, firewall = apply_firewall(observer_probe, gateway)
        second = sandbox_request(names[1], observer_probe, 2)
        header_request(names[1], header_port)
        counts = [json.loads(row).get("count") for row in trace.read_text().splitlines() if row.strip()]
        headers = [json.loads(row) for row in header_log.read_text().splitlines() if row.strip()]
        xff = [row.get("xff") for row in headers]
        blocked = second != "200"
        rule_text = f"INPUT -p tcp --dport {observer_probe} -s {gateway} -j ACCEPT, INPUT -p tcp --dport {observer_probe} -s 172.16.0.0/12 -j DROP"
        line(f"egress: alias_rule=allow@172.16.0.0/12:tcp:{observer_probe} observed_gateway={gateway}")
        line(f"firewall: rules=\"{rule_text}\" result={firewall} applied_before_second=1")
        line(f"second sandbox: probe_a={first} probe_b={second} trace_counts={counts} xff={xff} firewall_blocked={1 if blocked else 0}")
        if first != "200":
            raise SystemExit("first sandbox probe did not reach the observer")
        if second == "200":
            if 2 not in counts:
                raise SystemExit("second sandbox request is not in the observer trace")
            line("second sandbox: second_event=present isolation=not-established")
        else:
            if firewall != "installed":
                raise SystemExit("the second sandbox failed without a firewall")
            if 2 in counts:
                raise SystemExit("the blocked second request is still in the trace")
            line("second sandbox: second_event=absent isolation=firewall-blocked")
        if len(xff) != 2:
            raise SystemExit(f"expected two header probes: {xff}")
        if any(value is not None for value in xff):
            raise SystemExit(f"unexpected X-Forwarded-For: {xff}")
    finally:
        if firewall == "installed":
            for rule in reversed(rules):
                subprocess.run(["iptables", "-w", "-D"] + rule[3:], capture_output=True, text=True)
        for name in names:
            subprocess.run([msb, "remove", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for name in sorted(sandbox_names() - before):
            if name.startswith("kalari-"):
                subprocess.run([msb, "remove", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for proc in (header, observer):
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()

def mid_run_kill_test():
    root = work / "kill"
    (root / "candidate").mkdir(parents=True, exist_ok=True)
    (root / "baseline").mkdir(parents=True, exist_ok=True)
    (root / "candidate/sleep.py").write_text("import time\ntime.sleep(60)\n")
    setup = json.loads(json.dumps(payouts_setup))
    setup["session_id"] = "live-kill"
    setup["workspace"] = str(root / "candidate")
    setup["baseline"]["workspace"] = str(root / "baseline")
    setup["baseline"]["command"] = ["python3", str(root / "baseline/consumer.py")]
    setup["artifact"] = "kill.jsonl"
    (work / "kill-session.json").write_text(json.dumps(setup, indent=2) + "\n")
    before = sandbox_names()
    service = Service("kill", work / "kill-session.json", harness=True)
    try:
        service.call("what_changed", {"old_spec": setup["old_spec"], "new_spec": setup["new_spec"]})
        service.send("run_in_sandbox", {
            "workspace": setup["workspace"],
            "command": ["python3", str(root / "candidate/sleep.py")],
            "caps": caps, "allowlist": [endpoint(observer_port)]})
        found = []
        deadline = time.time() + 60
        while time.time() < deadline:
            found = observer_pids(observer_port)
            if found:
                break
            time.sleep(0.2)
        if not found:
            raise SystemExit("mid-run kill test did not start an observer")
        line("mid-run kill: observer_started=1")
        pgid = os.getpgid(service.proc.pid)
        child = lean_child(service.proc.pid)
        if child is not None:
            os.kill(child, signal.SIGKILL)
            line("mid-run kill: killed=lean")
        elif "lean" in process_args(service.proc.pid):
            os.kill(service.proc.pid, signal.SIGKILL)
            line("mid-run kill: killed=lean")
        else:
            os.kill(service.proc.pid, signal.SIGKILL)
            line("mid-run kill: killed=lake-wrapper")
        try:
            service.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        service.stderr.close()
        time.sleep(0.5)
        leaked = observer_pids(observer_port)
        line(f"mid-run kill: after_service_sigkill observer_leaked={len(leaked)}")
        os.killpg(pgid, signal.SIGKILL)
        deadline = time.time() + 10
        while time.time() < deadline:
            if not observer_pids(observer_port):
                break
            time.sleep(0.1)
        remaining = observer_pids(observer_port)
        if remaining:
            raise SystemExit(f"observer survived its process group: {remaining}")
        line("mid-run kill: after_group_cleanup observer_remaining=0")
    finally:
        for name in sorted(sandbox_names() - before):
            if name.startswith("kalari-"):
                subprocess.run([msb, "remove", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if service.proc.poll() is None:
            service.kill()
        service.stderr.close()

services = []
fake_log = work / "fake-decisions.jsonl"
fake_port = free_port()
fake = subprocess.Popen(["python3", "-I", "-c", FAKE_DECISIONS, str(fake_port), str(fake_log)],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
fake_url = f"http://127.0.0.1:{fake_port}/v1/systemone"
try:
    wait_port(fake_port)
    if set(known_sandboxes) & sandbox_names():
        raise SystemExit("observer test sandboxes remain before the run")
    line(f"decisions: local_fake=loopback:{fake_port} real_endpoint=blocked")

    # 1. Production refuses every observer configuration.
    production_refusal("valid observer", work / "payouts-session.json")
    production_refusal("caller address", work / "bad-session.json")
    production_refusal("missing server", work / "missing-server-session.json")

    # 2. Verified payouts run through the harness. The observer must see the B5
    #    retry trace and the run must pass every check before a lesson can publish.
    payouts = Service("payouts", work / "payouts-session.json")
    services.append(payouts)
    changed = payouts.call("what_changed", {
        "old_spec": payouts_setup["old_spec"], "new_spec": payouts_setup["new_spec"]})
    payout_kinds = [change["kind"] for change in changed["changes"]]
    line(f"payouts what_changed: kinds={','.join(sorted(set(payout_kinds)))}")
    command = ["python3", str(work / "payouts/candidate/consumer.py"),
               "--base-url", f"http://{alias}:{observer_port}", "--out", "payouts.jsonl"]
    report = payouts.call("run_in_sandbox", {
        "workspace": payouts_setup["workspace"], "command": command,
        "caps": caps, "allowlist": [endpoint(observer_port)]})
    show_run("payouts run_in_sandbox", report)
    if not report["passed"]:
        raise SystemExit("payouts run did not pass")
    payouts_run = report["run_id"]

    lessons = payouts.call("record_lesson", {"run_id": payouts_run})
    if not lessons:
        raise SystemExit("payouts run published no lesson")
    for lesson in lessons:
        observation = lesson["observation"]
        if "429" not in observation or "identical request" not in observation:
            raise SystemExit("payouts lesson does not carry the retry observation")
        if lesson["check"]["id"] != "candidate-v1-truth-v1" or lesson["check"]["command"][2] != "payouts.jsonl":
            raise SystemExit("payouts lesson does not keep its payouts check")
        line(f"payouts record_lesson: observation={observation!r}")
        line(f"payouts record_lesson: check={lesson['check']['id']} command={lesson['check']['command']}")
        line(f"payouts record_lesson: memory_concept_id={lesson['memory_concept_id']}")
    payouts.close()
    if observer_pids(observer_port):
        raise SystemExit("payouts service left its observer")
    line("processes: payouts_observer_reaped=1")
    if lambo_children():
        raise SystemExit("payouts service left a Lambo child")

    # 3. Settlements recalls the linked constraint as a required check, then the
    #    trusted checker is rebound to settlements.jsonl for this upgrade.
    settlements = Service("settlements", work / "settlements-session.json")
    services.append(settlements)
    changed = settlements.call("what_changed", {
        "old_spec": settlements_setup["old_spec"], "new_spec": settlements_setup["new_spec"]})
    settlement_kinds = sorted({change["kind"] for change in changed["changes"]})
    line(f"settlements what_changed: kinds={','.join(settlement_kinds)}")
    recalled = settlements.call("recall_lessons", {"change_kinds": settlement_kinds})
    required = [entry for entry in recalled if entry["status"] == "required"]
    if not any(entry["lesson"]["check"]["id"] == "candidate-v1-truth-v1" and
               entry["lesson"]["observation"] for entry in required):
        raise SystemExit("settlements did not recall the payouts lesson as required")
    for entry in required:
        if entry["lesson"]["check"]["id"] == "candidate-v1-truth-v1":
            line(f"settlements recall_lessons: status={entry['status']} check={entry['lesson']['check']['id']} "
                 f"command={entry['lesson']['check']['command']}")
            line(f"settlements recall_lessons: observation={entry['lesson']['observation']!r}")

    def settlements_run(tag, consumer, expected):
        command = ["python3", str(work / "settlements/candidate/consumer.py"),
                   "--base-url", f"http://{alias}:{settlements_grading}", "--out", "settlements.jsonl"]
        command[1] = str(work / "settlements/candidate" / consumer)
        report = settlements.call("run_in_sandbox", {
            "workspace": settlements_setup["workspace"], "command": command,
            "caps": caps, "allowlist": [endpoint(settlements_grading)]})
        show_run(tag, report)
        if report["passed"] != expected:
            raise SystemExit(f"{tag}: passed={report['passed']}, want {expected}")
        return report

    correct = settlements_run("settlements correct", "consumer.py", True)
    partial = settlements_run("settlements partial_output", "partial_output.py", False)
    for report, tag in ((correct, "correct"), (partial, "partial")):
        checks = check_names(report)
        truth = checks.get("candidate-v1-truth-v1")
        diff = checks.get("differential-v1")
        if truth is None or diff is None:
            raise SystemExit(f"{tag}: recalled or differential check missing")
        if tag == "correct" and not (truth["passed"] and diff["passed"]):
            raise SystemExit("correct settlements run did not pass the recalled and differential checks")
        if tag == "partial":
            if truth["passed"] or diff["passed"]:
                raise SystemExit("partial-output run passed a recalled or differential check")
            line(f"settlements partial_output: recalled_detail={truth['detail']!r}")
            line(f"settlements partial_output: differential_detail={diff['detail']!r}")
    settlements.close()
    if lambo_children():
        raise SystemExit("settlements service left a Lambo child")

    # 4. The evidence store proves the rebind and the published lesson.
    store = evidence(work / "evidence/.kalari/evidence.jsonl")
    page = [r for r in store if r["kind"] == "page-observation" and r["run_id"] == payouts_run]
    if not page or "rate_limit_retry" not in page[0]["payload"]["behaviors"]:
        raise SystemExit("payouts page observation does not carry rate_limit_retry")
    line(f"evidence: payouts page observation behaviors={page[0]['payload']['behaviors']}")
    lesson_records = [r for r in store if r["kind"] == "lesson" and r["run_id"] == payouts_run]
    if not lesson_records or not lesson_records[0]["payload"]["observation"]:
        raise SystemExit("payouts lesson evidence is empty")
    line(f"evidence: published lesson={lesson_records[0]['payload']['observation']!r}")

    run_records = {r["run_id"]: r for r in store if r["kind"] == "run"}
    for report, tag in ((correct, "correct"), (partial, "partial")):
        record = run_records.get(report["run_id"])
        if record is None:
            raise SystemExit(f"{tag}: evidence run missing")
        check = next((c for c in record["payload"]["checks"] if c["id"] == "candidate-v1-truth-v1"), None)
        if check is None:
            raise SystemExit(f"{tag}: evidence has no candidate truth check")
        if "settlements.jsonl" not in check["command"] or "payouts.jsonl" in check["command"]:
            raise SystemExit(f"{tag}: check was not rebound to settlements.jsonl: {check['command']}")
        if tag == "correct":
            line(f"evidence: settlements check rebound command={check['command']}")

    # 5. Retry counts are derived from the evidence and the grading journal.
    journal_path = work / "settlements-grading-journal.jsonl"
    if not journal_path.exists():
        raise SystemExit("settlements grading journal missing")
    journal = [json.loads(row) for row in journal_path.read_text().splitlines() if row.strip()]
    throttled = sum(1 for row in journal if row.get("status") == 429)
    retried = sum(1 for row in journal if row.get("matching_retry"))
    payouts_retries = 1 if "rate_limit_retry" in page[0]["payload"]["behaviors"] else 0
    if payouts_retries != 1:
        raise SystemExit("payouts page observation has no rate_limit_retry")
    line(f"retries: agent_http=not-applicable grading_http=not-applicable "
         f"sandbox_payouts={payouts_retries} sandbox_settlements_429={throttled} "
         f"sandbox_settlements_retries={retried}")

    # 6. The alias rule is the msb pool. A second sandbox reaches the observer,
    #    and the gateway proxy shows both as loopback, so a host firewall on the
    #    observer port cannot tell them apart.
    second_sandbox_test()

    # 7. A mid-run SIGKILL leaves the observer. The process group removes it.
    mid_run_kill_test()

    # 8. Measured model calls and remaining processes.
    total = sum(item.model_calls or 0 for item in services if item.model_calls is not None)
    if total != 0:
        raise SystemExit(f"model calls were made: {total}")
    fake_calls = len(fake_log.read_text().splitlines()) if fake_log.exists() else 0
    line(f"decisions: fake_requests={fake_calls} model_calls={total}")
    if fake_calls != 0:
        raise SystemExit(f"the blocked decision endpoint received {fake_calls} requests")
    remaining_rows = observer_rows()
    if remaining_rows:
        raise SystemExit("observer process remains: " + " | ".join(remaining_rows))
    if harness_processes():
        raise SystemExit("harness process remains")
    if lambo_children():
        raise SystemExit("lambo child remains")
    remaining_sandboxes = sandbox_names()
    if set(known_sandboxes) & remaining_sandboxes or any(
        name.startswith("kalari-") for name in remaining_sandboxes):
        raise SystemExit("observer test sandbox remains")
    line("sandboxes: observer_test_remaining=0")
    line("processes: observer_remaining=0 service_remaining=0 lambo_remaining=0")
finally:
    for name in known_sandboxes:
        subprocess.run([msb, "remove", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for name in sandbox_names():
        if name.startswith("kalari-"):
            subprocess.run([msb, "remove", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for item in services:
        if item.proc.poll() is None:
            item.kill()
        try:
            item.stderr.close()
        except Exception:
            pass
    try:
        os.killpg(os.getpgid(fake.pid), signal.SIGKILL)
    except ProcessLookupError:
        pass
    fake.wait()
PY

say "rehearsal: observe -> publish -> recall -> enforce"
