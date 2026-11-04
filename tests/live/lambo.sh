#!/usr/bin/env bash
# Live Lambo check: fresh store, payouts lesson, three citing runs, Solo promotion.
# Not part of the gate. Needs VULTR_INFERENCE_API_KEY, or the vultr-inference
# keyring entry, and network to fetch the Lambo 0.9.0 release. Run after `lake build`.
# The key is never printed. The temp Lean file, the release binary, and the store
# are deleted on exit.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ -z "${VULTR_INFERENCE_API_KEY:-}" ]]; then
  VULTR_INFERENCE_API_KEY=$(secret-tool lookup service vultr-inference account kalari || true)
  export VULTR_INFERENCE_API_KEY
fi
if [[ -z "${VULTR_INFERENCE_API_KEY:-}" ]]; then
  echo "VULTR_INFERENCE_API_KEY is not set" >&2
  exit 1
fi

if [[ ! -f .lake/build/lib/lean/Kalari/Lambo.olean ]]; then
  echo "missing Kalari.Lambo olean; run lake build before this live test" >&2
  exit 1
fi

work=$(mktemp -d)
chmod 700 "$work"
lean_file="${work}/KalariLamboLive.lean"
toml="${work}/lambo.toml"
store="${work}/store.db"
lean_pid=""

say() {
  python3 -I -c 'import os, re, sys
k=os.environ.get("VULTR_INFERENCE_API_KEY","")
home=os.environ.get("HOME","")
t=sys.stdin.read()
if k:
    t=t.replace(k,"<redacted>")
if home:
    t=t.replace(home,"<home>")
t=re.sub(r"\d{4}-\d{2}-\d{2}(?:[T ][0-9:.+Z-]*)?", "<time>", t)
t=re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<ip>", t)
sys.stdout.write(t)' <<<"$*"
}

say_file() {
  python3 -I -c 'import os, re, sys
k=os.environ.get("VULTR_INFERENCE_API_KEY","")
home=os.environ.get("HOME","")
t=open(sys.argv[1], errors="replace").read()
if k:
    t=t.replace(k,"<redacted>")
if home:
    t=t.replace(home,"<home>")
t=re.sub(r"\d{4}-\d{2}-\d{2}(?:[T ][0-9:.+Z-]*)?", "<time>", t)
t=re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<ip>", t)
if t and not t.endswith("\n"):
    t += "\n"
sys.stdout.write(t)' "$1"
}

lambo_pids() {
  ps -eo pid,comm,args | awk -v cfg="$toml" '$2 == "lambo" && index($0, cfg) { print $1 }'
}

cleanup() {
  local st=$?
  trap - EXIT
  if [[ -n "${lean_pid}" ]] && kill -0 "$lean_pid" 2>/dev/null; then
    kill "$lean_pid" 2>/dev/null || true
    wait "$lean_pid" 2>/dev/null || true
  fi
  if [[ -n "${toml}" ]]; then
    local pids
    pids=$(lambo_pids || true)
    if [[ -n "${pids}" ]]; then
      kill ${pids} 2>/dev/null || true
      sleep 0.5
      pids=$(lambo_pids || true)
      if [[ -n "${pids}" ]]; then
        kill -9 ${pids} 2>/dev/null || true
      fi
    fi
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

# Published with the v0.9.0 release asset lambo-0.9.0-linux-x86_64.sha256.
# A mismatch stops the run. PATH's lambo is not used.
lambo_sha256=21f334dc4752625970ba1a4cf9760c7b901b7975ddf19f5ee024747678e7b0bd
lambo_url=https://github.com/nrynss/lambo/releases/download/v0.9.0/lambo-0.9.0-linux-x86_64
lambo_bin="${work}/lambo-0.9.0-linux-x86_64"
if ! curl -fsSL --retry 3 --retry-delay 2 -o "$lambo_bin" "$lambo_url"; then
  echo "lambo 0.9.0 download failed" >&2
  exit 1
fi
got_sha=$(sha256sum "$lambo_bin" | awk '{print $1}')
if [[ "$got_sha" != "$lambo_sha256" ]]; then
  echo "lambo 0.9.0 checksum did not match" >&2
  exit 1
fi
chmod 755 "$lambo_bin"
mkdir -p "${work}/bin"
ln -s "$lambo_bin" "${work}/bin/lambo"
export PATH="${work}/bin:${PATH}"
lambo_version=$(lambo --version)
if [[ "$lambo_version" != "lambo 0.9.0" ]]; then
  echo "lambo --version is ${lambo_version}, want lambo 0.9.0" >&2
  exit 1
fi
say "lambo_version=${lambo_version}"
say "lambo_sha256=ok"

cat >"$toml" <<EOF
promotion_policy = "Solo"

[store]
kind = "sqlite"
path = "${store}"

[embedder]
kind = "openai"
url = "https://api.vultrinference.com"
model = "qwen3-embedding-4b"
dim = 2560
api_key_env = "VULTR_INFERENCE_API_KEY"

[daemon]
gc_interval = 1

[serve]
default_session = "kalari"
EOF

say "config"
say_file "$toml"

if ! lambo provision --config "$toml" >"$work/provision.out" 2>"$work/provision.err"; then
  echo "lambo provision failed" >&2
  say_file "$work/provision.out" >&2 || true
  say_file "$work/provision.err" >&2 || true
  exit 1
fi
say "provision"
say_file "$work/provision.out"
if [[ -s "$work/provision.err" ]]; then
  say "provision_stderr"
  say_file "$work/provision.err"
fi

cat >"$lean_file" <<'LEAN'
import Kalari.Lambo
import Lean.Data.Json

open Lean

def lessonText : String :=
  "Stop on the end flag, never on the token's presence or a short or empty page; key records by id, and the last delivery wins. Check: exact count against v1, zero duplicate ids, every record equal to v1."

def runTexts : List String := [
  "run r-001: payouts v2 stopped on a short page and imported 100 of 2431 records; the fix that follows the end flag passed",
  "run r-002: settlements connection cited the lesson, kept the last delivery of each amended record, and passed",
  "run r-003: a later payouts export cited the lesson, followed the drained flag, keyed records by id, and passed"
]

def optStr (j : Json) (k : String) : String :=
  match j.getObjVal? k with
  | .ok v => match v.getStr? with
    | .ok s => s
    | .error _ => v.compress
  | .error _ => ""

def optCompress (j : Json) (k : String) : String :=
  match j.getObjVal? k with
  | .ok v => v.compress
  | .error _ => ""

def conceptId (outcome : Json) : Except String String := do
  let created ← (outcome.getObjVal? "created") >>= Json.getArr?
  let matched ← (outcome.getObjVal? "matched") >>= Json.getArr?
  match (created ++ matched)[0]? with
  | some id => Json.getStr? id
  | none => throw "Lambo applied write returned no concept id"

def summarize (kind : String) (outcome : Json) : String :=
  s!"write kind={kind} state={optStr outcome "state"} created={optCompress outcome "created"} matched={optCompress outcome "matched"}"

def focusLabel (j : Json) : String :=
  match j.getObjVal? "focus" with
  | .ok focus => optStr focus "label"
  | .error e => s!"no focus: {e}"

def depLabels (j : Json) : String :=
  match j.getObjVal? "focus" with
  | .error e => s!"no focus: {e}"
  | .ok focus =>
    match focus.getObjVal? "dependents" with
    | .error e => s!"no dependents: {e}"
    | .ok deps => deps.compress

def admissionLine (j : Json) : String :=
  match j.getObjVal? "admission" with
  | .error e => s!"admission_missing {e}"
  | .ok a =>
    let score := match a.getObjVal? "solo" with
      | .ok solo => optCompress solo "score"
      | .error _ => ""
    s!"status={optStr a "status"} eligible={optCompress a "eligible"} next={optStr a "next"} score={score} reasons={optCompress a "reasons"}"

def waitSignal (root : System.FilePath) : IO String := do
  for _ in List.range 600 do
    if (← (root / "stop").pathExists) then return "stop"
    if (← (root / "go").pathExists) then return "go"
    IO.sleep 200
  return "timeout"

def checkpoint (c : Kalari.Lambo.Client) (lessonId mark : String) (elapsedMs : Nat) : IO Bool := do
  let found ← Kalari.Lambo.lessons c "pagination_changed"
  IO.println s!"checkpoint {mark} elapsed_ms={elapsedMs} count={found.length}"
  let mut candidate := false
  let mut saw := false
  for lesson in found do
    let flag := lesson.label.endsWith " [Constraint, candidate]"
    if lesson.id == lessonId then saw := true
    if flag then candidate := true
    IO.println s!"lesson id={lesson.id} stale={lesson.stale} candidate={flag} label={lesson.label}"
  IO.println s!"lessons_found_id={saw}"
  let viewed ← Kalari.Lambo.inspect c lessonId
  IO.println s!"inspect {mark} {admissionLine viewed}"
  IO.println s!"inspect_label {mark} {focusLabel viewed}"
  return candidate

/-- Sleep `want` ms, but not past `cap` ms after `start`. Returns elapsed ms. -/
def sleepUpTo (start cap want : Nat) : IO Nat := do
  let now ← IO.monoMsNow
  let elapsed := now - start
  if elapsed >= cap then
    return elapsed
  let room := cap - elapsed
  let ms := if want < room then want else room
  if ms > 0 then
    IO.sleep ms.toUInt32
  let done ← IO.monoMsNow
  return done - start

def body (c : Kalari.Lambo.Client) (root : System.FilePath) : IO UInt32 := do
  let change ← Kalari.Lambo.write c "resource" "pagination_changed"
  IO.FS.writeFile (root / "change-kind.txt") (summarize "resource" change ++ "\n")
  IO.FS.writeFile (root / "change-kind.done") "ok\n"
  IO.println (summarize "resource" change)
  let signal ← waitSignal root
  match signal with
  | "stop" =>
    IO.println "stopped_after_change_kind"
    return 2
  | "timeout" =>
    IO.println "budget_signal_timeout"
    return 2
  | "go" => pure ()
  | other =>
    throw <| .userError s!"unexpected budget signal {other}"
  IO.println s!"lesson_text {lessonText}"
  let lessonOut ← Kalari.Lambo.write c "constraint" lessonText ["pagination_changed"]
  IO.println (summarize "constraint" lessonOut)
  let lessonId ← IO.ofExcept (conceptId lessonOut)
  IO.println s!"lesson_id {lessonId}"
  let mut n : Nat := 0
  for run in runTexts do
    n := n + 1
    let outcome ← Kalari.Lambo.write c "observation" run [lessonId]
    IO.println s!"citing {n} {summarize "observation" outcome}"
  let changeView ← Kalari.Lambo.inspect c "pagination_changed"
  IO.println s!"change_kind_label {focusLabel changeView}"
  IO.println s!"change_kind_dependents {depLabels changeView}"
  let early ← checkpoint c lessonId "early" 0
  if early then
    IO.println "candidate_before_age_floor"
  let start ← IO.monoMsNow
  let e1 ← sleepUpTo start 180000 75000
  let mid ← checkpoint c lessonId "age_floor" e1
  if mid then
    IO.println "promoted candidate"
    return 0
  let e2 ← sleepUpTo start 180000 70000
  let late ← checkpoint c lessonId "cycle" e2
  if late then
    IO.println "promoted candidate"
    return 0
  let e3 ← sleepUpTo start 180000 180000
  let last ← checkpoint c lessonId "cap" e3
  if last then
    IO.println "promoted candidate"
    return 0
  IO.println "promotion_not_candidate"
  return 3

def main (args : List String) : IO UInt32 := do
  let configPath ← match args[0]? with
    | some s => pure s
    | none => throw <| .userError "missing config path"
  let work ← match args[1]? with
    | some s => pure s
    | none => throw <| .userError "missing work dir"
  let client ← Kalari.Lambo.create {
    command := ["lambo", "serve"]
    config_path := configPath
  }
  let rc ←
    try
      body client (System.FilePath.mk work)
    catch e =>
      try Kalari.Lambo.shutdown client catch _ => pure ()
      throw e
  Kalari.Lambo.shutdown client
  IO.println "shutdown_returned"
  return rc
LEAN

if ! lake env lean "$lean_file" >"$work/lean-warm.out" 2>&1; then
  echo "lean elaborate failed" >&2
  say_file "$work/lean-warm.out" >&2
  exit 1
fi

usage_snapshot "$work/usage-before.json"

timeout 420 lake env lean --run "$lean_file" "$toml" "$work" >"$work/lean.out" 2>"$work/lean.err" &
lean_pid=$!

seen=0
for _ in $(seq 1 180); do
  if [[ -f "$work/change-kind.done" ]]; then
    seen=1
    break
  fi
  if ! kill -0 "$lean_pid" 2>/dev/null; then
    echo "lean exited before the change-kind write" >&2
    wait "$lean_pid" || true
    lean_pid=""
    say_file "$work/lean.out" >&2 || true
    say_file "$work/lean.err" >&2 || true
    exit 1
  fi
  sleep 1
done
if [[ "$seen" != 1 ]]; then
  echo "change-kind write did not finish" >&2
  say_file "$work/lean.out" >&2 || true
  say_file "$work/lean.err" >&2 || true
  exit 1
fi

say "change_kind"
say_file "$work/change-kind.txt"

usage_snapshot "$work/usage-after.json"
reread=0
python3 -I - "$work" <<'PY' || reread=$?
import json, os, sys
work = sys.argv[1]
before = json.load(open(os.path.join(work, "usage-before.json")))
after = json.load(open(os.path.join(work, "usage-after.json")))

def embed_in(doc):
    rows = doc.get("usage", {}).get("current_month", {}).get("chat_usage", [])
    for row in rows:
        if row.get("model") == "qwen3-embedding-4b":
            return int(row.get("input_tokens") or 0)
    return None

b, a = embed_in(before), embed_in(after)
if b is None or a is None or a - b <= 0:
    sys.exit(3)
PY
if [[ "$reread" -eq 3 ]]; then
  sleep 3
  usage_snapshot "$work/usage-after.json"
elif [[ "$reread" -ne 0 ]]; then
  exit "$reread"
fi

budget_rc=0
python3 -I - "$work" <<'PY' || budget_rc=$?
import json, os, sys
work = sys.argv[1]
before = json.load(open(os.path.join(work, "usage-before.json")))
after = json.load(open(os.path.join(work, "usage-after.json")))

def embed_tokens(doc):
    rows = doc.get("usage", {}).get("current_month", {}).get("chat_usage", [])
    for row in rows:
        if row.get("model") == "qwen3-embedding-4b":
            return True, int(row.get("input_tokens") or 0), int(row.get("output_tokens") or 0)
    return False, 0, 0

bf, bi, bo = embed_tokens(before)
af, ai, ao = embed_tokens(after)
# Lesson plus three citing runs. The change kind is already written.
remaining = 4
price = 0.05 / 1_000_000
source = "usage"
if bf and af and ai - bi > 0:
    delta = ai - bi
    out_delta = ao - bo
else:
    # Ceiling: one short concept plus a canary set, if the counter has not moved.
    delta = 4000
    out_delta = 0
    source = "estimate"
cost = delta * price
projected = cost * remaining
report = {
    "source": source,
    "model": "qwen3-embedding-4b",
    "input_before": bi if bf else None,
    "input_after": ai if af else None,
    "input_tokens": delta,
    "output_tokens": out_delta,
    "usd": cost,
    "remaining_writes": remaining,
    "usd_times_remaining": projected,
    "price_per_million_input": 0.05,
}
json.dump(report, open(os.path.join(work, "budget.json"), "w"))
print(
    f"change_kind_cost source={source} input_tokens={delta} output_tokens={out_delta} "
    f"usd={cost:.8f} times_remaining={projected:.8f} remaining_writes={remaining}"
)
if projected > 0.01:
    sys.exit(2)
PY
if [[ "$budget_rc" -eq 2 ]]; then
  say "stopping before the remaining writes: projected cost would exceed 0.01"
  : >"$work/stop"
elif [[ "$budget_rc" -ne 0 ]]; then
  exit "$budget_rc"
else
  : >"$work/go"
fi

rc=0
wait "$lean_pid" || rc=$?
lean_pid=""

left=$(lambo_pids || true)
if [[ -n "$left" ]]; then
  say "child_still_running"
  if [[ "$rc" -eq 0 ]]; then
    rc=5
  fi
else
  say "child_gone"
fi

say "lean_exit=${rc}"
say "stdout"
say_file "$work/lean.out" || true
if [[ -s "$work/lean.err" ]]; then
  say "stderr"
  say_file "$work/lean.err" || true
fi

usage_snapshot "$work/usage-final.json"
python3 -I - "$work" <<'PY'
import json, os, sys
work = sys.argv[1]
before = json.load(open(os.path.join(work, "usage-before.json")))
final = json.load(open(os.path.join(work, "usage-final.json")))
budget = json.load(open(os.path.join(work, "budget.json")))

def embed_in(doc):
    rows = doc.get("usage", {}).get("current_month", {}).get("chat_usage", [])
    for row in rows:
        if row.get("model") == "qwen3-embedding-4b":
            return int(row.get("input_tokens") or 0), int(row.get("output_tokens") or 0)
    return None

b = embed_in(before)
f = embed_in(final)
if b is None or f is None:
    print("total_cost source=unavailable")
    sys.exit(0)
din, dout = f[0] - b[0], f[1] - b[1]
if din < 0:
    din = 0
usd = din * 0.05 / 1_000_000
print(
    f"total_cost source=usage input_tokens={din} output_tokens={dout} usd={usd:.8f} "
    f"first_call_source={budget['source']}"
)
if usd > 0.01:
    sys.exit(2)
PY

exit "$rc"
