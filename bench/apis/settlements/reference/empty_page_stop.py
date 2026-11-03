"""Follows hasNextPage but stops on an empty page (B3)."""
import argparse, json, urllib.request

Q = "query($a: String) { settlements(first: 100, after: $a) { nodes { id batchDate amountCents currency status } pageInfo { endCursor hasNextPage } } }"

def page(url, after):
    body = json.dumps({"query": Q, "variables": {"a": after}}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        res = json.load(r)
    if res.get("errors"):
        raise RuntimeError(res["errors"])
    return res["data"]["settlements"]

def write(out, rows):
    with open(out, "w") as f:
        for s in rows:
            f.write(json.dumps(s) + "\n")

ap = argparse.ArgumentParser(); ap.add_argument("--base-url", required=True); ap.add_argument("--out", default="settlements.jsonl")
a = ap.parse_args(); U = a.base_url.rstrip("/") + "/v2/graphql"

rows, after = [], None
while True:
    p = page(U, after); rows += p["nodes"]; after = p["pageInfo"]["endCursor"]
    if not p["nodes"] or not p["pageInfo"]["hasNextPage"]:
        break
write(a.out, rows); print(f"reconciled {len(rows)} settlements")
