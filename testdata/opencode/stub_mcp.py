"""A logging MCP server standing in for `kalari serve`, to record what OpenCode sends.

Usage (as OpenCode's MCP command): python3 -I stub_mcp.py <log.jsonl>
Logs every line received and every reply, with a timestamp and direction. Offers one tool,
`what_changed`, returning a fixed change list.
"""
import json, sys, time

LOG = open(sys.argv[1], "a", buffering=1)
TOOLS = [{
    "name": "what_changed",
    "description": "List what changed between two versions of an API spec, with stable change IDs.",
    "inputSchema": {"type": "object", "properties": {
        "old_spec": {"type": "string", "description": "Path to the older spec"},
        "new_spec": {"type": "string", "description": "Path to the newer spec"}},
        "required": ["old_spec", "new_spec"]},
}]
CHANGES = ("pagination_changed vc2_example on GET /v2/payouts: v2 returns a window with a cursor and a drained flag; "
           "windows overlap by one payout.")


def log(direction, obj):
    LOG.write(json.dumps({"t": round(time.time(), 3), "dir": direction, "msg": obj}) + "\n")


def reply(obj):
    log("out", obj)
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except ValueError:
        log("in-unparsed", line); continue
    log("in", msg)
    mid, method = msg.get("id"), msg.get("method")
    if mid is None:
        continue
    if method == "initialize":
        reply({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}}, "serverInfo": {"name": "kalari-stub", "version": "0.0.1"}}})
    elif method == "tools/list":
        reply({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        reply({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": CHANGES}], "isError": False}})
    elif method == "ping":
        reply({"jsonrpc": "2.0", "id": mid, "result": {}})
    else:
        reply({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method not found: {method}"}})
