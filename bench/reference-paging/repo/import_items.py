"""Import every item from the items API into items.jsonl. Written for API v1."""
import json, sys, urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"

def main():
    with urllib.request.urlopen(f"{BASE}/items") as resp:
        items = json.load(resp)["items"]
    with open("items.jsonl", "w") as out:
        for item in items:
            out.write(json.dumps(item) + "\n")
    print(f"imported {len(items)} items")

if __name__ == "__main__":
    main()
