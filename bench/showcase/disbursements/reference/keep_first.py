"""Follows the cursor until drained, keeps the first delivery per id (the unadjusted amount)."""
import argparse, json, urllib.request


def window(base, cursor):
    url = f"{base}/v2/disbursements?limit=100" + (f"&cursor={cursor}" if cursor else "")
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


ap = argparse.ArgumentParser(); ap.add_argument("--base-url", required=True); ap.add_argument("--out", default="disbursements.jsonl")
a = ap.parse_args(); base = a.base_url.rstrip("/")

seen, rows, cursor = set(), [], None
while True:
    w = window(base, cursor)
    for d in w["disbursements"]:
        if d["id"] not in seen:
            seen.add(d["id"])
            rows.append(d)
    cursor = w["cursor"]
    if w["drained"]:
        break
with open(a.out, "w") as f:
    for d in rows:
        f.write(json.dumps(d) + "\n")
print(f"synced {len(rows)} disbursements")
