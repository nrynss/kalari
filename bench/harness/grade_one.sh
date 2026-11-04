#!/usr/bin/env bash
# One hidden-grader pass, shared by remote.sh and the no-inference rehearsal.
#
# grade_one <source-dir> <basename>
#
# Only `/w/out.jsonl`, produced by the consumer inside the fresh grading guest,
# is copied out and graded. There is deliberately no copy from
# `/w/src/${OUT_NAME}` or from the agent workspace: a file left behind cannot
# stand in for a run that produced nothing.
#
# The caller supplies RUN, RUN_ID, STAGE, CONSUMER, OUT_NAME, IP, GRADE_PORT,
# WS, KALARI_REDACT_KEY and KALARI_PUBLIC_IP. The rehearsal puts a stub `msb`
# on PATH and calls this function with the same arguments remote.sh uses.
set -euo pipefail

grade_one() { # $1 source dir, $2 basename. Failures are recorded; they must not drop the session.
  local src=$1 base=$2
  local name="kalari-grade-${base}-${RUN_ID}"
  local failed="" exec_rc=0
  # The first pass's output can only be stale in the source tree that pass
  # grades, not in the agent workspace the final pass used.
  local status_workspace=$WS
  if [[ "$base" == first ]]; then
    status_workspace=$src
  fi
  echo "status=grade:$base" >&2
  umask 022
  rm -f "$RUN/${base}.status" "$RUN/${base}.jsonl" "$RUN/${base}.consumer.log" "$RUN/${base}.grade.json"
  if ! msb create --name "$name" --cpus 1 --memory 512M --pull never --no-net \
    --net-rule "allow@${IP}/32:tcp:${GRADE_PORT}" python >/dev/null; then
    failed=create
  elif ! msb exec "$name" -- mkdir -p /w/src; then
    failed=mkdir
  elif ! tar -C "$src" --exclude .git -czf "$RUN/${base}.tgz" .; then
    failed=tar
  elif ! msb copy -q "$RUN/${base}.tgz" "$name:/w/src.tgz"; then
    failed=copy
  elif ! msb copy -q "$STAGE/grade_runner.py" "$name:/w/grade_runner.py"; then
    failed=copy-runner
  elif ! msb exec "$name" -- tar -C /w/src -xzf /w/src.tgz; then
    failed=untar
  fi
  if [[ -n "$failed" ]]; then
    echo "EXIT $failed" > "$RUN/${base}.status"
  else
    set +e
    timeout 150 msb exec "$name" -- python3 /w/grade_runner.py "/w/src/${CONSUMER}" "http://${IP}:${GRADE_PORT}" "/w/out.jsonl" \
      > "$RUN/${base}.status" 2> "$RUN/${base}.err"
    exec_rc=$?
    set -e
    # The only output copied out is the one the grading guest just wrote.
    msb copy -q "$name:/w/out.jsonl" "$RUN/${base}.jsonl" 2>/dev/null || true
    msb copy -q "$name:/w/consumer.log" "$RUN/${base}.consumer.log" 2>/dev/null || true
  fi
  msb remove -f "$name" >/dev/null 2>&1 || true
  python3 "$STAGE/grade_status.py" \
    --status "$RUN/${base}.status" \
    --fresh-output "$RUN/${base}.jsonl" \
    --workspace "$status_workspace" \
    --output-name "$OUT_NAME" \
    --exec-rc "$exec_rc" \
    --pass "$base" \
    --out "$RUN/${base}.grade.json"
  python3 - "$RUN/${base}.consumer.log" "$RUN/${base}.log-excerpt" << 'PY'
import os, re, sys
src, dest = sys.argv[1], sys.argv[2]
key = os.environ.get("KALARI_REDACT_KEY", "")
ip = os.environ.get("KALARI_PUBLIC_IP", "")
text = ""
if os.path.exists(src):
    text = open(src, errors="replace").read()[-1500:]
if key:
    text = text.replace(key, "[redacted]")
if ip:
    text = text.replace(ip, "the VM's public address")
text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "the VM's public address", text)
text = re.sub(r"/home/[^/\s]+", "~", text)
open(dest, "w").write(text)
PY
}
