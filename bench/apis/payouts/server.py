"""Payouts API, v1 and v2, for the Kalari benchmark. Never shown to an arm.

v1: GET /v1/payouts returns every payout in one response.
v2: GET /v2/payouts is a resumable export, modelled on a real time-windowed export API
(bench/README.md names it; the arms never see the name). Its behaviours:

  B1  every response carries a fresh `cursor`, the last one included; `drained` says the
      export has caught up. Following the cursor at the end returns the boundary payout
      again with a newly minted cursor, forever.
  B2  each window starts at the last payout of the previous one, inclusive, so that payout
      appears in both responses.
  B4  `limit` is accepted up to 1000 (as the spec says) but each response holds at most 100.

Usage: server.py [--bind ADDR] [--port N] [--v1 on|off]
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from data import COUNT, PAYOUTS  # noqa: E402

PAGE_CAP = 100
SPEC_MAX_LIMIT = 1000
SECRET = os.urandom(16)
TRACE_LIMIT = 256
TRACE = None
TRACE_LOCK = threading.Lock()
TRACE_COUNT = 0

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest() if value else ""


def mint(offset: int) -> str:
    body = base64.urlsafe_b64encode(json.dumps({"w": offset, "t": time.time_ns()}).encode()).decode().rstrip("=")
    sig = hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()[:16]
    return f"{body}.{sig}"


def read(token: str):
    try:
        body, sig = token.rsplit(".", 1)
        if not hmac.compare_digest(sig, hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()[:16]):
            return None
        return int(json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))["w"])
    except Exception:
        return None


class Handler(BaseHTTPRequestHandler):
    v1_enabled = True

    def reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[-1] for k, v in parse_qs(url.query).items()}
        if url.path == "/v1/payouts":
            if not self.v1_enabled:
                return self.reply(410, {"error": "gone", "message": "API v1 has been retired. Use /v2/payouts."})
            return self.reply(200, {"payouts": PAYOUTS})
        if url.path == "/v2/payouts":
            return self.v2(q)
        return self.reply(404, {"error": "not_found"})

    def v2(self, q):
        try:
            limit = int(q.get("limit", "100"))
        except ValueError:
            return self.reply(400, {"error": "invalid_limit", "message": "limit must be an integer"})
        if not 1 <= limit <= SPEC_MAX_LIMIT:
            return self.reply(400, {"error": "invalid_limit", "message": f"limit must be between 1 and {SPEC_MAX_LIMIT}"})
        if "cursor" in q:
            start = read(q["cursor"])
            if start is None:
                return self.reply(400, {"error": "invalid_cursor", "message": "cursor is malformed or was not issued by this server"})
        else:
            start = 0
        size = min(limit, PAGE_CAP)                     # B4
        page = PAYOUTS[start:start + size]
        end = start + len(page)
        drained = end >= COUNT
        nxt = max(end - 1, 0)                           # B2: the next window starts at this page's last payout
        cursor = mint(nxt)
        response = {"payouts": page, "cursor": cursor, "drained": drained}
        if TRACE is None:
            return self.reply(200, response)
        # Serialize response completion and trace appends so the host can reject
        # branching or interleaving instead of guessing an order.
        global TRACE_COUNT
        with TRACE_LOCK:
            self.reply(200, response)
            if TRACE_COUNT < TRACE_LIMIT:
                event = {"request": digest(q.get("cursor", "")), "response": digest(cursor),
                         "first": page[0]["id"] if page else "", "last": page[-1]["id"] if page else "",
                         "ids": [p["id"] for p in page], "count": len(page), "drained": drained}
                TRACE.write(json.dumps(event, separators=(",", ":")) + "\n")
                TRACE.flush()
            elif TRACE_COUNT == TRACE_LIMIT:
                TRACE.write('{"overflow":true}\n')
                TRACE.flush()
            TRACE_COUNT += 1

    def log_message(self, *args):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--v1", choices=["on", "off"], default="on")
    ap.add_argument("--trace", help="exclusive host-owned page trace file")
    a = ap.parse_args()
    global TRACE
    if a.trace:
        fd = os.open(a.trace, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        TRACE = os.fdopen(fd, "w", encoding="utf-8")
    Handler.v1_enabled = a.v1 == "on"
    print(f"payouts listening on {a.bind}:{a.port} (v1 {a.v1})", flush=True)
    ThreadingHTTPServer((a.bind, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
