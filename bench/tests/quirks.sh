#!/usr/bin/env bash
# Every behaviour in bench/apis fires as bench/README.md says: each obvious consumer fails the
# hidden grader the way QUIRKS.md predicts, and the correct one passes. Localhost only.
# The servers run with v1 retired, as the grader runs them (after cutover).
#
# B5 has its own block. It checks the real status and the Retry-After header, that each
# traversal gets one 429 and its identical retry succeeds without skipping a page, that a
# changed GraphQL query or changed variables stays throttled, and that B5 off changes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
tmp=$(mktemp -d)
pids=()
cleanup() {
  local pid
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$tmp"
}
trap cleanup EXIT

start_server() { # <api> <port> <log> [server args...]
  local api=$1 port=$2 log=$3
  shift 3
  timeout 180 python3 -I "apis/$api/server.py" --port "$port" --v1 off "$@" >"$log" 2>&1 &
  pids+=("$!")
}

wait_api() { # <api> <port>
  local api=$1 port=$2
  for _ in $(seq 1 50); do
    if [[ $api == payouts ]]; then
      curl -s "http://127.0.0.1:$port/v2/payouts?limit=1" >/dev/null 2>&1 && return 0
    else
      curl -s -d '{"query":"{ __typename }"}' "http://127.0.0.1:$port/v2/graphql" >/dev/null 2>&1 && return 0
    fi
    sleep 0.1
  done
  return 1
}

pp=$(( 21000 + RANDOM % 9000 )); sp=$(( pp + 1 ))
start_server payouts "$pp" "$tmp/p.log" --retry-journal "$tmp/full-payouts.jsonl"
start_server settlements "$sp" "$tmp/s.log" --retry-journal "$tmp/full-settlements.jsonl"
wait_api payouts "$pp"
wait_api settlements "$sp"

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

jcount() { # <journal> <field> <value>
  python3 -I - "$1" "$2" "$3" <<'PYJ'
import json, sys
path, field, want = sys.argv[1:4]
n = 0
for line in open(path):
    line = line.strip()
    if line and str(json.loads(line).get(field)).lower() == want:
        n += 1
print(n)
PYJ
}

expect_count() { # <label> <got> <want>
  if [[ "$2" == "$3" ]]; then echo "ok   $1: $2"
  else echo "FAIL $1: wanted $3, got $2"; fail=1
  fi
}

check_b5() { # <api> <ref> <port> <journal> <want429> <wantRetries> <expected outcome>
  : > "$4"
  check "$1" "$2" "$3" "$7"
  expect_count "$1/$2 429 responses" "$(jcount "$4" throttled true)" "$5"
  expect_count "$1/$2 matching retries" "$(jcount "$4" matching_retry true)" "$6"
}

# Full servers: every behaviour, B5 included.
check payouts     v1_unchanged     "$pp" CRASH                 # v1 retired: 410
check payouts     single_page      "$pp" FAIL:missing=2331
check payouts     correct          "$pp" PASS
check payouts     no_retry         "$pp" CRASH                 # B5: no retry, the run dies
check payouts     partial_output   "$pp" FAIL:missing=846      # B5: 429 treated as the end

check settlements v1_unchanged     "$sp" CRASH
check settlements single_page      "$sp" FAIL:missing=1773,mismatched=1   # st_00097 arrives in its old version
check settlements correct          "$sp" PASS
check settlements no_retry         "$sp" CRASH                 # B5
check settlements partial_output   "$sp" FAIL:missing=1078,mismatched=3   # B5: 429 treated as the end

# Dedicated observed instance: no page requests are used for readiness, so the
# trace contains only this one real reference-consumer run.
op=$((sp + 1))
python3 -I apis/payouts/server.py --port "$op" --v1 off --trace "$tmp/observed.jsonl" --trace-client 127.0.0.1 >"$tmp/observed.log" 2>&1 &
observer_pid=$!
pids+=("$observer_pid")
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

# B5 off: the full paging behaviour of each API, exactly as before B5 existed.
p_b5off=$((op + 1)); s_b5off=$((op + 2))
start_server payouts "$p_b5off" "$tmp/p-b5off.log" --behaviours B1,B2,B4 --retry-journal "$tmp/b5off-payouts.jsonl"
start_server settlements "$s_b5off" "$tmp/s-b5off.log" --behaviours B1,B2,B3 --retry-journal "$tmp/b5off-settlements.jsonl"
wait_api payouts "$p_b5off"
wait_api settlements "$s_b5off"

check payouts     v1_unchanged     "$p_b5off" CRASH
check payouts     single_page      "$p_b5off" FAIL:missing=2331
check payouts     short_page_stop  "$p_b5off" FAIL:missing=2331     # B4
check payouts     cursor_loop      "$p_b5off" TIMEOUT               # B1
check payouts     no_dedupe        "$p_b5off" FAIL:duplicates=24    # B2
check payouts     correct          "$p_b5off" PASS

check settlements v1_unchanged     "$s_b5off" CRASH
check settlements single_page      "$s_b5off" FAIL:missing=1773,mismatched=1
check settlements empty_page_stop  "$s_b5off" FAIL:missing=1473,duplicates=1,mismatched=4   # B3
check settlements cursor_loop      "$s_b5off" TIMEOUT               # B1
check settlements no_dedupe        "$s_b5off" FAIL:duplicates=19,mismatched=19   # B2
check settlements keep_first       "$s_b5off" FAIL:mismatched=19    # B2: dedupes, but keeps the old version
check settlements correct          "$s_b5off" PASS

expect_count "payouts B5 off 429 responses" "$(jcount "$tmp/b5off-payouts.jsonl" throttled true)" 0
expect_count "settlements B5 off 429 responses" "$(jcount "$tmp/b5off-settlements.jsonl" throttled true)" 0

# One behaviour at a time. Expected lines were measured on that server.
p_b1=$((op + 3)); p_b2=$((op + 4)); p_b4=$((op + 5))
s_b1=$((op + 6)); s_b2=$((op + 7)); s_b3=$((op + 8))
start_server payouts "$p_b1" "$tmp/p-b1.log" --behaviours B1
start_server payouts "$p_b2" "$tmp/p-b2.log" --behaviours B2
start_server payouts "$p_b4" "$tmp/p-b4.log" --behaviours B4
start_server settlements "$s_b1" "$tmp/s-b1.log" --behaviours B1
start_server settlements "$s_b2" "$tmp/s-b2.log" --behaviours B2
start_server settlements "$s_b3" "$tmp/s-b3.log" --behaviours B3
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

# B5 alone: one throttle per traversal, and each consumer's own outcome from it.
p_b5=$((op + 9)); s_b5=$((op + 10))
start_server payouts "$p_b5" "$tmp/p-b5.log" --behaviours B5 --retry-journal "$tmp/b5-payouts.jsonl"
start_server settlements "$s_b5" "$tmp/s-b5.log" --behaviours B5 --retry-journal "$tmp/b5-settlements.jsonl"
wait_api payouts "$p_b5"
wait_api settlements "$s_b5"

check_b5 payouts     correct        "$p_b5" "$tmp/b5-payouts.jsonl"    1 1 PASS
check_b5 payouts     no_retry       "$p_b5" "$tmp/b5-payouts.jsonl"    1 0 CRASH
check_b5 payouts     partial_output "$p_b5" "$tmp/b5-payouts.jsonl"    1 0 FAIL:missing=431
check_b5 settlements correct        "$s_b5" "$tmp/b5-settlements.jsonl" 1 1 PASS
check_b5 settlements no_retry       "$s_b5" "$tmp/b5-settlements.jsonl" 1 0 CRASH
check_b5 settlements partial_output "$s_b5" "$tmp/b5-settlements.jsonl" 1 0 FAIL:missing=873

# Interleave two fresh traversals on one server. Each gets its own identity and its
# own 429, each identical retry succeeds, and no page is skipped or reordered.
p_il=$((op + 11)); s_il=$((op + 12))
start_server payouts "$p_il" "$tmp/p-il.log" --retry-journal "$tmp/il-payouts.jsonl"
start_server settlements "$s_il" "$tmp/s-il.log" --retry-journal "$tmp/il-settlements.jsonl"
wait_api payouts "$p_il"
wait_api settlements "$s_il"
for pair in "payouts:$p_il:$tmp/il-payouts.jsonl" "settlements:$s_il:$tmp/il-settlements.jsonl"; do
  api=${pair%%:*}; rest=${pair#*:}; port=${rest%%:*}; journal=${rest#*:}
  : > "$journal"
  if ! python3 -I - "$api" "$port" "$journal" <<'PYB5'
import json, sys, urllib.error, urllib.request

api, port, journal = sys.argv[1], int(sys.argv[2]), sys.argv[3]
LIMIT = 50
QUERY = ("query($f: Int, $a: String) { settlements(first: $f, after: $a) { "
         "nodes { id } pageInfo { endCursor hasNextPage } } }")
if api == "payouts":
    TRUTH = [f"po_{i:05d}" for i in range(1, 2432)]
else:
    TRUTH = [f"st_{i:05d}" for i in range(1, 1874)]


def build(cursor):
    if api == "payouts":
        url = f"http://127.0.0.1:{port}/v2/payouts?limit={LIMIT}"
        if cursor:
            url += f"&cursor={cursor}"
        return urllib.request.Request(url)
    body = json.dumps({"query": QUERY, "variables": {"f": LIMIT, "a": cursor}}).encode()
    return urllib.request.Request(f"http://127.0.0.1:{port}/v2/graphql", data=body,
                                  headers={"Content-Type": "application/json"})


def fetch(cursor):
    try:
        with urllib.request.urlopen(build(cursor), timeout=10) as r:
            return r.status, json.load(r), r.headers
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}"), e.headers


class Traversal:
    def __init__(self, name):
        self.name = name
        self.cursor = None
        self.first_cursor = None
        self.in_order = []
        self.seen = set()
        self.throttled = 0
        self.retried = 0
        self.done = False

    def step(self):
        if self.done:
            return
        code, body, headers = fetch(self.cursor)
        if code == 429:
            self.throttled += 1
            assert headers.get("Retry-After") == "1", (self.name, "Retry-After", headers.get("Retry-After"))
            code, body, headers = fetch(self.cursor)   # the identical request
            assert code == 200, (self.name, "retry", code)
            self.retried += 1
        assert code == 200, (self.name, "status", code)
        if api == "payouts":
            page = [p["id"] for p in body["payouts"]]
            self.cursor = body["cursor"]
            self.done = body["drained"]
        else:
            conn = body["data"]["settlements"]
            page = [s["id"] for s in conn["nodes"]]
            self.cursor = conn["pageInfo"]["endCursor"]
            self.done = not conn["pageInfo"]["hasNextPage"]
        if self.first_cursor is None:
            self.first_cursor = self.cursor
        for record_id in page:
            if record_id not in self.seen:
                self.seen.add(record_id)
                self.in_order.append(record_id)


one, two = Traversal("one"), Traversal("two")
for _turn in range(400):
    one.step()
    two.step()
    if one.done and two.done:
        break
else:
    raise AssertionError("traversals did not drain")

assert one.throttled == 1 and two.throttled == 1, (one.throttled, two.throttled)
assert one.retried == 1 and two.retried == 1, (one.retried, two.retried)
for t in (one, two):
    assert t.in_order == TRUTH, (t.name, "skipped or reordered pages", len(t.in_order))

# One 429 per traversal: replaying an old cursor of a cleared lineage is served.
code, _body, _headers = fetch(one.first_cursor)
assert code == 200, ("replay after the one 429", code)

events = [json.loads(line) for line in open(journal) if line.strip()]
throttles = [e for e in events if e.get("throttled")]
retries = [e for e in events if e.get("matching_retry")]
assert len(throttles) == 2, len(throttles)
assert len(retries) == 2, len(retries)
assert len({e["traversal"] for e in throttles}) == 2, "traversal identities are not distinct"
by_trav = {}
for e in events:
    by_trav.setdefault(e["traversal"], []).append(e)
assert len(by_trav) == 2, sorted(by_trav)
for trav, seq in by_trav.items():
    assert trav, "empty traversal digest"
    t429 = [e for e in seq if e.get("throttled")]
    retry = [e for e in seq if e.get("matching_retry")]
    assert len(t429) == 1 and len(retry) == 1, (trav, len(t429), len(retry))
    assert t429[0]["status"] == 429 and retry[0]["status"] == 200
    assert t429[0]["request"] == retry[0]["request"], (trav, "retry is not the identical request")
print(f"ok   {api} interleaved: 2 identities, 1 x 429 each, identical retries, no skipped page")
PYB5
  then
    echo "FAIL $api interleaved traversal"; fail=1
  fi
done

# A changed GraphQL query or changed variables is not the identical retry.
s_chg=$((op + 13))
start_server settlements "$s_chg" "$tmp/s-chg.log" --retry-journal "$tmp/chg-settlements.jsonl"
wait_api settlements "$s_chg"
: > "$tmp/chg-settlements.jsonl"
if ! python3 -I - "$s_chg" "$tmp/chg-settlements.jsonl" <<'PYCHG'
import json, sys, urllib.error, urllib.request

port, journal = int(sys.argv[1]), sys.argv[2]
QUERY = ("query($f: Int, $a: String) { settlements(first: $f, after: $a) { "
         "nodes { id } pageInfo { endCursor hasNextPage } } }")
CHANGED_QUERY = ("query($f: Int, $a: String) { settlements(first: $f, after: $a) { "
                 "nodes { id batchDate } pageInfo { endCursor hasNextPage } } }")
URL = f"http://127.0.0.1:{port}/v2/graphql"


def send(query, variables):
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.load(r), r.headers
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}"), e.headers


cursor = None
blocked_at = None
seen = set()
while True:
    code, body, _headers = send(QUERY, {"f": 100, "a": cursor})
    if code == 429:
        blocked_at = cursor
        break
    assert code == 200, code
    conn = body["data"]["settlements"]
    seen |= {s["id"] for s in conn["nodes"]}
    cursor = conn["pageInfo"]["endCursor"]
    assert conn["pageInfo"]["hasNextPage"], "the throttle never fired"
assert blocked_at is not None

# A changed variable is not the identical request.
code, _body, headers = send(QUERY, {"f": 50, "a": blocked_at})
assert code == 429, ("changed variable", code)
assert headers.get("Retry-After") == "1", headers.get("Retry-After")
# Changed query text is not the identical request.
code, _body, headers = send(CHANGED_QUERY, {"f": 100, "a": blocked_at})
assert code == 429, ("changed query", code)
assert headers.get("Retry-After") == "1", headers.get("Retry-After")
# The identical request succeeds and the traversal continues.
code, body, _headers = send(QUERY, {"f": 100, "a": blocked_at})
assert code == 200, ("identical retry", code)
conn = body["data"]["settlements"]
seen |= {s["id"] for s in conn["nodes"]}
cursor = conn["pageInfo"]["endCursor"]
while conn["pageInfo"]["hasNextPage"]:
    code, body, _headers = send(QUERY, {"f": 100, "a": cursor})
    assert code == 200, code
    conn = body["data"]["settlements"]
    seen |= {s["id"] for s in conn["nodes"]}
    cursor = conn["pageInfo"]["endCursor"]
assert len(seen) == 1873, len(seen)

events = [json.loads(line) for line in open(journal) if line.strip()]
assert len({e["traversal"] for e in events}) == 1, "more than one traversal"
throttles = [e for e in events if e.get("throttled")]
retries = [e for e in events if e.get("matching_retry")]
assert len(throttles) == 3, len(throttles)
assert len(retries) == 1, len(retries)
assert len({e["request"] for e in throttles}) == 3, "the three requests did not differ"
assert throttles[0]["request"] == retries[0]["request"], "the matching retry is not the first request"
print("ok   settlements changed query or variables stays throttled")
PYCHG
then
  echo "FAIL settlements changed request"; fail=1
fi

# Trusted retry measurement: one journal split into two phases gives separate agent
# and grading counts. A missing or malformed journal is unknown with null counts.
rj=$((op + 14))
start_server payouts "$rj" "$tmp/rj.log" --behaviours B5 --retry-journal "$tmp/rj-journal.jsonl"
wait_api payouts "$rj"
: > "$tmp/rj-journal.jsonl"
timeout 8 python3 -I apis/payouts/reference/correct.py --base-url "http://127.0.0.1:$rj" --out "$tmp/rj-agent.jsonl" >/dev/null
python3 -I harness/retry_journal.py read --phase agent --local "payouts_live=$tmp/rj-journal.jsonl" --out "$tmp/rj-agent.json" >/dev/null
: > "$tmp/rj-journal.jsonl"
timeout 8 python3 -I apis/payouts/reference/correct.py --base-url "http://127.0.0.1:$rj" --out "$tmp/rj-grading.jsonl" >/dev/null
python3 -I harness/retry_journal.py read --phase grading --local "payouts_live=$tmp/rj-journal.jsonl" --out "$tmp/rj-grading.json" >/dev/null
python3 -I harness/retry_journal.py read --phase agent --local "payouts_live=$tmp/does-not-exist.jsonl" --out "$tmp/rj-missing.json" >/dev/null
printf 'not json\n' > "$tmp/rj-bad.jsonl"
python3 -I harness/retry_journal.py read --phase agent --local "payouts_live=$tmp/rj-bad.jsonl" --out "$tmp/rj-bad.json" >/dev/null
if ! python3 -I - "$tmp/rj-agent.json" "$tmp/rj-grading.json" "$tmp/rj-missing.json" "$tmp/rj-bad.json" <<'PYRJ'
import json, sys
agent, grading, missing, bad = (json.load(open(p)) for p in sys.argv[1:5])
for phase, doc in (("agent", agent), ("grading", grading)):
    assert doc["phase"] == phase and doc["status"] == "ok", doc
    assert (doc["b5_429_responses"], doc["matching_retry_attempts"],
            doc["successful_matching_retries"]) == (1, 1, 1), doc
    assert doc["apis"]["payouts_live"]["status"] == "ok"
    assert "sandbox" not in json.dumps(doc)
for doc in (missing, bad):
    assert doc["status"] == "unknown", doc
    assert doc["b5_429_responses"] is None and doc["matching_retry_attempts"] is None
    assert doc["successful_matching_retries"] is None
print("ok   retry journal: agent 1/1/1, grading 1/1/1, missing and malformed unknown, no sandbox count")
PYRJ
then
  echo "FAIL retry journal measurement"; fail=1
fi

# A token outside that server's set is an error that names the token.
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
reject payouts B6
reject payouts B3
reject settlements B6
reject settlements B4

exit $fail
