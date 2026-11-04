"""Settlements API (GraphQL), v1 and v2, for the Kalari benchmark. Never shown to an arm.

v1: POST /v1/graphql, `settlements: [Settlement!]!` returns every settlement.
v2: POST /v2/graphql, `settlements(first, after): SettlementConnection!`, modelled on real
delta and scan APIs (bench/README.md names them; the arms never see the names). Its behaviours:

  B1  `pageInfo.endCursor` is never null, the last page included; `hasNextPage` says whether
      more remain. Following the end cursor returns an empty page and a new cursor, forever.
  B2  amended settlements are emitted again later in the stream: first the version before the
      amendment, later the final one (the one v1 returns).
  B3  a page is `first` rows of the internal stream before voided rows are filtered out, so
      pages can be short or empty while `hasNextPage` is still true.
  B5  the first request of a traversal at or past offset 1000 gets HTTP 429 with
      `Retry-After: 1`. The identical request then succeeds. Each traversal gets one 429.
      The first response mints a traversal identity and carries it inside the opaque
      `after` cursor, so replaying a saved cursor continues that lineage.

Usage: server.py [--bind ADDR] [--port N] [--v1 on|off] [--behaviours B1,B2,B3,B5]
                  [--retry-journal PATH]

Omit --behaviours and B1, B2, B3, and B5 are all on. A comma-separated list enables only
those ids. Any other token is an error that names the token. A behaviour that is off does
the plain thing: B1 off, the last page's `endCursor` is null; B2 off, each settlement is
emitted once, in v1's version; B3 off, void rows are dropped before the page is cut;
B5 off, no request is throttled.

The retry journal is a JSON-lines file in the API guest with one event per request. The
harness truncates it at a phase start and reads it at a phase end over `msb exec`. It
carries a timestamp, a client digest, the HTTP status, the request fingerprint digest,
the traversal digest and whether the request was the matching retry. It never carries a
raw cursor, a raw request or a token. A wrong type or an overflow marker reads as
unknown, never as zero. The request fingerprint covers the exact query text, every
variable and the operation name, not only `after`.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "vendor", "graphql_core-3.3.1-py3-none-any.whl"))
sys.path.insert(0, os.path.join(HERE, "graphql_core-3.3.1-py3-none-any.whl"))  # when deployed flat
from graphql import GraphQLError, build_schema, graphql_sync, parse  # noqa: E402
from data import COUNT, PRELIMINARY, SETTLEMENTS, STREAM, VOID_RUN_EVERY, VOID_RUN_LENGTH  # noqa: E402

MAX_FIRST = 100
SECRET = os.urandom(16)
CLIENT_KEY = os.urandom(16)

COMMON = """
enum SettlementStatus { SETTLED PENDING ADJUSTED }
type Settlement {
  id: ID!
  batchDate: String!
  amountCents: Int!
  currency: String!
  status: SettlementStatus!
}
"""
SCHEMA_V1 = build_schema(COMMON + """
type Query {
  settlements: [Settlement!]!
}
""")
SCHEMA_V2 = build_schema(COMMON + """
type PageInfo {
  endCursor: String!
  hasNextPage: Boolean!
}
type SettlementConnection {
  nodes: [Settlement!]!
  pageInfo: PageInfo!
}
type Query {
  settlements(first: Int = 50, after: String): SettlementConnection!
}
""")
# B1 off: endCursor is null on the last page, so the field has to be nullable.
# B1 on keeps SCHEMA_V2, where endCursor is String!.
SCHEMA_V2_NULLABLE_CURSOR = build_schema(COMMON + """
type PageInfo {
  endCursor: String
  hasNextPage: Boolean!
}
type SettlementConnection {
  nodes: [Settlement!]!
  pageInfo: PageInfo!
}
type Query {
  settlements(first: Int = 50, after: String): SettlementConnection!
}
""")

# B2 on, B3 off: keep amendment repeats, drop void rows before paging.
STREAM_NO_VOID = [row for row in STREAM if row[0] != "void"]


def _final_with_voids():
    # B2 off, B3 on: v1's version once, void runs on the same settlement boundaries, no repeats.
    out = []
    for i in range(COUNT):
        out.append(("s", i))
        if i % VOID_RUN_EVERY == VOID_RUN_EVERY - 1:
            out.extend(("void", k) for k in range(VOID_RUN_LENGTH))
    return out


FINAL_WITH_VOIDS = _final_with_voids()
# B2 off, B3 off: v1's version once, in order.
FINAL_ONLY = [("s", i) for i in range(COUNT)]

B1 = True
B2 = True
B3 = True
B5 = True

# B5: one throttled request per traversal, at a fixed mid-stream offset.
# Both maps are capped. A traversal that falls out of the cap can see a second
# 429, which is better than growing without bound.
B5_OFFSET = 1000
B5_STATE_LIMIT = 4096
B5_LOCK = threading.Lock()
B5_PENDING = {}     # traversal -> {"cursor": incoming cursor digest, "request": fingerprint}
B5_CLEARED = {}     # traversals that already retried successfully

JOURNAL = None
JOURNAL_LOCK = threading.Lock()
JOURNAL_LIMIT = 100000
JOURNAL_COUNT = 0

# The traversal decided for this request, so the resolver mints the same lineage.
REQUEST = threading.local()


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()[:32] if value else ""


def mint(pos: int, traversal: str) -> str:
    body = base64.urlsafe_b64encode(
        json.dumps({"p": pos, "t": time.time_ns(), "v": traversal}).encode()
    ).decode().rstrip("=")
    return f"{body}.{hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()[:16]}"


def read(token: str):
    """Return (position, traversal) for a cursor this server minted, else None."""
    try:
        body, sig = token.rsplit(".", 1)
        if not hmac.compare_digest(sig, hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()[:16]):
            return None
        doc = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
        return int(doc["p"]), str(doc["v"])
    except Exception:
        return None


def request_fingerprint(method, path, query, variables, operation):
    """Digest of the complete canonical request: exact query, every variable, operation."""
    canon = json.dumps(
        [method, path, query, variables, operation],
        sort_keys=True, separators=(",", ":"), default=str,
    )
    return hashlib.sha256(canon.encode()).hexdigest()[:32]


def settlements_arguments(query, variables, operation_name):
    """Resolve the settlements field's arguments, following fragments.

    Returns `(has_field, arguments)`. `has_field` is False when the document has
    no settlements field. `arguments` is None when a field is present but this
    parser cannot resolve it, so the caller rejects the request instead of
    treating it as a fresh traversal.
    """
    doc = parse(query)
    ops = [d for d in doc.definitions if getattr(d, "kind", "") == "operation_definition"]
    if operation_name:
        ops = [d for d in ops if getattr(getattr(d, "name", None), "value", None) == operation_name]
    fragments = {}
    for d in doc.definitions:
        if getattr(d, "kind", "") != "fragment_definition":
            continue
        name = getattr(getattr(d, "name", None), "value", None)
        if name:
            fragments[name] = d
    fields = []
    seen = set()

    def walk(selection_set):
        if selection_set is None:
            return
        for sel in selection_set.selections:
            kind = getattr(sel, "kind", "")
            if kind == "field":
                if sel.name.value == "settlements":
                    fields.append(sel)
            elif kind == "inline_fragment":
                walk(getattr(sel, "selection_set", None))
            elif kind == "fragment_spread":
                name = getattr(getattr(sel, "name", None), "value", None)
                if name in fragments and name not in seen:
                    seen.add(name)
                    walk(fragments[name].selection_set)

    if len(ops) == 1:
        walk(ops[0].selection_set)
    else:
        for op in ops:
            walk(op.selection_set)
        if fields:
            return True, None
    if not fields:
        return False, {}
    # Several settlements fields can only come from fragments. Use the one that
    # carries `after`, the field that decides the traversal offset.
    chosen = next(
        (f for f in fields if any(a.name.value == "after" for a in f.arguments)),
        fields[0],
    )
    found = {}
    for arg in chosen.arguments:
        name, value = arg.name.value, arg.value
        kind = getattr(value, "kind", "")
        if kind == "variable":
            found[name] = (variables or {}).get(value.name.value)
        elif kind == "string_value":
            found[name] = value.value
        elif kind == "int_value":
            found[name] = int(value.value)
        elif kind == "null_value":
            found[name] = None
        else:
            return True, None
    return True, found


def b5_decide(traversal, cursor_key, offset, fingerprint):
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
                    B5_CLEARED.pop(next(iter(B5_CLEARED)))
                return "retry", True
            # A changed query or changed variables does not count as the identical retry.
            return "throttle", candidate
        if offset >= B5_OFFSET:
            if len(B5_PENDING) >= B5_STATE_LIMIT:
                B5_PENDING.pop(next(iter(B5_PENDING)))
            B5_PENDING[traversal] = {"cursor": cursor_key, "request": fingerprint}
            return "throttle", False
        return "serve", False


def client_tag(address):
    # Phase-safe: a keyed digest, never an address, and not reversible without the key.
    return hmac.new(CLIENT_KEY, address.encode(), hashlib.sha256).hexdigest()[:16]


def v1_settlements(_info):  # graphql-core calls a callable root value as fn(info, **args)
    return SETTLEMENTS


def v2_settlements(_info, first=50, after=None):
    if first is None or not 1 <= first <= MAX_FIRST:
        raise GraphQLError(f"first must be between 1 and {MAX_FIRST}")
    start = 0
    traversal = ""
    if after is not None:
        decoded = read(after)
        if decoded is None:
            raise GraphQLError("after is malformed or was not issued by this server")
        start, traversal = decoded
    state = getattr(REQUEST, "state", None)
    if state and state.get("traversal"):
        traversal = state["traversal"]
    if not traversal:
        traversal = os.urandom(8).hex()
    if B1 and B2 and B3:
        # All three behaviours: the original paging, unchanged.
        window = STREAM[start:start + first]                         # B3: page first, then filter
        nodes = [PRELIMINARY[i] if kind == "pre" else SETTLEMENTS[i]   # B2: the first copy of an amended
                 for kind, i in window if kind != "void"]               # settlement is the old version
        end = start + len(window)
        return {"nodes": nodes, "pageInfo": {"endCursor": mint(end, traversal), "hasNextPage": end < len(STREAM)}}  # B1
    if B2 and B3:
        rows = STREAM
    elif B2:
        rows = STREAM_NO_VOID
    elif B3:
        rows = FINAL_WITH_VOIDS
    else:
        rows = FINAL_ONLY
    window = rows[start:start + first]                           # B3 on: voids are still in the window
    nodes = [PRELIMINARY[i] if kind == "pre" else SETTLEMENTS[i]
             for kind, i in window if kind != "void"]
    end = start + len(window)
    has_next = end < len(rows)
    # B1 on: endCursor is never null. Off: null once nothing remains.
    end_cursor = mint(end, traversal) if B1 or has_next else None
    return {"nodes": nodes, "pageInfo": {"endCursor": end_cursor, "hasNextPage": has_next}}


class Handler(BaseHTTPRequestHandler):
    v1_enabled = True

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
        self.reply(405, {"errors": [{"message": "use POST with a JSON body: {\"query\": ..., \"variables\": ...}"}]})
        return self.journal(405, request_fingerprint("GET", self.path, "", None, None), "", api="other")

    def do_POST(self):
        if self.path == "/v1/graphql":
            if not self.v1_enabled:
                self.reply(410, {"errors": [{"message": "API v1 has been retired. Use /v2/graphql."}]})
                return self.journal(410, request_fingerprint("POST", self.path, "", None, None), "", api="v1")
            return self.execute(SCHEMA_V1, {"settlements": v1_settlements}, "v1")
        if self.path == "/v2/graphql":
            return self.execute(SCHEMA_V2 if B1 else SCHEMA_V2_NULLABLE_CURSOR,
                                {"settlements": v2_settlements}, "v2")
        self.reply(404, {"errors": [{"message": "not found"}]})
        return self.journal(404, request_fingerprint("POST", self.path, "", None, None), "", api="other")

    def execute(self, schema, root, api):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(min(n, 1 << 20)) or b"{}")
            query = req["query"]
            if not isinstance(query, str):
                raise ValueError("query must be a string")
        except Exception:
            self.reply(400, {"errors": [{"message": "body must be JSON with a query string"}]})
            return self.journal(400, request_fingerprint("POST", self.path, "", None, None), "", api=api)
        variables = req.get("variables")
        if variables is not None and not isinstance(variables, dict):
            variables = None
        operation = req.get("operationName")
        fingerprint = request_fingerprint("POST", self.path, query, variables, operation)
        action, traversal, cursor_key, candidate = "serve", "", "", False
        if api == "v2":
            try:
                has_field, args = settlements_arguments(query, variables, operation)
            except Exception:
                has_field, args = False, {}
            if has_field and args is None:
                self.reply(400, {"errors": [{"message": "could not resolve the settlements field arguments"}]})
                return self.journal(400, fingerprint, "", api=api)
            after = (args or {}).get("after")
            decoded = read(after) if isinstance(after, str) and after else None
            # A malformed cursor is the resolver's GraphQL error, not a throttle.
            malformed = isinstance(after, str) and bool(after) and decoded is None
            if decoded is not None:
                offset, traversal = decoded
                cursor_key = digest(after)
            else:
                offset, traversal = 0, os.urandom(8).hex()
            if B5 and not malformed:
                action, candidate = b5_decide(traversal, cursor_key, offset, fingerprint)
        if action == "throttle":
            self.reply(429, {"errors": [{"message": "too many requests, retry after 1 second"}]}, retry_after="1")
            return self.journal(429, fingerprint, traversal, throttled=True, retry_candidate=candidate, api=api)
        REQUEST.state = {"traversal": traversal}
        try:
            result = graphql_sync(schema, query, root_value=root, variable_values=variables,
                                  operation_name=operation)
        finally:
            REQUEST.state = None
        out = {}
        if result.errors:
            out["errors"] = [e.formatted for e in result.errors]
        if result.data is not None:
            out["data"] = result.data
        self.reply(200, out)
        return self.journal(200, fingerprint, traversal, matching_retry=action == "retry",
                            retry_candidate=candidate, api=api)

    def log_message(self, *args):
        pass


def behaviours_arg(raw):
    known = ("B1", "B2", "B3", "B5")
    tokens = [part.strip() for part in raw.split(",") if part.strip()]
    for token in tokens:
        if token not in known:
            raise argparse.ArgumentTypeError(f"unknown behaviour: {token}")
    return set(tokens)


def main():
    global B1, B2, B3, B5, JOURNAL, JOURNAL_LIMIT
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=18081)
    ap.add_argument("--v1", choices=["on", "off"], default="on")
    ap.add_argument("--behaviours", type=behaviours_arg, help="comma-separated subset of B1,B2,B3,B5; omit for all")
    ap.add_argument("--retry-journal", help="retry journal file, one JSON event per request")
    ap.add_argument("--retry-journal-limit", type=int, default=JOURNAL_LIMIT,
                    help="stop writing events after N, for tests")
    a = ap.parse_args()
    JOURNAL_LIMIT = a.retry_journal_limit
    if a.retry_journal:
        # Append mode: the harness truncates the file between phases and the held
        # descriptor must keep appending at the new end.
        fd = os.open(a.retry_journal, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        JOURNAL = os.fdopen(fd, "a", encoding="utf-8")
    if a.behaviours is None:
        B1 = B2 = B3 = B5 = True
        behaviours = ""
    else:
        B1 = "B1" in a.behaviours
        B2 = "B2" in a.behaviours
        B3 = "B3" in a.behaviours
        B5 = "B5" in a.behaviours
        names = ",".join(name for name in ("B1", "B2", "B3", "B5") if name in a.behaviours)
        behaviours = f" behaviours {names or 'none'}"
    Handler.v1_enabled = a.v1 == "on"
    print(f"settlements listening on {a.bind}:{a.port} (v1 {a.v1}; {COUNT} settlements, stream {len(STREAM)}){behaviours}", flush=True)
    ThreadingHTTPServer((a.bind, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
