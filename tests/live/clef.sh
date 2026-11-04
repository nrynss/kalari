#!/usr/bin/env bash
# Live Clef check for the payouts no_dedupe failure. Not part of the gate.
# Needs VULTR_INFERENCE_API_KEY, or the vultr-inference keyring entry.
# Run after `lake build`. The key is never printed.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ -z "${VULTR_INFERENCE_API_KEY:-}" ]]; then
  VULTR_INFERENCE_API_KEY=$(secret-tool lookup service vultr-inference account kalari)
  export VULTR_INFERENCE_API_KEY
fi
if [[ -z "${VULTR_INFERENCE_API_KEY:-}" ]]; then
  echo "VULTR_INFERENCE_API_KEY is not set" >&2
  exit 1
fi

if [[ ! -f .lake/build/lib/lean/Kalari/Clef.olean ]]; then
  echo "missing Kalari.Clef olean; run lake build before this live test" >&2
  exit 1
fi

work=$(mktemp -d)
lean_file="${work}/KalariClefLive.lean"
server_pid=""

say() {
  python3 -c 'import os,sys
k=os.environ.get("VULTR_INFERENCE_API_KEY","")
t=sys.stdin.read()
sys.stdout.write(t.replace(k,"<redacted>") if k else t)' <<<"$*"
}

say_file() {
  python3 -c 'import os,sys
k=os.environ.get("VULTR_INFERENCE_API_KEY","")
t=open(sys.argv[1], errors="replace").read()
if k:
    t=t.replace(k,"<redacted>")
if t and not t.endswith("\n"):
    t += "\n"
sys.stdout.write(t)' "$1"
}

redact_ips() {
  sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g'
}

cleanup() {
  local st=$?
  trap - EXIT
  if [[ -n "${server_pid}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
  exit "$st"
}
trap cleanup EXIT

usage_snapshot() {
  local dest=$1
  local code
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$VULTR_INFERENCE_API_KEY" \
    | curl -sS --max-time 30 --config - -o "$dest" -w '%{http_code}' \
      https://api.vultrinference.com/v1/usage) || {
    echo "usage request failed" >&2
    return 1
  }
  if [[ "$code" != "200" ]]; then
    echo "usage http ${code}" >&2
    say_file "$dest" >&2
    return 1
  fi
}

# Local grader run. Free. Same shape as bench/tests/quirks.sh for no_dedupe.
pp=$((21000 + RANDOM % 9000))
timeout 120 python3 -I bench/apis/payouts/server.py --bind 127.0.0.1 --port "$pp" --v1 off \
  >"$work/server.log" 2>&1 &
server_pid=$!
ready=0
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:${pp}/v2/payouts?limit=1" >/dev/null; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" != 1 ]]; then
  echo "payouts server did not start" >&2
  redact_ips <"$work/server.log" >&2 || true
  exit 1
fi

out="${work}/no_dedupe.jsonl"
cons_rc=0
timeout 30 python3 -I bench/apis/payouts/reference/no_dedupe.py \
  --base-url "http://127.0.0.1:${pp}" --out "$out" >"$work/consumer.out" 2>"$work/consumer.err" || cons_rc=$?
kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""
if [[ "$cons_rc" != 0 ]]; then
  echo "no_dedupe exited ${cons_rc}" >&2
  say_file "$work/consumer.out" >&2 || true
  say_file "$work/consumer.err" >&2 || true
  exit 1
fi

grade_rc=0
python3 -I bench/graders/grade.py payouts "$out" >"$work/grade.out" || grade_rc=$?
python3 - "$work/grade.out" "$work/run.json" <<'PY'
import json, sys
text = open(sys.argv[1]).read().strip()
v = json.loads(text)
open(sys.argv[2], "w").write(json.dumps(v))
if v.get("verdict") != "FAIL" or v.get("duplicates") != 24:
    sys.stderr.write("grader was not FAIL with duplicates 24\n")
    sys.exit(1)
PY

say "local no_dedupe"
say_file "$work/consumer.out"
say "grader_exit=${grade_rc}"
say "grader_json=$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text())' "$work/run.json")"

code_src="bench/apis/payouts/reference/no_dedupe.py"
cp "$code_src" "$work/code.py"
line_no=$(grep -n '/v2/payouts' "$code_src" | head -1 | cut -d: -f1)
hit_line=$(sed -n "${line_no}p" "$code_src")
printf '%s:%s:%s' "$code_src" "$line_no" "$hit_line" >"$work/hit.txt"
printf '%s' "The next window starts at the previous window's last payout, and the docs say to deduplicate on id." >"$work/change.txt"
printf '%s' "Deduplicate on id." >"$work/lesson.txt"
say "change"
say_file "$work/change.txt"
say "call_site"
say_file "$work/hit.txt"
say "lesson"
say_file "$work/lesson.txt"
say "code ${code_src}"
say_file "$work/code.py"

cat >"$lean_file" <<'LEAN'
import Kalari.Clef
import Lean.Data.Json

open Kalari.Backend

def wait (ms : Nat) : IO Unit := do
  IO.sleep ms.toUInt32

def showPair (p : String × Float) : String :=
  s!"{p.1}={p.2}"

def showPairs : List (String × Float) → String
  | [] => ""
  | [p] => showPair p
  | p :: ps => showPair p ++ " " ++ showPairs ps

def showAnswer (which : String) (ans : DecisionAnswer) : String :=
  match ans with
  | .label label probs confidence =>
    s!"{which} label={label} confidence={confidence} {showPairs probs}"
  | .probabilities values =>
    s!"{which} {showPairs values}"
  | .error status message =>
    s!"{which} error status={status} message={message}"

def main (args : List String) : IO UInt32 := do
  let mode : String ← match args[0]? with
    | some s => pure s
    | none => throw <| .userError "missing mode"
  let dir : String ← match args[1]? with
    | some s => pure s
    | none => throw <| .userError "missing dir"
  let root := System.FilePath.mk dir
  let change ← IO.FS.readFile (root / "change.txt")
  let code ← IO.FS.readFile (root / "code.py")
  let runText ← IO.FS.readFile (root / "run.json")
  let run ← match Lean.Json.parse runText with
    | .ok j => pure j
    | .error e => throw <| .userError s!"run json: {e}"
  let hit ← IO.FS.readFile (root / "hit.txt")
  let lesson ← IO.FS.readFile (root / "lesson.txt")
  let runner := Kalari.Clef.live "/usr/bin:/bin"
  let keyEnv := "VULTR_INFERENCE_API_KEY"
  let result ← match mode with
    | "failure" =>
      Kalari.Clef.failureCause runner wait keyEnv change run code
    | "calls" =>
      Kalari.Clef.callsChangedOperation runner wait keyEnv change [("no_dedupe_call", hit)]
    | "lesson" =>
      Kalari.Clef.lessonApplies runner wait keyEnv lesson [("b2", change)]
    | other =>
      throw <| .userError s!"unknown mode {other}"
  match result with
  | .error e => throw <| .userError e
  | .ok ans =>
    IO.println (showAnswer mode ans)
    return 0
LEAN

# Elaborate once so the timed window is the request, not the compiler.
if ! lake env lean "$lean_file" >"$work/lean-warm.out" 2>&1; then
  echo "lean elaborate failed" >&2
  say_file "$work/lean-warm.out" >&2
  exit 1
fi

run_question() {
  local mode=$1
  local dest="$work/${mode}.out"
  local err="$work/${mode}.err"
  local rc=0
  timeout 300 lake env lean --run "$lean_file" "$mode" "$work" >"$dest" 2>"$err" || rc=$?
  if [[ "$rc" != 0 ]]; then
    echo "${mode} exited ${rc}" >&2
    say_file "$dest" >&2 || true
    say_file "$err" >&2 || true
    return "$rc"
  fi
  say_file "$dest"
  if [[ -s "$err" ]]; then
    say "stderr ${mode}"
    say_file "$err"
  fi
}

usage_snapshot "$work/usage-before.json"
run_question failure
usage_snapshot "$work/usage-after.json"

# One reread when the account counter has not moved yet. Not another Clef call.
reread=0
python3 - "$work" <<'PY' || reread=$?
import json, os, sys
work = sys.argv[1]
before = json.load(open(os.path.join(work, "usage-before.json")))
after = json.load(open(os.path.join(work, "usage-after.json")))

def clef_in(doc):
    rows = doc.get("usage", {}).get("current_month", {}).get("chat_usage", [])
    for row in rows:
        if row.get("model") == "clef":
            return int(row.get("input_tokens") or 0)
    return None

b, a = clef_in(before), clef_in(after)
if b is None or a is None or a - b <= 0:
    sys.exit(3)
PY
if [[ "$reread" -eq 3 ]]; then
  sleep 3
  usage_snapshot "$work/usage-after.json"
elif [[ "$reread" -ne 0 ]]; then
  exit "$reread"
fi

python3 - "$work" <<'PY'
import json, os, sys
work = sys.argv[1]
before = json.load(open(os.path.join(work, "usage-before.json")))
after = json.load(open(os.path.join(work, "usage-after.json")))

def clef_tokens(doc):
    rows = doc.get("usage", {}).get("current_month", {}).get("chat_usage", [])
    inp = out = 0
    found = False
    for row in rows:
        if row.get("model") == "clef":
            found = True
            inp += int(row.get("input_tokens") or 0)
            out += int(row.get("output_tokens") or 0)
    return found, inp, out

bf, bi, bo = clef_tokens(before)
af, ai, ao = clef_tokens(after)
meta = {
    "before_found": bf,
    "after_found": af,
    "input_before": bi,
    "input_after": ai,
    "output_before": bo,
    "output_after": ao,
}
if bf and af:
    meta["input_delta"] = ai - bi
    meta["output_delta"] = ao - bo
else:
    meta["input_delta"] = None
    meta["output_delta"] = None
json.dump(meta, open(os.path.join(work, "usage-delta.json"), "w"))
PY

# /v1/usage has token counts, not dollars. Clef list price is $0.10 per 1M input tokens.
# If the counter did not move, estimate at 1 token per character of the inputs plus
# 2000 characters for the question envelope. That is above the client's 4 chars/token.
budget_rc=0
python3 - "$work" <<'PY' || budget_rc=$?
import json, os, sys
work = sys.argv[1]
meta = json.load(open(os.path.join(work, "usage-delta.json")))
price_per_token = 0.10 / 1_000_000
delta = meta["input_delta"]
out_delta = meta["output_delta"]
source = "usage"
if delta is None or delta <= 0:
    n = 2000
    for name in ("change.txt", "code.py", "run.json", "hit.txt", "lesson.txt"):
        n += os.path.getsize(os.path.join(work, name))
    delta = n
    source = "estimate"
    out_delta = 0
cost = delta * price_per_token
projected = cost * 3
report = {
    "source": source,
    "input_tokens": delta,
    "output_tokens": out_delta,
    "usd": cost,
    "usd_times_three": projected,
    "price_per_million_input": 0.10,
}
json.dump(report, open(os.path.join(work, "budget.json"), "w"))
print(
    f"failure_cost source={source} input_tokens={delta} output_tokens={out_delta} "
    f"usd={cost:.8f} times_three={projected:.8f}"
)
if projected > 0.01:
    sys.exit(2)
PY
if [[ "$budget_rc" -eq 2 ]]; then
  say "stopping before the other two calls: projected cost would exceed 0.01"
  exit 2
elif [[ "$budget_rc" -ne 0 ]]; then
  exit "$budget_rc"
fi

run_question calls
run_question lesson

usage_snapshot "$work/usage-final.json"
python3 - "$work" <<'PY'
import json, os, sys
work = sys.argv[1]
before = json.load(open(os.path.join(work, "usage-before.json")))
final = json.load(open(os.path.join(work, "usage-final.json")))
budget = json.load(open(os.path.join(work, "budget.json")))

def clef_in(doc):
    rows = doc.get("usage", {}).get("current_month", {}).get("chat_usage", [])
    for row in rows:
        if row.get("model") == "clef":
            return int(row.get("input_tokens") or 0), int(row.get("output_tokens") or 0)
    return None

b = clef_in(before)
f = clef_in(final)
if b is None or f is None:
    print("total_cost source=unavailable")
    sys.exit(0)
din, dout = f[0] - b[0], f[1] - b[1]
usd = din * 0.10 / 1_000_000
print(
    f"total_cost source=usage input_tokens={din} output_tokens={dout} usd={usd:.8f} "
    f"first_call_source={budget['source']}"
)
if usd > 0.01:
    sys.exit(2)
PY
