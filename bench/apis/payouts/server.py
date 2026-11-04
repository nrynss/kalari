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
  B5  the first request of a traversal at or past offset 1500 gets HTTP 429 with
      `Retry-After: 1`. The identical request then succeeds. Each traversal gets one 429.
      The first response mints a traversal identity and carries it inside the opaque
      cursor, so replaying a saved cursor continues that lineage.

Usage: server.py [--bind ADDR] [--port N] [--v1 on|off] [--behaviours B1,B2,B4,B5]
                  [--retry-journal PATH]

Omit --behaviours and B1, B2, B4, and B5 are all on. A comma-separated list enables only
those ids. Any other token is an error that names the token. A behaviour that is off does
the plain thing: B1 off, a drained response has `cursor` null; B2 off, the next window
starts after the previous window's last payout; B4 off, the response holds up to `limit`
(still at most 1000); B5 off, no request is throttled.

The retry journal is a JSON-lines file in the API guest with one event per request. The
harness truncates it at a phase start and reads it at a phase end over `msb exec`. It
carries a timestamp, a client digest, the HTTP status, the request fingerprint digest,
the traversal digest and whether the request was the matching retry. It never carries a
raw cursor, a raw request or a token. A wrong type, an overflow marker or an eviction
marker reads as unknown, never as zero.

The host trace (`--trace`) holds one event per v2 request, in send order, for a single
exclusive client. A page event carries the HTTP status, the incoming cursor digest, the
full-request fingerprint digest, the retry flag and the page the API sent. A 429 event
carries the status, the incoming cursor digest, the fingerprint digest, the retry flag
and the `Retry-After` value, and no page. The matching retry repeats the throttled
request digest and fingerprint and is the only event marked `retry`. The trace never
carries a raw cursor, a raw request or a token.
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
CLIENT_KEY = os.urandom(16)
TRACE_LIMIT = 256
TRACE = None
TRACE_LOCK = threading.Lock()
TRACE_COUNT = 0

# B5: one throttled request per traversal, at a fixed mid-stream offset.
# Both maps are capped. A traversal that falls out of the cap can see a second
# 429, so the server marks the journal and the phase reads as unknown.
B5_OFFSET = 1500
B5_STATE_LIMIT = 4096
RETRY_AFTER = "1"
B5_LOCK = threading.Lock()
B5_PENDING = {}   # traversal -> {"cursor": incoming cursor digest, "request": fingerprint}
B5_CLEARED = {}   # traversals that already retried successfully

JOURNAL = None
JOURNAL_LOCK = threading.Lock()
JOURNAL_LIMIT = 100000
JOURNAL_COUNT = 0


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()[:32] if value else ""


def mint(offset: int, traversal: str) -> str:
    body = base64.urlsafe_b64encode(
        json.dumps({"w": offset, "t": time.time_ns(), "v": traversal}).encode()
    ).decode().rstrip("=")
    sig = hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()[:16]
    return f"{body}.{sig}"


def read(token: str):
    """Return (offset, traversal) for a cursor this server minted, else None."""
    try:
        body, sig = token.rsplit(".", 1)
        if not hmac.compare_digest(sig, hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()[:16]):
            return None
        doc = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
        return int(doc["w"]), str(doc["v"])
    except Exception:
        return None


def request_fingerprint(method: str, path: str, pairs) -> str:
    """Digest of the complete canonical request: method, path and every query value."""
    canon = method + "\n" + path + "\n" + "&".join(f"{k}={v}" for k, v in sorted(pairs))
    return hashlib.sha256(canon.encode()).hexdigest()[:32]


def evicted() -> None:
    """Mark the journal when the B5 state cap drops a traversal.

    An evicted traversal can see a second 429, so the phase reads as unknown.
    """
    global JOURNAL_COUNT
    if JOURNAL is None:
        return
    with JOURNAL_LOCK:
        if JOURNAL_COUNT < JOURNAL_LIMIT:
            JOURNAL.write('{"eviction":true}\n')
            JOURNAL.flush()
            JOURNAL_COUNT += 1


def b5_decide(traversal: str, cursor_key: str, offset: int, fingerprint: str):
    """One-shot throttle for this traversal.

    Returns (action, candidate). `candidate` says the request presented the
    throttled cursor, so it is an attempt to retry the failed request. The
    action is `serve`, `retry` (a matching candidate) or `throttle`.
    """
    if traversal in B5_CLEARED:
        return "serve", False
    with B5_LOCK:
        if traversal in B5_CLEARED:
            return "serve", False
        pending = B5_PENDING.get(traversal)
        if pending is not None:
            candidate = pending["cursor"] == cursor_key
            if candidate and pending["request"] == fingerprint:
                del B5_PENDING[traversal]
                B5_CLEARED[traversal] = None
                if len(B5_CLEARED) > B5_STATE_LIMIT:
                    evicted()
                    B5_CLEARED.pop(next(iter(B5_CLEARED)))
                return "retry", True
            # A changed request does not count as the identical retry.
            return "throttle", candidate
        if offset >= B5_OFFSET:
            if len(B5_PENDING) >= B5_STATE_LIMIT:
                evicted()
                B5_PENDING.pop(next(iter(B5_PENDING)))
            B5_PENDING[traversal] = {"cursor": cursor_key, "request": fingerprint}
            return "throttle", False
        return "serve", False


def client_tag(address: str) -> str:
    # Phase-safe: a keyed digest, never an address, and not reversible without the key.
    return hmac.new(CLIENT_KEY, address.encode(), hashlib.sha256).hexdigest()[:16]


def trace_event(event) -> None:
    """Append one event to the host trace.

    The caller holds TRACE_LOCK while it completes the response and calls this, so
    the host can reject branching or interleaving instead of guessing an order.
    """
    global TRACE_COUNT
    if TRACE_COUNT < TRACE_LIMIT:
        TRACE.write(json.dumps(event, separators=(",", ":")) + "\n")
        TRACE.flush()
    elif TRACE_COUNT == TRACE_LIMIT:
        TRACE.write('{"overflow":true}\n')
        TRACE.flush()
    TRACE_COUNT += 1


class Handler(BaseHTTPRequestHandler):
    v1_enabled = True
    trace_client = None
    b1 = True
    b2 = True
    b4 = True
    b5 = True

    def journal(self, status, fingerprint, traversal, throttled=False, matching_retry=False,
                retry_candidate=False, api="v2"):
        if JOURNAL is None:
            return
        global JOURNAL_COUNT
        event = {
            "t": round(time.time(), 3),
            "client": client_tag(self.client_address[0]),
            "api": api,
            "status": status,
            "request": fingerprint,
            "traversal": digest(traversal),
            "throttled": bool(throttled),
            "matching_retry": bool(matching_retry),
            "retry_candidate": bool(retry_candidate),
        }
        with JOURNAL_LOCK:
            if JOURNAL_COUNT < JOURNAL_LIMIT:
                JOURNAL.write(json.dumps(event, separators=(",", ":"), sort_keys=True) + "\n")
            else:
                # Write the marker on every request at or past the limit. The
                # harness truncates the file between phases, so the next request
                # after a truncate writes it again. A phase after an overflow then
                # reads as unknown, never as a false zero.
                JOURNAL.write('{"overflow":true}\n')
            JOURNAL.flush()
            JOURNAL_COUNT += 1

    def reply(self, status, obj, retry_after=None):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if retry_after is not None:
            self.send_header("Retry-After", retry_after)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        pairs = [(k, v) for k, vs in parse_qs(url.query, keep_blank_values=True).items() for v in vs]
        fingerprint = request_fingerprint("GET", url.path, pairs)
        if self.trace_client and self.client_address[0] != self.trace_client:
            self.reply(403, {"error": "forbidden"})
            return self.journal(403, fingerprint, "", api="other")
        q = {k: v[-1] for k, v in parse_qs(url.query).items()}
        if url.path == "/v1/payouts":
            if not self.v1_enabled:
                self.reply(410, {"error": "gone", "message": "API v1 has been retired. Use /v2/payouts."})
                return self.journal(410, fingerprint, "", api="v1")
            self.reply(200, {"payouts": PAYOUTS})
            return self.journal(200, fingerprint, "", api="v1")
        if url.path == "/v2/payouts":
            return self.v2(q, fingerprint)
        self.reply(404, {"error": "not_found"})
        return self.journal(404, fingerprint, "", api="other")

    def v2(self, q, fingerprint):
        try:
            limit = int(q.get("limit", "100"))
        except ValueError:
            self.reply(400, {"error": "invalid_limit", "message": "limit must be an integer"})
            return self.journal(400, fingerprint, "")
        if not 1 <= limit <= SPEC_MAX_LIMIT:
            self.reply(400, {"error": "invalid_limit", "message": f"limit must be between 1 and {SPEC_MAX_LIMIT}"})
            return self.journal(400, fingerprint, "")
        if "cursor" in q:
            decoded = read(q["cursor"])
            if decoded is None:
                self.reply(400, {"error": "invalid_cursor", "message": "cursor is malformed or was not issued by this server"})
                return self.journal(400, fingerprint, "")
            start, traversal = decoded
            cursor_key = digest(q["cursor"])
        else:
            start, traversal = 0, os.urandom(8).hex()
            cursor_key = ""
        action, candidate = b5_decide(traversal, cursor_key, start, fingerprint) if self.b5 else ("serve", False)
        if action == "throttle":
            body = {"error": "rate_limited", "message": "too many requests, retry after 1 second"}
            if TRACE is None:
                self.reply(429, body, retry_after=RETRY_AFTER)
            else:
                event = {"status": 429, "request": digest(q.get("cursor", "")),
                         "fingerprint": fingerprint, "retry": False, "retry_after": RETRY_AFTER}
                with TRACE_LOCK:
                    self.reply(429, body, retry_after=RETRY_AFTER)
                    trace_event(event)
            return self.journal(429, fingerprint, traversal, throttled=True, retry_candidate=candidate)
        if self.b1 and self.b2 and self.b4:
            # All three paging behaviours: the original paging, unchanged.
            size = min(limit, PAGE_CAP)                     # B4
            page = PAYOUTS[start:start + size]
            end = start + len(page)
            drained = end >= COUNT
            nxt = max(end - 1, 0)                           # B2: the next window starts at this page's last payout
            cursor = mint(nxt, traversal)
        else:
            size = min(limit, PAGE_CAP) if self.b4 else limit
            page = PAYOUTS[start:start + size]
            end = start + len(page)
            drained = end >= COUNT
            # B2 on: the next window starts at this page's last payout. Off: just after it.
            nxt = max(end - 1, 0) if self.b2 else end
            # B1 on: a fresh cursor on every response, the last included. Off: null once drained.
            cursor = mint(nxt, traversal) if self.b1 or not drained else None
        response = {"payouts": page, "cursor": cursor, "drained": drained}
        if TRACE is None:
            self.reply(200, response)
            return self.journal(200, fingerprint, traversal, matching_retry=action == "retry",
                                retry_candidate=candidate)
        # Serialize response completion and trace appends so the host can reject
        # branching or interleaving instead of guessing an order.
        with TRACE_LOCK:
            self.reply(200, response)
            event = {"status": 200, "request": digest(q.get("cursor", "")),
                     "fingerprint": fingerprint, "retry": action == "retry",
                     "response": digest(cursor),
                     "first": page[0]["id"] if page else "", "last": page[-1]["id"] if page else "",
                     "ids": [p["id"] for p in page], "count": len(page), "drained": drained}
            trace_event(event)
        return self.journal(200, fingerprint, traversal, matching_retry=action == "retry",
                            retry_candidate=candidate)

    def log_message(self, *args):
        pass


def behaviours_arg(raw):
    known = ("B1", "B2", "B4", "B5")
    tokens = [part.strip() for part in raw.split(",") if part.strip()]
    for token in tokens:
        if token not in known:
            raise argparse.ArgumentTypeError(f"unknown behaviour: {token}")
    return set(tokens)


def main():
    global TRACE, JOURNAL, JOURNAL_LIMIT
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--v1", choices=["on", "off"], default="on")
    ap.add_argument("--behaviours", type=behaviours_arg, help="comma-separated subset of B1,B2,B4,B5; omit for all")
    ap.add_argument("--trace", help="exclusive host-owned page trace file")
    ap.add_argument("--trace-client", help="only this client IPv4 may access an observed instance")
    ap.add_argument("--retry-journal", help="retry journal file, one JSON event per request")
    ap.add_argument("--retry-journal-limit", type=int, default=JOURNAL_LIMIT,
                    help="stop writing events after N, for tests")
    a = ap.parse_args()
    JOURNAL_LIMIT = a.retry_journal_limit
    if a.trace:
        fd = os.open(a.trace, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        TRACE = os.fdopen(fd, "w", encoding="utf-8")
    if bool(a.trace) != bool(a.trace_client):
        ap.error("--trace and --trace-client must be used together")
    if a.retry_journal:
        # Append mode: the harness truncates the file between phases and the held
        # descriptor must keep appending at the new end.
        fd = os.open(a.retry_journal, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        JOURNAL = os.fdopen(fd, "a", encoding="utf-8")
    Handler.v1_enabled = a.v1 == "on"
    Handler.trace_client = a.trace_client
    if a.behaviours is None:
        Handler.b1 = Handler.b2 = Handler.b4 = Handler.b5 = True
        behaviours = ""
    else:
        Handler.b1 = "B1" in a.behaviours
        Handler.b2 = "B2" in a.behaviours
        Handler.b4 = "B4" in a.behaviours
        Handler.b5 = "B5" in a.behaviours
        names = ",".join(name for name in ("B1", "B2", "B4", "B5") if name in a.behaviours)
        behaviours = f" behaviours {names or 'none'}"
    server = ThreadingHTTPServer((a.bind, a.port), Handler)
    print(f"payouts listening on {a.bind}:{a.port} (v1 {a.v1}){behaviours}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
