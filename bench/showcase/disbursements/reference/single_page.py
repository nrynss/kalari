"""Requests one window and stops: 100 of 2,341 disbursements."""
import argparse, json, urllib.request

ap = argparse.ArgumentParser(); ap.add_argument("--base-url", required=True); ap.add_argument("--out", default="disbursements.jsonl")
a = ap.parse_args()
with urllib.request.urlopen(f"{a.base_url.rstrip('/')}/v2/disbursements?limit=100", timeout=30) as r:
    rows = json.load(r)["disbursements"]
with open(a.out, "w") as f:
    for d in rows:
        f.write(json.dumps(d) + "\n")
print(f"synced {len(rows)} disbursements")
