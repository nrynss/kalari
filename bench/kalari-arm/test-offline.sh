#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
touch "$tmp/bin/.kalari-offline-fixture"
for name in kalari kalari-aashaan lambo; do ln -s /bin/true "$tmp/bin/$name"; done
cat > "$tmp/bin/vimanam" <<'SH'
#!/bin/sh
printf '%s\n' '{"changes":[{"kind":"pagination_changed"}]}'
SH
cat > "$tmp/bin/opencode" <<'SH'
#!/bin/sh
if [ "$1" = --version ]; then echo '2.2.5'; exit; fi
[ "$1" = run ] && [ "$2" = --standalone ] || exit 1
if [ -e "$(dirname "$0")/HANG" ]; then
  python3 - "$(dirname "$0")/hung-child.pid" <<'PY'
import subprocess, sys, time
child=subprocess.Popen(['sleep','300'])
open(sys.argv[1],'w').write(str(child.pid))
time.sleep(300)
PY
  exit
fi
python3 - <<'PY'
import json, os
assert os.environ.get('KALARI_OFFLINE_FIXTURE') == '1'
assert 'KALARI_TEST_SECRET' not in os.environ
for name in ('what_changed','blast_radius','recall_lessons','run_in_sandbox','record_lesson'):
 print(json.dumps({'type':'tool_use','part':{'tool':'kalari_'+name,'state':{'status':'completed','input':{'text':os.environ['VULTR_INFERENCE_API_KEY']+' 127.0.0.1'}}}}))
PY
SH
cat > "$tmp/bin/msb" <<'SH'
#!/bin/sh
case "$1" in
 create) printf '%s\n' create >> "$MSB_LOG";;
 remove) printf '%s\n' remove >> "$MSB_LOG";;
 exec) case "$*" in *grade_runner.py*) echo 'EXIT 0';; esac;;
 copy) case "$3" in *:/w/out.jsonl) ;; *) :;; esac;;
esac
SH
chmod +x "$tmp/bin/"{vimanam,opencode,msb}
export KALARI_TEST_SECRET='must-not-leak-to-child'
python3 "$root/bench/kalari-arm/runner.py" --offline-fixture --tools "$tmp/bin" --opencode "$tmp/bin/opencode" --api-host 127.0.0.1 --result "$tmp/result" >/dev/null
python3 - "$tmp" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); events=(p/'result/transcript.jsonl').read_text(); m=json.loads((p/'result/measures.json').read_text())
assert 'offline-fixture-invalid-key' not in events and '127.0.0.1' not in events
assert len(m['tool_calls']) == 5 and all(v == 1 for v in m['tool_calls'].values())
assert m['grade']['verdict'] == 'FAIL' and m['grader_status'] == 'EXIT 0'
assert (p/'msb.log').read_text().splitlines() == ['create','remove']
PY
touch "$tmp/bin/HANG"
python3 "$root/bench/kalari-arm/runner.py" --offline-fixture --tools "$tmp/bin" --opencode "$tmp/bin/opencode" --api-host 127.0.0.1 --result "$tmp/interrupted" >/dev/null 2>&1 &
runner_pid=$!
for _ in $(seq 1 200); do [ -s "$tmp/bin/hung-child.pid" ] && break; sleep 0.05; done
[ -s "$tmp/bin/hung-child.pid" ] || { echo 'fixture runner did not start hanging child' >&2; kill "$runner_pid" 2>/dev/null || true; exit 1; }
child_pid=$(cat "$tmp/bin/hung-child.pid")
kill -TERM "$runner_pid"
wait "$runner_pid" || true
for _ in $(seq 1 40); do kill -0 "$child_pid" 2>/dev/null || break; sleep 0.05; done
if kill -0 "$child_pid" 2>/dev/null && [ "$(ps -o stat= -p "$child_pid" | tr -d ' ')" != Z ]; then
  echo 'fixture descendant survived runner SIGTERM' >&2; exit 1
fi
if python3 "$root/bench/kalari-arm/runner.py" --tools "$tmp/bin" --opencode "$tmp/bin/opencode" --api-host 127.0.0.1 --result "$tmp/live" 2>/dev/null; then
  echo 'live execution unexpectedly enabled' >&2; exit 1
fi
echo 'offline Kalari arm fixture passed'
