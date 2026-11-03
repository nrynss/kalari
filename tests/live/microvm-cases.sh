#!/usr/bin/env bash
# kalari-aashaan's eight cases inside a Microsandbox microVM, on the Vultr VM.
# Not part of the gate: needs msb and /dev/kvm. Run after `lake build`.
set -euo pipefail
cd "$(dirname "$0")/../.."
name="aashaan-$$"
msb create --name "$name" --cpus 1 --memory 256M --no-net debian >/dev/null
trap 'msb stop "$name" >/dev/null 2>&1; msb remove "$name" >/dev/null 2>&1' EXIT
msb copy -q .lake/build/bin/kalari-aashaan "$name":/usr/local/bin/kalari-aashaan
msb exec "$name" -- chmod +x /usr/local/bin/kalari-aashaan
# Without this the Lean runtime can't start threads in the guest (no swap, heuristic overcommit).
msb exec "$name" -- sh -c 'echo 1 > /proc/sys/vm/overcommit_memory'
msb exec "$name" -- bash -s <<'EOF'
export VULTR_INFERENCE_API_KEY=should-not-leak
printf "trap 'echo got-term' TERM\nwhile :; do :; done\n" > /tmp/trap.sh
echo 'setsid sleep 104 & echo spawned; while :; do :; done' > /tmp/escape.sh
r(){ echo "== $1"; shift; timeout 20 kalari-aashaan "$@" | cut -c1-200; }
r normal   2000 4096 sh -c 'echo hello; echo warn >&2'
r exit3    2000 4096 sh -c 'exit 3'
r loop      800 4096 sh -c 'while :; do :; done'
r trapterm  800 4096 sh /tmp/trap.sh
r fork      800 4096 sh -c 'sleep 101 & sleep 102 & echo spawned; wait'
r flood    5000  100 yes
r secret   2000 4096 sh -c 'echo "key=[$VULTR_INFERENCE_API_KEY]"'
r escape    800 4096 sh /tmp/escape.sh       # expect pipe_held_open: true; teardown ends it
EOF
