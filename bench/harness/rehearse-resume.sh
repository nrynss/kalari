#!/usr/bin/env bash
# No-inference rehearsal for condition 1's continuous session.
#
# It drives real `opencode run --standalone` against a loopback scripted
# provider. Run one creates the session in the stable condition-1 workspace.
# Run two resumes that session after the workspace's contents are replaced with
# the settlements tree. The scripted agent's first settlements consumer is
# deliberately incomplete: it runs, fails the output contract, and is replaced
# by the reference consumer, which runs again. The rehearsal then checks the
# real condition-1 preparation (condition1.sh), the real grading path
# (grade_one.sh with a stub `msb`), the real measures, the real grader and
# structural checks on the production call sites.
# Nothing leaves loopback and no key is used.
#
# This is a resume test, not the reference arm's sandbox test. It uses the host
# `shell` tool, while the reference opencode.jsonc denies `shell` and runs the
# consumer through the microsandbox MCP `execute`. Do not read `sandbox_runs`
# from this rehearsal as a reference-arm number.
set -euo pipefail
umask 022

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

ok() { echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

# `set -e` must not swallow the friendly error when opencode is missing.
OPENCODE=${KALARI_OPENCODE:-}
[[ -n "$OPENCODE" ]] || OPENCODE=$(command -v opencode || true)
[[ -n "$OPENCODE" ]] || fail "opencode not found and KALARI_OPENCODE is not set"
[[ -x "$OPENCODE" ]] || fail "opencode is not executable: $OPENCODE"

parent=${TMPDIR:-/tmp/opencode}
mkdir -p "$parent"
TMP=$(mktemp -d "$parent/kalari-rehearse.XXXXXX")
ROOT=$TMP/root
STAGE=$TMP/stage
XDG=$ROOT/state/condition-1-xdg
STATE=$ROOT/state/condition-1.json
A=$ROOT/workspaces/condition-1

api_pid=""
provider_pid=""
cleanup() {
  local rc=$?
  [[ -n "$provider_pid" ]] && kill "$provider_pid" 2>/dev/null || true
  [[ -n "$api_pid" ]] && kill "$api_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  # Keep the logs only when debugging the rehearsal itself; the default removes
  # the temp directory.
  if [[ "${KALARI_REHEARSAL_KEEP:-0}" == 1 ]]; then
    echo "rehearsal logs kept in $TMP" >&2
  else
    rm -rf "$TMP"
  fi
  exit "$rc"
}
trap cleanup EXIT

pycheck() {
  local desc=$1
  shift
  if python3 "$@"; then ok "$desc"; else fail "$desc"; fi
}

sha() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
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
[[ -f "$HERE/rehearsal_first_attempt.py" ]] || fail "missing the first-attempt consumer"
ok "using the real settlements reference consumer and a first-attempt fixture"

# The production call sites must exist. The behavioural tests below exercise
# the shared modules themselves.
[[ -f "$HERE/remote.sh" ]] || fail "remote.sh is missing"
[[ -f "$HERE/run.sh" ]] || fail "run.sh is missing"
[[ -f "$HERE/condition1.sh" ]] || fail "condition1.sh is missing"
[[ -f "$HERE/grade_one.sh" ]] || fail "grade_one.sh is missing"
python3 "$HERE/structure_check.py" "$HERE" || fail "structural checks failed"
ok "structural checks passed"

echo "== stage"
mkdir -p "$ROOT/state" "$STAGE/workspaces"
for name in condition1.sh continuation.sh continuation.py tree_digest.py \
  grade_status.py grade_runner.py grade_one.sh result_grade.py; do
  cp "$HERE/$name" "$STAGE/$name"
done
cp -a "$REPO/bench/workspaces/payout-sync" "$STAGE/workspaces/payout-sync"
cp -a "$REPO/bench/workspaces/settlement-reconcile" "$STAGE/workspaces/settlement-reconcile"
ok "staged the harness and both workspaces under $STAGE"

echo "== local settlements API (v1 retired, as the hidden grader runs it)"
api_port=$(pick_port)
python3 -I "$REPO/bench/apis/settlements/server.py" --port "$api_port" --v1 off \
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
python3 "$HERE/scripted_provider.py" \
  --port-file "$provider_port_file" \
  --trace "$TMP/provider.jsonl" \
  --consumer-source "$REPO/bench/apis/settlements/reference/correct.py" \
  --first-consumer-source "$HERE/rehearsal_first_attempt.py" \
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

write_config "$STAGE"

# The production module, sourced from the working tree. remote.sh sources the
# same file from the staged harness on the VM.
. "$HERE/condition1.sh"

echo "== run one: payouts session in the stable condition-1 workspace"
mkdir -p "$ROOT/workspaces/stale-dir"
printf 'stale\n' > "$ROOT/workspaces/stale-dir/old.txt"
printf 'stale\n' > "$ROOT/workspaces/stale-file"
prepare_condition1 "$ROOT" "$STAGE" "$STAGE/workspaces/payout-sync" payouts
[[ "$WS" == "$A" ]] || fail "condition-1 payouts chose workspace $WS, not the stable workspace $A"
[[ "$XDG_BASE" == "$XDG" ]] || fail "condition-1 payouts chose XDG $XDG_BASE, not $XDG"
[[ "$SESSION_CONTINUED" == 0 ]] || fail "condition-1 payouts started as a continuation"
[[ ! -e "$ROOT/workspaces/stale-dir" ]] || fail "a stale workspace directory survived the payouts start"
[[ ! -e "$ROOT/workspaces/stale-file" ]] || fail "a stale workspace file survived the payouts start"
[[ -d "$A" ]] || fail "the condition-1 workspace is missing"
payout_stage_digest=$STAGE_DIGEST
ok "the workspace parent keeps only condition-1"
ok "the shared preparation chose the stable workspace $A (digest $payout_stage_digest)"

run_session "$A" "PHASE=payouts: start the payout upgrade" "$TMP/events-1.jsonl" "$TMP/opencode-1.err"
[[ -f "$A/payouts-canary.txt" ]] || fail "run one did not write its canary in $A"
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
ok "run one created session $sid in the stable workspace"

python3 "$HERE/continuation.py" save \
  --state "$STATE" \
  --workspace "$A" \
  --xdg "$XDG" \
  --session-id "$sid" \
  --start-digest "$payout_stage_digest"
[[ -s "$STATE" ]] || fail "continuation state was not written"
pycheck "continuation state records the workspace, XDG, session and start digest" - \
  "$STATE" "$A" "$XDG" "$sid" "$payout_stage_digest" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("workspace") != sys.argv[2]:
    raise SystemExit(f"workspace: {doc.get('workspace')}")
if doc.get("xdg") != sys.argv[3]:
    raise SystemExit(f"xdg: {doc.get('xdg')}")
if doc.get("session_id") != sys.argv[4]:
    raise SystemExit(f"session: {doc.get('session_id')}")
if doc.get("payouts_start_digest") != sys.argv[5]:
    raise SystemExit(f"start digest: {doc.get('payouts_start_digest')}")
if "workspace_digest" in doc:
    raise SystemExit("the old workspace_digest field is still present")
PY

echo "== run two: replace the workspace's contents, resume the same session"
prepare_condition1 "$ROOT" "$STAGE" "$STAGE/workspaces/settlement-reconcile" settlements
[[ "$WS" == "$A" ]] || fail "condition-1 settlements chose workspace $WS; the saved workspace condition requires $A"
[[ "$XDG_BASE" == "$XDG" ]] || fail "condition-1 settlements chose XDG $XDG_BASE, not $XDG"
[[ "$SESSION_ID" == "$sid" ]] || fail "condition-1 settlements chose session $SESSION_ID, not $sid"
[[ "$SESSION_CONTINUED" == 1 ]] || fail "condition-1 settlements did not continue the saved session"
settle_stage_digest=$STAGE_DIGEST
workspace_digest=$WORKSPACE_DIGEST
[[ "$workspace_digest" == "$settle_stage_digest" ]] || fail "the reused workspace does not match the settlements stage"
ok "the shared preparation reused $A and replaced its contents (digest $workspace_digest)"
[[ ! -e "$A/payouts-canary.txt" ]] || fail "the payouts canary survived the replacement"
ok "the payouts canary is gone"

# The state is gone before the session starts. A hard kill cannot leave a live
# state that a retry would resume.
[[ "$STATE_CONSUMED" == 1 ]] || fail "the settlements preparation did not consume the continuation state"
[[ ! -e "$STATE" ]] || fail "the settlements preparation left the continuation state live"
ok "the settlements preparation consumed the continuation state before the session"
second_rc=0
second_out=$(prepare_condition1 "$ROOT" "$STAGE" "$STAGE/workspaces/settlement-reconcile" settlements 2>&1) || second_rc=$?
[[ "$second_rc" != 0 ]] || fail "a second settlements preparation was accepted"
grep -q "Run a fresh condition-1 payouts first" <<<"$second_out" || fail "the retry error does not ask for a fresh condition-1 payouts run"
ok "a second settlements preparation fails before any session starts"

first_attempt_sha=$(sha "$HERE/rehearsal_first_attempt.py")
final_sha=$(sha "$REPO/bench/apis/settlements/reference/correct.py")
[[ "$first_attempt_sha" != "$final_sha" ]] || fail "the first attempt and the final consumer are identical"
ok "the first attempt ($first_attempt_sha) differs from the final consumer ($final_sha)"

run_session "$A" "PHASE=settlements: continue with the settlement upgrade" \
  "$TMP/events-2.jsonl" "$TMP/opencode-2.err" "$sid"
[[ -f "$A/settlements-canary.txt" ]] || fail "the resumed session did not write its canary in $A"
grep -qx "settlements" "$A/settlements-canary.txt" || fail "the settlements canary has the wrong content"
ok "the resumed session wrote its canary by relative path in $A"
outside=$(find "$TMP" -name settlements-canary.txt ! -path "$A/settlements-canary.txt" -print -quit)
[[ -z "$outside" ]] || fail "the resumed canary also appeared outside $A: $outside"
ok "the canary appears only in $A"
[[ -f "$A/settlement_reconcile.py" ]] || fail "the resumed session did not write the consumer in $A"
ok "the resumed session wrote the consumer in $A"
[[ -s "$A/settlements.jsonl" ]] || fail "the consumer wrote no settlements output in $A"
ok "the consumer wrote settlements.jsonl in $A"

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
pycheck "the scripted provider wrote two different consumers and ran each once" - "$TMP/provider.jsonl" <<'PY'
import json, sys
offered = set()
actions = []
resumed = False
for line in open(sys.argv[1]):
    row = json.loads(line)
    offered.update(row.get("tools") or [])
    action = row.get("action") or {}
    if action.get("kind") == "call":
        actions.append(action)
    if row.get("settlements_context") and row.get("payouts_context"):
        resumed = True
if not {"write", "shell"}.issubset(offered):
    raise SystemExit(f"tools offered: {sorted(offered)}")
shells = [a for a in actions if a.get("name") == "shell"]
consumer_writes = [
    a for a in actions
    if a.get("name") == "write"
    and str((a.get("arguments") or {}).get("path") or "").endswith("settlement_reconcile.py")
]
if len(shells) != 2:
    raise SystemExit(f"shell calls: {len(shells)}")
if len(consumer_writes) != 2:
    raise SystemExit(f"consumer writes: {len(consumer_writes)}")
first = consumer_writes[0]["arguments"]["content"]
final = consumer_writes[1]["arguments"]["content"]
if first == final:
    raise SystemExit("the provider wrote the same consumer twice")
if not resumed:
    raise SystemExit("run two did not carry the payouts conversation")
PY
ok "run two carried the payouts conversation into the settlements phase"

echo "== base state for the rejection cases"
# The rejection cases below need a valid base state. The production path never
# re-saves one. The session database and workspace still exist.
python3 "$HERE/continuation.py" save \
  --state "$STATE" \
  --workspace "$A" \
  --xdg "$XDG" \
  --session-id "$sid" \
  --start-digest "$payout_stage_digest"

echo "== measures and grading from the stable workspace"
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
pycheck "measures recorded the stable workspace, both attempts and the resumed session" - \
  "$TMP/analysis.json" "$A" "$workspace_digest" "$sid" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("workspace") != sys.argv[2]:
    raise SystemExit(f"workspace: {doc.get('workspace')}")
if doc.get("workspace_digest") != sys.argv[3]:
    raise SystemExit("workspace digest missing")
if doc.get("session_id") != sys.argv[4]:
    raise SystemExit(f"observed session id: {doc.get('session_id')}")
if doc.get("session_id_expected") != sys.argv[4] or doc.get("session_identity_ok") is not True:
    raise SystemExit("resumed session identity not recorded")
if doc.get("workspace_identity_ok") is not True:
    raise SystemExit("workspace identity not recorded")
if not (doc.get("first_v2") or {}).get("found"):
    raise SystemExit("measures did not find the first v2 consumer run")
if (doc.get("first_v2") or {}).get("basis") != "snapshot":
    raise SystemExit(f"first v2 basis: {(doc.get('first_v2') or {}).get('basis')}")
runs = doc.get("consumer_runs") or []
if len(runs) != 2:
    raise SystemExit(f"consumer runs: {len(runs)}")
if [r.get("status") for r in runs] != ["completed", "completed"]:
    raise SystemExit(f"consumer statuses: {[r.get('status') for r in runs]}")
if doc.get("sandbox_runs") != 2:
    raise SystemExit(f"sandbox runs: {doc.get('sandbox_runs')}")
PY
[[ -f "$TMP/first-v2-src/settlement_reconcile.py" ]] || fail "measures did not materialize first-v2-src"
ok "measures materialized the first v2 source"

materialized_sha=$(sha "$TMP/first-v2-src/settlement_reconcile.py")
[[ "$materialized_sha" == "$first_attempt_sha" ]] || fail \
  "first-v2-src is $materialized_sha, not the first attempt $first_attempt_sha; the workspace condition requires the first source, not the final one"
final_source_sha=$(sha "$A/settlement_reconcile.py")
[[ "$final_source_sha" == "$final_sha" ]] || fail \
  "the final consumer is $final_source_sha, not the reference consumer $final_sha"
ok "first-v2-src is the first attempt, not the final source"

# Grade the output the resumed session produced in A with the final consumer.
final_grade=$(python3 -I "$REPO/bench/graders/grade.py" settlements "$A/settlements.jsonl" || true)
pycheck "the final attempt passes the hidden grader" - "$final_grade" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
if doc.get("verdict") != "PASS":
    raise SystemExit(json.dumps(doc))
if doc.get("missing") != 0 or doc.get("duplicates") != 0:
    raise SystemExit(json.dumps(doc))
PY

# The first pass runs the materialized first-attempt source, as remote.sh does.
mkdir -p "$TMP/first-grade"
cp -a "$TMP/first-v2-src/." "$TMP/first-grade/"
python3 -I "$TMP/first-grade/settlement_reconcile.py" \
  --base-url "http://127.0.0.1:$api_port" --out "$TMP/first-grade/out.jsonl" > /dev/null
first_grade=$(python3 -I "$REPO/bench/graders/grade.py" settlements "$TMP/first-grade/out.jsonl" || true)
pycheck "the first attempt runs, produces output and fails the output contract" - "$first_grade" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
if doc.get("verdict") != "FAIL":
    raise SystemExit(json.dumps(doc))
if doc.get("records", 0) <= 0:
    raise SystemExit("the first attempt produced no output")
if (doc.get("missing") or 0) <= 0:
    raise SystemExit("the first attempt has no missing records")
PY
pycheck "the first grade reflects the first attempt, not the final one" - \
  "$first_grade" "$final_grade" <<'PY'
import json, sys
first, final = json.loads(sys.argv[1]), json.loads(sys.argv[2])
if first.get("verdict") != "FAIL" or final.get("verdict") != "PASS":
    raise SystemExit(f"verdicts: first {first.get('verdict')}, final {final.get('verdict')}")
if first.get("records") == final.get("records"):
    raise SystemExit("the first and final outputs have the same record count")
# run.sh's right-first-time is false when the first pass is not PASS.
if first.get("verdict") == "PASS":
    raise SystemExit("right first time would be true")
PY
ok "the first grade is FAIL and the final grade is PASS"

echo "== measures failures"
mismatch_rc=0
python3 "$HERE/measures.py" \
  --events "$TMP/events-2.jsonl" \
  --upgrade settlements \
  --workspace "$A" \
  --xdg "$XDG/data" \
  --elapsed 1 \
  --exit-code 0 \
  --out "$TMP/analysis-digest-mismatch.json" \
  --workspace-digest aaa \
  --stage-digest bbb > /dev/null 2> "$TMP/measures-digest-mismatch.err" || mismatch_rc=$?
[[ "$mismatch_rc" != 0 ]] || fail "measures accepted a workspace digest mismatch"
pycheck "a workspace digest mismatch is recorded and fails" - "$TMP/analysis-digest-mismatch.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("workspace_identity_ok") is not False:
    raise SystemExit(f"workspace_identity_ok: {doc.get('workspace_identity_ok')}")
PY
ok "measures fails on a workspace identity mismatch"

python3 "$HERE/measures.py" \
  --events "$TMP/events-2.jsonl" \
  --upgrade settlements \
  --workspace "$A" \
  --xdg "$XDG/data" \
  --elapsed 1 \
  --exit-code 0 \
  --out "$TMP/analysis-no-digest.json" > /dev/null 2>&1
pycheck "measures without digest arguments is a no-op" - "$TMP/analysis-no-digest.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("workspace_identity_ok") is not None:
    raise SystemExit(f"workspace_identity_ok: {doc.get('workspace_identity_ok')}")
PY
ok "measures without digest arguments does not fail"

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

pycheck "run.sh refuses a condition-1 settlements row without session identity" - "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import result_grade
bad = [
    {"session_continued": False, "session_identity_ok": True},
    {"session_continued": True, "session_identity_ok": None},
    {"session_continued": True, "session_identity_ok": False},
]
for doc in bad:
    try:
        result_grade.require_condition1_identity(1, "settlements", doc)
    except SystemExit:
        continue
    raise SystemExit(f"accepted: {doc}")
result_grade.require_condition1_identity(
    1, "settlements", {"session_continued": True, "session_identity_ok": True}
)
result_grade.require_condition1_identity(2, "settlements", {})
PY
ok "run.sh's result guard requires a continued, identity-checked condition-1 session"

pycheck "the result publishes the condition-1 and grading evidence" - "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import result_grade
cond = result_grade.condition1_evidence({
    "condition1_workspace": "/w/condition-1",
    "continuation_state_consumed": True,
    "continuation_state_consumed_at": "condition1_prepare",
})
if cond.get("condition1_workspace") != "/w/condition-1":
    raise SystemExit(cond)
if cond.get("continuation_state_consumed") is not True:
    raise SystemExit(cond)
if cond.get("continuation_state_consumed_at") != "condition1_prepare":
    raise SystemExit(cond)
grading = result_grade.grading_evidence({
    "first": {"workspace_checked": "/w/first"},
    "final": {"workspace_checked": "/w/final"},
})
if (grading.get("first") or {}).get("workspace_checked") != "/w/first":
    raise SystemExit(grading)
if (grading.get("final") or {}).get("workspace_checked") != "/w/final":
    raise SystemExit(grading)
PY
ok "the result carries the condition-1 and grading evidence fields"

echo "== denied consumer commands are not sandbox runs"
cat > "$TMP/denied-events.jsonl" <<'JSON'
{"type":"tool_use","sessionID":"ses_test","timestamp":1000,"part":{"tool":"shell","state":{"status":"error","input":{"command":"python3 settlement_reconcile.py --base-url http://127.0.0.1:1 --out settlements.jsonl"},"time":{"start":1000,"end":2000}}}}
{"type":"tool_use","sessionID":"ses_test","timestamp":2000,"part":{"tool":"bash","state":{"status":"error","input":{"command":"python3 settlement_reconcile.py --base-url http://127.0.0.1:1 --out settlements.jsonl"},"time":{"start":2000,"end":3000}}}}
JSON
cat > "$TMP/completed-events.jsonl" <<'JSON'
{"type":"tool_use","sessionID":"ses_test","timestamp":1000,"part":{"tool":"shell","state":{"status":"error","input":{"command":"python3 settlement_reconcile.py --base-url http://127.0.0.1:1 --out settlements.jsonl"},"time":{"start":1000,"end":2000}}}}
{"type":"tool_use","sessionID":"ses_test","timestamp":2000,"part":{"tool":"bash","state":{"status":"error","input":{"command":"python3 settlement_reconcile.py --base-url http://127.0.0.1:1 --out settlements.jsonl"},"time":{"start":2000,"end":3000}}}}
{"type":"tool_use","sessionID":"ses_test","timestamp":3000,"part":{"tool":"shell","state":{"status":"completed","input":{"command":"python3 settlement_reconcile.py --base-url http://127.0.0.1:1 --out settlements.jsonl"},"time":{"start":3000,"end":4000}}}}
JSON
mkdir -p "$TMP/empty-ws" "$TMP/empty-xdg"
python3 "$HERE/measures.py" \
  --events "$TMP/denied-events.jsonl" \
  --upgrade settlements \
  --workspace "$TMP/empty-ws" \
  --xdg "$TMP/empty-xdg" \
  --elapsed 1 \
  --exit-code 0 \
  --out "$TMP/denied.json"
pycheck "a denied shell consumer attempt gives sandbox_runs 0 and one denial" - "$TMP/denied.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("sandbox_runs") != 0:
    raise SystemExit(f"sandbox_runs: {doc.get('sandbox_runs')}")
if doc.get("consumer_runs"):
    raise SystemExit(f"consumer_runs: {doc.get('consumer_runs')}")
ev = doc.get("event_summary") or {}
if ev.get("shell_denied") != 1:
    raise SystemExit(f"shell_denied: {ev.get('shell_denied')}")
if ev.get("bash_denied") != 1:
    raise SystemExit(f"bash_denied: {ev.get('bash_denied')}")
if ev.get("consumer_denied") != 2:
    raise SystemExit(f"consumer_denied: {ev.get('consumer_denied')}")
PY
python3 "$HERE/measures.py" \
  --events "$TMP/completed-events.jsonl" \
  --upgrade settlements \
  --workspace "$TMP/empty-ws" \
  --xdg "$TMP/empty-xdg" \
  --elapsed 1 \
  --exit-code 0 \
  --out "$TMP/completed.json"
pycheck "a completed consumer run still counts once" - "$TMP/completed.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("sandbox_runs") != 1:
    raise SystemExit(f"sandbox_runs: {doc.get('sandbox_runs')}")
runs = doc.get("consumer_runs") or []
if len(runs) != 1 or runs[0].get("status") != "completed":
    raise SystemExit(f"consumer runs: {runs}")
PY
ok "denied shell and bash attempts are not sandbox runs"

echo "== grading status cases"
mkdir -p "$TMP/none"
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

mkdir -p "$TMP/no-output-ws"
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

for status in create launch usage; do
  printf 'EXIT %s\n' "$status" > "$TMP/grader-$status.status"
  python3 "$HERE/grade_status.py" \
    --status "$TMP/grader-$status.status" \
    --fresh-output "$TMP/none/out.jsonl" \
    --workspace "$TMP/no-output-ws" \
    --output-name settlements.jsonl \
    --exec-rc 0 \
    --pass final \
    --out "$TMP/grader-$status.grade.json"
done
pycheck "sandbox create, launch and usage failures are grader_failed" - \
  "$TMP/grader-create.grade.json" "$TMP/grader-launch.grade.json" "$TMP/grader-usage.grade.json" <<'PY'
import json, sys
for path in sys.argv[1:]:
    doc = json.load(open(path))
    if doc.get("grade_status") != "grader_failed":
        raise SystemExit(f"{path}: {doc.get('grade_status')}")
    if doc.get("consumer_exit") is not None:
        raise SystemExit(f"{path}: consumer_exit {doc.get('consumer_exit')}")
    if doc.get("output_present") is not False:
        raise SystemExit(f"{path}: output_present {doc.get('output_present')}")
PY
pycheck "a launch failure leaves lost and duplicated unmeasurable" - \
  "$HERE" "$TMP/grader-launch.grade.json" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import result_grade
doc = json.load(open(sys.argv[2]))
if doc.get("stale_output_ignored") is not True:
    raise SystemExit("the stale workspace output was not recorded as ignored")
missing = result_grade.grade_missing()
if missing.get("missing") is not None or missing.get("duplicates") is not None:
    raise SystemExit(f"missing output policy: {missing}")
PY
ok "EXIT launch is grader_failed with null consumer exit and unmeasurable counts"

echo "EXIT timeout" > "$TMP/timeout.status"
python3 "$HERE/grade_status.py" \
  --status "$TMP/timeout.status" \
  --fresh-output "$TMP/none/out.jsonl" \
  --workspace "$TMP/no-output-ws" \
  --output-name settlements.jsonl \
  --exec-rc 0 \
  --pass final \
  --out "$TMP/timeout.grade.json"
pycheck "EXIT timeout is still a consumer crash" - "$TMP/timeout.grade.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("grade_status") != "consumer_crashed" or doc.get("consumer_exit") != "timeout":
    raise SystemExit(json.dumps(doc))
if doc.get("output_present") is not False:
    raise SystemExit("timeout output_present was not false")
PY

printf '{"id":"partial"}\n' > "$TMP/partial.jsonl"
echo "EXIT 3" > "$TMP/partial.status"
python3 "$HERE/grade_status.py" \
  --status "$TMP/partial.status" \
  --fresh-output "$TMP/partial.jsonl" \
  --workspace "$TMP/no-output-ws" \
  --output-name settlements.jsonl \
  --exec-rc 0 \
  --pass final \
  --out "$TMP/partial.grade.json"
pycheck "a crash with partial fresh output is a crash with partial output graded" - "$TMP/partial.grade.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("grade_status") != "consumer_crashed" or doc.get("consumer_exit") != 3:
    raise SystemExit(json.dumps(doc))
if doc.get("output_present") is not True:
    raise SystemExit("partial output was not present")
if "partial output graded" not in (doc.get("note") or ""):
    raise SystemExit(f"note: {doc.get('note')}")
PY
ok "timeout, usage and partial-output crash cases classify correctly"

echo "== stale output cannot rescue a run that wrote nothing"
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

# The real grade_one: the guest runs, exits 0 and writes no /w/out.jsonl, while
# the workspace holds a stale settlements.jsonl. This is the production "which
# file is graded" decision. A workspace fallback of any spelling would put the
# stale file in $RUN/final.jsonl and turn no_output into ok.
echo "== the grading path never falls back to the workspace"
GRADE_RUN=$TMP/grade-run
mkdir -p "$GRADE_RUN" "$TMP/stub-bin" "$TMP/grade-ws"
printf '{"id":"stale","amountCents":1}\n' > "$TMP/grade-ws/settlements.jsonl"
cat > "$TMP/stub-bin/msb" <<'SH'
#!/usr/bin/env bash
# Stub msb. The grading guest exists, runs and reports EXIT 0, but /w/out.jsonl
# is never created. A copy of /w/src/settlements.jsonl or of the workspace
# output materializes the stale file, exactly as the old fallback would.
set -eu
cmd=${1:-}
shift || true
case "$cmd" in
  create|remove) exit 0 ;;
  exec)
    while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
    [[ $# -gt 0 ]] && shift
    case "${1:-}" in
      python3) echo "EXIT 0" ;;
      *) exit 0 ;;
    esac
    ;;
  copy)
    [[ "${1:-}" == "-q" ]] && shift
    src=${1:-}; dst=${2:-}
    case "$src" in
      */w/out.jsonl) exit 1 ;;
      */w/src/settlements.jsonl) cp "$STALE_WORKSPACE_FILE" "$dst" ;;
      */w/consumer.log) : > "$dst" ;;
    esac
    ;;
esac
exit 0
SH
chmod +x "$TMP/stub-bin/msb"
export STALE_WORKSPACE_FILE=$TMP/grade-ws/settlements.jsonl
(
  set -euo pipefail
  RUN=$GRADE_RUN
  RUN_ID=rehearsal
  STAGE=$STAGE
  CONSUMER=settlement_reconcile.py
  OUT_NAME=settlements.jsonl
  IP=127.0.0.1
  GRADE_PORT=1
  WS=$TMP/grade-ws
  export PATH="$TMP/stub-bin:$PATH"
  . "$HERE/grade_one.sh"
  grade_one "$WS" final
)
[[ ! -e "$GRADE_RUN/final.jsonl" ]] || fail "grade_one copied a workspace file as the fresh output"
pycheck "a grader run with no fresh output is no_output, not the workspace file" - \
  "$GRADE_RUN/final.grade.json" "$TMP/grade-ws" "$HERE" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[3])
import result_grade
doc = json.load(open(sys.argv[1]))
if doc.get("grade_status") != "no_output":
    raise SystemExit(json.dumps(doc))
if doc.get("output_present") is not False:
    raise SystemExit("workspace output was treated as fresh")
if doc.get("stale_output_ignored") is not True:
    raise SystemExit("stale workspace output was not recorded as ignored")
if doc.get("workspace_checked") != sys.argv[2]:
    raise SystemExit(f"workspace_checked: {doc.get('workspace_checked')}")
missing = result_grade.grade_missing()
if missing.get("missing") is not None or missing.get("duplicates") is not None:
    raise SystemExit(f"missing output policy: {missing}")
PY
ok "grade_one grades only the guest's fresh output"

# The first pass checks its own source tree for stale output, not the agent
# workspace the final pass used.
mkdir -p "$TMP/grade-first-src"
printf '{"id":"stale-first"}\n' > "$TMP/grade-first-src/settlements.jsonl"
(
  set -euo pipefail
  RUN=$GRADE_RUN
  RUN_ID=rehearsal
  STAGE=$STAGE
  CONSUMER=settlement_reconcile.py
  OUT_NAME=settlements.jsonl
  IP=127.0.0.1
  GRADE_PORT=1
  WS=$TMP/grade-ws
  export PATH="$TMP/stub-bin:$PATH"
  . "$HERE/grade_one.sh"
  grade_one "$TMP/grade-first-src" first
)
pycheck "the first grading pass checks its own source tree for stale output" - \
  "$GRADE_RUN/first.grade.json" "$TMP/grade-first-src" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
if doc.get("grade_status") != "no_output":
    raise SystemExit(json.dumps(doc))
if doc.get("workspace_checked") != sys.argv[2]:
    raise SystemExit(f"workspace_checked: {doc.get('workspace_checked')}")
if doc.get("stale_output_ignored") is not True:
    raise SystemExit("stale first-source output was not recorded as ignored")
PY
ok "the first pass checks the first source tree, not the final workspace"

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
echo "rehearsal passed: 1 session, 2 workspace states, first attempt then final, real resume, real preparation, real grade path, real measures, real grade"
