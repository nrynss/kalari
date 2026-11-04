#!/usr/bin/env bash
# kalari-aashaan's eight cases inside a Microsandbox microVM.
# Not part of the gate: needs msb and /dev/kvm. Run after `lake build`.
# Image is Kalari.Config.defaultImage. Create argv is createArgv for that
# image with an empty allowlist: name, --cpus, --memory, --no-net, --pull never, image last.
set -euo pipefail
cd "$(dirname "$0")/../.."
umask 022

image=python:3.13-slim
name="aashaan-$$"
work=$(mktemp -d)
created=0

redact() {
  sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g'
}

cleanup() {
  local st=$?
  trap - EXIT
  if [[ "$created" -eq 1 ]]; then
    msb remove -f "$name" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
  exit "$st"
}
trap cleanup EXIT

# msb create, as createArgv builds it. No allow rule. Image last.
create() {
  if msb create --name "$name" --cpus 1 --memory 256M --no-net --pull never "$image" \
      >"$work/create.out" 2>"$work/create.err"; then
    created=1
    return 0
  fi
  return 1
}

# A missing image is not a case failure: pull at most three times, then create once more.
if ! create; then
  if ! grep -q 'not cached' "$work/create.err" && ! grep -q 'not cached' "$work/create.out"; then
    echo "create failed" >&2
    redact <"$work/create.err" >&2 || true
    exit 1
  fi
  echo "image ${image} is not cached"
  pulled=0
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
    exit 1
  fi
  msb remove -f "$name" >/dev/null 2>&1 || true
  if ! create; then
    echo "create failed after pull" >&2
    redact <"$work/create.err" >&2 || true
    exit 1
  fi
fi
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
