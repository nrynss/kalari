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
    else got="FAIL:$(python3 -I -c 'import json,sys; v=json.loads(sys.argv[1]); print(",".join(f"{k}={v[k]}" for k in ("missing","duplicates") if v[k]))' "$v")"
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
check settlements single_page      "$sp" FAIL:missing=1773
check settlements empty_page_stop  "$sp" FAIL:missing=1473,duplicates=1   # B3 (and one amended repeat before the stop)
check settlements cursor_loop      "$sp" TIMEOUT               # B1
check settlements no_dedupe        "$sp" FAIL:duplicates=19    # B2
check settlements correct          "$sp" PASS

exit $fail
