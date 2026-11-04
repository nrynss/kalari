#!/usr/bin/env bash
# Every behaviour in bench/apis fires as bench/README.md says: each obvious consumer fails the
# hidden grader the way QUIRKS.md predicts, and the correct one passes. Localhost only.
# The servers run with v1 retired, as the grader runs them (after cutover).
#
# B5 has its own block. It checks the real status and the Retry-After header, that each
# traversal gets one 429 and its identical retry succeeds without skipping a page, that a
# changed GraphQL query, variable, operation name or payout parameter stays throttled, that
# a settlements fragment or a dual `after` document reaches the same field, that an
# ambiguous document is rejected, and that B5 off changes nothing. The observed trace block
# checks one 429, its identical retry, the joined cursor chain and digests only. The retry
# journal block checks phase counts, event types, digest shapes, overflow, evictions and
# grading isolation.
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
# trace contains only this one real reference-consumer run. B5 is on, so the run
# crosses one 429 and its identical retry inside the same trace.
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
import json, re, subprocess, sys
raw = open(sys.argv[1], "rb").read()
assert raw.endswith(b"\n") and len(raw) <= 262144
events = [json.loads(line) for line in raw.splitlines()]
assert 1 < len(events) <= 256
# Exactly one 429, and the page immediately after it is the identical retry.
throttled = [i for i, e in enumerate(events) if e.get("status") == 429]
assert len(throttled) == 1, ("one 429 expected", throttled)
i = throttled[0]
assert 0 < i < len(events) - 1
throttle, retry = events[i], events[i + 1]
assert throttle.get("retry") is False and throttle.get("retry_after") == "1"
assert not {"response", "first", "last", "count", "ids", "drained"} & set(throttle), "429 carries a page"
assert retry.get("status") == 200 and retry.get("retry") is True
assert retry.get("request") == throttle.get("request") and throttle.get("request")
assert len(throttle.get("fingerprint", "")) == 32
assert retry.get("fingerprint") == throttle.get("fingerprint")
pages = [e for e in events if e.get("status") == 200]
assert len(pages) == len(events) - 1
assert [p for p in pages if p.get("retry")] == [retry]
assert not pages[0]["request"]
assert all(p["count"] == len(p["ids"]) > 0 for p in pages)
assert all(a["response"] == b["request"] for a, b in zip(pages, pages[1:]))
assert all(not p["drained"] for p in pages[:-1])
assert pages[-1]["drained"] and pages[-1]["response"]
assert all(set(a["ids"]) & set(b["ids"]) == {a["last"]} == {b["first"]} for a, b in zip(pages, pages[1:]))
# Every request, response and fingerprint field is a digest, never a raw cursor.
DIGEST = re.compile(r"[0-9a-f]{0,32}")
assert all(DIGEST.fullmatch(p["request"]) for p in pages), "trace request is not a digest"
assert all(DIGEST.fullmatch(p["response"]) for p in pages), "trace response is not a digest"
assert all(len(p["response"]) == 32 for p in pages), "trace response digest is not 32 hex"
assert DIGEST.fullmatch(throttle["request"]), "429 request is not a digest"
assert all(DIGEST.fullmatch(e["fingerprint"]) and len(e["fingerprint"]) == 32 for e in events)
assert b"cursor" not in raw and not re.search(rb"[A-Za-z0-9_-]{16,}\.[0-9a-f]{16}", raw), "raw cursor in the trace"
grade = json.loads(subprocess.check_output(["python3", "-I", "graders/grade.py", "payouts", sys.argv[2]]))
assert grade["verdict"] == "PASS"
print(f"ok   payouts observed: {len(pages)} pages, one 429 and its identical retry, one-record overlaps, final token, digests only, grader PASS")
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

# B5 off keeps the old error path. The new argument parser stays out of it, so an
# ambiguous document and a list argument return the schema's GraphQL errors with 200.
if ! python3 -I - "$s_b5off" "$tmp/b5off-settlements.jsonl" <<'PYB5OFF'
import json, sys, urllib.error, urllib.request

port, journal = int(sys.argv[1]), sys.argv[2]
URL = f"http://127.0.0.1:{port}/v2/graphql"
AMBIG = ("query A($a: String) { settlements(first: 100, after: $a) { pageInfo { hasNextPage } } } "
         "query B($a: String) { settlements(first: 100, after: $a) { pageInfo { hasNextPage } } }")
LIST = "query Q { settlements(first: [1, 2]) { nodes { id } pageInfo { hasNextPage } } }"


def send(query, variables):
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


for label, query, variables in (
    ("ambiguous two operations", AMBIG, {"a": None}),
    ("list argument", LIST, {}),
):
    code, body = send(query, variables)
    assert code == 200, (label, code, body)
    assert body.get("errors"), (label, body)
events = [json.loads(line) for line in open(journal) if line.strip()]
assert not any(event.get("throttled") for event in events), "B5 off throttled a request"
print("ok   settlements B5 off: the old GraphQL errors return for both edge documents")
PYB5OFF
then
  echo "FAIL settlements B5 off error path"; fail=1
fi

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
import json, re, sys, urllib.error, urllib.request

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
        self.cursors = []
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
            assert set(body) == {"payouts", "cursor", "drained"}, sorted(body)
            page = [p["id"] for p in body["payouts"]]
            self.cursor = body["cursor"]
            self.done = body["drained"]
        else:
            assert set(body) <= {"data", "errors"}, sorted(body)
            assert "data" in body, sorted(body)
            conn = body["data"]["settlements"]
            page = [s["id"] for s in conn["nodes"]]
            self.cursor = conn["pageInfo"]["endCursor"]
            self.done = not conn["pageInfo"]["hasNextPage"]
        if self.first_cursor is None:
            self.first_cursor = self.cursor
        self.cursors.append(self.cursor)
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
# Digest shapes only, and no raw cursor anywhere in the journal.
DIGEST = re.compile(r"[0-9a-f]{0,32}")
CLIENT = re.compile(r"[0-9a-f]{16}")
raw = open(journal).read()
for e in events:
    assert DIGEST.fullmatch(e["request"]), e
    assert DIGEST.fullmatch(e["traversal"]), e
    assert CLIENT.fullmatch(e["client"]), e
for t in (one, two):
    for cursor in t.cursors:
        assert cursor and cursor not in raw, "raw cursor in the journal"
print(f"ok   {api} interleaved: 2 identities, 1 x 429 each, identical retries, no skipped page, digests only")
PYB5
  then
    echo "FAIL $api interleaved traversal"; fail=1
  fi
done

# A changed GraphQL query, changed variables or an added operation name is not the
# identical retry. The first request fingerprint is the one the matching retry repeats.
s_chg=$((op + 13))
start_server settlements "$s_chg" "$tmp/s-chg.log" --retry-journal "$tmp/chg-settlements.jsonl"
wait_api settlements "$s_chg"
: > "$tmp/chg-settlements.jsonl"
if ! python3 -I - "$s_chg" "$tmp/chg-settlements.jsonl" <<'PYCHG'
import json, sys, urllib.error, urllib.request

port, journal = int(sys.argv[1]), sys.argv[2]
QUERY = ("query Settlements($f: Int, $a: String) { settlements(first: $f, after: $a) { "
         "nodes { id } pageInfo { endCursor hasNextPage } } }")
CHANGED_QUERY = ("query Settlements($f: Int, $a: String) { settlements(first: $f, after: $a) { "
                 "nodes { id batchDate } pageInfo { endCursor hasNextPage } } }")
URL = f"http://127.0.0.1:{port}/v2/graphql"


def send(query, variables, operation=None):
    body = {"query": query, "variables": variables}
    if operation:
        body["operationName"] = operation
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
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
# The same query and variables with an operation name is a different request.
code, _body, headers = send(QUERY, {"f": 100, "a": blocked_at}, operation="Settlements")
assert code == 429, ("changed operation name", code)
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
assert len(throttles) == 4, len(throttles)
assert len(retries) == 1, len(retries)
assert len({e["request"] for e in throttles}) == 4, "the four requests did not differ"
assert throttles[0]["request"] == retries[0]["request"], "the matching retry is not the first request"
print("ok   settlements changed query, variables or operation name stays throttled")
PYCHG
then
  echo "FAIL settlements changed request"; fail=1
fi

# A changed payout request stays throttled. The decoded parameter set is the unit:
# order does not matter, a repeated parameter or a padded value makes a new request.
p_chg=$((op + 15))
start_server payouts "$p_chg" "$tmp/p-chg.log" --retry-journal "$tmp/chg-payouts.jsonl"
wait_api payouts "$p_chg"
: > "$tmp/chg-payouts.jsonl"
if ! python3 -I - "$p_chg" "$tmp/chg-payouts.jsonl" <<'PYCHGP'
import json, sys, urllib.error, urllib.parse, urllib.request

port, journal = int(sys.argv[1]), sys.argv[2]


def url(limit, cursor=None, order="limit-first", repeat=False):
    params = [("limit", limit)]
    if repeat:
        params.append(("limit", limit))
    if cursor:
        params.append(("cursor", cursor))
    if order == "cursor-first":
        params.reverse()
    return f"http://127.0.0.1:{port}/v2/payouts?" + urllib.parse.urlencode(params)


def get(limit, cursor=None, order="limit-first", repeat=False):
    req = urllib.request.Request(url(limit, cursor, order, repeat))
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.load(r), r.headers
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}"), e.headers


def first_throttle():
    cursor = None
    seen = set()
    while True:
        code, body, _headers = get("100", cursor)
        if code == 429:
            return cursor, seen
        assert code == 200, code
        seen |= {p["id"] for p in body["payouts"]}
        cursor = body["cursor"]
        assert not body["drained"], "the throttle never fired"


def drain(cursor, seen):
    code, body, _headers = get("100", cursor)
    assert code == 200, code
    seen |= {p["id"] for p in body["payouts"]}
    cursor = body["cursor"]
    while not body["drained"]:
        code, body, _headers = get("100", cursor)
        assert code == 200, code
        seen |= {p["id"] for p in body["payouts"]}
        cursor = body["cursor"]
    return seen


# One traversal shows that each changed request stays throttled and the exact
# request clears it.
blocked_at, seen_a = first_throttle()
# A repeated parameter parses to the same values but is a different request.
code, _body, headers = get("100", blocked_at, repeat=True)
assert code == 429, ("duplicate parameter", code)
assert headers.get("Retry-After") == "1", headers.get("Retry-After")
# A zero-padded integer is the same value but a different request.
code, _body, headers = get("0100", blocked_at)
assert code == 429, ("padded limit", code)
assert headers.get("Retry-After") == "1", headers.get("Retry-After")
# A changed limit is a different request.
code, _body, headers = get("99", blocked_at)
assert code == 429, ("changed limit", code)
assert headers.get("Retry-After") == "1", headers.get("Retry-After")
# The exact request succeeds and the traversal continues.
code, body, _headers = get("100", blocked_at)
assert code == 200, ("identical retry", code)
seen_a |= {p["id"] for p in body["payouts"]}
cursor = body["cursor"]
while not body["drained"]:
    code, body, _headers = get("100", cursor)
    assert code == 200, code
    seen_a |= {p["id"] for p in body["payouts"]}
    cursor = body["cursor"]
assert len(seen_a) == 2431, len(seen_a)

events = [json.loads(line) for line in open(journal) if line.strip()]
assert len({e["traversal"] for e in events}) == 1, "more than one traversal"
throttles = [e for e in events if e.get("throttled")]
retries = [e for e in events if e.get("matching_retry")]
assert len(throttles) == 4, len(throttles)
assert len(retries) == 1, len(retries)
assert len({e["request"] for e in throttles}) == 4, "the four requests did not differ"
assert throttles[0]["request"] == retries[0]["request"], "the matching retry is not the first request"

# A second traversal shows that reordered parameters are the identical request.
open(journal, "w").close()
blocked_at, seen_b = first_throttle()
code, body, _headers = get("100", blocked_at, order="cursor-first")
assert code == 200, ("reordered retry", code)
seen_b |= {p["id"] for p in body["payouts"]}
seen_b = drain(body["cursor"], seen_b)
assert len(seen_b) == 2431, len(seen_b)
events = [json.loads(line) for line in open(journal) if line.strip()]
assert len({e["traversal"] for e in events}) == 1, "more than one traversal"
throttles = [e for e in events if e.get("throttled")]
retries = [e for e in events if e.get("matching_retry")]
assert len(throttles) == 1 and len(retries) == 1, (len(throttles), len(retries))
assert throttles[0]["request"] == retries[0]["request"], "reordered parameters are not the same request"
print("ok   payouts changed request stays throttled, reordered parameters retry")
PYCHGP
then
  echo "FAIL payouts changed request"; fail=1
fi

# A settlements field inside a named or inline fragment still reaches B5, and an
# ambiguous document is rejected instead of starting a fresh traversal.
s_frag=$((op + 16))
start_server settlements "$s_frag" "$tmp/s-frag.log" --retry-journal "$tmp/frag-settlements.jsonl"
wait_api settlements "$s_frag"
if ! python3 -I - "$s_frag" "$tmp/frag-settlements.jsonl" <<'PYFRAG'
import json, re, sys, urllib.error, urllib.request

port, journal = int(sys.argv[1]), sys.argv[2]
URL = f"http://127.0.0.1:{port}/v2/graphql"
NAMED = ("query Q($f: Int, $a: String) { ...S } "
         "fragment S on Query { settlements(first: $f, after: $a) { "
         "nodes { id } pageInfo { endCursor hasNextPage } } }")
INLINE = ("query Q($f: Int, $a: String) { ... on Query { settlements(first: $f, after: $a) { "
          "nodes { id } pageInfo { endCursor hasNextPage } } } }")
AMBIGUOUS = ("query A($f: Int, $a: String) { settlements(first: $f, after: $a) { "
             "pageInfo { hasNextPage } } } "
             "query B($f: Int, $a: String) { settlements(first: $f, after: $a) { "
             "pageInfo { hasNextPage } } }")


def send(query, variables):
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.load(r), r.headers
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}"), e.headers


def drain(label, query):
    open(journal, "w").close()
    cursor = None
    seen = set()
    throttles = retries = 0
    while True:
        code, body, headers = send(query, {"f": 100, "a": cursor})
        if code == 429:
            throttles += 1
            assert headers.get("Retry-After") == "1", (label, headers.get("Retry-After"))
            code, body, _headers = send(query, {"f": 100, "a": cursor})
            assert code == 200, (label, "retry", code)
            retries += 1
        assert code == 200, (label, code, body)
        conn = body["data"]["settlements"]
        seen |= {s["id"] for s in conn["nodes"]}
        cursor = conn["pageInfo"]["endCursor"]
        if not conn["pageInfo"]["hasNextPage"]:
            break
    assert len(seen) == 1873, (label, len(seen))
    assert throttles == 1, (label, "throttles", throttles)
    assert retries == 1, (label, "retries", retries)
    events = [json.loads(line) for line in open(journal) if line.strip()]
    assert len({e["traversal"] for e in events}) == 1, (label, "more than one traversal")
    hits = [e for e in events if e.get("throttled")]
    again = [e for e in events if e.get("matching_retry")]
    assert len(hits) == 1 and len(again) == 1, (label, len(hits), len(again))
    assert hits[0]["request"] == again[0]["request"], (label, "retry is not identical")
    print(f"ok   settlements {label}: one 429, one matching retry, full stream")


drain("named fragment", NAMED)
drain("inline fragment", INLINE)

# A fragment on a different type cannot contribute a settlements field. The parser
# leaves it to the schema, so it never reaches the ambiguity check.
WRONG_INLINE = ("query Q($a: String, $b: String) { "
                "settlements(first: 1, after: $a) { nodes { id } pageInfo { hasNextPage } } "
                "... on Settlement { settlements(first: 1, after: $b) { nodes { id } } } }")
WRONG_NAMED = ("query Q($a: String, $b: String) { "
               "settlements(first: 1, after: $a) { nodes { id } pageInfo { hasNextPage } } "
               "...S } fragment S on Settlement { settlements(first: 1, after: $b) { nodes { id } } }")
for label, query in (("inline", WRONG_INLINE), ("named", WRONG_NAMED)):
    open(journal, "w").close()
    code, body, _headers = send(query, {"a": "cursor-a", "b": "cursor-b"})
    assert code == 200, (label, code, body)
    messages = [error["message"] for error in body.get("errors") or []]
    assert any("cannot be spread here" in message for message in messages), (label, messages)
    events = [json.loads(line) for line in open(journal) if line.strip()]
    assert len(events) == 1 and events[0]["status"] == 200, (label, events)
print("ok   settlements different-type fragments stay with the schema, no ambiguous 400")

# Two settlements fields: the one that carries `after` decides the offset.
open(journal, "w").close()
DUAL = ("query Q($f: Int, $a: String) { "
        "first: settlements(first: 1) { pageInfo { hasNextPage } } "
        "second: settlements(first: $f, after: $a) { "
        "nodes { id } pageInfo { endCursor hasNextPage } } }")
cursor = None
seen = set()
throttles = retries = 0
while True:
    code, body, headers = send(DUAL, {"f": 100, "a": cursor})
    if code == 429:
        throttles += 1
        assert headers.get("Retry-After") == "1", headers.get("Retry-After")
        code, body, _headers = send(DUAL, {"f": 100, "a": cursor})
        assert code == 200, ("dual retry", code)
        retries += 1
    assert code == 200, (code, body)
    conn = body["data"]["second"]
    seen |= {s["id"] for s in conn["nodes"]}
    cursor = conn["pageInfo"]["endCursor"]
    if not conn["pageInfo"]["hasNextPage"]:
        break
assert len(seen) == 1873, len(seen)
assert throttles == 1 and retries == 1, (throttles, retries)
print("ok   settlements multiple fields: the field with after sets the throttle")

# Two fields both carry `after`: a null one must not win over the paging cursor.
DUAL_TWO_AFTER = ("query Q($a: String, $b: String) { "
                  "one: settlements(first: 1, after: $a) { pageInfo { hasNextPage } } "
                  "two: settlements(first: 100, after: $b) { "
                  "nodes { id } pageInfo { endCursor hasNextPage } } }")
open(journal, "w").close()
cursor = None
seen = set()
throttles = retries = 0
while True:
    code, body, headers = send(DUAL_TWO_AFTER, {"a": None, "b": cursor})
    if code == 429:
        throttles += 1
        assert headers.get("Retry-After") == "1", headers.get("Retry-After")
        code, body, _headers = send(DUAL_TWO_AFTER, {"a": None, "b": cursor})
        assert code == 200, ("dual after retry", code)
        retries += 1
    assert code == 200, (code, body)
    conn = body["data"]["two"]
    seen |= {s["id"] for s in conn["nodes"]}
    cursor = conn["pageInfo"]["endCursor"]
    if not conn["pageInfo"]["hasNextPage"]:
        break
assert len(seen) == 1873, len(seen)
assert throttles == 1 and retries == 1, (throttles, retries)
events = [json.loads(line) for line in open(journal) if line.strip()]
assert len({e["traversal"] for e in events}) == 1, "the null after started a new traversal"
print("ok   settlements dual after: the non-null paging cursor decides the traversal")

# Two non-null `after` values cannot resolve to one traversal: 400, no traversal.
open(journal, "w").close()
code, body, _headers = send(DUAL_TWO_AFTER, {"a": cursor, "b": cursor})
assert code == 400, (code, body)
message = body["errors"][0]["message"]
assert message.startswith("ambiguous settlements field"), message
events = [json.loads(line) for line in open(journal) if line.strip()]
assert len(events) == 1 and events[0]["status"] == 400, events
assert events[0]["traversal"] == "", events
print("ok   settlements two non-null after fields: distinct 400 without a traversal")

# Two operations and no operation name cannot resolve to one field: 400, no traversal.
open(journal, "w").close()
code, body, _headers = send(AMBIGUOUS, {"f": 100, "a": None})
assert code == 400, (code, body)
assert body["errors"][0]["message"].startswith("could not resolve the settlements field"), body
events = [json.loads(line) for line in open(journal) if line.strip()]
assert len(events) == 1 and events[0]["status"] == 400, events
assert events[0]["traversal"] == "", events
print("ok   settlements ambiguous document rejected without a traversal")
PYFRAG
then
  echo "FAIL settlements fragment traversal"; fail=1
fi

# Trusted retry measurement: one journal split into two phases gives separate agent
# and grading counts. A missing, malformed or wrong-typed journal is unknown with null
# counts. The grading read also rejects live-API traffic and extra grading clients.
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
python3 -I - "$tmp/rj-journal.jsonl" "$tmp/rj-wrongtype.jsonl" <<'PYWT'
import json, sys
event = json.loads(next(line for line in open(sys.argv[1]) if line.strip()))
event["throttled"] = "true"
open(sys.argv[2], "w").write(json.dumps(event) + "\n")
PYWT
python3 -I harness/retry_journal.py read --phase agent --local "payouts_live=$tmp/rj-wrongtype.jsonl" --out "$tmp/rj-wrongtype.json" >/dev/null

# Grading isolation: a clean pair is ok, live traffic or an extra client is unknown.
# The harness grades the final source and the first-v2 source in two fresh guests, so
# it passes an expected count of 2 when a first-v2 source exists.
python3 -I - "$tmp/rj-journal.jsonl" "$tmp" <<'PYISO'
import json, sys
event = json.loads(next(line for line in open(sys.argv[1]) if line.strip()))
grading = dict(event, client="a" * 16)

def write(name, events):
    with open(f"{sys.argv[2]}/{name}", "w") as f:
        for item in events:
            f.write(json.dumps(item) + "\n")

write("iso-live-clean.jsonl", [])
write("iso-grading.jsonl", [grading])
write("iso-live-dirty.jsonl", [dict(event, client="a" * 16)])
write("iso-grading-two.jsonl", [grading, dict(grading, client="b" * 16)])
write("iso-grading-three.jsonl", [grading, dict(grading, client="b" * 16),
                                   dict(grading, client="c" * 16)])
PYISO
python3 -I harness/retry_journal.py read --phase grading \
  --local "live=$tmp/iso-live-clean.jsonl" --local "grade=$tmp/iso-grading.jsonl" \
  --grading-live live --grading-grade grade --grading-clients 1 --out "$tmp/iso-clean.json" >/dev/null
python3 -I harness/retry_journal.py read --phase grading \
  --local "live=$tmp/iso-live-dirty.jsonl" --local "grade=$tmp/iso-grading.jsonl" \
  --grading-live live --grading-grade grade --grading-clients 1 --out "$tmp/iso-dirty.json" >/dev/null
python3 -I harness/retry_journal.py read --phase grading \
  --local "live=$tmp/iso-live-clean.jsonl" --local "grade=$tmp/iso-grading-two.jsonl" \
  --grading-live live --grading-grade grade --grading-clients 2 --out "$tmp/iso-two.json" >/dev/null
python3 -I harness/retry_journal.py read --phase grading \
  --local "live=$tmp/iso-live-clean.jsonl" --local "grade=$tmp/iso-grading-two.jsonl" \
  --grading-live live --grading-grade grade --grading-clients 1 --out "$tmp/iso-two-strict.json" >/dev/null
python3 -I harness/retry_journal.py read --phase grading \
  --local "live=$tmp/iso-live-clean.jsonl" --local "grade=$tmp/iso-grading-three.jsonl" \
  --grading-live live --grading-grade grade --grading-clients 2 --out "$tmp/iso-three.json" >/dev/null

if ! python3 -I - "$tmp/rj-agent.json" "$tmp/rj-grading.json" "$tmp/rj-missing.json" \
  "$tmp/rj-bad.json" "$tmp/rj-wrongtype.json" "$tmp/iso-clean.json" "$tmp/iso-dirty.json" \
  "$tmp/iso-two.json" "$tmp/iso-two-strict.json" "$tmp/iso-three.json" <<'PYRJ'
import json, sys
(agent, grading, missing, bad, wrongtype, clean, dirty,
 two, two_strict, three) = (json.load(open(p)) for p in sys.argv[1:11])
for phase, doc in (("agent", agent), ("grading", grading)):
    assert doc["phase"] == phase and doc["status"] == "ok", doc
    assert (doc["b5_429_responses"], doc["matching_retry_attempts"],
            doc["successful_matching_retries"]) == (1, 1, 1), doc
    assert doc["apis"]["payouts_live"]["status"] == "ok"
    assert "sandbox" not in json.dumps(doc)
for doc in (missing, bad, wrongtype):
    assert doc["status"] == "unknown", doc
    assert doc["b5_429_responses"] is None and doc["matching_retry_attempts"] is None
    assert doc["successful_matching_retries"] is None
assert clean["status"] == "ok" and clean["requests"] == 1 and clean["clients"] == 1, clean
assert dirty["status"] == "unknown" and "expected 0" in dirty["reason"], dirty
# The real two-pass case: two grading guests, expected count 2, is ok.
assert two["status"] == "ok" and two["clients"] == 2 and two["requests"] == 2, two
assert two_strict["status"] == "unknown" and "at most 1" in two_strict["reason"], two_strict
assert three["status"] == "unknown" and "at most 2" in three["reason"], three
print("ok   retry journal: phases 1/1/1, missing, malformed and wrong type unknown, grading one or two passes")
PYRJ
then
  echo "FAIL retry journal measurement"; fail=1
fi

# Digest shapes only. A raw cursor or a raw request would fail these.
if ! python3 -I - "$tmp/rj-journal.jsonl" <<'PYSHAPE'
import json, re, sys
DIGEST = re.compile(r"[0-9a-f]{0,32}")
CLIENT = re.compile(r"[0-9a-f]{16}")
for line in open(sys.argv[1]):
    if not line.strip():
        continue
    event = json.loads(line)
    assert DIGEST.fullmatch(event["request"]), event
    assert DIGEST.fullmatch(event["traversal"]), event
    assert CLIENT.fullmatch(event["client"]), event
print("ok   retry journal holds request, traversal and client digests only")
PYSHAPE
then
  echo "FAIL retry journal digest shape"; fail=1
fi

# Overflow: the server writes the marker on every request at or past the limit.
# Two requests after the first marker must leave two markers. After a truncate, two
# more requests write two markers again, so the phase reads as unknown.
ov=$((op + 17))
start_server payouts "$ov" "$tmp/ov.log" --behaviours B5 --retry-journal "$tmp/ov-journal.jsonl" --retry-journal-limit 2
for _ in $(seq 1 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/$ov") 2>/dev/null && break
  sleep 0.1
done
: > "$tmp/ov-journal.jsonl"
for _ in 1 2 3 4; do curl -s -o /dev/null "http://127.0.0.1:$ov/v2/payouts?limit=1"; done
lines_before=$(wc -l < "$tmp/ov-journal.jsonl")
markers_before=$(grep -c '"overflow":true' "$tmp/ov-journal.jsonl" || true)
python3 -I harness/retry_journal.py read --phase agent --local "payouts_live=$tmp/ov-journal.jsonl" --out "$tmp/ov-before.json" >/dev/null
: > "$tmp/ov-journal.jsonl"
for _ in 1 2; do curl -s -o /dev/null "http://127.0.0.1:$ov/v2/payouts?limit=1"; done
markers_after=$(grep -c '"overflow":true' "$tmp/ov-journal.jsonl" || true)
python3 -I harness/retry_journal.py read --phase agent --local "payouts_live=$tmp/ov-journal.jsonl" --out "$tmp/ov-after.json" >/dev/null
if [[ "$lines_before" == 4 && "$markers_before" == 2 && "$markers_after" == 2 ]] && python3 -I - "$tmp/ov-before.json" "$tmp/ov-after.json" <<'PYOV'
import json, sys
before, after = (json.load(open(p)) for p in sys.argv[1:3])
for doc in (before, after):
    assert doc["status"] == "unknown", doc
    assert doc["requests"] is None, doc
    assert "overflow" in doc["apis"]["payouts_live"]["reason"], doc
PYOV
then
  echo "ok   retry journal overflow: two markers, two more after truncate, unknown"
else
  echo "FAIL retry journal overflow (lines=$lines_before markers=$markers_before/$markers_after)"; fail=1
fi

# The B5 state maps stay bounded. A traversal that falls out of the cap can be
# throttled again, so the server writes an eviction marker and the phase reads unknown.
if ! python3 -I - "$tmp" <<'PYCAP'
import importlib.util
import json
import os
import sys

tmp = sys.argv[1]


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


for path, name in (("apis/payouts/server.py", "payouts_cap"),
                   ("apis/settlements/server.py", "settlements_cap")):
    sys.modules.pop("data", None)
    server = load(path, name)
    server.B5_STATE_LIMIT = 2
    journal = os.path.join(tmp, name + "-evict.jsonl")
    server.JOURNAL = open(journal, "w")
    for i in range(5):
        assert server.b5_decide(f"p{i}", "", server.B5_OFFSET, "f")[0] == "throttle"
    assert len(server.B5_PENDING) <= 2, (name, len(server.B5_PENDING))
    for i in range(5):
        trav = f"c{i}"
        assert server.b5_decide(trav, "", server.B5_OFFSET, "f")[0] == "throttle"
        assert server.b5_decide(trav, "", server.B5_OFFSET, "f")[0] == "retry"
    assert len(server.B5_CLEARED) <= 2, (name, len(server.B5_CLEARED))
    assert len(server.B5_PENDING) <= 2, (name, len(server.B5_PENDING))
    server.JOURNAL.flush()
    server.JOURNAL.close()
    lines = [json.loads(line) for line in open(journal) if line.strip()]
    assert any(line.get("eviction") is True for line in lines), (name, lines)
    # Truncate at a phase start, then evict again. The marker must return.
    open(journal, "w").close()
    server.JOURNAL = open(journal, "w")
    for i in range(3):
        server.b5_decide(f"again{i}", "", server.B5_OFFSET, "f")
    server.JOURNAL.flush()
    server.JOURNAL.close()
    lines = [json.loads(line) for line in open(journal) if line.strip()]
    assert any(line.get("eviction") is True for line in lines), (name, "after truncate", lines)
print("ok   B5 pending and cleared maps stay capped and mark an eviction")
PYCAP
then
  echo "FAIL B5 state cap"; fail=1
fi
python3 -I harness/retry_journal.py read --phase agent --local "payouts_live=$tmp/payouts_cap-evict.jsonl" --out "$tmp/cap-evict.json" >/dev/null
if python3 -I - "$tmp/cap-evict.json" <<'PYEV'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["status"] == "unknown", doc
assert "eviction" in doc["apis"]["payouts_live"]["reason"], doc
assert doc["requests"] is None, doc
print("ok   B5 eviction marker: the phase reads as unknown, not zero")
PYEV
then
  :
else
  echo "FAIL B5 eviction marker"; fail=1
fi

# Consumer sandbox runs and HTTP retries are separate fields. Three consumer runs
# and two successful retries must not add up to five sandbox runs.
if ! python3 -I - <<'PYMEAS'
import sys
sys.path.insert(0, "harness")
import result_measures
analysis = {
    "sandbox_runs": 3,
    "consumer_runs": [{"run": i} for i in range(3)],
    "retry_measure": {"phases": {
        "agent": {"status": "ok", "b5_429_responses": 2,
                  "matching_retry_attempts": 2, "successful_matching_retries": 2},
        "grading": {"status": "ok", "b5_429_responses": 0,
                    "matching_retry_attempts": 0, "successful_matching_retries": 0},
    }},
}
measures, retries = result_measures.build(analysis, "PASS", True, 100, 50, 0, 0)
assert measures["sandbox_runs"] == 3, measures
assert retries["agent"]["successful_matching_retries"] == 2, retries
assert retries["agent"]["b5_429_responses"] == 2, retries
assert retries["grading"]["successful_matching_retries"] == 0, retries
assert "sandbox_runs" not in retries, retries
print("ok   result measures: 3 sandbox runs stay apart from 2 successful retries")
PYMEAS
then
  echo "FAIL result measures separation"; fail=1
fi

# The shell writes measures["sandbox_runs"] only from result_measures.build. A
# reassignment after the builder would add HTTP retries to sandbox runs.
if ! python3 -I - harness/run.sh pilot/run-one.sh <<'PYWIRE'
import ast, re, sys

for path in sys.argv[1:]:
    text = open(path).read()
    blocks = re.findall(r"<< 'PY'\n(.*?)^PY$", text, re.S | re.M)
    assert blocks, f"{path}: no result block"
    tree = ast.parse(blocks[-1])
    build_at = None
    for index, node in enumerate(tree.body):
        if not isinstance(node, ast.Assign):
            continue
        if any(isinstance(target, ast.Tuple) and
               any(isinstance(element, ast.Name) and element.id == "measures"
                   for element in target.elts)
               for target in node.targets):
            build_at = index
    assert build_at is not None, f"{path}: no result_measures.build assignment"
    for node in tree.body[build_at + 1:]:
        targets = []
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, ast.AugAssign):
            targets = [node.target]
        for target in targets:
            for sub in ast.walk(target):
                if isinstance(sub, ast.Name) and sub.id == "measures":
                    raise SystemExit(f"{path}: measures is reassigned after build")
print("ok   shell result wiring: sandbox_runs comes only from result_measures.build")
PYWIRE
then
  echo "FAIL shell result wiring"; fail=1
fi

# The stand-alone reader bounds `msb` and sets its own umask.
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$tmp/bin/msb"
chmod +x "$tmp/bin/msb"
start_s=$(date +%s)
set +e
PATH="$tmp/bin:$PATH" KALARI_MSB_TIMEOUT=1 timeout 8 python3 -I harness/retry_journal.py truncate \
  --remote "x=/p" --out "$tmp/rj-timeout.json" >/dev/null 2>&1
timeout_rc=$?
set -e
elapsed_s=$(( $(date +%s) - start_s ))
if [[ $timeout_rc == 0 && $elapsed_s -lt 5 ]] && grep -q '"status": "failed"' "$tmp/rj-timeout.json"; then
  echo "ok   retry journal msb timeout: failed status, no hang"
else
  echo "FAIL retry journal msb timeout (rc=$timeout_rc elapsed=${elapsed_s}s)"; fail=1
fi
rm -f "$tmp/umask-out.json"
( umask 000; python3 -I harness/retry_journal.py read --phase agent \
    --local "x=$tmp/no-such.jsonl" --out "$tmp/umask-out.json" >/dev/null )
mode=$(stat -c %a "$tmp/umask-out.json")
if [[ "$mode" == 644 ]]; then
  echo "ok   retry journal sets umask 0022 (output mode $mode)"
else
  echo "FAIL retry journal umask: output mode $mode, wanted 644"; fail=1
fi

# The grading window opens only after the arm's sandboxes and processes are gone.
grading_line=$(grep -n '^retry_truncate grading$' harness/remote.sh | cut -d: -f1)
remove_line=$(awk -v g="$grading_line" 'NR < g && /^remove_ours$/ { last = NR } END { print last }' harness/remote.sh)
kill_line=$(awk -v g="$grading_line" 'NR < g && /^kill_new_procs$/ { last = NR } END { print last }' harness/remote.sh)
pilot_guest=$(grep -n 'msb remove -f "\$GUEST"' pilot/remote.sh | head -1 | cut -d: -f1)
pilot_grade=$(grep -n '^retry_truncate grading$' pilot/remote.sh | cut -d: -f1)
if [[ -n "$grading_line" && -n "$remove_line" && -n "$kill_line" && "$remove_line" -lt "$grading_line" && "$kill_line" -lt "$grading_line" ]] &&
  [[ -n "$pilot_guest" && -n "$pilot_grade" && "$pilot_guest" -lt "$pilot_grade" ]] &&
  grep -q -- '--grading-live' harness/remote.sh && grep -q -- '--grading-grade' harness/remote.sh &&
  grep -q -- '--grading-live' pilot/remote.sh && grep -q -- '--grading-grade' pilot/remote.sh; then
  echo "ok   grading window opens after arm sandboxes and processes are gone"
else
  echo "FAIL grading boundary order (harness remove=$remove_line kill=$kill_line grade=$grading_line; pilot guest=$pilot_guest grade=$pilot_grade)"
  fail=1
fi

# The grading pass count comes from the harness: one pass, or two when a first-v2
# source exists. Run each retry_read body against a stub that records its arguments.
mkdir -p "$tmp/stub"
cat > "$tmp/stub/retry_journal.py" <<'PYSTUB'
import json, os, sys
open(os.environ["KALARI_CAPTURE"], "w").write(json.dumps(sys.argv[1:]))
PYSTUB
wire_read() { # <script> <first-v2: 0|1> <capture file>
  local script=$1 first=$2 capture=$3
  (
    export KALARI_CAPTURE=$capture
    STAGE=$tmp/stub RUN=$tmp/wire-run CONSUMER=payout_sync.py
    RETRY_JOURNAL=/srv/retry-journal.jsonl UPGRADE=payouts
    API_LIVE=api-payouts-live API_GRADE=api-payouts-grading
    rm -rf "$RUN"
    mkdir -p "$RUN"
    if [[ $first == 1 ]]; then
      mkdir -p "$RUN/first-v2-src"
      : > "$RUN/first-v2-src/$CONSUMER"
    fi
    retry_api() { printf 'api-%s-%s\n' "$UPGRADE" "$1"; }
    eval "$(awk '/^retry_read\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$script")"
    retry_read grading
  )
}
wire_read harness/remote.sh 0 "$tmp/wire-h1.json" || true
wire_read harness/remote.sh 1 "$tmp/wire-h2.json" || true
wire_read pilot/remote.sh 0 "$tmp/wire-p1.json" || true
wire_read pilot/remote.sh 1 "$tmp/wire-p2.json" || true
if python3 -I - "$tmp/wire-h1.json" "$tmp/wire-h2.json" \
  "$tmp/wire-p1.json" "$tmp/wire-p2.json" <<'PYWIRE'
import json, sys
for path, want in zip(sys.argv[1:], ("1", "2", "1", "2")):
    args = json.load(open(path))
    assert "--grading-clients" in args, (path, args)
    got = args[args.index("--grading-clients") + 1]
    assert got == want, (path, got, want)
print("ok   retry_read grading: one pass without a first-v2 source, two with")
PYWIRE
then
  :
else
  echo "FAIL retry_read grading client count"; fail=1
fi

# The condition route honours a destination root and never overwrites an old row.
if out=$(pilot/run.sh --list --condition 3 --upgrade payouts --root bench/pilot/harder/results) &&
  grep -q 'bench/pilot/harder/results/condition-3-payouts-r1.json' <<<"$out"; then
  echo "ok   pilot condition route honours --root"
else
  echo "FAIL pilot condition root"; fail=1
fi
if pilot/run.sh --list --condition 3 --upgrade payouts --root /tmp >/dev/null 2>&1; then
  echo "FAIL pilot accepted an unknown root"; fail=1
else
  echo "ok   pilot rejects an unknown root"
fi
# The B5 route uses the harder root and rejects an explicit baseline root.
if out=$(pilot/run.sh --list --behaviour B5 --upgrade payouts) &&
  grep -q 'bench/pilot/harder/results/behaviour-payouts-B5-r1.json' <<<"$out"; then
  echo "ok   pilot B5 route defaults to the harder root"
else
  echo "FAIL pilot B5 default root"; fail=1
fi
if out=$(pilot/run.sh --list --behaviour B5 --upgrade payouts --root bench/pilot/harder/results) &&
  grep -q 'bench/pilot/harder/results/behaviour-payouts-B5-r1.json' <<<"$out"; then
  echo "ok   pilot B5 route honours the harder root"
else
  echo "FAIL pilot B5 harder root"; fail=1
fi
if pilot/run.sh --list --behaviour B5 --upgrade payouts --root bench/pilot/results >/dev/null 2>"$tmp/pilot-b5-root.err"; then
  echo "FAIL pilot B5 accepted an explicit baseline root"; fail=1
elif grep -q "B5 rows need" "$tmp/pilot-b5-root.err"; then
  echo "ok   pilot B5 rejects an explicit baseline root"
else
  echo "FAIL pilot B5 root rejection message"; cat "$tmp/pilot-b5-root.err"; fail=1
fi
if pilot/run.sh --list --behaviour B1 --upgrade payouts --root bench/pilot/harder/results >/dev/null 2>"$tmp/pilot-b1-root.err"; then
  echo "FAIL pilot non-B5 accepted --root"; fail=1
elif grep -q "condition rows and B5 rows" "$tmp/pilot-b1-root.err"; then
  echo "ok   pilot rejects --root for a non-B5 behaviour"
else
  echo "FAIL pilot non-B5 root message"; cat "$tmp/pilot-b1-root.err"; fail=1
fi
if pilot/run.sh --list --behaviour B1 --upgrade payouts >/dev/null; then
  echo "ok   pilot non-B5 listing needs no root"
else
  echo "FAIL pilot non-B5 listing"; fail=1
fi
if [[ ! -f pilot/results/condition-3-payouts-r1.json ]]; then
  echo "FAIL pilot baseline row missing, refusing the overwrite test"; fail=1
elif pilot/run.sh --run --condition 3 --upgrade payouts --repeat 1 \
  --root bench/pilot/results >/dev/null 2>"$tmp/pilot-dest.err"; then
  echo "FAIL pilot overwrote an existing condition row"; fail=1
elif grep -q "result already exists" "$tmp/pilot-dest.err"; then
  echo "ok   pilot refuses an existing condition destination"
else
  echo "FAIL pilot existing destination check"; cat "$tmp/pilot-dest.err"; fail=1
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
