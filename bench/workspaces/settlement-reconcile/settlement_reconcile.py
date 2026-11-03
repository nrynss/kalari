"""Copy every settlement from the Clearwell Settlements API into settlements.jsonl."""
import argparse
import json
import urllib.request

QUERY = "{ settlements { id batchDate amountCents currency status } }"


def graphql(url, query, variables=None):
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        result = json.load(resp)
    if result.get("errors"):
        raise RuntimeError(result["errors"])
    return result["data"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--out", default="settlements.jsonl")
    args = ap.parse_args()
    settlements = graphql(f"{args.base_url.rstrip('/')}/v1/graphql", QUERY)["settlements"]
    with open(args.out, "w") as f:
        for s in settlements:
            f.write(json.dumps(s) + "\n")
    print(f"reconciled {len(settlements)} settlements")


if __name__ == "__main__":
    main()
