"""First rehearsal attempt: stops after the first page.

It runs and writes settlements.jsonl, but it never follows hasNextPage, so the
output misses most settlements. The rehearsal uses it to prove that the graded
first-attempt source is the source that ran first, not the corrected consumer
that replaced it.
"""
import argparse
import json
import urllib.request

QUERY = (
    "query($a: String) { settlements(first: 100, after: $a) "
    "{ nodes { id batchDate amountCents currency status } "
    "pageInfo { endCursor hasNextPage } } }"
)

ap = argparse.ArgumentParser()
ap.add_argument("--base-url", required=True)
ap.add_argument("--out", default="settlements.jsonl")
args = ap.parse_args()

url = args.base_url.rstrip("/") + "/v2/graphql"
body = json.dumps({"query": QUERY, "variables": {"a": None}}).encode()
req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=30) as response:
    page = json.load(response)["data"]["settlements"]
with open(args.out, "w") as f:
    for settlement in page["nodes"]:
        f.write(json.dumps(settlement) + "\n")
print(f"wrote {len(page['nodes'])} settlements without following hasNextPage")
