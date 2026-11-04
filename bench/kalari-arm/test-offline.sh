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
if [ -e "$(dirname "$0")/UNTERMINATED" ]; then
  python3 -u - <<'PYCODE'
import json,time
print(json.dumps({'type':'step_finish','part':{'tokens':{'input':1400000,'output':0,'reasoning':0,'cache':{'read':0,'write':0}}}}),end='',flush=True)
time.sleep(300)
PYCODE
  exit
fi
if [ -e "$(dirname "$0")/MALFORMED" ]; then
  printf '%s\n' '{"type":"step_finish","part":{"tokens":{"input":"unknown"}}}'
  sleep 300
  exit
fi
if [ -e "$(dirname "$0")/SPEND" ]; then
  python3 -u - "$(dirname "$0")/cutoff-child.pid" <<'PYCODE'
import json, subprocess, sys, time
child = subprocess.Popen(['sleep', '300'])
open(sys.argv[1], 'w').write(str(child.pid))
for n in (100, 1400000):
 print(json.dumps({'type':'step_finish','part':{'tokens':{'input':n, 'output':0, 'reasoning':0,'cache':{'read':0,'write':0}}}}),flush=True)
 time.sleep(.3)
time.sleep(300)
PYCODE
  exit
fi
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
# Preflight refuses to start a live session without the required search tool.
if python3 "$root/bench/kalari-arm/runner.py" --live --tools "$tmp/bin" --opencode "$tmp/bin/opencode" --api-host 127.0.0.1 --result "$tmp/missing-rg" </dev/null 2>"$tmp/preflight.err"; then
  echo 'live preflight accepted missing rg' >&2; exit 1
fi
grep -q 'needs executable rg' "$tmp/preflight.err"

# A completed step over the soft cutoff stops the process group and is reported.
touch "$tmp/bin/SPEND"
python3 "$root/bench/kalari-arm/runner.py" --offline-fixture --tools "$tmp/bin" --opencode "$tmp/bin/opencode" --api-host 127.0.0.1 --result "$tmp/cutoff" >/dev/null
python3 - "$tmp" <<'PYCODE'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); m=json.loads((p/'cutoff/measures.json').read_text())
assert m['cutoff_reason']=='spend_cutoff' and m['completed_steps']==2
assert m['estimated_step_cost_usd'] >= .20
PYCODE
cutoff_child=$(cat "$tmp/bin/cutoff-child.pid")
if kill -0 "$cutoff_child" 2>/dev/null && [ "$(ps -o stat= -p "$cutoff_child" | tr -d ' ')" != Z ]; then
 echo 'cutoff left a descendant alive' >&2; exit 1
fi
rm "$tmp/bin/SPEND"
# Silent process hits watchdog, not the spending cutoff.
python3 "$root/bench/kalari-arm/runner.py" --offline-fixture --tools "$tmp/bin" --opencode "$tmp/bin/opencode" --api-host 127.0.0.1 --result "$tmp/watchdog" --timeout 1 >/dev/null
python3 - "$tmp/watchdog/measures.json" <<'PYCODE'
import json,sys
m=json.load(open(sys.argv[1])); assert m['cutoff_reason']=='watchdog' and m['timed_out']
PYCODE

rm "$tmp/bin/HANG"
touch "$tmp/bin/MALFORMED"
python3 "$root/bench/kalari-arm/runner.py" --offline-fixture --tools "$tmp/bin" --opencode "$tmp/bin/opencode" --api-host 127.0.0.1 --result "$tmp/malformed" >/dev/null
python3 - "$tmp/malformed/measures.json" <<'PYCODE'
import json,sys
assert json.load(open(sys.argv[1]))['cutoff_reason']=='invalid_telemetry'
PYCODE

rm "$tmp/bin/MALFORMED"
touch "$tmp/bin/UNTERMINATED"
python3 "$root/bench/kalari-arm/runner.py" --offline-fixture --tools "$tmp/bin" --opencode "$tmp/bin/opencode" --api-host 127.0.0.1 --result "$tmp/unterminated" --timeout 5 >/dev/null
python3 - "$tmp/unterminated/measures.json" <<'PYCODE'
import json,sys
m=json.load(open(sys.argv[1])); assert m['cutoff_reason']=='spend_cutoff' and m['completed_steps']==1 and m['estimated_step_cost_usd'] >= .20
PYCODE
