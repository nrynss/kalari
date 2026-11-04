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

Usage: server.py [--bind ADDR] [--port N] [--v1 on|off] [--behaviours B1,B2,B3]

Omit --behaviours and B1, B2, and B3 are all on. A comma-separated list enables only
those ids. Any other token, including B5, is an error that names the token. A behaviour
that is off does the plain thing: B1 off, the last page's `endCursor` is null; B2 off,
each settlement is emitted once, in v1's version; B3 off, void rows are dropped before
the page is cut.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "vendor", "graphql_core-3.3.1-py3-none-any.whl"))
sys.path.insert(0, os.path.join(HERE, "graphql_core-3.3.1-py3-none-any.whl"))  # when deployed flat
from graphql import GraphQLError, build_schema, graphql_sync  # noqa: E402
from data import COUNT, PRELIMINARY, SETTLEMENTS, STREAM, VOID_RUN_EVERY, VOID_RUN_LENGTH  # noqa: E402

MAX_FIRST = 100
SECRET = os.urandom(16)

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


def mint(pos: int) -> str:
    body = base64.urlsafe_b64encode(json.dumps({"p": pos, "t": time.time_ns()}).encode()).decode().rstrip("=")
    return f"{body}.{hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()[:16]}"


def read(token: str):
    try:
        body, sig = token.rsplit(".", 1)
        if not hmac.compare_digest(sig, hmac.new(SECRET, body.encode(), hashlib.sha256).hexdigest()[:16]):
            return None
        return int(json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))["p"])
    except Exception:
        return None


def v1_settlements(_info):  # graphql-core calls a callable root value as fn(info, **args)
    return SETTLEMENTS


def v2_settlements(_info, first=50, after=None):
    if first is None or not 1 <= first <= MAX_FIRST:
        raise GraphQLError(f"first must be between 1 and {MAX_FIRST}")
    start = 0
    if after is not None:
        start = read(after)
        if start is None:
            raise GraphQLError("after is malformed or was not issued by this server")
    if B1 and B2 and B3:
        # All three behaviours: the original paging, unchanged.
        window = STREAM[start:start + first]                         # B3: page first, then filter
        nodes = [PRELIMINARY[i] if kind == "pre" else SETTLEMENTS[i]   # B2: the first copy of an amended
                 for kind, i in window if kind != "void"]               # settlement is the old version
        end = start + len(window)
        return {"nodes": nodes, "pageInfo": {"endCursor": mint(end), "hasNextPage": end < len(STREAM)}}  # B1
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
    end_cursor = mint(end) if B1 or has_next else None
    return {"nodes": nodes, "pageInfo": {"endCursor": end_cursor, "hasNextPage": has_next}}


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
        self.reply(405, {"errors": [{"message": "use POST with a JSON body: {\"query\": ..., \"variables\": ...}"}]})

    def do_POST(self):
        if self.path == "/v1/graphql":
            if not self.v1_enabled:
                return self.reply(410, {"errors": [{"message": "API v1 has been retired. Use /v2/graphql."}]})
            schema, root = SCHEMA_V1, {"settlements": v1_settlements}
        elif self.path == "/v2/graphql":
            schema = SCHEMA_V2 if B1 else SCHEMA_V2_NULLABLE_CURSOR
            root = {"settlements": v2_settlements}
        else:
            return self.reply(404, {"errors": [{"message": "not found"}]})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(min(n, 1 << 20)) or b"{}")
            query = req["query"]
        except Exception:
            return self.reply(400, {"errors": [{"message": "body must be JSON with a query string"}]})
        result = graphql_sync(schema, query, root_value=root, variable_values=req.get("variables"),
                              operation_name=req.get("operationName"))
        out = {}
        if result.errors:
            out["errors"] = [e.formatted for e in result.errors]
        if result.data is not None:
            out["data"] = result.data
        self.reply(200, out)

    def log_message(self, *args):
        pass


def behaviours_arg(raw):
    known = ("B1", "B2", "B3")
    tokens = [part.strip() for part in raw.split(",") if part.strip()]
    for token in tokens:
        if token not in known:
            raise argparse.ArgumentTypeError(f"unknown behaviour: {token}")
    return set(tokens)


def main():
    global B1, B2, B3
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=18081)
    ap.add_argument("--v1", choices=["on", "off"], default="on")
    ap.add_argument("--behaviours", type=behaviours_arg, help="comma-separated subset of B1,B2,B3; omit for all")
    a = ap.parse_args()
    if a.behaviours is None:
        B1 = B2 = B3 = True
        behaviours = ""
    else:
        B1 = "B1" in a.behaviours
        B2 = "B2" in a.behaviours
        B3 = "B3" in a.behaviours
        names = ",".join(name for name in ("B1", "B2", "B3") if name in a.behaviours)
        behaviours = f" behaviours {names or 'none'}"
    Handler.v1_enabled = a.v1 == "on"
    print(f"settlements listening on {a.bind}:{a.port} (v1 {a.v1}; {COUNT} settlements, stream {len(STREAM)}){behaviours}", flush=True)
    ThreadingHTTPServer((a.bind, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
