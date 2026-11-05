#!/usr/bin/env bash
# Run one reference-arm showcase session on the benchmark VM and collect its result under
# bench/showcase/disbursements/runs/reference/. A lean adaptation of bench/harness/run.sh:
# one fresh session per run, no condition machinery, no retry journals, and the result is
# assembled on the laptop from the VM's analysis.json plus the Vultr usage delta.
# Usage: bench/showcase/disbursements/_harness/run-reference.sh --repeat N
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
umask 022

REPEAT=""
MODEL=""
LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeat) REPEAT=${2:?}; shift 2 ;;
    --model) MODEL=${2:?}; shift 2 ;;
    --label) LABEL=${2:?}; shift 2 ;;
    *) echo "usage: run-reference.sh --repeat N --model M --label L" >&2; exit 2 ;;
  esac
done
case "$REPEAT" in 1|2|3|4|5) ;; *) echo "repeat must be 1..5" >&2; exit 2 ;; esac
if [[ -z "$MODEL" || -z "$LABEL" ]]; then
  echo "--model and --label are required" >&2; exit 2
fi
export MODEL
case "$LABEL" in *[!a-zA-Z0-9._-]*) echo "bad label" >&2; exit 2 ;; esac

if [[ -z ${VULTR_INFERENCE_API_KEY:-} || ${#VULTR_INFERENCE_API_KEY} -lt 8 ]]; then
  VULTR_INFERENCE_API_KEY=$(secret-tool lookup service vultr-inference account kalari || true)
  export VULTR_INFERENCE_API_KEY
fi
if [[ ${#VULTR_INFERENCE_API_KEY} -lt 8 ]]; then
  echo "no inference key in the environment or the keyring" >&2
  exit 1
fi

fetch_usage() {
  python3 - << 'PY'
import json, os, sys, urllib.request
key = os.environ["VULTR_INFERENCE_API_KEY"]
req = urllib.request.Request(
    "https://api.vultrinference.com/v1/usage",
    headers={"Authorization": "Bearer " + key},
)
with urllib.request.urlopen(req, timeout=60) as r:
    json.dump(json.load(r), sys.stdout)
PY
}

DEST=bench/showcase/disbursements/runs/reference/${LABEL}.json
if [[ -e "$DEST" ]]; then
  echo "refusing to overwrite $DEST" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; unset VULTR_INFERENCE_API_KEY' EXIT
mkdir -p bench/showcase/disbursements/runs/reference
fetch_usage > "$tmp/usage-before.json"
echo "status=usage_before" >&2

ssh -o BatchMode=yes -o ConnectTimeout=10 kalari 'rm -rf ~/kalari-showcase-ref/stage && mkdir -p ~/kalari-showcase-ref/stage/workspaces ~/kalari-showcase-ref/stage/prompts ~/kalari-showcase-ref/stage/grader ~/kalari-showcase-ref/runs'
rsync -a bench/showcase/disbursements/_harness/remote-reference.sh kalari:kalari-showcase-ref/stage/
rsync -a bench/harness/grade_runner.py kalari:kalari-showcase-ref/stage/
rsync -a bench/showcase/disbursements/workspace/disbursement-sync kalari:kalari-showcase-ref/stage/workspaces/
rsync -a bench/prompts/upgrade.txt kalari:kalari-showcase-ref/stage/prompts/
rsync -a bench/showcase/disbursements/grader/grade.py bench/showcase/disbursements/data.py kalari:kalari-showcase-ref/stage/grader/
# The per-model OpenCode config is generated from the frozen reference config with the
# model swapped; the reference setup itself is unchanged.
MODEL="$MODEL" python3 - << 'PY'
import os
model = os.environ["MODEL"]
src = open("bench/reference-paging/repo/opencode.jsonc").read()
# The bare id appears twice: as the provider models key and in "vultr/<id>".
src = src.replace("deepseek-v4.1-flash-1017", model)
src = src.replace('"name": "DeepSeek V4.1 Flash"', '"name": "%s"' % model)
open("/tmp/opencode-showcase.jsonc", "w").write(src)
PY
rsync -a /tmp/opencode-showcase.jsonc kalari:kalari-showcase-ref/stage/opencode.jsonc
rm -f /tmp/opencode-showcase.jsonc
ssh -o BatchMode=yes kalari 'chmod +x ~/kalari-showcase-ref/stage/remote-reference.sh'

echo "status=remote" >&2
set +e
printf '%s\n' "$VULTR_INFERENCE_API_KEY" | ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=80 \
  kalari 'bash ~/kalari-showcase-ref/stage/remote-reference.sh --repeat '"$REPEAT" \
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

scp -o BatchMode=yes "kalari:kalari-showcase-ref/runs/$run_id/analysis.json" "$tmp/analysis.json"
scp -o BatchMode=yes "kalari:kalari-showcase-ref/runs/$run_id/events.jsonl" "$tmp/events.jsonl"
scp -o BatchMode=yes "kalari:kalari-showcase-ref/runs/$run_id/final.jsonl" "$tmp/final.jsonl" 2>/dev/null || true
fetch_usage > "$tmp/usage-after.json"

python3 - "$tmp" "$DEST" "bench/showcase/disbursements/runs/reference/${LABEL}.transcript.jsonl" << 'PY'
import json, os, re, sys
tmp, dest, transcript_dest = sys.argv[1:4]
key = os.environ.get("VULTR_INFERENCE_API_KEY", "")
analysis = json.load(open(os.path.join(tmp, "analysis.json")))

def rows(path):
    doc = json.load(open(path))
    return {row["model"]: row for row in doc["usage"]["current_month"]["chat_usage"]}

before = rows(os.path.join(tmp, "usage-before.json"))
after = rows(os.path.join(tmp, "usage-after.json"))
deltas = []
for model in sorted(set(before) | set(after)):
    b, a = before.get(model, {}), after.get(model, {})
    deltas.append({
        "model": model,
        "input": int(a.get("input_tokens") or 0) - int(b.get("input_tokens") or 0),
        "output": int(a.get("output_tokens") or 0) - int(b.get("output_tokens") or 0),
    })
deep = next((d for d in deltas if d["model"] == os.environ["MODEL"]), {"input": 0, "output": 0})
# List prices per million tokens (cached input counted as input, no cache discount).
PRICES = {"mimo-v2.6-flash": (0.10, 0.25), "qwen3.8-27b": (0.15, 1.00), "glm-5.3-flash": (0.10, 0.35),
          "muse-glimmer-30b": (0.25, 1.00), "qwen3.8-flash-next": (0.10, 0.20), "deepseek-v4.1-flash-1017": (0.15, 0.60)}
pin, pout = PRICES.get(os.environ["MODEL"], (None, None))
cost = pin * deep["input"] / 1_000_000 + pout * deep["output"] / 1_000_000 if pin is not None else None

grade = analysis.get("grade") or {}
analysis["model"] = os.environ["MODEL"]
analysis["usage_delta"] = deltas
analysis["cost_usd"] = round(cost, 6)
analysis["cost_note"] = "List price for the session model, cached input counted as input, no cache discount; null when no price is recorded"
analysis["records_lost"] = grade.get("missing")
analysis["records_duplicated"] = grade.get("duplicates")
analysis["records_extra"] = grade.get("extra")
analysis["records_mismatched"] = grade.get("mismatched")

text = json.dumps(analysis, indent=2)
if key and len(key) >= 8 and key in text:
    sys.exit("refusing to write a result that still contains the key")
text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "the VM's public address", text)
text = re.sub(r"/home/[^/\s\"']+", "~", text)
open(dest, "w").write(text + "\n")

# The session transcript, sanitized: the key never appears in OpenCode events, but the
# public address can (tool outputs), so it is replaced here.
tr = open(os.path.join(tmp, "events.jsonl"), errors="replace").read()
if key:
    tr = tr.replace(key, "[redacted]")
tr = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "the VM's public address", tr)
tr = re.sub(r"/home/[^/\s\"']+", "~", tr)
open(transcript_dest, "w").write(tr)
os.chmod(transcript_dest, 0o600)
print(json.dumps({"result": dest, "verdict": grade.get("verdict"),
                  "wall_time_s": analysis.get("wall_time_s"),
                  "cost_usd": analysis.get("cost_usd"),
                  "records_lost": analysis.get("records_lost"),
                  "records_duplicated": analysis.get("records_duplicated"),
                  "records_mismatched": analysis.get("records_mismatched")}))
PY
