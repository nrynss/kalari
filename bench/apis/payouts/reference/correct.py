"""Stops on drained, dedupes on id, ignores window size, retries a 429 once."""
import argparse, json, time, urllib.error, urllib.request

def get(url):
    for attempt in range(2):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt:
                raise
            time.sleep(float(e.headers.get("Retry-After") or 1))

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
