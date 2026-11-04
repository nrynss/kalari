#!/usr/bin/env bash
# Run the final candidate against the hidden v2-only service, in an isolated VM.
set -euo pipefail
umask 022
[[ $# == 5 ]] || { echo 'usage: grade.sh WORKSPACE GRADE_RUNNER API_IPV4 PORT OUTPUT_DIR' >&2; exit 2; }
workspace=$(realpath "$1"); runner=$(realpath "$2"); host=$3; port=$4; output=$(realpath "$5")
[[ -d $workspace && -f $workspace/payout_sync.py && -f $runner && -d $output ]] || exit 2
[[ $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && $port =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]] || exit 2
rm -f "$output/result.jsonl" "$output/status" "$output/stderr"
name="kalari-grade-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
created=0
cleanup() { if (( created )); then msb remove -f "$name" >/dev/null 2>&1 || { echo 'grade sandbox removal failed' >&2; exit 1; }; fi; }
trap cleanup EXIT
msb create --name "$name" --cpus 1 --memory 512M --pull never --no-net --net-rule "allow@${host}/32:tcp:${port}" python >/dev/null
created=1
msb exec "$name" -- mkdir -p /w/src
tar -C "$workspace" --exclude .git -czf "$output/source.tgz" .
msb copy -q "$output/source.tgz" "$name:/w/src.tgz"
msb copy -q "$runner" "$name:/w/grade_runner.py"
msb exec "$name" -- tar -C /w/src -xzf /w/src.tgz
# The untrusted guest never gets credentials or unrestricted egress.
timeout 150 msb exec "$name" -- python3 /w/grade_runner.py /w/src/payout_sync.py "http://${host}:${port}" /w/out.jsonl > "$output/status" 2> "$output/stderr" || true
msb copy -q "$name:/w/out.jsonl" "$output/result.jsonl" 2>/dev/null || true
rm -f "$output/source.tgz"
