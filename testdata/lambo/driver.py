# python3 -I driver.py <lambo-bin> <workdir> <config> <steps.json> <transcript.jsonl>
# Like mcp_b4.py, plus: every JSON-RPC line both ways goes to the transcript, and a step
# with "receipt": true passes the last ack's receipt id to lambo_stats.
import json, re, subprocess, sys, time

lambo, workdir, config, steps_path, tpath = sys.argv[1:6]
steps = json.load(open(steps_path))
T = open(tpath, "w", buffering=1)
p = subprocess.Popen([lambo, "serve", "--config", config, "--session", "kalari-b4", "--agent", "kalari"],
                     cwd=workdir, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=open(f"{workdir}/serve.err", "a"), text=True, bufsize=1)
nid, last_text = 0, ""

def call(method, params=None, notify=False):
    global nid
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not notify:
        nid += 1; msg["id"] = nid
    T.write(json.dumps({"dir": "out", "msg": msg}) + "\n")
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
    if notify:
        return None
    while True:
        line = p.stdout.readline()
        if not line:
            raise SystemExit("lambo serve exited; see serve.err")
        r = json.loads(line)
        T.write(json.dumps({"dir": "in", "msg": r}) + "\n")
        if r.get("id") == nid:
            return r

r = call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "b4", "version": "0"}})
print("===== initialize", json.dumps(r.get("result", r))[:300])
call("notifications/initialized", notify=True)
r = call("tools/list", {})
print("===== tools/list", [t["name"] for t in r["result"]["tools"]])
for s in steps:
    if s.get("sleep"):
        time.sleep(s["sleep"]); continue
    args = dict(s["args"], agent_id="kalari")
    if s.get("receipt"):
        m = re.search(r"receipt[= ](lwr1\.[0-9a-f.]+[0-9a-f])", last_text)
        args["receipt"] = m.group(1) if m else None
        args.setdefault("wait_ms", 10000)
    r = call("tools/call", {"name": s["tool"], "arguments": args})
    res = r.get("result") or r.get("error")
    text = "\n".join(c.get("text", "") for c in res.get("content", [])) if isinstance(res, dict) and "content" in res else json.dumps(res)
    if isinstance(res, dict) and res.get("structuredContent"):
        text += "\n[structured] " + json.dumps(res["structuredContent"])
    last_text = text
    print(f"===== {s['tool']} {s.get('label', '')}")
    print(text[: s.get("max", 4000)])
p.stdin.close(); p.wait(timeout=60)
