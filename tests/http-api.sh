#!/usr/bin/env bash
# Prove kalari serves MCP over stdio and the HTTP API on loopback together,
# and the Lean API matches the shim on every route and status.
# Offline: loopback only, no key, no network beyond the toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
B=.lake/build/bin
fail=0
tmp=$(mktemp -d)
pid=""
shimpid=""
cleanup() {
  if [[ -n "${shimpid:-}" ]]; then kill "$shimpid" 2>/dev/null || true; fi
  if [[ -n "${pid:-}" ]]; then kill "$pid" 2>/dev/null || true; fi
  exec 3>&- 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

expect() {  # expect <name> <want-substring> <got>
  if [[ "$3" == *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: wanted $2, got $3"; fail=1; fi
}

check_same() {  # check_same <name> <path> [curl args...]
  # Status plus parsed JSON must match. Key order is exempt: Lean's `compress`
  # sorts keys alphabetically while the shim preserves file order; values are
  # what the contract covers (see web/check.py, which compares parsed JSON).
  local name=$1 path=$2; shift 2
  local lean shim lc sc lb sb
  lean=$(curl -s -w $'\n%{http_code}' "$@" "http://127.0.0.1:$leanPort$path")
  shim=$(curl -s -w $'\n%{http_code}' "$@" "http://127.0.0.1:$shimPort$path")
  lc=${lean##*$'\n'}; sc=${shim##*$'\n'}
  lb=${lean%$'\n'*}; sb=${shim%$'\n'*}
  if [[ "$lc" != "$sc" ]]; then
    echo "FAIL $name: status lean=$lc shim=$sc"; fail=1; return
  fi
  if python3 - "$lb" "$sb" <<'EOF'
import json, sys
sys.exit(0 if json.loads(sys.argv[1]) == json.loads(sys.argv[2]) else 1)
EOF
  then echo "ok   $name"
  else echo "FAIL $name:"; echo "--- lean ---"; printf '%s\n' "$lean"; echo "--- shim ---"; printf '%s\n' "$shim"; fail=1
  fi
}

leanPort=$(( 20000 + RANDOM % 20000 ))
shimPort=$(( 20000 + RANDOM % 20000 ))
while [[ "$shimPort" == "$leanPort" ]]; do shimPort=$(( 20000 + RANDOM % 20000 )); done

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

# Point the shim at the fixture's own store so both read the same records.
store=$(grep -o 'kalari evidence: .*' "$tmp/stderr.log" | head -1 | sed 's/kalari evidence: //')
[[ -f "$store" ]] || { echo "FAIL evidence store not found: $store"; exit 1; }
python3 - "$store" <<'EOF'
import json, sys
record = {"kind": "benchmark", "session_id": "parity", "run_id": "parity-bench-1",
          "change_kinds": ["pagination_changed"], "payload": {"provenance": "http-api-check"}}
with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
EOF
python3 deploy/vultr/kalari-api.py --store "$store" \
  --host 127.0.0.1 --port "$shimPort" 3>&- >"$tmp/shim.log" 2>&1 &
shimpid=$!
for _ in $(seq 1 100); do
  curl -s "http://127.0.0.1:$shimPort/api/runs" >/dev/null 2>&1 && break
  sleep 0.1
done

sid=$(curl -s "http://127.0.0.1:$leanPort/api/sessions" | python3 -c "import json,sys; print(json.load(sys.stdin)[0])")
rid=$(curl -s "http://127.0.0.1:$leanPort/api/runs" | python3 -c "import json,sys; print(json.load(sys.stdin)[0])")
check_same "sessions" "/api/sessions"
check_same "runs" "/api/runs"
check_same "lessons" "/api/lessons"
check_same "benchmark" "/api/benchmark"
check_same "session detail" "/api/sessions/$sid"
check_same "run detail" "/api/runs/$rid"
check_same "parity run detail" "/api/runs/parity-bench-1"
check_same "parity session" "/api/sessions/parity"
check_same "missing run" "/api/runs/does-not-exist-xyz"
check_same "unknown resource" "/api/nope"
check_same "empty run id" "/api/runs/"
check_same "bad session id" "/api/sessions/bad!id"
check_same "post empty" "/api/runs" -X POST
check_same "put" "/api/runs" -X PUT
check_same "post body" "/api/runs" --data-binary 'x'
check_same "get body" "/api/runs" -X GET --data-binary 'x'
check_same "query" "/api/runs?bad"
check_same "body over cap" "/api/runs" --data-binary "$(head -c 5000 /dev/zero | tr '\0' a)"
check_same "body at cap" "/api/runs" --data-binary "$(head -c 4096 /dev/zero | tr '\0' a)"

# HEAD is the one known difference: the shim answers it, Lean 404s its
# GET-only contract. Record both behaviours explicitly.
expect "lean HEAD is 404" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -I "http://127.0.0.1:$leanPort/api/runs")"
expect "shim HEAD is 200" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -I "http://127.0.0.1:$shimPort/api/runs")"

# Closing stdin ends MCP; the HTTP server must shut down and the process exit.
exec 3>&-
if wait "$pid"; then echo "ok   clean exit on stdin EOF"; else echo "FAIL fixture exit status"; fail=1; fi
pid=""
kill "$shimpid" 2>/dev/null || true
shimpid=""
wait 2>/dev/null || true

exit $fail
