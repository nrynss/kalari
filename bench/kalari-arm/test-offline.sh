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
python3 - <<'PY'
import json, os
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
export MSB_LOG="$tmp/msb.log"
python3 "$root/bench/kalari-arm/runner.py" --offline-fixture --tools "$tmp/bin" --opencode "$tmp/bin/opencode" --api-host 127.0.0.1 --result "$tmp/result" >/dev/null
python3 - "$tmp" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); events=(p/'result/transcript.jsonl').read_text(); m=json.loads((p/'result/measures.json').read_text())
assert 'offline-fixture-invalid-key' not in events and '127.0.0.1' not in events
assert len(m['tool_calls']) == 5 and all(v == 1 for v in m['tool_calls'].values())
assert m['grade']['verdict'] == 'FAIL' and m['grader_status'] == 'EXIT 0'
assert (p/'msb.log').read_text().splitlines() == ['create','remove']
PY
if python3 "$root/bench/kalari-arm/runner.py" --tools "$tmp/bin" --opencode "$tmp/bin/opencode" --api-host 127.0.0.1 --result "$tmp/live" 2>/dev/null; then
  echo 'live execution unexpectedly enabled' >&2; exit 1
fi
echo 'offline Kalari arm fixture passed'
