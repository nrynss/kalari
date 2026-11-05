#!/usr/bin/env bash
# Run one Kalari-arm showcase session on the benchmark VM and collect
# its result under bench/showcase/disbursements/runs/kalari/.
# An adapted copy of bench/runs/kalari/_harness/run-kalari.sh: the suite is fixed to
# disbursements, the stage is ~/kalari-showcase, and the frozen harness helpers are staged
# unchanged alongside the adapted copies. The inference key comes from the keyring and
# crosses SSH on stdin.
# Usage: bench/showcase/disbursements/_harness/run-kalari.sh --repeat N [--timeout S]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
umask 022

REPEAT=""
TIMEOUT=600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeat) REPEAT=${2:?}; shift 2 ;;
    --timeout) TIMEOUT=${2:?}; shift 2 ;;
    *) echo "usage: run-kalari.sh --repeat N [--timeout S]" >&2; exit 2 ;;
  esac
done
case "$REPEAT" in 1|2|3|4|5) ;; *) echo "repeat must be 1..5" >&2; exit 2 ;; esac

if [[ ${VULTR_INFERENCE_API_KEY:-} && ${#VULTR_INFERENCE_API_KEY} -ge 8 ]]; then
  :
else
  VULTR_INFERENCE_API_KEY=$(secret-tool lookup service vultr-inference account kalari || true)
  export VULTR_INFERENCE_API_KEY
fi
if [[ ${#VULTR_INFERENCE_API_KEY} -lt 8 ]]; then
  echo "no inference key in the environment or the keyring" >&2
  exit 1
fi

DEST=bench/showcase/disbursements/runs/kalari/r${REPEAT}.json
if [[ -e "$DEST" ]]; then
  echo "refusing to overwrite $DEST" >&2
  exit 1
fi

echo "status=verify_frozen" >&2
bash bench/runs/kalari/_harness/verify-frozen.sh >&2

echo "status=exclusion" >&2
if ssh -o BatchMode=yes -o ConnectTimeout=10 kalari 'ps -eo args | grep -E "[o]pencode run|[r]emote\.sh|[r]emote-kalari\.sh|[r]emote-reference\.sh" | grep -q .'; then
  echo "another benchmark session is active on the VM; refusing to start" >&2
  exit 3
fi

echo "status=stage" >&2
ssh -o BatchMode=yes kalari 'mkdir -p ~/kalari-showcase/bin ~/kalari-showcase/stage ~/kalari-showcase/runs ~/kalari-showcase/stores ~/kalari-showcase/stage/bench/prompts'
rsync -a --exclude runs bench/showcase/disbursements/ kalari:kalari-showcase/stage/bench/showcase/disbursements/
rsync -a bench/prompts/upgrade.txt kalari:kalari-showcase/stage/bench/prompts/
# The frozen helpers are staged unchanged next to the adapted copies in the showcase _harness.
rsync -a bench/runs/kalari/_harness/prepare.py bench/runs/kalari/_harness/summarize.py \
  bench/runs/kalari/_harness/bootstrap_proxy.py bench/runs/kalari/_harness/grade.sh \
  bench/runs/kalari/_harness/grade_runner.py bench/runs/kalari/_harness/to_result.py \
  kalari:kalari-showcase/stage/bench/showcase/disbursements/_harness/
scp -q .lake/build/bin/kalari .lake/build/bin/kalari-aashaan kalari:kalari-showcase/bin/
ssh -o BatchMode=yes kalari 'chmod +x ~/kalari-showcase/stage/bench/showcase/disbursements/_harness/remote-kalari.sh ~/kalari-showcase/bin/kalari ~/kalari-showcase/bin/kalari-aashaan
  for b in lambo vimanam rg; do [ -x ~/kalari-showcase/bin/$b ] || cp ~/kalari-t54/bin/$b ~/kalari-showcase/bin/$b; done
  [ -e ~/kalari-showcase/bin/msb ] || ln -s ~/.local/bin/msb ~/kalari-showcase/bin/msb
  ~/kalari-showcase/bin/kalari --version; ~/kalari-showcase/bin/vimanam --version; ~/kalari-showcase/bin/lambo --version'

echo "status=remote" >&2
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; unset VULTR_INFERENCE_API_KEY' EXIT
set +e
printf '%s\n' "$VULTR_INFERENCE_API_KEY" | ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=80 \
  kalari 'bash ~/kalari-showcase/stage/bench/showcase/disbursements/_harness/remote-kalari.sh --repeat '"$REPEAT"' --timeout '"$TIMEOUT" \
  > "$tmp/remote.out" 2> "$tmp/remote.err"
remote_rc=$?
set -e
echo "status=remote_exit:$remote_rc" >&2
python3 - "$tmp/remote.err" "$tmp/remote.out" << 'PY'
import os, re, sys
key = os.environ.get("VULTR_INFERENCE_API_KEY", "")
err_path, out_path = sys.argv[1], sys.argv[2]
err = open(err_path, errors="replace").read()
out = open(out_path, errors="replace").read()
def clean(text):
    if key:
        text = text.replace(key, "[redacted]")
    text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "the VM's public address", text)
    text = re.sub(r"/home/[^/\s\"']+", "~", text)
    return text
sys.stderr.write(clean(err))
kept = [line for line in clean(out).splitlines() if line.startswith("KALARI_RUN ")]
open(out_path, "w").write("\n".join(kept) + ("\n" if kept else ""))
PY

run_id=$(awk '/^KALARI_RUN / {print $2}' "$tmp/remote.out" | tail -1)
if [[ -z "$run_id" ]]; then
  echo "no run id from the VM" >&2
  exit 1
fi
case "$run_id" in
  *[!a-zA-Z0-9]*) echo "bad run id" >&2; exit 1 ;;
esac

mkdir -p "$tmp/got"
scp -o BatchMode=yes -r "kalari:kalari-showcase/runs/$run_id/result" "$tmp/got/result"
scp -o BatchMode=yes "kalari:kalari-showcase/runs/$run_id/cleanup.json" "$tmp/got/cleanup.json" 2>/dev/null || true

python3 bench/runs/kalari/_harness/to_result.py --run-dir "$tmp/got/result" --meta "$tmp/got/result/meta.json" > "$tmp/final.json"
python3 - "$tmp/final.json" "$DEST" << 'PY'
import json, re, sys
key = None
try:
    import subprocess
    key = subprocess.run(["secret-tool", "lookup", "service", "vultr-inference", "account", "kalari"],
                         capture_output=True, text=True).stdout.strip()
except Exception:
    pass
text = open(sys.argv[1]).read()
doc = json.loads(text)
text = json.dumps(doc, indent=2)
if key and len(key) >= 8 and key in text:
    sys.exit("refusing to write a result that still contains the key")
text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "the VM's public address", text)
text = re.sub(r"/home/[^/\s\"']+", "~", text)
open(sys.argv[2], "w").write(text + "\n")
print(json.dumps({"result": sys.argv[2], "verdict": doc["measures"]["verdict"],
                  "right_first_time": doc["measures"]["right_first_time"],
                  "sandbox_runs": doc["measures"]["sandbox_runs"],
                  "wall_time_s": doc["measures"]["wall_time_s"],
                  "tokens_in": doc["measures"]["tokens_input"],
                  "tokens_out": doc["measures"]["tokens_output"],
                  "cost_usd": doc.get("cost_usd"),
                  "records_lost": doc.get("records_lost"),
                  "records_duplicated": doc.get("records_duplicated"),
                  "records_mismatched": doc.get("records_mismatched"),
                  "lessons": len(doc.get("lessons_published") or [])}))
PY
cp "$tmp/got/result/transcript.jsonl" "bench/showcase/disbursements/runs/kalari/r${REPEAT}.transcript.jsonl"
chmod 600 "bench/showcase/disbursements/runs/kalari/r${REPEAT}.transcript.jsonl"
