"""Run Vimanam on generated spec pairs and print Markdown result tables for the issues.

Usage: python3 -I matrix.py <vimanam-2.0.0> <vimanam-main> <outdir>
"""
import json, re, subprocess, sys
from pathlib import Path

V2, VMAIN, OUT = sys.argv[1], sys.argv[2], Path(sys.argv[3])
OUT.mkdir(parents=True, exist_ok=True)

ITEM = {"type": "object", "required": ["id"], "properties": {"id": {"type": "string"}}}


def openapi(version, path, op_id, params=(), cont=None, server="https://api.example.test"):
    props = {"items": {"type": "array", "items": {"$ref": "#/components/schemas/Item"}}}
    if cont:
        if "." in cont:
            outer, inner = cont.split(".", 1)
            props[outer] = {"type": "object", "properties": {inner: {"type": "string"}}}
        else:
            props[cont] = {"type": "string"}
    op = {"operationId": op_id, "responses": {"200": {"description": "ok", "content": {"application/json": {
        "schema": {"type": "object", "properties": props}}}}}}
    if params:
        op["parameters"] = [{"name": n, "in": "query", "schema": {"type": "integer" if n in ("limit", "page_size", "pageSize", "size") else "string"}} for n in params]
    return json.dumps({"openapi": "3.0.3", "info": {"title": "Items", "version": version}, "servers": [{"url": server}],
                       "paths": {path: {"get": op}}, "components": {"schemas": {"Item": ITEM}}}, indent=1)


def run(vimanam, old, new, name, ext):
    o, n = OUT / f"{name}-v1.{ext}", OUT / f"{name}-v2.{ext}"
    o.write_text(old); n.write_text(new)
    p = subprocess.run([vimanam, "diff", str(o), str(n), "--format", "json"], capture_output=True, text=True)
    if p.returncode not in (0, 3):
        return f"error: {p.stderr.strip().splitlines()[-1][:80]}"
    kinds = [c["kind"] for c in json.loads(p.stdout)["changes"]]
    (OUT / f"{name}.json").write_text(p.stdout)
    native = [c.get("native_kind", "") for c in json.loads(p.stdout)["changes"] if c["kind"] == "pagination_changed"]
    return kinds, native


# --- Issue 1: operations moving across version prefixes (2.0.0) ---
print("## Matrix 1: version prefixes (Vimanam 2.0.0)\n")
print("v1: `GET` returns `{items: [Item]}`, no paging. v2: adds `cursor` and `limit` query parameters and a `next_cursor` response field, which on an unchanged path is detected.\n")
print("| Case | v1 path | v2 path | operationId | Change kinds | `pagination_changed` |")
print("|---|---|---|---|---|---|")
cases1 = [
    ("control: same path", "/items", "/items", "listItems", "listItems", "https://api.example.test"),
    ("version in the path", "/v1/items", "/v2/items", "listItems", "listItems", "https://api.example.test"),
    ("version in the path, under /api", "/api/v1/items", "/api/v2/items", "listItems", "listItems", "https://api.example.test"),
    ("version in the path, operationId changed", "/v1/items", "/v2/items", "listItems", "exportItems", "https://api.example.test"),
    ("version in the server URL", "/items", "/items", "listItems", "listItems", None),
]
for label, p1, p2, id1, id2, server in cases1:
    s1 = server or "https://api.example.test/v1"; s2 = server or "https://api.example.test/v2"
    old = openapi("1.0.0", p1, id1, server=s1)
    new = openapi("2.0.0", p2, id2, params=("cursor", "limit"), cont="next_cursor", server=s2)
    r = run(V2, old, new, "m1-" + re.sub(r"[^a-z0-9]+", "-", label), "json")
    if isinstance(r, str): print(f"| {label} | | | | {r} | |"); continue
    kinds, native = r
    print(f"| {label} | `{p1}` | `{p2}` | `{id1}` → `{id2}` | {', '.join(kinds)} | {'**yes**' if native else 'no'} |")

# --- Issue 2: continuation field names (2.0.0), same path ---
print("\n## Matrix 2: continuation fields and request controls (Vimanam 2.0.0)\n")
print("Same path `/items` in both. v1 returns `{items: [Item]}`. v2 adds the request parameters and the response field shown.\n")
print("| Response continuation field | Request parameters | Seen in (examples) | `pagination_changed` |")
print("|---|---|---|---|")
cases2 = [
    ("next_cursor", ("cursor", "limit"), "Slack (`response_metadata.next_cursor` is nested; flat here)"),
    ("nextCursor", ("cursor", "limit"), ""),
    ("next_page_token", ("page_token", "page_size"), "Google APIs (`nextPageToken`)"),
    ("next_page", ("page",), "Zendesk incremental export"),
    ("cursor", ("cursor", "limit"), "many cursor APIs"),
    ("next", ("cursor", "limit"), "many REST APIs"),
    ("after_cursor", ("cursor", "limit"), "Zendesk cursor export"),
    ("after", ("cursor", "limit"), ""),
    ("continuation_token", ("cursor", "limit"), ""),
    ("continuationToken", ("cursor", "limit"), "Azure (`continuationToken`)"),
    ("nextLink", ("cursor", "limit"), "Azure REST"),
    ("@odata.nextLink", ("cursor", "limit"), "Microsoft Graph"),
    ("LastEvaluatedKey", ("cursor", "limit"), "DynamoDB"),
    ("response_metadata.next_cursor", ("cursor", "limit"), "Slack (nested)"),
    ("links.next", ("cursor", "limit"), "JSON:API"),
    ("next_cursor", ("starting_after", "limit"), "Stripe-style request control"),
    ("next_cursor", ("after", "limit"), "`after` as the request control"),
]
for cont, params, seen in cases2:
    old = openapi("1.0.0", "/items", "listItems")
    new = openapi("2.0.0", "/items", "listItems", params=params, cont=cont)
    r = run(V2, old, new, "m2-" + re.sub(r"[^A-Za-z0-9]+", "-", cont + "-" + "-".join(params)), "json")
    if isinstance(r, str): print(f"| `{cont}` | | {seen} | {r} |"); continue
    kinds, native = r
    print(f"| `{cont}` | `{'`, `'.join(params)}` | {seen} | {'**yes**' if native else 'no'} |")

# --- Issue 3: GraphQL connection shapes (main) ---
print("\n## Matrix 3: GraphQL connection shapes (Vimanam `main` at 491b02c)\n")
print("v1: `items: [Item!]!`. v2: `items(<args>): ItemConnection!` with the connection fields shown.\n")
print("| Connection fields | Arguments | Seen in (examples) | Change kinds | `pagination_changed` |")
print("|---|---|---|---|---|")
G1 = "type Item { id: ID! }\ntype Query { items: [Item!]! }\n"
PI = "type PageInfo { endCursor: String hasNextPage: Boolean! }\n"
EDGE = "type ItemEdge { node: Item! cursor: String! }\n"
cases3 = [
    ("edges, pageInfo", "edges: [ItemEdge!]! pageInfo: PageInfo!", "first: Int, after: String", "Relay spec", True),
    ("nodes, pageInfo", "nodes: [Item!]! pageInfo: PageInfo!", "first: Int, after: String", "GitHub (`nodes` shortcut), many APIs", False),
    ("edges, nodes, pageInfo", "edges: [ItemEdge!]! nodes: [Item!]! pageInfo: PageInfo!", "first: Int, after: String", "GitHub", True),
    ("edges, pageInfo (backward)", "edges: [ItemEdge!]! pageInfo: PageInfo!", "last: Int, before: String", "Relay spec", True),
    ("nodes, pageInfo, totalCount", "nodes: [Item!]! pageInfo: PageInfo! totalCount: Int!", "first: Int, after: String", "", False),
    ("items, nextCursor", "items: [Item!]! nextCursor: String", "limit: Int, cursor: String", "non-Relay cursor pages", False),
    ("edges, no pageInfo", "edges: [ItemEdge!]!", "first: Int, after: String", "", True),
]
for label, fields, args, seen, needs_edge in cases3:
    new = "type Item { id: ID! }\n" + PI + (EDGE if needs_edge else "") + f"type ItemConnection {{ {fields} }}\ntype Query {{ items({args}): ItemConnection! }}\n"
    r = run(VMAIN, G1, new, "m3-" + re.sub(r"[^a-z0-9]+", "-", label), "graphql")
    if isinstance(r, str):
        print(f"| {label} | `{args}` | {seen} | {r} | — |"); continue
    kinds, native = r
    print(f"| `{label}` | `{args}` | {seen} | {', '.join(kinds)} | {'**yes** (' + native[0] + ')' if native else 'no'} |")
