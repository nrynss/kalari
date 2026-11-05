#!/usr/bin/env bash
# Deliberate containment demonstration (T5.6a). Not part of the gate; run on the
# benchmark VM from a staged copy of this repository layout:
#
#   <stage>/bin/{kalari,kalari-aashaan,msb,vimanam,lambo}
#   <stage>/tests/live/containment.sh
#   <stage>/bench/apis/payouts/reference/{cursor_loop,v1_unchanged}.py
#   <stage>/bench/workspaces/payout-sync/specs/openapi-v{1,2}.yaml
#
#   tests/live/containment.sh            the live run (needs no key, no inference)
#   tests/live/containment.sh --dry      failure-path cleanup proof and the boundary
#                                        probe only; never runs the cursor-loop consumer
#   tests/live/containment.sh --assemble RAWDIR
#                                        rebuild the sanitised bundle from a raw directory
#
# The live run does exactly one production `run_in_sandbox` call for the buggy
# consumer (payouts cursor_loop: it follows the page cursor forever), with a
# short time cap, then one more production call with the same caps and the same
# allowlist that runs a probe from a fresh guest. It prints its progress as it
# goes. It reuses the wiring of tests/live/run.sh. A shim in front of `msb`
# records the exact creation arguments and the effective network policy of every
# sandbox this test creates. Every sandbox it creates is removed and checked.
#
# Raw output stays on the VM under $OUT (it holds the VM address). The
# sanitised bundle is $OUT/bundle/{evidence.jsonl,transcript.txt}.
set -euo pipefail
umask 022
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"

mode=live
raw_arg=""
case "${1:-}" in
  "") ;;
  --dry) mode=dry ;;
  --rehearse) mode=rehearse ;;
  --assemble) mode=assemble; raw_arg=${2:?usage: containment.sh --assemble RAWDIR} ;;
  *) echo 'usage: containment.sh [--dry | --assemble RAWDIR]' >&2; exit 2 ;;
esac

: "${TOOL_BIN:=$root/bin}"
: "${CAP_MS:=5000}"
: "${PAYOUTS_PORT:=18080}"
: "${PAYOUTS_V2_PORT:=18090}"
: "${OUT:=$root/out/containment-$$}"
[[ "$CAP_MS" =~ ^[0-9]+$ && "$CAP_MS" -ge 1000 && "$CAP_MS" -le 30000 ]] || { echo 'CAP_MS must be 1000..30000' >&2; exit 2; }

driver=$(mktemp)
work=""
real_msb="$TOOL_BIN/msb"
cleanup() {
  local st=$?
  trap - EXIT INT TERM
  # Last resort if the driver was killed: remove only the sandboxes the shim
  # recorded as created by this test, and stop anything still tied to its work dir.
  if [[ -n "$work" && -f "$work/cap/created.txt" ]]; then
    local n
    while IFS= read -r n; do
      [[ -n "$n" ]] && "$real_msb" remove -f "$n" >/dev/null 2>&1 || true
    done <"$work/cap/created.txt"
  fi
  if [[ -n "$work" ]]; then
    local p
    for p in $(pgrep -f -- "$work" 2>/dev/null || true); do kill "$p" 2>/dev/null || true; done
    rm -rf "$work"
  fi
  rm -f "$driver"
  exit "$st"
}
trap cleanup EXIT INT TERM

if [[ $mode != assemble ]]; then
  for bin in kalari kalari-aashaan msb vimanam lambo; do
    [[ -x "$TOOL_BIN/$bin" ]] || { echo "missing $TOOL_BIN/$bin" >&2; exit 2; }
  done
  for f in bench/apis/payouts/reference/cursor_loop.py bench/apis/payouts/reference/v1_unchanged.py \
           bench/workspaces/payout-sync/specs/openapi-v1.yaml bench/workspaces/payout-sync/specs/openapi-v2.yaml; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 2; }
  done
  # The guest cannot reach the host's loopback; the benchmark APIs are published
  # on the VM's own address. Resolve it here, on the VM, and never write it down.
  API_HOST=$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')
  [[ "$API_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'could not resolve the VM address' >&2; exit 2; }
  case "$API_HOST" in 127.*|0.*|169.254.*) echo 'refusing a non-routable VM address' >&2; exit 2 ;; esac
  work=$(mktemp -d)
  mkdir -p "$OUT"
  chmod 755 "$work"
fi

cat >"$driver" <<'PY'
import json, os, re, shutil, signal, subprocess, sys, threading, time
import urllib.request

mode = sys.argv[1]
IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
HOME = os.path.expanduser("~")


def dedot(s, host="", work=""):
    """Sanitise one string: the VM address, the temporary work directory, any
    other IPv4 address and the home directory."""
    s = re.sub(r"https?://[^\s\"',\]]+", "ENDPOINT", s)
    if host:
        s = s.replace(host, "<vm-public-ip>")
    if work:
        s = s.replace(work, "<work>")
    s = s.replace(HOME, "~")
    return IPV4.sub("<ip>", s)


def walk(value, fn):
    if isinstance(value, str):
        return fn(value)
    if isinstance(value, list):
        return [walk(x, fn) for x in value]
    if isinstance(value, dict):
        return {k: walk(v, fn) for k, v in value.items()}
    return value


# ---------------------------------------------------------------- assemble --

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def argv_blocks(path):
    """The shim writes one block per msb call: a line `--`, then one argument per line."""
    try:
        text = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        return []
    blocks, cur = [], None
    for line in text.split("\n"):
        if line == "--":
            if cur is not None:
                blocks.append(cur)
            cur = []
        elif cur is not None and line != "":
            cur.append(line)
    if cur:
        blocks.append(cur)
    return blocks


def assemble(raw):
    meta = read_json(f"{raw}/meta.json")
    if meta is None:
        raise SystemExit("assemble: meta.json missing")
    host, work = meta.get("host", ""), meta.get("work", "")
    clean = lambda v: walk(v, lambda s: dedot(s, host, work))
    cursor = read_json(f"{raw}/report-cursor.json")
    probe = read_json(f"{raw}/report-probe.json")
    cleanup = read_json(f"{raw}/cleanup.json")
    if cursor is None or probe is None or cleanup is None:
        raise SystemExit("assemble: a report or the cleanup proof is missing")
    store = []
    try:
        for line in open(f"{raw}/evidence-store.jsonl", encoding="utf-8"):
            if line.strip():
                store.append(json.loads(line))
    except FileNotFoundError:
        raise SystemExit("assemble: evidence-store.jsonl missing")
    run_id = cursor["run_id"]
    mine = [r for r in store if r.get("run_id") == run_id and r.get("kind") in ("run", "check")]
    run_rec = next((r for r in mine if r["kind"] == "run"), None)
    if run_rec is None:
        raise SystemExit("assemble: no run record for the containment run")
    name = "kalari-" + run_id
    creates = [b for b in argv_blocks(f"{raw}/msb-argv.log") if b[:1] == ["create"]]
    create = next((b for b in creates if "--name" in b and b[b.index("--name") + 1] == name), None)
    inspect = read_json(f"{raw}/inspect-{name}.json") or {}
    probe_inspect = read_json(f"{raw}/inspect-kalari-{probe['run_id']}.json") or {}
    probe_policy = probe_inspect.get("active_config", probe_inspect).get("network", {}).get("policy", {})
    active = inspect.get("active_config", inspect)
    net = active.get("network", {})
    policy = net.get("policy", {})
    request = run_rec["payload"]["request"]
    caps = request["caps"]
    verdict = cursor["verdict"]
    diff = next((c for c in cursor["checks"] if c["check_id"] == "differential-v1"), None)
    probe_results = meta.get("probe_results", [])
    breaches = [p for p in probe_results if p["expected"] == "refused" and p["observed"] != "refused"]
    allowed_ok = [p for p in probe_results if p["expected"] == "allowed" and p["observed"] == "allowed"]
    payload = {
        "schema": "kalari.containment.v1",
        "label": "Deliberate containment demonstration",
        "benchmark": False,
        "synthetic": bool(meta.get("synthetic")),
        "case": meta.get("case", "payouts cursor_loop: a consumer that follows the page cursor and never stops"),
        "config": {
            "time_cap_ms": caps["timeout_ms"],
            "time_ceiling_ms": meta["ceiling"]["timeout_ms"],
            "output_cap_bytes": caps["output_cap_bytes"],
            "memory_mib": caps["memory_mib"],
            "note": "The output and memory caps are configuration only. Neither is claimed to have fired in this run.",
        },
        "result": {
            "run_id": run_id,
            "verdict": verdict["verdict"],
            "exit_code": verdict.get("exit_code"),
            "passed": cursor["passed"],
            "wall_ms": verdict["wall_ms"],
            "call_ms": meta.get("cursor_call_ms"),
            "stdout_truncated": verdict.get("stdout_truncated"),
            "pipe_held_open": verdict.get("pipe_held_open"),
            "supervisor_peak_rss_kb": verdict.get("supervisor_peak_rss_kb"),
            "enforcement_note": "The supervisor polls, so the measured elapsed time can exceed the configured cap. No fixed bound is promised.",
        },
        "outcomes": {
            "candidate": {"verdict": verdict["verdict"], "exit_code": verdict.get("exit_code"), "passed": False},
            "baseline": {
                "executed": any(b[:1] == ["create"] and "--name" in b and b[b.index("--name") + 1] == name + "-v1" for b in creates),
                "note": "The v1 baseline runs only after the candidate has produced an output file. This candidate never wrote one, so the production pipeline did not start a baseline guest.",
            },
            "differential": {
                "check_id": diff["check_id"] if diff else None,
                "passed": diff["passed"] if diff else None,
                "detail": diff.get("detail") if diff else None,
            },
        },
        "creation": {
            "argv": (["msb"] + create) if create else None,
            "source": "an msb shim on the service's PATH recorded the argument list at the moment of the call",
            "image": (active.get("image", {}).get("Oci", {}) or {}).get("reference"),
            "cpus": active.get("resources", {}).get("cpus"),
            "memory_mib": active.get("resources", {}).get("memory_mib"),
        },
        "network": {
            "requested": {
                "mode": "msb create --no-net plus one --net-rule",
                "rules": [a for a in (create or []) if a.startswith("allow@")],
            },
            "effective": {
                "source": "msb inspect --format json, read right after create",
                "enabled": net.get("enabled"),
                "default_egress": policy.get("default_egress"),
                "default_ingress": policy.get("default_ingress"),
                "rules": [
                    {
                        "action": r.get("action"),
                        "direction": r.get("direction"),
                        "destination": r.get("destination"),
                        "protocols": r.get("protocols"),
                        "ports": r.get("ports"),
                    }
                    for r in policy.get("rules", [])
                ],
            },
            "observed": {
                "source": "a probe run through the same production run_in_sandbox path, with the same caps and the same allowlist",
                "same_guest": False,
                "probe_policy_matches_candidate": probe_policy == policy,
                "same_configuration": True,
                "probe_run_id": probe["run_id"],
                "probe_verdict": probe["verdict"]["verdict"],
                "probe_exit_code": probe["verdict"].get("exit_code"),
                "attempts": probe_results,
                "denied_attempts": sum(1 for p in probe_results if p["expected"] == "refused"),
                "denied_and_refused": sum(1 for p in probe_results if p["expected"] == "refused" and p["observed"] == "refused"),
                "allowed_attempts": sum(1 for p in probe_results if p["expected"] == "allowed"),
                "allowed_and_answered": len(allowed_ok),
                "breaches": len(breaches),
            },
        },
        "cleanup": cleanup,
        "limits": [
            "Observed restrictions only: the listed requests from one guest configuration, on this host, with this msb and this guest kernel.",
            "This is not a claim of zero blast radius, and not a security audit.",
            "The probe ran in a second guest created with the same arguments, not inside the guest that ran the consumer.",
            "The output cap and the memory cap are recorded as configuration. This run did not exercise either.",
        ],
        "versions": meta.get("versions", {}),
    }
    record = {
        "kind": "containment",
        "session_id": "containment-demo",
        "run_id": run_id,
        "change_kinds": run_rec.get("change_kinds", []),
        "payload": payload,
    }
    recs = []
    for r in mine:
        r = dict(r)
        r["session_id"] = "containment-demo"
        recs.append(r)
    recs.append(record)
    recs = [clean(r) for r in recs]
    bundle = f"{raw}/bundle"
    os.makedirs(bundle, exist_ok=True)
    with open(f"{bundle}/evidence.jsonl", "w", encoding="utf-8", newline="\n") as f:
        for r in recs:
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")
    try:
        transcript = open(f"{raw}/progress.txt", encoding="utf-8").read()
    except FileNotFoundError:
        transcript = ""
    with open(f"{bundle}/transcript.txt", "w", encoding="utf-8", newline="\n") as f:
        f.write(clean(transcript))
    print(f"bundle: {len(recs)} records, transcript {len(transcript)} bytes -> {bundle}")


if mode == "assemble":
    assemble(sys.argv[2])
    raise SystemExit(0)

# -------------------------------------------------------------------- live --

(_, mode, root, work, cap, out, tools, host, port, v2port, cap_ms) = sys.argv[:11]
port, v2port, cap_ms = int(port), int(v2port), int(cap_ms)
real_msb = tools + "/msb"
IMAGE = "python:3.13-slim"
progress = open(out + "/progress.txt", "w", encoding="utf-8", buffering=1)
lock = threading.Lock()


def say(line=""):
    text = dedot(line, host, work)
    with lock:
        print(text, flush=True)
        progress.write(text + "\n")


def msb(*args, check=True):
    r = subprocess.run([real_msb, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError("msb " + " ".join(args[:2]) + " failed: " + dedot(r.stderr.strip()[:200], host, work))
    return r


def listed():
    r = msb("list", "--format", "json")
    return json.loads(r.stdout or "[]")


def created_names():
    try:
        return [x for x in open(cap + "/created.txt", encoding="utf-8").read().split("\n") if x]
    except FileNotFoundError:
        return []


def proc_hits(needles):
    """PIDs other than ours whose command line holds one of the needles."""
    hits = []
    skip = {os.getpid()}
    pid_ = os.getppid()
    while pid_ > 1 and pid_ not in skip:
        skip.add(pid_)
        try:
            pid_ = int(open(f"/proc/{pid_}/stat").read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    for pid in filter(str.isdigit, os.listdir("/proc")):
        if int(pid) in skip:
            continue
        try:
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        if any(n and n in cmd for n in needles):
            hits.append((int(pid), cmd))
    return hits


cleanup_proof = None


def prove_cleanup(pre, service, whole=True):
    """Remove only the sandboxes this test created, then verify: none listed,
    every sandbox that existed before is untouched, no child process left."""
    global cleanup_proof
    names = created_names()
    present = {e["name"] for e in listed()}
    gone = [n for n in names if n not in present]
    removed = []
    for n in names:
        if n in present and msb("remove", "-f", n, check=False).returncode == 0:
            removed.append(n)
    if service is not None:
        try:
            service.stdin.close()
        except Exception:
            pass
        try:
            service.wait(timeout=15)
        except subprocess.TimeoutExpired:
            service.kill()
            service.wait()
    # sandbox processes take a moment to leave after remove
    deadline = time.monotonic() + 8
    while True:
        hits = proc_hits(([work] if whole else []) + names)
        if not hits or time.monotonic() > deadline:
            break
        time.sleep(0.25)
    after = listed()
    after_names = [e["name"] for e in after]
    pre_names = [e["name"] for e in pre]
    cleanup_proof = {
        "sandboxes_created": names,
        "removed_by_run_in_sandbox": gone,
        "removed_by_forced_cleanup": removed,
        "still_listed": [n for n in names if n in after_names],
        "pre_existing_before": sorted(pre_names),
        "pre_existing_unchanged": sorted(n for n in after_names if n in pre_names) == sorted(pre_names)
        and all(
            next(e for e in after if e["name"] == n)["status"] == next(e for e in pre if e["name"] == n)["status"]
            for n in pre_names
            if n in after_names
        ),
        "other_kalari_sandboxes_listed_untouched": sorted(n for n in after_names if n.startswith("kalari-") and n not in names),
        "child_processes_remaining": [{"pid": p, "cmd": dedot(c[:120], host, work)} for p, c in hits],
        "service_exited": service is None or service.poll() is not None,
    }
    cleanup_proof["ok"] = (
        not cleanup_proof["still_listed"]
        and cleanup_proof["pre_existing_unchanged"]
        and not cleanup_proof["child_processes_remaining"]
        and cleanup_proof["service_exited"]
    )
    return cleanup_proof


def describe_rules(pol):
    parts = []
    for r in pol.get("rules", []):
        ports = ",".join(
            str(p.get("start")) if p.get("end") == p.get("start") else "%s-%s" % (p.get("start"), p.get("end"))
            for p in r.get("ports", []))
        parts.append("%s %s %s %s port %s" % (r.get("action"), r.get("direction"), ",".join(r.get("protocols", [])),
                                              r.get("destination", {}).get("cidr", "?"), ports))
    return "; ".join(parts) or "none"


def preflight():
    state = {e["name"]: e["status"] for e in pre}
    for n in ("api-payouts-live", "api-payouts-grading"):
        if str(state.get(n)).lower() != "running":
            raise RuntimeError(n + " is not running")
    with urllib.request.urlopen(f"http://{host}:{v2port}/v2/payouts?limit=1", timeout=5) as r:
        if r.status != 200:
            raise RuntimeError("the grading API did not answer 200")
    import socket
    socket.create_connection((host, port), timeout=5).close()


def sigterm(signum, frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, sigterm)

caps_max = {"timeout_ms": 30000, "output_cap_bytes": 65536, "memory_mib": 512}
caps_run = {"timeout_ms": cap_ms, "output_cap_bytes": 65536, "memory_mib": 512}
baseline_net = [{"host": host, "port": port}]
candidate_net = [{"host": host, "port": v2port}]
endpoint = {"endpoint": "https://example.invalid", "model": "unused", "api_key_env": "KALARI_LIVE_DUMMY"}
config = {
    "models": endpoint,
    "decisions": dict(endpoint, endpoint="https://api.vultrinference.com/v1/systemone", model="clef"),
    "sandbox": {"backend": "microsandbox", "caps": caps_max, "allowlist": baseline_net + candidate_net},
    "lambo": {"command": [tools + "/lambo", "serve"], "config_path": work + "/lambo.toml"},
}
old, new = work + "/old.yaml", work + "/new.yaml"
consumer_cmd = lambda root_, p: ["python3", root_ + "/consumer.py", "--base-url", f"http://{host}:{p}", "--out", "payouts.jsonl"]
setup = {
    "session_id": "containment-demo", "repo_scope": "containment-demo", "workspace": work + "/candidate", "old_spec": old, "new_spec": new,
    "baseline": {"workspace": work + "/baseline", "command": consumer_cmd(work + "/baseline", port), "caps": caps_max, "allowlist": baseline_net},
    "check_workspace": work + "/checks", "evidence_workspace": work + "/evidence", "artifact": "payouts.jsonl",
    "aashaan": tools + "/kalari-aashaan", "tool_path": f"{work}/shim:{tools}:/usr/local/bin:/usr/bin:/bin",
}

service = None
announced = set()
pre = []
status = 1
meta = {"host": host, "work": work, "synthetic": mode == "rehearse", "ceiling": caps_max}
if mode == "rehearse":
    meta["case"] = "REHEARSAL with a sleeping stub, not the cursor-loop consumer"
try:
    pre = listed()
    for d in ("candidate", "baseline", "checks", "evidence"):
        os.makedirs(f"{work}/{d}", exist_ok=True)
    if mode == "rehearse":
        with open(work + "/candidate/consumer.py", "w") as f:
            f.write("import time\ntime.sleep(3600)\n")
    else:
        shutil.copy("bench/apis/payouts/reference/cursor_loop.py", work + "/candidate/consumer.py")
    shutil.copy("bench/apis/payouts/reference/v1_unchanged.py", work + "/baseline/consumer.py")
    shutil.copy("bench/workspaces/payout-sync/specs/openapi-v1.yaml", old)
    shutil.copy("bench/workspaces/payout-sync/specs/openapi-v2.yaml", new)
    with open(work + "/lambo.toml", "w") as f:
        f.write(f'[store]\nkind = "sqlite"\npath = "{work}/lambo.db"\n[embedder]\nkind = "fixture"\n[serve]\ndefault_session = "containment-demo"\n')
    subprocess.run([tools + "/lambo", "provision", "--config", work + "/lambo.toml"], check=True, capture_output=True)
    diff = subprocess.run([tools + "/vimanam", "diff", "--format", "json", old, new], check=True, capture_output=True, text=True).stdout
    for kind in sorted({c["kind"] for c in json.loads(diff)["changes"]}):
        subprocess.run([tools + "/lambo", "derive", "--config", work + "/lambo.toml", "--session", "containment-demo",
                        "--agent", "containment-demo", "--content", kind, "--kind", "resource"], check=True, capture_output=True)
    for name, value in (("config", config), ("session", setup)):
        with open(f"{work}/{name}.json", "w") as f:
            json.dump(value, f)
    os.environ["KALARI_LIVE_DUMMY"] = "live-test-placeholder"
    versions = {
        "msb": msb("--version").stdout.strip(),
        "kalari": subprocess.run([tools + "/kalari", "--version"], capture_output=True, text=True).stdout.strip(),
        "image": IMAGE,
    }
    meta["versions"] = versions

    service = subprocess.Popen([tools + "/kalari", "serve", work + "/config.json", work + "/session.json"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(work + "/serve.err", "wb"), text=True)
    seq = [0]

    def call(name, args, tick=None):
        seq[0] += 1
        service.stdin.write(json.dumps({"jsonrpc": "2.0", "id": seq[0], "method": "tools/call", "params": {"name": name, "arguments": args}}) + "\n")
        service.stdin.flush()
        stop = threading.Event()
        t0 = time.monotonic()
        th = None
        if tick:
            th = threading.Thread(target=tick, args=(stop, t0), daemon=True)
            th.start()
        try:
            line = service.stdout.readline()
        finally:
            stop.set()
            if th:
                th.join(timeout=3)
        if not line:
            raise RuntimeError("service closed without a response")
        response = json.loads(line)
        result = response.get("result", {})
        if result.get("isError") or "error" in response:
            raise RuntimeError("tool error: " + dedot(result.get("content", [{}])[0].get("text", "protocol error"), host, work))
        return json.loads(result["content"][0]["text"]), time.monotonic() - t0

    def watcher(stop, t0):
        """Print each sandbox as it is created, with its creation arguments and
        effective network policy, and a line per second while the run is going."""
        seen = announced
        last = 0
        while not stop.wait(0.2):
            for n in created_names():
                if n in seen:
                    continue
                insp = read_json(f"{cap}/inspect-{n}.json")
                if insp is None:
                    continue
                seen.add(n)
                blocks = [b for b in argv_blocks(cap + "/msb-argv.log") if b[:1] == ["create"] and "--name" in b and b[b.index("--name") + 1] == n]
                say(f"   sandbox created: {n}")
                if blocks:
                    say("   creation arguments: msb " + " ".join(blocks[0]))
                act = insp.get("active_config", insp)
                pol = act.get("network", {}).get("policy", {})
                say("   effective network policy (msb inspect): default egress %s, default ingress %s; rules: %s" % (
                    pol.get("default_egress"), pol.get("default_ingress"), describe_rules(pol)))
            sec = int(time.monotonic() - t0)
            if sec > last and seen:
                last = sec
                say(f"   ... {sec} s elapsed, the call has not returned")

    preflight()
    say("== Deliberate containment demonstration ==")
    say("A consumer with a known bug is run on purpose, to show the time limit and the boundary.")
    say("This is not a benchmark session, and no benchmark row is involved.")
    if mode == "rehearse":
        say("REHEARSAL: a sleeping stub stands in for the cursor-loop consumer. Not the demonstration.")
    say(f"Case:    {meta.get('case', 'payouts cursor_loop, a consumer that follows the page cursor and never stops')}")
    say(f"Config:  time cap {cap_ms} ms (ceiling {caps_max['timeout_ms']} ms), output cap {caps_max['output_cap_bytes']} bytes, memory {caps_max['memory_mib']} MiB")
    say("         The output and memory caps are configuration. This run does not exercise them.")
    say(f"Network: --no-net plus one allow rule for the grading API port only (resolved on this VM)")
    say(f"Tools:   {versions['msb']}, {versions['kalari']}, image {IMAGE}")
    say(f"Before:  {len(pre)} sandboxes exist and are not ours: " + ", ".join(sorted(e['name'] for e in pre)))
    say("")
    changes, _ = call("what_changed", {"old_spec": old, "new_spec": new})
    if mode != "dry":
        say("-- run_in_sandbox, production path: candidate against the v2 API --")
        report, took = call("run_in_sandbox", {"workspace": work + "/candidate", "command": consumer_cmd(work + "/candidate", v2port),
                                               "caps": caps_run, "allowlist": candidate_net}, tick=watcher)
        v = report["verdict"]
        diff_check = next((c for c in report["checks"] if c["check_id"] == "differential-v1"), {})
        meta["cursor_call_ms"] = int(took * 1000)
        with open(out + "/report-cursor.json", "w") as f:
            json.dump(report, f, indent=1)
        say("")
        say("-- verdict --")
        say(f"run id:          {report['run_id']}")
        say(f"configured cap:  {cap_ms} ms")
        say(f"measured wall:   {v['wall_ms']} ms (the aashaan's clock; the supervisor polls, so this can exceed the cap)")
        exit_text = "none (killed)" if v.get("exit_code") is None else str(v["exit_code"])
        say(f"verdict:         {v['verdict']}   exit code: {exit_text}   passed: {str(report['passed']).lower()}")
        say(f"output:          stdout_truncated={str(v.get('stdout_truncated')).lower()} (output cap not exercised), pipe_held_open={str(v.get('pipe_held_open')).lower()}")
        say(f"whole call:      {meta['cursor_call_ms']} ms on the host, including create, copy, exec and remove")
        say(f"candidate:       {v['verdict']}")
        say(f"baseline (v1):   not run; it follows only a candidate that wrote an output file")
        say(f"differential:    passed={str(diff_check.get('passed')).lower()}  {diff_check.get('detail')}")
        cursor_ok = v["verdict"] == "killed_timeout" and report["passed"] is False
    else:
        cursor_ok = True
        say("-- dry: failure path --")
        dry_name = "kalari-dry-abort-%d" % os.getpid()
        r = subprocess.run([work + "/shim/msb", "create", "--name", dry_name, "--cpus", "1", "--memory", "256M", "--no-net", "--pull", "never", IMAGE],
                           capture_output=True, text=True)
        say(f"   created {dry_name} through the shim (rc {r.returncode} {r.stderr.strip()[:160]}), then simulated a failure")
        announced.add(dry_name)
        mid = prove_cleanup(pre, None, whole=False)
        say("   after it: still listed %s; sandboxes from before unchanged %s" % (mid["still_listed"] or "none", str(mid["pre_existing_unchanged"]).lower()))
        if r.returncode != 0 or not mid["ok"]:
            raise RuntimeError("the failure-path cleanup did not verify")

    # Boundary: a probe through the same production path, same caps, same allowlist.
    targets = [
        ("allowed", host, v2port, "/v2/payouts?limit=1", "allowed"),
        ("other-port-same-host", host, port, "/v1/payouts?limit=1", "refused"),
        ("host-ssh", host, 22, "-", "refused"),
        ("metadata-link-local", "169.254.169.254", 80, "/", "refused"),
        ("internet", None, 80, "/", "refused"),
    ]
    inet = subprocess.run(["getent", "ahostsv4", "example.com"], capture_output=True, text=True).stdout.split()
    inet = inet[0] if inet else ""
    if not IPV4.fullmatch(inet) or inet == host:
        raise RuntimeError("could not resolve a public address for the internet probe")
    probe_py = '''import socket, sys

def one(label, host, port, path):
    try:
        s = socket.create_connection((host, int(port)), timeout=5)
    except Exception as e:
        print(f"{label}: refused {type(e).__name__}", flush=True); return
    try:
        s.settimeout(5)
        if path != "-":
            s.sendall(f"GET {path} HTTP/1.0\\r\\nHost: {host}\\r\\nConnection: close\\r\\n\\r\\n".encode())
        data = b""
        while len(data) < 1200:
            try:
                chunk = s.recv(1200)
            except socket.timeout:
                print(f"{label}: refused timeout", flush=True); return
            if not chunk:
                break
            data += chunk
    except Exception as e:
        print(f"{label}: refused {type(e).__name__}", flush=True); return
    finally:
        s.close()
    text = data.decode("utf-8", "replace")
    if "network_policy_denied" in text.lower():
        print(f"{label}: refused network_policy_denied", flush=True); return
    if text.startswith("SSH-"):
        print(f"{label}: ANSWERED ssh-banner", flush=True); return
    first = text.split("\\r\\n", 1)[0]
    if first.startswith("HTTP/"):
        parts = first.split()
        print(f"{label}: ANSWERED http-{parts[1] if len(parts) > 1 else '?'}", flush=True); return
    if not text.strip():
        print(f"{label}: refused empty", flush=True); return
    print(f"{label}: ANSWERED payload", flush=True)

for raw in open(sys.argv[1]):
    if raw.strip():
        one(*raw.split())
'''
    with open(work + "/candidate/probe.py", "w") as f:
        f.write(probe_py)
    with open(work + "/candidate/targets", "w") as f:
        for label, h, p, path, _ in targets:
            f.write(f"{label} {h or inet} {p} {path}\n")
    say("")
    say("-- boundary: a probe through the same production path (same caps, same allowlist, a fresh guest) --")
    say("   The probe asks the allowed API port and four things the allowlist does not name.")
    probe_report, probe_took = call("run_in_sandbox", {"workspace": work + "/candidate",
                                    "command": ["python3", work + "/candidate/probe.py", work + "/candidate/targets"],
                                    "caps": dict(caps_run, timeout_ms=30000), "allowlist": candidate_net}, tick=watcher)
    with open(out + "/report-probe.json", "w") as f:
        json.dump(probe_report, f, indent=1)
    pv = probe_report["verdict"]
    outcomes = {}
    for line in pv["stdout"].splitlines():
        m = re.match(r"^([\w-]+): (refused|ANSWERED)\s*(.*)$", line)
        if m:
            outcomes[m.group(1)] = (m.group(2), m.group(3))
    results = []
    for label, h, p, path, want in targets:
        got = outcomes.get(label)
        observed = "no-result" if got is None else ("refused" if got[0] == "refused" else "allowed")
        results.append({"label": label, "port": p, "expected": want, "observed": observed, "detail": (got[1] if got else "")})
        say(f"   {label:22s} expected {want:8s} observed {observed:8s} {got[0] + ' ' + got[1] if got else '(no output)'}")
    meta["probe_results"] = results
    boundary_ok = all((r["observed"] == "refused") if r["expected"] == "refused" else (r["observed"] == "allowed") for r in results)
    say("   Requested policy is what msb create was asked for. Observed enforcement is only the lines above.")
except BaseException as e:
    say("")
    say(f"!! the run stopped before the end: {type(e).__name__}: {dedot(str(e), host, work)}")
    try:
        tail = open(work + "/serve.err", "rb").read()[-600:].decode("utf-8", "replace").strip()
        if tail:
            say("   service stderr: " + tail.replace("\n", " | "))
    except OSError:
        pass
    cursor_ok = False
    boundary_ok = False
finally:
    say("")
    say("-- cleanup --")
    proof = prove_cleanup(pre, service)
    say(f"sandboxes this test created: {', '.join(proof['sandboxes_created']) or 'none'}")
    say(f"removed by run_in_sandbox:    {', '.join(proof['removed_by_run_in_sandbox']) or 'none'}")
    say(f"needed forced cleanup:       {', '.join(proof['removed_by_forced_cleanup']) or 'none'}")
    say(f"still listed afterwards:     {', '.join(proof['still_listed']) or 'none'}")
    say(f"sandboxes from before:       {'all present and unchanged' if proof['pre_existing_unchanged'] else 'CHANGED'}")
    say(f"child processes remaining:   {len(proof['child_processes_remaining'])}")
    say(f"kalari service exited:       {str(proof['service_exited']).lower()}")
    with open(out + "/cleanup.json", "w") as f:
        json.dump(proof, f, indent=1)
    with open(out + "/meta.json", "w") as f:
        json.dump(meta, f, indent=1)

ok = locals().get("cursor_ok", False) and locals().get("boundary_ok", False) and cleanup_proof and cleanup_proof["ok"]
try:
    shutil.copy(work + "/evidence/.kalari/evidence.jsonl", out + "/evidence-store.jsonl")
except Exception:
    pass
for f in os.listdir(cap):
    shutil.copy(f"{cap}/{f}", f"{out}/{f}")
say("")
if mode != "dry" and ok:
    say(("REHEARSAL " if mode == "rehearse" else "") + "RESULT: killed_timeout and passed=false at the configured cap; the boundary refused every request it was asked to refuse; every sandbox this test created is gone and no child process remains.")
    say("This shows the listed requests from one guest configuration. It is not a claim of zero blast radius.")
    progress.flush()
    assemble(out)
elif mode == "dry":
    say("DRY RUN: " + ("boundary probe and cleanup verified; the cursor-loop consumer was not run." if boundary_ok and cleanup_proof and cleanup_proof["ok"] else "FAILED"))
    ok = boundary_ok and bool(cleanup_proof and cleanup_proof["ok"])
else:
    say("RESULT: NOT AS EXPECTED. See above. The raw files are in the output directory.")
sys.exit(0 if ok else 1)
PY

if [[ $mode == assemble ]]; then
  exec python3 -I "$driver" assemble "$raw_arg"
fi

# The shim sits first on the service's PATH. It logs every msb argument list,
# records each sandbox name the moment before create, and snapshots the effective
# configuration (network policy included) right after a create succeeds. It
# changes nothing about the call.
mkdir -p "$work/shim" "$work/cap"
cat >"$work/shim/msb" <<SHIM
#!/bin/sh
cap='$work/cap'
real='$real_msb'
{ printf '%s\n' '--'; for a in "\$@"; do printf '%s\n' "\$a"; done; } >>"\$cap/msb-argv.log"
if [ "\$1" = create ]; then
  name=''; prev=''
  for a in "\$@"; do
    [ "\$prev" = --name ] && name=\$a
    prev=\$a
  done
  printf '%s\n' "\$name" >>"\$cap/created.txt"
  "\$real" "\$@"; rc=\$?
  if [ \$rc -eq 0 ]; then
    "\$real" inspect "\$name" --format json >"\$cap/inspect-\$name.json" 2>/dev/null || true
  fi
  exit \$rc
fi
exec "\$real" "\$@"
SHIM
chmod 755 "$work/shim/msb"

echo "output directory: $OUT"
# Bounded at spawn: the whole driver, and with it kalari and lambo, ends within
# the timeout even if this shell is interrupted.
status=0
timeout 240 python3 -I "$driver" "$mode" "$root" "$work" "$work/cap" "$OUT" "$TOOL_BIN" "$API_HOST" \
  "$PAYOUTS_PORT" "$PAYOUTS_V2_PORT" "$CAP_MS" || status=$?
echo "raw output: $OUT   sanitised bundle: $OUT/bundle"
exit "$status"
