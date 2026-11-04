#!/usr/bin/env bash
# Live Microsandbox check: payouts reference programs under kalari-aashaan,
# then a sandbox with no allow rule. Not part of the gate. Needs msb and /dev/kvm.
set -euo pipefail
cd "$(dirname "$0")/../.."
umask 022

aashaan=".lake/build/bin/kalari-aashaan"
if [[ ! -x "$aashaan" ]]; then
  echo "missing ${aashaan}; run lake build before this live test" >&2
  exit 1
fi

work=$(mktemp -d)
run_id=$$
prefix="kalari-live-${run_id}-"
name_correct="${prefix}correct"
name_cursor="${prefix}cursor"
name_deny="${prefix}deny"
# Kalari.Config.defaultImage. Same string createArgv appends. Not a second image.
image=python:3.13-slim
py=""
server_pid=""
created=()

redact() {
  sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g'
}

untrack() {
  local name=$1
  local -a keep=()
  local n
  for n in "${created[@]+"${created[@]}"}"; do
    if [[ "$n" != "$name" ]]; then
      keep+=("$n")
    fi
  done
  created=("${keep[@]+"${keep[@]}"}")
}

remove_sandbox() {
  local name=$1
  if ! msb remove -f "$name" >"$work/remove.out" 2>"$work/remove.err"; then
    echo "msb remove failed for a sandbox this script created" >&2
    redact <"$work/remove.err" >&2 || true
    return 1
  fi
  untrack "$name"
}

cleanup() {
  local st=$?
  trap - EXIT
  if [[ -n "${server_pid}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  local n
  for n in "${created[@]+"${created[@]}"}"; do
    msb remove -f "$n" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
  exit "$st"
}
trap cleanup EXIT

# The guest cannot use the host's loopback. Take the address from the default
# route at runtime. Never the documentation address, and never a hardcoded one.
host_ip=$(ip -4 route show default | awk '{
  for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }
}')
if [[ -z "$host_ip" ]]; then
  host_ip=$(ip -4 route get 1.1.1.1 | awk '{
    for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }
  }')
fi
if [[ ! "$host_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "no host address for the grading server" >&2
  exit 1
fi
case "$host_ip" in
  127.*|0.0.0.0|169.254.169.254|203.0.113.10)
    echo "refusing grading target" >&2
    exit 1
    ;;
esac

port=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  cand=$(( 20000 + RANDOM % 20000 ))
  if python3 -I -c 'import socket, sys
s = socket.socket()
try:
    s.bind((sys.argv[1], int(sys.argv[2])))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
' "$host_ip" "$cand"; then
    port=$cand
    break
  fi
done
if [[ -z "$port" ]]; then
  echo "no free port for the grading server" >&2
  exit 1
fi

inet_ip=$(getent ahostsv4 example.com | awk '{ print $1; exit }')
if [[ -z "$inet_ip" ]]; then
  inet_ip=$(python3 -I -c 'import socket; print(socket.gethostbyname("example.com"))')
fi
if [[ ! "$inet_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$inet_ip" == "$host_ip" ]]; then
  echo "could not resolve a public address for the internet refusal check" >&2
  exit 1
fi
case "$inet_ip" in
  127.*|10.*|192.168.*|169.254.*|203.0.113.10|0.0.0.0)
    echo "public resolve did not return a public address" >&2
    exit 1
    ;;
  172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
    echo "public resolve did not return a public address" >&2
    exit 1
    ;;
esac

# msb create, as the backend builds it. Image last. One allow rule, or none.
# A missing image is pulled at most three times, then create runs once.
create_sandbox() {
  local name=$1
  local with_rule=$2
  local -a args=(create --name "$name" --cpus 1 --memory 256M --no-net)
  if [[ "$with_rule" == yes ]]; then
    args+=(--net-rule "allow@${host_ip}/32:tcp:${port}")
  fi
  args+=(--pull never "$image")
  if msb "${args[@]}" >"$work/create.out" 2>"$work/create.err"; then
    created+=("$name")
    return 0
  fi
  if ! grep -q 'not cached' "$work/create.err" && ! grep -q 'not cached' "$work/create.out"; then
    echo "create failed" >&2
    redact <"$work/create.err" >&2 || true
    redact <"$work/create.out" >&2 || true
    return 1
  fi
  echo "image ${image} is not cached"
  local i pulled=0
  for i in 1 2 3; do
    echo "pull ${image} attempt ${i}"
    if msb pull "$image" >"$work/pull.out" 2>"$work/pull.err"; then
      pulled=1
      break
    fi
    redact <"$work/pull.err" >&2 || true
    if [[ "$i" -lt 3 ]]; then
      sleep "$i"
    fi
  done
  if [[ "$pulled" -ne 1 ]]; then
    echo "msb pull ${image} failed after 3 tries" >&2
    return 1
  fi
  msb remove -f "$name" >/dev/null 2>&1 || true
  if ! msb "${args[@]}" >"$work/create.out" 2>"$work/create.err"; then
    echo "create failed after pull" >&2
    redact <"$work/create.err" >&2 || true
    return 1
  fi
  created+=("$name")
}

python_path() {
  local name=$1
  local found
  found=$(msb exec "$name" -- sh -c 'command -v python3 || true' | tr -d '\r' | awk '/^\//{ print; exit }')
  if [[ "$found" == /* ]]; then
    printf '%s\n' "$found"
  fi
}

# The configured image. --no-net cannot apt-get, and this script does not switch images.
ensure_runtime() {
  local name=$1
  local with_rule=$2
  create_sandbox "$name" "$with_rule"
  py=$(python_path "$name" || true)
  if [[ -z "$py" ]]; then
    echo "guest has no python3" >&2
    return 1
  fi
}

prepare_aashaan() {
  local name=$1
  msb copy -q "$aashaan" "${name}:/usr/local/bin/kalari-aashaan"
  msb copy -q bench/apis/payouts/reference/correct.py "${name}:/tmp/correct.py"
  msb copy -q bench/apis/payouts/reference/cursor_loop.py "${name}:/tmp/cursor_loop.py"
  msb exec "$name" -- chmod +x /usr/local/bin/kalari-aashaan
  msb exec "$name" -- sh -c 'echo 1 > /proc/sys/vm/overcommit_memory'
  local oc
  oc=$(msb exec "$name" -- cat /proc/sys/vm/overcommit_memory | tr -d '\r' | awk 'NF { print; exit }' | tr -d '[:space:]')
  if [[ "$oc" != 1 ]]; then
    echo "overcommit was not set" >&2
    return 1
  fi
}

start_server() {
  # Bound to the host address the guest allowlist names, not 127.0.0.1.
  # quirks.sh uses the same server with --v1 off. Output is redirected so the
  # host process is not a held pipe.
  timeout 1200 python3 -I bench/apis/payouts/server.py \
    --bind "$host_ip" --port "$port" --v1 off >"$work/server.log" 2>&1 &
  server_pid=$!
  local _
  for _ in $(seq 1 50); do
    if curl -sf -m 1 "http://${host_ip}:${port}/v2/payouts?limit=1" >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "grading server did not start" >&2
  redact <"$work/server.log" >&2 || true
  return 1
}

# Read one aashaan verdict. Prints a redacted summary. Exit 0 when the
# requested kind matches.
read_verdict() {
  local kind=$1
  local file=$2
  python3 -I - "$kind" "$file" <<'PY'
import json, re, sys
kind, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
line = ""
for candidate in text.splitlines():
    if candidate.startswith("{"):
        line = candidate
if not line:
    sys.stderr.write("no verdict json\n")
    raise SystemExit(2)
v = json.loads(line)
out = v.get("stdout") or ""
err = v.get("stderr") or ""
red = re.compile(r"\d{1,3}(?:\.\d{1,3}){3}")
synced = ""
m = re.search(r"synced (\d+) payouts", out)
if m:
    synced = m.group(1)
summary = {
    "verdict": v.get("verdict"),
    "exit": v.get("exit_code"),
    "wall_ms": v.get("wall_ms"),
    "synced": synced,
}
sys.stdout.write(json.dumps(summary) + "\n")
if kind == "correct":
    ok = v.get("verdict") == "exited" and v.get("exit_code") == 0 and synced != ""
    if not ok:
        blob = red.sub("<ip>", err)[-500:]
        if blob:
            sys.stderr.write(blob + "\n")
        net = ("URLError", "Connection refused", "timed out", "Network is unreachable", "Errno")
        if any(s in err for s in net):
            sys.stderr.write("correct could not reach the grading server; stopping\n")
        raise SystemExit(1)
elif kind == "cursor":
    if v.get("verdict") != "killed_timeout":
        sys.stderr.write("cursor verdict was not killed_timeout\n")
        raise SystemExit(1)
else:
    raise SystemExit(2)
PY
}

run_aashaan() {
  local name=$1
  local tmo=$2
  shift 2
  local out="$work/verdict.json"
  if ! msb exec "$name" -- /usr/local/bin/kalari-aashaan "$tmo" 65536 "$@" \
      >"$out" 2>"$work/aashaan.err"; then
    echo "aashaan exec failed" >&2
    redact <"$work/aashaan.err" >&2 || true
    redact <"$out" >&2 || true
    return 1
  fi
}

ensure_runtime "$name_correct" yes
prepare_aashaan "$name_correct"
start_server

run_aashaan "$name_correct" 30000 \
  "$py" /tmp/correct.py --base-url "http://${host_ip}:${port}" --out /tmp/payouts.jsonl
set +e
correct_summary=$(read_verdict correct "$work/verdict.json" 2>"$work/correct.err")
correct_rc=$?
set -e
if [[ "$correct_rc" -ne 0 ]]; then
  echo "outcome correct failed ${correct_summary}" >&2
  cat "$work/correct.err" >&2
  exit 1
fi
if ! msb copy -q "${name_correct}:/tmp/payouts.jsonl" "$work/payouts.jsonl"; then
  echo "could not copy the payouts output" >&2
  exit 1
fi
set +e
grade=$(python3 -I bench/graders/grade.py payouts "$work/payouts.jsonl" 2>"$work/grade.err")
grade_rc=$?
set -e
echo "outcome correct ${correct_summary} grade=${grade}"
if [[ "$grade_rc" -ne 0 ]]; then
  echo "grade did not pass" >&2
  cat "$work/grade.err" >&2
  exit 1
fi
remove_sandbox "$name_correct"

ensure_runtime "$name_cursor" yes
prepare_aashaan "$name_cursor"
run_aashaan "$name_cursor" 800 \
  "$py" /tmp/cursor_loop.py --base-url "http://${host_ip}:${port}" --out /tmp/payouts.jsonl
set +e
cursor_summary=$(read_verdict cursor "$work/verdict.json" 2>"$work/cursor.err")
cursor_rc=$?
set -e
if [[ "$cursor_rc" -ne 0 ]]; then
  echo "outcome cursor failed ${cursor_summary}" >&2
  cat "$work/cursor.err" >&2
  exit 1
fi
echo "outcome cursor ${cursor_summary}"
remove_sandbox "$name_cursor"

if [[ -n "$server_pid" ]]; then
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
fi

create_sandbox "$name_deny" no
py=$(python_path "$name_deny" || true)
if [[ -z "$py" ]]; then
  echo "deny sandbox has no python3" >&2
  exit 1
fi

cat >"$work/probe.py" <<'PY'
import socket
import sys

def one(label, host, port, path):
    try:
        s = socket.create_connection((host, int(port)), timeout=5)
    except Exception as e:
        print(f"{label}: refused {type(e).__name__}", flush=True)
        return 0
    try:
        s.settimeout(5)
        if path != "-":
            req = (
                f"GET {path} HTTP/1.0\r\n"
                f"Host: {host}\r\n"
                "Connection: close\r\n\r\n"
            )
            s.sendall(req.encode())
        data = b""
        while len(data) < 1200:
            try:
                chunk = s.recv(1200)
            except socket.timeout:
                print(f"{label}: refused timeout", flush=True)
                return 0
            if not chunk:
                break
            data += chunk
    except Exception as e:
        print(f"{label}: refused {type(e).__name__}", flush=True)
        return 0
    finally:
        s.close()
    text = data.decode("utf-8", "replace")
    if "network_policy_denied" in text.lower():
        print(f"{label}: refused network_policy_denied", flush=True)
        return 0
    if text.startswith("SSH-"):
        print(f"{label}: SUCCESS ssh-banner", flush=True)
        return 1
    first = text.split("\r\n", 1)[0]
    if first.startswith("HTTP/"):
        parts = first.split()
        code = parts[1] if len(parts) > 1 else "?"
        print(f"{label}: SUCCESS http-{code}", flush=True)
        return 1
    if not text.strip():
        print(f"{label}: refused empty", flush=True)
        return 0
    print(f"{label}: SUCCESS payload", flush=True)
    return 1

def main():
    failed = 0
    with open(sys.argv[1], encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            label, host, port, path = line.split()
            failed |= one(label, host, port, path)
    return failed

if __name__ == "__main__":
    sys.exit(main())
PY

cat >"$work/targets" <<EOF
metadata 169.254.169.254 80 /
ssh ${host_ip} 22 -
internet ${inet_ip} 80 /
EOF

msb copy -q "$work/probe.py" "${name_deny}:/tmp/probe.py"
msb copy -q "$work/targets" "${name_deny}:/tmp/targets"
set +e
msb exec "$name_deny" -- "$py" /tmp/probe.py /tmp/targets >"$work/deny.out" 2>"$work/deny.err"
deny_rc=$?
set -e
if grep -q 'SUCCESS' "$work/deny.out"; then
  echo "deny sandbox reached a forbidden target; stopping" >&2
  cat "$work/deny.out" >&2
  exit 1
fi
for label in metadata ssh internet; do
  if ! grep -q "^${label}: refused" "$work/deny.out"; then
    echo "deny probe missing a refusal for ${label}" >&2
    cat "$work/deny.out" >&2
    redact <"$work/deny.err" >&2 || true
    exit 1
  fi
done
if [[ "$deny_rc" -ne 0 ]]; then
  echo "deny probe exited ${deny_rc}" >&2
  cat "$work/deny.out" >&2
  redact <"$work/deny.err" >&2 || true
  exit 1
fi
echo "outcome deny $(tr '\n' ' ' <"$work/deny.out" | sed -E 's/[[:space:]]+$//')"
remove_sandbox "$name_deny"

list_raw=$(msb list --format json)
python3 -I -c '
import json, sys
prefix, raw = sys.argv[1], sys.argv[2].strip()
if not raw:
    raise SystemExit(0)
data = json.loads(raw)
bad = [e.get("name", "") for e in data if str(e.get("name", "")).startswith(prefix)]
if bad:
    print("sandboxes still listed:", len(bad))
    raise SystemExit(1)
' "$prefix" "$list_raw"
echo "outcome image=${image}"
echo "outcome list_clear=yes"
