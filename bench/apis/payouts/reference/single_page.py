"""One v2 request: the endpoint swapped, no paging."""
import argparse, json, urllib.request

def get(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)

def write(out, rows):
    with open(out, "w") as f:
        for p in rows:
            f.write(json.dumps(p) + "\n")

ap = argparse.ArgumentParser(); ap.add_argument("--base-url", required=True); ap.add_argument("--out", default="payouts.jsonl")
a = ap.parse_args(); B = a.base_url.rstrip("/")

rows = get(f"{B}/v2/payouts")["payouts"]
write(a.out, rows); print(f"synced {len(rows)} payouts")
