#!/usr/bin/env bash
# Run one reference-arm session of one condition and one upgrade.
# Usage: bench/harness/run.sh --condition 1|2|3|6 --upgrade payouts|settlements
# The inference key is read from the keyring and passed on SSH stdin.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

COND=""
UPGRADE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --condition) COND=${2:?}; shift 2 ;;
    --upgrade) UPGRADE=${2:?}; shift 2 ;;
    *) echo "usage: bench/harness/run.sh --condition 1|2|3|6 --upgrade payouts|settlements" >&2; exit 2 ;;
  esac
done
case "$COND" in
  1|2|3|6) ;;
  *) echo "condition must be 1, 2, 3, or 6" >&2; exit 2 ;;
esac
case "$UPGRADE" in
  payouts|settlements) ;;
  *) echo "upgrade must be payouts or settlements" >&2; exit 2 ;;
esac

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

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; unset VULTR_INFERENCE_API_KEY' EXIT
fetch_usage > "$tmp/usage-before.json"
echo "status=usage_before" >&2

ssh -o BatchMode=yes kalari 'rm -rf ~/kalari-harness/stage && mkdir -p ~/kalari-harness/stage ~/kalari-harness/runs'
rsync -a bench/harness/remote.sh bench/harness/measures.py bench/harness/grade_runner.py \
  bench/harness/continuation.py bench/harness/continuation.sh bench/harness/condition1.sh \
  bench/harness/grade_one.sh bench/harness/tree_digest.py bench/harness/grade_status.py \
  bench/harness/retry_journal.py \
  kalari:kalari-harness/stage/
rsync -a bench/prompts bench/workspaces kalari:kalari-harness/stage/
rsync -a bench/reference-paging/repo/opencode.jsonc kalari:kalari-harness/stage/opencode.jsonc
ssh -o BatchMode=yes kalari 'chmod +x ~/kalari-harness/stage/remote.sh'

echo "status=remote" >&2
set +e
printf '%s\n' "$VULTR_INFERENCE_API_KEY" | ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=80 \
  kalari 'bash ~/kalari-harness/stage/remote.sh --condition '"$COND"' --upgrade '"$UPGRADE" \
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
# Keep only the run id on stdout. Anything else stays off the result.
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

scp -o BatchMode=yes "kalari:kalari-harness/runs/$run_id/analysis.json" "$tmp/analysis.json"
scp -o BatchMode=yes "kalari:kalari-harness/runs/$run_id/final.jsonl" "$tmp/final.jsonl" 2>/dev/null || true
scp -o BatchMode=yes "kalari:kalari-harness/runs/$run_id/first.jsonl" "$tmp/first.jsonl" 2>/dev/null || true
fetch_usage > "$tmp/usage-after.json"

python3 - "$tmp" "$COND" "$UPGRADE" "bench/harness/results/c${COND}-${UPGRADE}.json" << 'PY'
import json, os, re, sys
tmp, cond, upgrade, dest = sys.argv[1:5]
key = os.environ.get("VULTR_INFERENCE_API_KEY", "")
sys.path.insert(0, os.path.join(os.getcwd(), "bench", "harness"))
import result_grade
import result_measures
analysis = json.load(open(os.path.join(tmp, "analysis.json")))

# Condition 1 settlements is only evidence if the session really continued.
# A remote.sh regression that drops the expected id must not write a row.
result_grade.require_condition1_identity(cond, upgrade, analysis)

def rows(path):
    doc = json.load(open(path))
    return {row["model"]: row for row in doc["usage"]["current_month"]["chat_usage"]}

before = rows(os.path.join(tmp, "usage-before.json"))
after = rows(os.path.join(tmp, "usage-after.json"))
models = sorted(set(before) | set(after))
deltas = []
for model in models:
    b, a = before.get(model, {}), after.get(model, {})
    deltas.append({
        "model": model,
        "input": int(a.get("input_tokens") or 0) - int(b.get("input_tokens") or 0),
        "output": int(a.get("output_tokens") or 0) - int(b.get("output_tokens") or 0),
    })
deep = next((d for d in deltas if d["model"] == "deepseek-v4.1-flash-1017"), {"input": 0, "output": 0})
# List price, cached input counted as input. No cache discount.
# dev-diary/research/vultr-inference.md: DeepSeek V4.1 Flash $0.15 / $0.60 per 1M.
cost = deep["input"] * 0.15 / 1_000_000 + deep["output"] * 0.60 / 1_000_000

grading = analysis.get("grading") or {}
final = result_grade.apply_meta(
    result_grade.grade(upgrade, os.path.join(tmp, "final.jsonl")), grading.get("final")
)
first_path = os.path.join(tmp, "first.jsonl")
first_meta = grading.get("first")
first = (
    result_grade.apply_meta(result_grade.grade(upgrade, first_path), first_meta)
    if (os.path.exists(first_path) or first_meta)
    else None
)
found = bool((analysis.get("first_v2") or {}).get("found"))
if not found:
    right = False
    right_basis = "no consumer run against v2"
elif first and first.get("verdict") == "PASS":
    right = True
    right_basis = (analysis.get("first_v2") or {}).get("basis") or "graded"
else:
    right = False
    right_basis = (analysis.get("first_v2") or {}).get("basis") or "graded"

lost = final.get("missing")
duplicated = final.get("duplicates")

measures, http_retries = result_measures.build(
    analysis,
    verdict=final.get("verdict"),
    right_first_time=right,
    tokens_input=deep["input"],
    tokens_output=deep["output"],
    records_lost=lost,
    records_duplicated=duplicated,
)
result = {
    "condition": int(cond),
    "upgrade": upgrade,
    "arm": "reference",
    "setup": "OpenCode 2.2.5 with microsandbox-mcp, no Kalari tools",
    "api_base": "the VM's public address",
    "live_port": analysis.get("live_port"),
    "grading_port": analysis.get("grading_port"),
    "prompt": analysis.get("prompt"),
    "opencode_version": analysis.get("opencode_version"),
    "session_continued": analysis.get("session_continued"),
    "session_id": analysis.get("session_id"),
    "resumed_session_id": analysis.get("resumed_session_id"),
    "session_id_expected": analysis.get("session_id_expected"),
    "session_identity_ok": analysis.get("session_identity_ok"),
    "workspace": analysis.get("workspace"),
    "workspace_digest": analysis.get("workspace_digest"),
    "workspace_identity_ok": analysis.get("workspace_identity_ok"),
    **result_grade.condition1_evidence(analysis),
    "notes_attached": analysis.get("notes_attached"),
    "session_cap_s": 1200,
    "session_capped": analysis.get("session_capped"),
    "consumer_exit": final.get("consumer_exit"),
    "output_present": final.get("output_present"),
    "grade_status": final.get("grade_status"),
    "measures": measures,
    "sandbox_runs_against_v1": analysis.get("sandbox_runs_against_v1"),
    "sandbox_runs_against_v2": analysis.get("sandbox_runs_against_v2"),
    "http_retries": http_retries,
    "retry_measure": analysis.get("retry_measure"),
    "records_extra": final.get("extra"),
    "records_mismatched": final.get("mismatched"),
    "grade": final,
    "first_v2_grade": first,
    "grading": result_grade.grading_evidence(grading),
    "right_first_time_basis": right_basis,
    "cost_usd": round(cost, 6),
    "cost_note": "DeepSeek V4.1 Flash list price, cached input counted as input, no cache discount",
    "usage_delta": deltas,
    "opencode_tokens": analysis.get("opencode_tokens"),
    "consumer_runs": analysis.get("consumer_runs"),
    "event_summary": analysis.get("event_summary"),
    "grader_runs": analysis.get("grader_runs"),
    "cleanup": analysis.get("cleanup"),
    "process_elapsed_s": analysis.get("process_elapsed_s"),
    "opencode_exit": analysis.get("opencode_exit"),
}
text = json.dumps(result, indent=2)
if key:
    text = text.replace(key, "[redacted]")
text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "the VM's public address", text)
text = re.sub(r"/home/[^/\s\"']+", "~", text)
if key and key in text:
    sys.exit("refusing to write a result that still contains the key")
os.makedirs(os.path.dirname(dest), exist_ok=True)
with open(dest, "w") as f:
    f.write(text)
    f.write("\n")
print(json.dumps({
    "result": dest,
    "verdict": result["measures"]["verdict"],
    "right_first_time": right,
    "sandbox_runs": result["measures"]["sandbox_runs"],
    "http_retries_agent": http_retries["agent"],
    "http_retries_grading": http_retries["grading"],
    "wall_time_s": result["measures"]["wall_time_s"],
    "time_stuck_s": result["measures"]["time_stuck_s"],
    "tokens_input": deep["input"],
    "tokens_output": deep["output"],
    "cost_usd": result["cost_usd"],
    "records_lost": lost,
    "records_duplicated": duplicated,
    "consumer_exit": result["consumer_exit"],
    "output_present": result["output_present"],
    "grade_status": result["grade_status"],
    "session_capped": result["session_capped"],
    "cleanup": result["cleanup"],
}))
PY
