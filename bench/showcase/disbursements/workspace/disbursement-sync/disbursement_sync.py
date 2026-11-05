"""Copy every disbursement from the Meridian Disbursements API into disbursements.jsonl."""
import argparse
import json
import urllib.request


def fetch_disbursements(base_url):
    with urllib.request.urlopen(f"{base_url}/v1/disbursements", timeout=30) as resp:
        return json.load(resp)["disbursements"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--out", default="disbursements.jsonl")
    args = ap.parse_args()
    disbursements = fetch_disbursements(args.base_url.rstrip("/"))
    with open(args.out, "w") as f:
        for d in disbursements:
            f.write(json.dumps(d) + "\n")
    print(f"synced {len(disbursements)} disbursements")


if __name__ == "__main__":
    main()
