"""A payouts consumer for the containment run. It is constructed for the test.

It honours Retry-After on a 429 (sleep, then repeat the same request) and it
keeps the end-of-stream bug: it follows the cursor on every response and never
looks at the `drained` flag, so it does not stop. It prints one line per page.
"""
import argparse, json, sys, time, urllib.error, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--base-url", required=True)
ap.add_argument("--out", default="payouts.jsonl")
a = ap.parse_args()
base = a.base_url.rstrip("/")

rows, cursor, page = [], None, 0
while True:
    url = f"{base}/v2/payouts" + (f"?cursor={cursor}" if cursor else "")
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            body = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code != 429:
            raise
        wait = int(e.headers.get("Retry-After", "1"))
        print(f"page {page + 1}: 429 too many requests, waiting {wait} s then repeating it", flush=True)
        time.sleep(wait)
        continue
    page += 1
    rows += body["payouts"]
    cursor = body.get("cursor")
    print(f"page {page}: {len(body['payouts'])} payouts, drained {str(body.get('drained')).lower()}, cursor {str(cursor)[-8:]}", flush=True)
    time.sleep(0.05)  # a polite pause between pages
    # The bug: no check of body["drained"], and the cursor is never absent.
    if not cursor:
        break
with open(a.out, "w") as f:
    for p in rows:
        f.write(json.dumps(p) + "\n")
print(f"synced {len(rows)} payouts")
