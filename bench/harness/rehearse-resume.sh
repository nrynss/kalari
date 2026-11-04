#!/usr/bin/env bash
# No-inference rehearsal for condition 1's continuous session.
#
# It drives the real `opencode run --standalone` against a loopback scripted
# provider. Run one creates the session in workspace A. Run two resumes that
# session after A's contents are replaced with the settlements tree. The
# rehearsal then runs the real measures code and the real grader on the output
# produced from A. Nothing leaves loopback and no key is used.
set -euo pipefail
umask 022

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OPENCODE=${KALARI_OPENCODE:-$(command -v opencode)}
parent=${TMPDIR:-/tmp/opencode}
mkdir -p "$parent"
TMP=$(mktemp -d "$parent/kalari-rehearse.XXXXXX")
ROOT=$TMP/root
STAGE=$TMP/stage
A=$ROOT/runs/payouts/workspace
XDG=$ROOT/state/condition-1-xdg
STATE=$ROOT/state/condition-1.json
SETTLE_STAGE=$STAGE/settlement-reconcile
mkdir -p "$ROOT/state" "$ROOT/runs/payouts" "$STAGE" "$XDG/data" "$XDG/state" "$XDG/cache" "$XDG/config"

api_pid=""
provider_pid=""
cleanup() {
  local rc=$?
  [[ -n "$provider_pid" ]] && kill "$provider_pid" 2>/dev/null || true
  [[ -n "$api_pid" ]] && kill "$api_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT

ok() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }
pycheck() {
  local desc=$1
  shift
  if python3 "$@"; then ok "$desc"; else fail "$desc"; fi
}

pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

echo "== environment"
[[ -x "$OPENCODE" ]] || fail "opencode is not executable: $OPENCODE"
ver=$("$OPENCODE" --version 2>/dev/null || true)
[[ "$ver" == *2.2.5* ]] || fail "need OpenCode 2.2.5, got: ${ver:-none}"
ok "OpenCode 2.2.5: $ver"
[[ -f "$REPO/bench/apis/settlements/reference/correct.py" ]] || fail "missing settlements reference consumer"
ok "using the real settlements reference consumer"

echo "== local settlements API (v1 retired, as the hidden grader runs it)"
api_port=$(pick_port)
timeout 300 python3 -I "$REPO/bench/apis/settlements/server.py" --port "$api_port" --v1 off \
  > "$TMP/api.out" 2> "$TMP/api.err" &
api_pid=$!
for _ in $(seq 1 100); do
  if curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -d '{"query":"{ __typename }"}' "http://127.0.0.1:$api_port/v2/graphql" | grep -qx 200; then
    break
  fi
  sleep 0.1
done
curl -s -o /dev/null -H 'Content-Type: application/json' \
  -d '{"query":"{ __typename }"}' "http://127.0.0.1:$api_port/v2/graphql" \
  || fail "settlements API did not start"
ok "settlements API on loopback, v1 retired"

echo "== scripted provider"
provider_port_file=$TMP/provider.port
timeout 300 python3 "$HERE/scripted_provider.py" \
  --port-file "$provider_port_file" \
  --trace "$TMP/provider.jsonl" \
  --consumer-source "$REPO/bench/apis/settlements/reference/correct.py" \
  --api-base-url "http://127.0.0.1:$api_port" > "$TMP/provider.out" 2> "$TMP/provider.err" &
provider_pid=$!
for _ in $(seq 1 100); do
  [[ -s "$provider_port_file" ]] && break
  sleep 0.1
done
[[ -s "$provider_port_file" ]] || fail "scripted provider did not write its port"
provider_port=$(cat "$provider_port_file")
ok "scripted provider on loopback port $provider_port"

write_config() { # $1 directory
  local dir=$1
  cat > "$dir/opencode.jsonc" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "providers": {
    "scripted": {
      "name": "Scripted rehearsal provider",
      "env": ["SCRIPTED_KEY"],
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "http://127.0.0.1:$provider_port/v1" },
      "models": { "scripted": { "name": "Scripted" } }
    }
  },
  "model": "scripted/scripted",
  "permissions": [
    { "action": "webfetch", "resource": "*", "effect": "deny" },
    { "action": "websearch", "resource": "*", "effect": "deny" },
    { "action": "external_directory", "resource": "*", "effect": "deny" }
  ]
}
JSON
}

run_session() { # $1 workspace, $2 prompt, $3 events, $4 stderr, $5 session id (or empty)
  local ws=$1 prompt=$2 events=$3 stderr=$4 sid=${5:-}
  local -a args=(run --standalone --format json --auto)
  [[ -n "$sid" ]] && args+=(--session "$sid")
  args+=("$prompt")
  ( cd "$ws" && env \
      XDG_DATA_HOME="$XDG/data" XDG_STATE_HOME="$XDG/state" \
      XDG_CACHE_HOME="$XDG/cache" XDG_CONFIG_HOME="$XDG/config" \
      SCRIPTED_KEY=rehearsal \
      timeout 120 "$OPENCODE" "${args[@]}" > "$events" 2> "$stderr" )
}

echo "== run one: payouts session in workspace A"
cp -a "$REPO/bench/workspaces/payout-sync/." "$A/"
write_config "$A"
git -C "$A" init -q
git -C "$A" config user.email rehearsal@localhost
git -C "$A" config user.name rehearsal
git -C "$A" add -A
git -C "$A" commit -qm "v1 consumer"
payout_stage_digest=$(python3 "$HERE/tree_digest.py" "$A")
run_session "$A" "PHASE=payouts: start the payout upgrade" "$TMP/events-1.jsonl" "$TMP/opencode-1.err"
[[ -f "$A/payouts-canary.txt" ]] || fail "run one did not write its canary in A"
grep -qx "payouts" "$A/payouts-canary.txt" || fail "run one canary has the wrong content"
sid=$(python3 - "$TMP/events-1.jsonl" <<'PY'
import json, sys
seen = []
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("sessionID"):
        seen.append(event["sessionID"])
if not seen:
    raise SystemExit("no session id in run one")
if len(set(seen)) != 1:
    raise SystemExit("run one produced more than one session id")
print(seen[0])
PY
)
ok "run one created session $sid in A"
ok "run one canary is in A"

python3 "$HERE/continuation.py" save \
  --state "$STATE" \
  --workspace "$A" \
  --xdg "$XDG" \
  --session-id "$sid" \
  --digest "$payout_stage_digest"
[[ -s "$STATE" ]] || fail "continuation state was not written"
ok "continuation state records workspace, XDG and session"

echo "== run two: replace A's contents, resume the same session"
cp -a "$REPO/bench/workspaces/settlement-reconcile/." "$SETTLE_STAGE/"
settle_stage_digest=$(python3 "$HERE/tree_digest.py" "$SETTLE_STAGE")
# This is the shared continuation helper remote.sh sources.
. "$HERE/continuation.sh"
load_condition1_state "$STATE"
[[ "$STATE_WORKSPACE" == "$A" ]] || fail "state workspace is not A"
[[ "$STATE_XDG" == "$XDG" ]] || fail "state XDG is not the payouts XDG"
[[ "$STATE_SESSION_ID" == "$sid" ]] || fail "state session is not run one's session"
find "$STATE_WORKSPACE" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a "$SETTLE_STAGE/." "$STATE_WORKSPACE/"
write_config "$STATE_WORKSPACE"
git -C "$STATE_WORKSPACE" init -q
git -C "$STATE_WORKSPACE" config user.email rehearsal@localhost
git -C "$STATE_WORKSPACE" config user.name rehearsal
git -C "$STATE_WORKSPACE" add -A
git -C "$STATE_WORKSPACE" commit -qm "v1 settlements consumer"
workspace_digest=$(python3 "$HERE/tree_digest.py" "$STATE_WORKSPACE")
[[ "$workspace_digest" == "$settle_stage_digest" ]] || fail "A's contents do not match the settlements stage"
ok "A's contents were replaced with the settlements tree (digest $workspace_digest)"
[[ ! -e "$A/payouts-canary.txt" ]] || fail "the payouts canary survived the replacement"
ok "the payouts canary is gone"

run_session "$A" "PHASE=settlements: continue with the settlement upgrade" \
  "$TMP/events-2.jsonl" "$TMP/opencode-2.err" "$sid"
[[ -f "$A/settlements-canary.txt" ]] || fail "the resumed session did not write its canary in A"
grep -qx "settlements" "$A/settlements-canary.txt" || fail "the settlements canary has the wrong content"
ok "the resumed session wrote its canary by relative path in A"
outside=$(find "$TMP" -name settlements-canary.txt ! -path "$A/settlements-canary.txt" -print -quit)
[[ -z "$outside" ]] || fail "the resumed canary also appeared outside A: $outside"
ok "the canary appears only in A"
[[ -f "$A/settlement_reconcile.py" ]] || fail "the resumed session did not write the consumer in A"
ok "the resumed session wrote the consumer in A"
[[ -s "$A/settlements.jsonl" ]] || fail "the consumer wrote no settlements output in A"
ok "the consumer wrote settlements.jsonl in A"

pycheck "the event log resumed the saved session id" - "$TMP/events-2.jsonl" "$sid" <<'PY'
import json, sys
seen = set()
for line in open(sys.argv[1]):
    try:
        event = json.loads(line)
    except ValueError:
        continue
    if event.get("sessionID"):
        seen.add(event["sessionID"])
if seen != {sys.argv[2]}:
    raise SystemExit(f"session ids in event log: {sorted(seen)}")
PY
pycheck "the scripted provider offered and used write and shell" - "$TMP/provider.jsonl" <<'PY'
import json, sys
offered = set()
actions = []
resumed = False
for line in open(sys.argv[1]):
    row = json.loads(line)
    offered.update(row.get("tools") or [])
    action = row.get("action") or {}
    if action.get("kind") == "call":
        actions.append(action.get("name"))
    if row.get("settlements_context") and row.get("payouts_context"):
        resumed = True
if not {"write", "shell"}.issubset(offered):
    raise SystemExit(f"tools offered: {sorted(offered)}")
if not {"write", "shell"}.issubset(actions):
    raise SystemExit(f"tool calls made: {actions}")
if not resumed:
    raise SystemExit("run two did not carry the payouts conversation")
PY
ok "run two carried the payouts conversation into the settlements phase"

echo "== measures and grading from A"
python3 "$HERE/measures.py" \
  --events "$TMP/events-2.jsonl" \
  --upgrade settlements \
  --workspace "$A" \
  --xdg "$XDG/data" \
  --elapsed 1 \
  --exit-code 0 \
  --out "$TMP/analysis.json" \
  --materialize "$TMP/first-v2-src" \
  --workspace-digest "$workspace_digest" \
  --stage-digest "$settle_stage_digest" \
  --session-id-expected "$sid" > "$TMP/measures.out" 2> "$TMP/measures.err"
pycheck "measures recorded workspace A, its digest and the resumed session" - "$TMP/analysis.json" "$A" "$workspace_digest" "$sid" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("workspace") != sys.argv[2]:
    raise SystemExit(f"workspace: {doc.get('workspace')}")
if doc.get("workspace_digest") != sys.argv[3]:
    raise SystemExit("workspace digest missing")
if doc.get("session_id_expected") != sys.argv[4] or doc.get("session_identity_ok") is not True:
    raise SystemExit("resumed session identity not recorded")
if doc.get("workspace_identity_ok") is not True:
    raise SystemExit("workspace identity not recorded")
if not (doc.get("first_v2") or {}).get("found"):
    raise SystemExit("measures did not find the first v2 consumer run")
if (doc.get("first_v2") or {}).get("basis") != "snapshot":
    raise SystemExit(f"first v2 basis: {(doc.get('first_v2') or {}).get('basis')}")
PY
[[ -f "$TMP/first-v2-src/settlement_reconcile.py" ]] || fail "measures did not materialize first-v2-src"
ok "measures materialized the first v2 source"

pycheck "first-attempt and final consumer source are identical" - \
  "$TMP/first-v2-src/settlement_reconcile.py" "$A/settlement_reconcile.py" <<'PY'
import hashlib, sys
def digest(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()
a, b = digest(sys.argv[1]), digest(sys.argv[2])
if a != b:
    raise SystemExit(f"first {a} != final {b}")
PY

# Grade the output the resumed session produced in A.
grade_json=$(python3 -I "$REPO/bench/graders/grade.py" settlements "$A/settlements.jsonl" || true)
pycheck "the newly produced output from A passes the hidden grader" - "$grade_json" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
if doc.get("verdict") != "PASS":
    raise SystemExit(json.dumps(doc))
PY

# The first grading pass uses first-v2-src, as remote.sh does.
mkdir -p "$TMP/first-grade"
cp -a "$TMP/first-v2-src/." "$TMP/first-grade/"
python3 -I "$TMP/first-grade/settlement_reconcile.py" \
  --base-url "http://127.0.0.1:$api_port" --out "$TMP/first-grade/out.jsonl" > /dev/null
first_grade=$(python3 -I "$REPO/bench/graders/grade.py" settlements "$TMP/first-grade/out.jsonl" || true)
pycheck "the first-attempt source grades PASS against the same output contract" - "$first_grade" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
if doc.get("verdict") != "PASS":
    raise SystemExit(json.dumps(doc))
PY

mismatch_rc=0
python3 "$HERE/measures.py" \
  --events "$TMP/events-2.jsonl" \
  --upgrade settlements \
  --workspace "$A" \
  --xdg "$XDG/data" \
  --elapsed 1 \
  --exit-code 0 \
  --out "$TMP/analysis-mismatch.json" \
  --session-id-expected "ses_wrong" > /dev/null 2> "$TMP/measures-mismatch.err" || mismatch_rc=$?
[[ "$mismatch_rc" != 0 ]] || fail "measures accepted a mismatched session id"
pycheck "a session id mismatch is recorded and fails" - "$TMP/analysis-mismatch.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("session_identity_ok") is not False:
    raise SystemExit("session_identity_ok was not false")
PY
ok "measures fails on a session identity mismatch"

echo "== grading status cases"
echo "EXIT 0" > "$TMP/ok.status"
python3 "$HERE/grade_status.py" \
  --status "$TMP/ok.status" \
  --fresh-output "$A/settlements.jsonl" \
  --workspace "$A" \
  --output-name settlements.jsonl \
  --exec-rc 0 \
  --pass final \
  --out "$TMP/ok.grade.json"
pycheck "exit 0 with fresh output is ok" - "$TMP/ok.grade.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("grade_status") != "ok" or doc.get("output_present") is not True:
    raise SystemExit(json.dumps(doc))
PY

mkdir -p "$TMP/no-output-ws" "$TMP/none"
printf '{"id":"stale"}\n' > "$TMP/no-output-ws/settlements.jsonl"
echo "EXIT 0" > "$TMP/no-output.status"
python3 "$HERE/grade_status.py" \
  --status "$TMP/no-output.status" \
  --fresh-output "$TMP/none/out.jsonl" \
  --workspace "$TMP/no-output-ws" \
  --output-name settlements.jsonl \
  --exec-rc 0 \
  --pass final \
  --out "$TMP/no-output.grade.json"
pycheck "exit 0 without fresh output is no_output, not stale output" - "$TMP/no-output.grade.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("grade_status") != "no_output":
    raise SystemExit(json.dumps(doc))
if doc.get("output_present") is not False or doc.get("stale_output_ignored") is not True:
    raise SystemExit(json.dumps(doc))
if "consumer exited 0" not in (doc.get("note") or ""):
    raise SystemExit(f"note: {doc.get('note')}")
PY

echo "EXIT create" > "$TMP/grader-failed.status"
python3 "$HERE/grade_status.py" \
  --status "$TMP/grader-failed.status" \
  --fresh-output "$TMP/none/out.jsonl" \
  --workspace "$TMP/no-output-ws" \
  --output-name settlements.jsonl \
  --exec-rc 0 \
  --pass final \
  --out "$TMP/grader-failed.grade.json"
pycheck "a sandbox create failure is grader_failed" - "$TMP/grader-failed.grade.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("grade_status") != "grader_failed" or doc.get("consumer_exit") is not None:
    raise SystemExit(json.dumps(doc))
if "EXIT create" not in (doc.get("note") or ""):
    raise SystemExit(f"note: {doc.get('note')}")
PY

echo "== stale output cannot rescue a crashed consumer"
printf '{"id":"stale","amountCents":1}\n' > "$A/settlements.jsonl"
mkdir -p "$TMP/crash"
cat > "$TMP/crash/settlement_reconcile.py" <<'PY'
raise SystemExit(1)
PY
crash_rc=0
( cd "$TMP/crash" && python3 settlement_reconcile.py \
    --base-url "http://127.0.0.1:$api_port" --out "$TMP/crash/out.jsonl" ) || crash_rc=$?
[[ "$crash_rc" != 0 ]] || fail "the crashing consumer exited 0"
[[ ! -e "$TMP/crash/out.jsonl" ]] || fail "the crashing consumer wrote fresh output"
echo "EXIT $crash_rc" > "$TMP/crash/status"
python3 "$HERE/grade_status.py" \
  --status "$TMP/crash/status" \
  --fresh-output "$TMP/crash/out.jsonl" \
  --workspace "$A" \
  --output-name settlements.jsonl \
  --exec-rc 0 \
  --pass final \
  --out "$TMP/crash/grade.json"
pycheck "the crash is a crash, not missing output, and the stale file is ignored" - "$TMP/crash/grade.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("grade_status") != "consumer_crashed":
    raise SystemExit(f"grade_status: {doc.get('grade_status')}")
if doc.get("output_present") is not False:
    raise SystemExit("stale output was treated as fresh")
if doc.get("stale_output_ignored") is not True:
    raise SystemExit("stale workspace output was not recorded as ignored")
if "crashed" not in (doc.get("note") or ""):
    raise SystemExit(f"note: {doc.get('note')}")
PY
stale_grade=$(python3 -I "$REPO/bench/graders/grade.py" settlements "$TMP/crash/out.jsonl" || true)
pycheck "grading the missing fresh output fails without reading A's stale file" - "$stale_grade" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
if doc.get("verdict") != "FAIL" or doc.get("output_present") is not False:
    raise SystemExit(json.dumps(doc))
PY
if grep -q 'msb copy -q "$name:/w/src/' "$HERE/remote.sh"; then
  fail "remote.sh still has the stale-output fallback"
fi
ok "remote.sh has no workspace-output fallback"

echo "== missing continuation state fails before opencode starts"
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/opencode" <<'SH'
#!/usr/bin/env bash
touch "$FAKE_OPENCODE_MARKER"
exit 42
SH
chmod +x "$TMP/fakebin/opencode"
export FAKE_OPENCODE_MARKER=$TMP/fake-opencode-called
export PATH="$TMP/fakebin:$PATH"
settlements_entry() {
  load_condition1_state "${1:-$STATE}" || return $?
  opencode run --standalone --auto "PHASE=settlements"
}
check_state_rejected() { # $1 label, $2 state file
  rm -f "$FAKE_OPENCODE_MARKER"
  if settlements_entry "$2"; then
    fail "$1 state was accepted"
  fi
  [[ ! -e "$FAKE_OPENCODE_MARKER" ]] || fail "$1 state reached opencode"
  ok "$1 state fails before opencode"
}
check_state_rejected "missing" "$TMP/no-such-state.json"
printf '{"session_id":"x","xdg":"%s"}\n' "$XDG" > "$TMP/incomplete.json"
check_state_rejected "incomplete" "$TMP/incomplete.json"
python3 - "$STATE" "$TMP/missing-workspace.json" "$TMP/nope" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["workspace"] = sys.argv[3]
json.dump(doc, open(sys.argv[2], "w"))
PY
check_state_rejected "missing workspace" "$TMP/missing-workspace.json"
python3 - "$STATE" "$TMP/missing-xdg.json" "$TMP/no-xdg" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["xdg"] = sys.argv[3]
json.dump(doc, open(sys.argv[2], "w"))
PY
check_state_rejected "missing xdg" "$TMP/missing-xdg.json"
python3 - "$STATE" "$TMP/missing-session.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["session_id"] = "ses_does_not_exist"
json.dump(doc, open(sys.argv[2], "w"))
PY
check_state_rejected "missing session" "$TMP/missing-session.json"
load_condition1_state "$STATE" > /dev/null
ok "the saved state still loads"

echo
echo "rehearsal passed: 1 session, 2 workspace states, real resume, real measures, real grade"
