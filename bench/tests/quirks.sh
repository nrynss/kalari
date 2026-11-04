#!/usr/bin/env bash
# Every behaviour in bench/apis fires as bench/README.md says: each obvious consumer fails the
# hidden grader the way QUIRKS.md predicts, and the correct one passes. Localhost only.
# The servers run with v1 retired, as the grader runs them (after cutover).
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

pp=$(( 21000 + RANDOM % 9000 )); sp=$(( pp + 1 ))
timeout 120 python3 -I apis/payouts/server.py --port "$pp" --v1 off >"$tmp/p.log" 2>&1 &
timeout 120 python3 -I apis/settlements/server.py --port "$sp" --v1 off >"$tmp/s.log" 2>&1 &
for _ in $(seq 1 50); do
  curl -s "http://127.0.0.1:$pp/v2/payouts?limit=1" >/dev/null 2>&1 &&
    curl -s -d '{"query":"{ __typename }"}' "http://127.0.0.1:$sp/v2/graphql" >/dev/null 2>&1 && break
  sleep 0.1
done

# check <api> <reference> <port> <expected: PASS | TIMEOUT | CRASH | FAIL:<field>=<n>[,<field>=<n>]>
check() {
  local api=$1 ref=$2 port=$3 want=$4 out="$tmp/$1-$2.jsonl" rc=0
  timeout 8 python3 -I "apis/$api/reference/$ref.py" --base-url "http://127.0.0.1:$port" --out "$out" >/dev/null 2>&1 || rc=$?
  local got
  if [[ $rc == 124 ]]; then got=TIMEOUT
  elif [[ $rc != 0 ]]; then got=CRASH
  else
    local v; v=$(python3 -I graders/grade.py "$api" "$out" || true)
    if [[ $v == *'"verdict": "PASS"'* ]]; then got=PASS
    else got="FAIL:$(python3 -I -c 'import json,sys; v=json.loads(sys.argv[1]); print(",".join(f"{k}={v[k]}" for k in ("missing","duplicates","mismatched") if v[k]))' "$v")"
    fi
  fi
  if [[ $got == "$want" ]]; then echo "ok   $api/$ref: $got"; else echo "FAIL $api/$ref: wanted $want, got $got"; fail=1; fi
}

check payouts     v1_unchanged     "$pp" CRASH                 # v1 retired: 410
check payouts     single_page      "$pp" FAIL:missing=2331
check payouts     short_page_stop  "$pp" FAIL:missing=2331     # B4
check payouts     cursor_loop      "$pp" TIMEOUT               # B1
check payouts     no_dedupe        "$pp" FAIL:duplicates=24    # B2
check payouts     correct          "$pp" PASS

check settlements v1_unchanged     "$sp" CRASH
check settlements single_page      "$sp" FAIL:missing=1773,mismatched=1   # st_00097 arrives in its old version
check settlements empty_page_stop  "$sp" FAIL:missing=1473,duplicates=1,mismatched=4   # B3; 4 amended settlements before the stop, only 1 repeated in time
check settlements cursor_loop      "$sp" TIMEOUT               # B1
check settlements no_dedupe        "$sp" FAIL:duplicates=19,mismatched=19   # B2: old copies too
check settlements keep_first       "$sp" FAIL:mismatched=19    # B2: dedupes, but keeps the old version
check settlements correct          "$sp" PASS

# Dedicated observed instance: no page requests are used for readiness, so the
# trace contains only this one real reference-consumer run.
op=$((sp + 1))
python3 -I apis/payouts/server.py --port "$op" --v1 off --trace "$tmp/observed.jsonl" --trace-client 127.0.0.1 >"$tmp/observed.log" 2>&1 &
observer_pid=$!
for _ in $(seq 1 50); do
  curl -s "http://127.0.0.1:$op/health" >/dev/null 2>&1 && break
  sleep 0.1
done
if ! timeout 8 python3 -I apis/payouts/reference/correct.py --base-url "http://127.0.0.1:$op" --out "$tmp/observed-output.jsonl" >/dev/null; then
  echo "FAIL observed payouts reference"; fail=1
fi
kill "$observer_pid" 2>/dev/null || true
wait "$observer_pid" 2>/dev/null || true
if ! python3 -I - "$tmp/observed.jsonl" "$tmp/observed-output.jsonl" <<'PYTRACE'
import json, subprocess, sys
raw = open(sys.argv[1], "rb").read()
assert raw.endswith(b"\n") and len(raw) <= 262144
pages = [json.loads(line) for line in raw.splitlines()]
assert 1 < len(pages) <= 256 and not pages[0]["request"]
assert all(p["count"] == len(p["ids"]) > 0 for p in pages)
assert all(a["response"] == b["request"] for a, b in zip(pages, pages[1:]))
assert all(not p["drained"] for p in pages[:-1])
assert pages[-1]["drained"] and pages[-1]["response"]
assert all(set(a["ids"]) & set(b["ids"]) == {a["last"]} == {b["first"]} for a, b in zip(pages, pages[1:]))
grade = json.loads(subprocess.check_output(["python3", "-I", "graders/grade.py", "payouts", sys.argv[2]]))
assert grade["verdict"] == "PASS"
print(f"ok   payouts observed: {len(pages)} pages, one-record overlaps, final token, grader PASS")
PYTRACE
then
  echo "FAIL observed payouts trace or grader"; fail=1
fi

# One behaviour at a time. Expected lines were measured on that server.
p_b1=$((op + 1)); p_b2=$((op + 2)); p_b4=$((op + 3))
s_b1=$((op + 4)); s_b2=$((op + 5)); s_b3=$((op + 6))
timeout 120 python3 -I apis/payouts/server.py --port "$p_b1" --v1 off --behaviours B1 >"$tmp/p-b1.log" 2>&1 &
timeout 120 python3 -I apis/payouts/server.py --port "$p_b2" --v1 off --behaviours B2 >"$tmp/p-b2.log" 2>&1 &
timeout 120 python3 -I apis/payouts/server.py --port "$p_b4" --v1 off --behaviours B4 >"$tmp/p-b4.log" 2>&1 &
timeout 120 python3 -I apis/settlements/server.py --port "$s_b1" --v1 off --behaviours B1 >"$tmp/s-b1.log" 2>&1 &
timeout 120 python3 -I apis/settlements/server.py --port "$s_b2" --v1 off --behaviours B2 >"$tmp/s-b2.log" 2>&1 &
timeout 120 python3 -I apis/settlements/server.py --port "$s_b3" --v1 off --behaviours B3 >"$tmp/s-b3.log" 2>&1 &
for _ in $(seq 1 50); do
  curl -s "http://127.0.0.1:$p_b1/v2/payouts?limit=1" >/dev/null 2>&1 &&
    curl -s "http://127.0.0.1:$p_b2/v2/payouts?limit=1" >/dev/null 2>&1 &&
    curl -s "http://127.0.0.1:$p_b4/v2/payouts?limit=1" >/dev/null 2>&1 &&
    curl -s -d '{"query":"{ __typename }"}' "http://127.0.0.1:$s_b1/v2/graphql" >/dev/null 2>&1 &&
    curl -s -d '{"query":"{ __typename }"}' "http://127.0.0.1:$s_b2/v2/graphql" >/dev/null 2>&1 &&
    curl -s -d '{"query":"{ __typename }"}' "http://127.0.0.1:$s_b3/v2/graphql" >/dev/null 2>&1 && break
  sleep 0.1
done

check payouts     cursor_loop      "$p_b1" TIMEOUT              # B1
check payouts     correct          "$p_b1" PASS
check payouts     no_dedupe        "$p_b2" FAIL:duplicates=24   # B2
check payouts     correct          "$p_b2" PASS
check payouts     short_page_stop  "$p_b4" FAIL:missing=2331    # B4
check payouts     correct          "$p_b4" PASS

check settlements cursor_loop      "$s_b1" TIMEOUT              # B1
check settlements correct          "$s_b1" PASS
check settlements no_dedupe        "$s_b2" FAIL:duplicates=19,mismatched=19   # B2
check settlements keep_first       "$s_b2" FAIL:mismatched=19   # B2: the first copy is not v1's
check settlements correct          "$s_b2" PASS
check settlements empty_page_stop  "$s_b3" FAIL:missing=1473    # B3 alone: 400 kept, no amended copy
check settlements correct          "$s_b3" PASS

# A token outside that server's set is an error that names the token. B5 is not a behaviour.
reject() {
  local api=$1
  local token=$2
  local rc=0
  local err="$tmp/reject-$api-$token.txt"
  timeout 3 python3 -I "apis/$api/server.py" --port $((op + 30)) --behaviours "$token" >"$tmp/reject.out" 2>"$err" || rc=$?
  if [[ $rc -ne 0 ]] && grep -F -q "unknown behaviour: $token" "$err"; then
    echo "ok   $api rejects $token"
  else
    echo "FAIL $api --behaviours $token (rc=$rc)"; cat "$err"; fail=1
  fi
}
reject payouts B5
reject payouts B3
reject settlements B5
reject settlements B4

exit $fail
