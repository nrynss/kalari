#!/usr/bin/env bash
# Live run_in_sandbox test. Run on the benchmark VM after staging the built
# binaries and Vimanam 2.1.0 / Lambo 0.9.0 in TOOL_BIN. No inference calls.
set -euo pipefail
umask 022
cd "$(dirname "$0")/../.."
: "${TOOL_BIN:?absolute directory with kalari, kalari-aashaan, msb, vimanam, lambo}"
: "${API_HOST:?benchmark VM address}"
: "${PAYOUTS_PORT:=18080}"
: "${SETTLEMENTS_PORT:=18081}"
: "${PAYOUTS_V2_PORT:=18090}"
: "${SETTLEMENTS_V2_PORT:=18091}"
case "${1:-}" in payouts|settlements) suite=$1;; *) echo 'usage: run.sh payouts|settlements case' >&2; exit 2;; esac
case "${2:-}" in correct|cursor_loop|no_dedupe|single_page|v1_unchanged|short_page_stop|empty_page_stop|keep_first) variant=$2;; *) echo 'unknown case' >&2; exit 2;; esac
[[ -f "bench/apis/$suite/reference/$variant.py" ]] || { echo 'case does not belong to suite' >&2; exit 2; }
[[ "$TOOL_BIN" = /* && "$API_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'invalid tool directory or API address' >&2; exit 2; }
for bin in kalari kalari-aashaan msb vimanam lambo; do [[ -x "$TOOL_BIN/$bin" ]] || { echo "missing $bin" >&2; exit 2; }; done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work"/{candidate,baseline,checks,evidence}
cp "bench/apis/$suite/reference/$variant.py" "$work/candidate/consumer.py"
cp "bench/apis/$suite/reference/v1_unchanged.py" "$work/baseline/consumer.py"
if [[ $suite == payouts ]]; then
  port=$PAYOUTS_PORT; v2port=$PAYOUTS_V2_PORT; artifact=payouts.jsonl; specs=bench/workspaces/payout-sync/specs; old=openapi-v1.yaml; new=openapi-v2.yaml
else
  port=$SETTLEMENTS_PORT; v2port=$SETTLEMENTS_V2_PORT; artifact=settlements.jsonl; specs=bench/workspaces/settlement-reconcile/specs; old=schema-v1.graphql; new=schema-v2.graphql
fi
cp "$specs/$old" "$work/old.${old##*.}"
cp "$specs/$new" "$work/new.${new##*.}"
cat >"$work/lambo.toml" <<TOML
[store]
kind = "sqlite"
path = "$work/lambo.db"
[embedder]
kind = "fixture"
[serve]
default_session = "kalari-live"
TOML
"$TOOL_BIN/lambo" provision --config "$work/lambo.toml" >/dev/null
# Seed the isolated graph with change-kind resources; no semantic lessons and
# no external embedding or decision service are involved.
"$TOOL_BIN/vimanam" diff --format json "$work/old.${old##*.}" "$work/new.${new##*.}" >"$work/diff.json"
while IFS= read -r kind; do
  "$TOOL_BIN/lambo" derive --config "$work/lambo.toml" --session kalari-live \
    --agent kalari-live --content "$kind" --kind resource >/dev/null
done < <(python3 -c 'import json,sys; print("\n".join(sorted({x["kind"] for x in json.load(open(sys.argv[1]))["changes"]})))' "$work/diff.json")
export KALARI_LIVE_DUMMY=live-test-placeholder
python3 - "$work" "$TOOL_BIN" "$API_HOST" "$port" "$v2port" "$artifact" "$suite" "$variant" <<'PY'
import json, os, subprocess, sys
work, tools, host, port, v2port, artifact, suite, variant = sys.argv[1:]
port, v2port = int(port), int(v2port)
caps = {"timeout_ms": 3000 if variant == "cursor_loop" else 30000, "output_cap_bytes": 65536, "memory_mib": 512}
baseline_net = [{"host": host, "port": port}]
candidate_net = [{"host": host, "port": v2port}]
endpoint = {"endpoint":"https://example.invalid", "model":"unused", "api_key_env":"KALARI_LIVE_DUMMY"}
config = {"models":endpoint, "decisions":dict(endpoint, endpoint="https://api.vultrinference.com/v1/systemone", model="clef"), "sandbox":{"backend":"microsandbox", "caps":caps, "allowlist":baseline_net+candidate_net}, "lambo":{"command":[tools+"/lambo", "serve"], "config_path":work+"/lambo.toml"}}
ext = "yaml" if suite == "payouts" else "graphql"
old, new = work+"/old."+ext, work+"/new."+ext
command = lambda root, apiport: ["python3", root+"/consumer.py", "--base-url", f"http://{host}:{apiport}", "--out", artifact]
setup = {"session_id":"live", "repo_scope":"live", "workspace":work+"/candidate", "old_spec":old, "new_spec":new, "baseline":{"workspace":work+"/baseline", "command":command(work+"/baseline",port), "caps":caps, "allowlist":baseline_net}, "check_workspace":work+"/checks", "evidence_workspace":work+"/evidence", "artifact":artifact, "aashaan":tools+"/kalari-aashaan", "tool_path":tools+":/usr/local/bin:/usr/bin:/bin"}
for name, value in [("config",config),("session",setup)]:
    with open(work+"/"+name+".json", "w") as f: json.dump(value,f)
p = subprocess.Popen([tools+"/kalari", "serve", work+"/config.json", work+"/session.json"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
def call(i, name, args):
    p.stdin.write(json.dumps({"jsonrpc":"2.0", "id":i, "method":"tools/call", "params":{"name":name,"arguments":args}})+"\n"); p.stdin.flush()
    line=p.stdout.readline()
    if not line: raise RuntimeError("service closed without response")
    response=json.loads(line); result=response.get("result",{})
    if result.get("isError") or "error" in response: raise RuntimeError("tool error: "+result.get("content",[{}])[0].get("text", "protocol error"))
    return json.loads(result["content"][0]["text"])
try:
    call(1,"what_changed",{"old_spec":old,"new_spec":new})
    report=call(2,"run_in_sandbox",{"workspace":work+"/candidate", "command":command(work+"/candidate",v2port), "caps":caps, "allowlist":candidate_net})
    listed=json.loads(subprocess.check_output([tools+"/msb", "list", "--format", "json"], text=True) or "[]")
    prefix="kalari-"+report["run_id"]
    if any(x.get("name", "").startswith(prefix) for x in listed): raise RuntimeError("run sandbox remains")
    verdict=report["verdict"]["verdict"]
    checks={x["check_id"]:x for x in report["checks"]}
    diff=checks.get("differential-v1",{})
    print(json.dumps({"suite":suite,"case":variant,"verdict":verdict,"exit":report["verdict"].get("exit_code"),"passed":report["passed"],"differential":diff.get("detail"),"sandboxes_clear":True}),flush=True)
    if variant == "correct": assert verdict == "exited" and report["passed"] and diff.get("passed")
    elif variant == "cursor_loop": assert verdict == "killed_timeout" and not report["passed"]
    elif variant == "v1_unchanged": assert verdict == "exited" and report["verdict"]["exit_code"] == 1 and not report["passed"]
    else:
        expected = {
            ("payouts", "no_dedupe"): "0 missing, 0 extra, 24 duplicates, 0 changed",
            ("payouts", "single_page"): "2331 missing, 0 extra, 0 duplicates, 0 changed",
            ("payouts", "short_page_stop"): "2331 missing, 0 extra, 0 duplicates, 0 changed",
            ("settlements", "no_dedupe"): "0 missing, 0 extra, 19 duplicates, 0 changed",
            ("settlements", "single_page"): "1773 missing, 0 extra, 0 duplicates, 1 changed",
            ("settlements", "empty_page_stop"): "1473 missing, 0 extra, 1 duplicates, 3 changed",
            ("settlements", "keep_first"): "0 missing, 0 extra, 0 duplicates, 19 changed",
        }
        assert verdict == "exited" and report["verdict"]["exit_code"] == 0 and not report["passed"] and diff.get("detail") == expected[(suite,variant)]
finally:
    p.stdin.close()
    try: p.wait(timeout=15)
    except subprocess.TimeoutExpired: p.kill(); p.wait()
PY
