#!/usr/bin/env bash
# Live observer rehearsal: payouts page observation -> retry lesson ->
# settlements recall -> trusted-check enforcement. Not part of the gate.
#
# Budget: zero model calls. The only traffic is loopback on the host and
# local microVM traffic through msb. The Lambo store uses the fixture
# embedder. No inference key is read or sent.
#
# Requires TOOL_BIN with: kalari, kalari-aashaan, msb, vimanam 2.1.0, lambo 0.9.x.
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
unset VULTR_INFERENCE_API_KEY 2>/dev/null || true
# The service requires a non-empty key environment name at startup. This is a
# placeholder, not a key: no model or decision call is made by this rehearsal.
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
  pids=$(ps -eo pid,args | awk -v cfg="$work/config.json" 'index($0, "kalari serve") && index($0, cfg) { print $1 }')
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
  if [[ -f "$sandbox_before" ]]; then
    "$TOOL_BIN/msb" list --format json >"$sandbox_after" 2>/dev/null || echo '[]' >"$sandbox_after"
    python3 -I - "$sandbox_before" "$sandbox_after" "$TOOL_BIN/msb" "$work/sandboxes-left.json" <<'PY'
import json, subprocess, sys
before_path, after_path, msb, left_path = sys.argv[1:]
def names(path):
    try:
        return {row.get("name", "") for row in json.load(open(path))}
    except Exception:
        return set()
removed = sorted(name for name in names(after_path) - names(before_path)
                 if name.startswith("kalari-"))
for name in removed:
    subprocess.run([msb, "remove", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
json.dump(removed, open(left_path, "w"))
if removed:
    print("cleanup: removed leftover sandboxes:", ",".join(removed))
PY
    "$TOOL_BIN/msb" list --format json >"$sandbox_after" 2>/dev/null || echo '[]' >"$sandbox_after"
    left=$(python3 -I - "$sandbox_before" "$sandbox_after" <<'PY'
import json, sys
def names(path):
    try:
        return {row.get("name", "") for row in json.load(open(path))}
    except Exception:
        return set()
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
  if [[ "${KEEP_WORK:-}" == 1 ]]; then
    echo "cleanup: kept work directory"
  else
    rm -rf "$work"
  fi
  exit "$status"
}
trap cleanup EXIT

exec > >(sanitize | tee "$transcript") 2>&1

say "observer rehearsal: budget model_calls=0 inference_key=absent placeholder=set"
say "versions: ${vimanam_version}, ${lambo_version}, msb $("$TOOL_BIN/msb" --version | head -1)"
say "embedder: fixture (local, no external model calls)"
"$TOOL_BIN/msb" list --format json >"$sandbox_before" 2>/dev/null || echo '[]' >"$sandbox_before"

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
  "$settlements_live" "$settlements_grading" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

work = Path(sys.argv[1])
tools = Path(sys.argv[2])
repo = Path(sys.argv[3])
payouts_live, observer_port, settlements_live, settlements_grading = map(int, sys.argv[4:8])
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

env = {
    "PATH": str(tools) + ":/usr/local/bin:/usr/bin:/bin",
    "HOME": os.environ.get("HOME", ""),
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "KALARI_LIVE_DUMMY": "live-test-placeholder",
}

def line(text):
    print(text, flush=True)

class Service:
    def __init__(self, tag, setup_path):
        self.tag = tag
        self.index = 0
        self.stderr = open(work / f"{tag}.stderr", "wb")
        self.proc = subprocess.Popen(
            [str(tools / "kalari"), "serve", str(work / "config.json"), str(setup_path)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            text=True, cwd=repo, env=env)

    def call(self, name, args):
        self.index += 1
        request = {"jsonrpc": "2.0", "id": self.index, "method": "tools/call",
                   "params": {"name": name, "arguments": args}}
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()
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
            reply, _ = self.proc.communicate(timeout=60)
            status = self.proc.returncode
        except subprocess.TimeoutExpired:
            self.proc.kill()
            reply, _ = self.proc.communicate()
            status = -1
        self.stderr.close()
        if reply.strip():
            raise SystemExit(f"{self.tag}: unexpected stdout after close: {reply[:200]}")
        if status != 0:
            raise SystemExit(f"{self.tag}: service exited {status}")
        return status

def lambo_children():
    listing = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout
    config = str(work / "lambo.toml")
    return [row for row in listing.splitlines() if config in row and "lambo" in row]

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

# 1. Verified payouts run. The observer must see the B5 retry trace and the
#    run must pass every check before a lesson can be published.
payouts = Service("payouts", work / "payouts-session.json")
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
if lambo_children():
    raise SystemExit("payouts service left a Lambo child")

# 2. Settlements recalls the linked constraint as a required check, then the
#    trusted checker is rebound to settlements.jsonl for this upgrade.
settlements = Service("settlements", work / "settlements-session.json")
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

# 3. The evidence store proves the rebind and the published lesson.
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

# 4. Agent and grading HTTP retries are separate from sandbox B5 retries.
journal_path = work / "settlements-grading-journal.jsonl"
journal = [json.loads(row) for row in journal_path.read_text().splitlines() if row.strip()] if journal_path.exists() else []
throttled = sum(1 for row in journal if row.get("status") == 429)
retried = sum(1 for row in journal if row.get("matching_retry"))
line(f"retries: agent_http=0 grading_http=0 sandbox_payouts=1 sandbox_settlements_429={throttled} "
     f"sandbox_settlements_retries={retried}")

# 5. A caller-supplied guest address cannot establish exclusivity.
bad_config = work / "bad-session.json"
bad = subprocess.run(
    [str(tools / "kalari"), "serve", str(work / "config.json"), str(bad_config)],
    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, cwd=repo, env=env)
message = bad.stderr.strip().splitlines()[-1] if bad.stderr.strip() else ""
if bad.returncode == 0 or "observer requires verified exclusive guest source isolation" not in bad.stderr:
    raise SystemExit("unproven observer configuration was not refused")
line(f"refusal: exit={bad.returncode} message={message!r}")

# 6. Every service process is gone. The shell cleans up APIs and sandboxes.
line("services: payouts=reaped settlements=reaped lambo=reaped")
PY

say "rehearsal: observe -> publish -> recall -> enforce"
