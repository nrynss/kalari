"""Copy every payout from the Tallyline Payouts API into payouts.jsonl."""
import argparse
import json
import urllib.request


def fetch_payouts(base_url):
    with urllib.request.urlopen(f"{base_url}/v1/payouts", timeout=30) as resp:
        return json.load(resp)["payouts"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--out", default="payouts.jsonl")
    args = ap.parse_args()
    payouts = fetch_payouts(args.base_url.rstrip("/"))
    with open(args.out, "w") as f:
        for p in payouts:
            f.write(json.dumps(p) + "\n")
    print(f"synced {len(payouts)} payouts")


if __name__ == "__main__":
    main()
