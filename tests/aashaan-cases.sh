#!/usr/bin/env bash
# kalari-aashaan's verdicts on the host. Safe anywhere: every job it starts is killed.
# The escape case (a job that leaves the process group) runs only in a microVM:
# tests/live/microvm-cases.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
A=.lake/build/bin/kalari-aashaan
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/trap.sh" <<'EOF'
trap 'echo got-term' TERM
while :; do :; done
EOF

# case <name> <expected substrings, |-separated> -- <aashaan args...>
case_() {
  local name=$1 expect=$2; shift 3
  local out
  out=$(VULTR_INFERENCE_API_KEY=should-not-leak timeout 20 "$A" "$@") || { echo "FAIL $name: exit $?"; fail=1; return; }
  local IFS='|'
  for want in $expect; do
    if [[ $out != *"$want"* ]]; then echo "FAIL $name: missing $want in $out"; fail=1; return; fi
  done
  echo "ok   $name"
}

case_ normal   '"verdict":"exited"|"exit_code":0|"stdout":"hello\n"|"stderr":"warn\n"' -- 2000 4096 sh -c 'echo hello; echo warn >&2'
case_ exit3    '"verdict":"exited"|"exit_code":3'                                       -- 2000 4096 sh -c 'exit 3'
case_ loop     '"verdict":"killed_timeout"'                                             -- 800 4096 sh -c 'while :; do :; done'
case_ trapterm '"verdict":"killed_timeout"|"stdout":""'                                 -- 800 4096 sh "$tmp/trap.sh"
case_ fork     '"verdict":"killed_timeout"|"stdout":"spawned\n"'                        -- 800 4096 sh -c 'sleep 101 & sleep 102 & echo spawned; wait'
case_ flood    '"verdict":"killed_output_cap"|"stdout_truncated":true'                  -- 5000 100 yes
case_ secret   '"verdict":"exited"|"stdout":"key=[]\n"'                                 -- 2000 4096 sh -c 'echo "key=[$VULTR_INFERENCE_API_KEY]"'

# The fork case's children must be gone with the group.
if pgrep -f 'sleep 10[12]$' >/dev/null; then echo "FAIL fork: children survived"; fail=1; fi

exit $fail
