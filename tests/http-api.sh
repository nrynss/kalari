#!/usr/bin/env bash
# Prove kalari serves MCP over stdio and the Lean HTTP API on loopback together.
# The Lean routes are asserted directly: status codes plus parsed JSON shapes.
# Offline: loopback only, no key, no network beyond the toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
B=.lake/build/bin
fail=0
tmp=$(mktemp -d)
pid=""
cleanup() {
  if [[ -n "${pid:-}" ]]; then kill "$pid" 2>/dev/null || true; fi
  exec 3>&- 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

expect() {  # expect <name> <want-substring> <got>
  if [[ "$3" == *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: wanted $2, got $3"; fail=1; fi
}

check_api() {  # check_api <name> <want-status> <path> [curl args...]
  # Status must match and the body must be JSON. Values are checked by the
  # detail helpers below; this covers every route and status of the contract.
  local name=$1 want=$2 path=$3; shift 3
  local out code body
  out=$(curl -s -w $'\n%{http_code}' "$@" "http://127.0.0.1:$leanPort$path")
  code=${out##*$'\n'}; body=${out%$'\n'*}
  if [[ "$code" != "$want" ]]; then
    echo "FAIL $name: wanted $want, got $code ($body)"; fail=1; return
  fi
  if ! python3 -c 'import json,sys; json.loads(sys.argv[1])' "$body"; then
    echo "FAIL $name: not JSON: $body"; fail=1; return
  fi
  echo "ok   $name"
}

check_detail() {  # check_detail <name> <path> <key> <id>
  # A detail route returns every record stored under that id, and nothing else.
  local name=$1 path=$2 key=$3 id=$4
  local body
  body=$(curl -s "http://127.0.0.1:$leanPort$path")
  if python3 - "$body" "$key" "$id" <<'EOF'
import json, sys
records = json.loads(sys.argv[1])
sys.exit(0 if records and all(r.get(sys.argv[2]) == sys.argv[3] for r in records) else 1)
EOF
  then echo "ok   $name"
  else echo "FAIL $name: $body"; fail=1
  fi
}

leanPort=$(( 20000 + RANDOM % 20000 ))

# One fixture process serves both paths: MCP on stdin/stdout, HTTP on loopback.
# stdin is a FIFO held open so both paths stay up together; closing it ends MCP.
# The children close the inherited writer (3>&-): the script's fd is the only
# writer, so closing it in the script delivers EOF to the fixture.
mkfifo "$tmp/in"
exec 3<>"$tmp/in"
KALARI_HTTP_PORT="$leanPort" "$B/kalari" --offline-fixture \
  <"$tmp/in" 3>&- >"$tmp/mcp.out" 2>"$tmp/stderr.log" &
pid=$!
for _ in $(seq 1 100); do
  curl -s "http://127.0.0.1:$leanPort/api/runs" >/dev/null 2>&1 && break
  sleep 0.1
done
if ! curl -s "http://127.0.0.1:$leanPort/api/runs" >/dev/null 2>&1; then
  echo "FAIL http never became ready"; cat "$tmp/stderr.log"; exit 1
fi
expect "loopback bind" "listening on 127.0.0.1:$leanPort" "$(cat "$tmp/stderr.log")"
expect "http runs" 'forged-artifact"] 200' \
  "$(curl -s -w ' %{http_code}' "http://127.0.0.1:$leanPort/api/runs")"

# MCP answers in the same process while HTTP keeps serving.
printf '%s\n' '{"jsonrpc":"2.0","id":99,"method":"ping","params":{}}' >&3
pinged=""
for _ in $(seq 1 100); do
  pinged=$(grep '"id":99' "$tmp/mcp.out" || true)
  [[ -n "$pinged" ]] && break
  sleep 0.1
done
expect "mcp concurrent with http" '"result":{}' "$pinged"
expect "http still serving" '200' \
  "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$leanPort/api/sessions")"

sid=$(curl -s "http://127.0.0.1:$leanPort/api/sessions" | python3 -c "import json,sys; print(json.load(sys.stdin)[0])")
rid=$(curl -s "http://127.0.0.1:$leanPort/api/runs" | python3 -c "import json,sys; print(json.load(sys.stdin)[0])")
check_api "sessions" 200 "/api/sessions"
check_api "runs" 200 "/api/runs"
check_api "lessons" 200 "/api/lessons"
check_api "benchmark" 200 "/api/benchmark"
check_detail "session detail" "/api/sessions/$sid" "session_id" "$sid"
check_detail "run detail" "/api/runs/$rid" "run_id" "$rid"

# The store is re-read per request: a record appended after startup appears
# without restarting the server.
store=$(grep -o 'kalari evidence: .*' "$tmp/stderr.log" | head -1 | sed 's/kalari evidence: //')
[[ -f "$store" ]] || { echo "FAIL evidence store not found: $store"; exit 1; }
python3 - "$store" <<'EOF'
import json, sys
record = {"kind": "benchmark", "session_id": "parity", "run_id": "parity-bench-1",
          "change_kinds": ["pagination_changed"], "payload": {"provenance": "http-api-check"}}
with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
EOF
check_detail "parity run detail" "/api/runs/parity-bench-1" "run_id" "parity-bench-1"
check_detail "parity session" "/api/sessions/parity" "session_id" "parity"

check_api "missing run" 404 "/api/runs/does-not-exist-xyz"
check_api "unknown resource" 404 "/api/nope"
check_api "empty run id" 400 "/api/runs/"
check_api "bad session id" 400 "/api/sessions/bad!id"
check_api "post empty" 404 "/api/runs" -X POST
check_api "put" 404 "/api/runs" -X PUT
check_api "post body" 400 "/api/runs" --data-binary 'x'
check_api "get body" 400 "/api/runs" -X GET --data-binary 'x'
check_api "query" 400 "/api/runs?bad"
check_api "body over cap" 413 "/api/runs" --data-binary "$(head -c 5000 /dev/zero | tr '\0' a)"
check_api "body at cap" 400 "/api/runs" --data-binary "$(head -c 4096 /dev/zero | tr '\0' a)"

# The contract is GET-only: HEAD on a route answers 404 like any other
# non-GET method.
expect "lean HEAD is 404" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -I "http://127.0.0.1:$leanPort/api/runs")"

# Closing stdin ends MCP; the HTTP server must shut down and the process exit.
exec 3>&-
if wait "$pid"; then echo "ok   clean exit on stdin EOF"; else echo "FAIL fixture exit status"; fail=1; fi
pid=""
wait 2>/dev/null || true

exit $fail
