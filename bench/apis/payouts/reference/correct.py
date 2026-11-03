"""Stops on drained, dedupes on id, ignores window size."""
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

rows, seen, cursor = [], set(), None
while True:
    r = get(f"{B}/v2/payouts?limit=1000" + (f"&cursor={cursor}" if cursor else ""))
    for p in r["payouts"]:
        if p["id"] not in seen:
            seen.add(p["id"]); rows.append(p)
    cursor = r["cursor"]
    if r["drained"]:
        break
write(a.out, rows); print(f"synced {len(rows)} payouts")
