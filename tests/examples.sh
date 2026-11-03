#!/usr/bin/env bash
# The Examples/ executables still do what docs/lean.md says. Offline: localhost only.
# (Examples.Gate and Examples.Json are checked by `lake build` itself: theorems and #guard.)
set -euo pipefail
cd "$(dirname "$0")/.."
B=.lake/build/bin
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

expect() {  # expect <name> <want-substring> <got>
  if [[ $3 == *"$2"* ]]; then echo "ok   $1"; else echo "FAIL $1: wanted $2, got $3"; fail=1; fi
}

# example-http: bounded by timeout, so it can't outlive the test however it exits.
port=$(( 20000 + RANDOM % 20000 ))
timeout 30 "$B/example-http" "$port" >"$tmp/http.log" 2>&1 &
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break; sleep 0.1; done
U="http://127.0.0.1:$port"
expect "http health"      '{"ok":true} 200'          "$(curl -s -w ' %{http_code}' "$U/health")"
expect "http allowed"     '{"allowed":true} 200'     "$(curl -s -w ' %{http_code}' -d '{"path":"/workspace/a","timeoutMs":100}' "$U/check")"
expect "http denied"      '{"allowed":false} 200'    "$(curl -s -w ' %{http_code}' -d '{"path":"/etc/x","timeoutMs":100}' "$U/check")"
expect "http bad json"    '400'                      "$(curl -s -w ' %{http_code}' -d '{"path":1}' "$U/check")"
expect "http body cap"    '413'                      "$(head -c 5000 /dev/zero | tr '\0' a | curl -s -w ' %{http_code}' --data-binary @- "$U/check")"
expect "http 404"         '404'                      "$(curl -s -w ' %{http_code}' "$U/nope")"

# example-curl: the key travels on curl's stdin; the server sees the header.
printf '{"path":"/workspace/a","timeoutMs":5}' > "$tmp/body.json"
expect "curl header"      '200 {"authorization_present":true}' "$(EXAMPLE_KEY=not-a-key "$B/example-curl" "$U/auth" EXAMPLE_KEY)"
expect "curl post"        '200 {"allowed":true}'               "$(EXAMPLE_KEY=not-a-key "$B/example-curl" "$U/check" EXAMPLE_KEY "$tmp/body.json")"
expect "curl unset key"   'is not set'                         "$("$B/example-curl" "$U/auth" UNSET_EXAMPLE_KEY 2>&1 || true)"

# example-jsonrpc: requests answered, the notification not, errors coded.
out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"nope"}' \
  'not json' | timeout 10 "$B/example-jsonrpc" 2>/dev/null)
expect "jsonrpc lines"    '4'                        "$(wc -l <<<"$out" | tr -d ' ')"
expect "jsonrpc init"     '"serverInfo"'             "$(sed -n 1p <<<"$out")"
expect "jsonrpc call"     '"text":"hi"'              "$(sed -n 2p <<<"$out")"
expect "jsonrpc unknown"  '-32601'                   "$(sed -n 3p <<<"$out")"
expect "jsonrpc parse"    '-32700'                   "$(sed -n 4p <<<"$out")"

exit $fail
