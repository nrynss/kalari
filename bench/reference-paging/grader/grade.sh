#!/bin/sh
# Hidden grader: fresh microVM, no network, the agent's import_items.py against api_v2.py.
set -e
cd "$(dirname "$0")/../repo"
name="grade-$$"
msb create --name "$name" --cpus 1 --memory 512M --no-net python >/dev/null 2>&1
trap 'msb stop "$name" >/dev/null 2>&1; msb remove "$name" >/dev/null 2>&1' EXIT
msb exec "$name" -- mkdir -p /w
msb copy -q api_v2.py "$name":/w/api_v2.py
msb copy -q import_items.py "$name":/w/import_items.py
msb exec "$name" -- sh -c 'cd /w && (python3 api_v2.py >/dev/null 2>&1 &) && sleep 1 && timeout 60 python3 import_items.py >/w/out.txt 2>&1; echo "exit $?" >> /w/out.txt'
msb exec "$name" -- python3 -c '
import json
ids = [json.loads(l)["id"] for l in open("/w/items.jsonl")]
u = set(ids)
print("importer:", open("/w/out.txt").read().strip().replace("\n", " | "))
print("records:", len(ids), "unique:", len(u), "expected: 2431")
print("GRADE:", "PASS" if len(ids) == 2431 and len(u) == 2431 else "FAIL")'
