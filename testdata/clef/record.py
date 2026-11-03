"""Record Clef's /v1/systemone answers on benchmark cases, for Kalari's Clef client (T3.3) to replay.

Usage: VULTR_INFERENCE_API_KEY=... python3 -I record.py <outdir>
Writes <case>.request.json and <case>.response.json. The key is sent in a header and never written.
Each case's `expect` is what a correct answer looks like; it isn't sent.
"""
import json, os, sys, time, urllib.request
from pathlib import Path

OUT = Path(sys.argv[1]); OUT.mkdir(parents=True, exist_ok=True)
URL = "https://api.vultrinference.com/v1/systemone"
KEY = os.environ["VULTR_INFERENCE_API_KEY"]

FAILURE = {
    "type": "choice",
    "instructions": "Why did this run fail?",
    "criteria": {
        "api_change": "the consumer does not handle the API change",
        "test_setup": "our test environment, network allowlist or fixtures are wrong",
        "flaky": "a transient or timing failure that would pass on retry",
        "unrelated_bug": "a bug in the consumer unrelated to the API change",
    },
}
CHANGE_PAYOUTS = ("GET /v2/payouts replaces GET /v1/payouts. v1 returned every payout in one response. v2 returns a window "
                  "of payouts with a cursor and a drained flag; windows overlap by one payout; limit is at most 1000 but a "
                  "response may hold fewer.")
CHANGE_SETTLEMENTS = ("Query.settlements changed from [Settlement!]! to a connection settlements(first, after): nodes plus "
                      "pageInfo { endCursor: String!, hasNextPage }.")
LESSON = ("When a list endpoint starts paging, stop on the end flag (drained or hasNextPage false), never on the "
          "cursor's presence or on a short or empty page; deduplicate records by id. Check: exact count against v1, zero duplicate ids.")

CASES = [
    # failure_cause: one question per case, realistic run evidence
    ("failure-api-change-duplicates", "api_change", {
        "change": CHANGE_PAYOUTS,
        "run": {"verdict": "exited", "exit_code": 0, "stdout": "synced 2455 payouts",
                "check": "every payout exactly once, compared with v1",
                "check_result": "failed: 2455 records, 2431 unique, 24 duplicate ids (po_00100, po_00199, ...)"},
        "code": "while True:\n    r = get(f'{B}/v2/payouts' + (f'?cursor={cursor}' if cursor else ''))\n    rows += r['payouts']; cursor = r['cursor']\n    if r['drained']:\n        break",
    }, {"failure_cause": FAILURE}),
    ("failure-api-change-hang", "api_change", {
        "change": CHANGE_PAYOUTS,
        "run": {"verdict": "killed_timeout", "exit_code": None, "wall_ms": 120000, "stdout": "", "stderr": "",
                "note": "the supervisor killed the run at its 120 s cap"},
        "code": "rows, cursor = [], None\nwhile True:\n    r = get(f'{B}/v2/payouts' + (f'?cursor={cursor}' if cursor else ''))\n    rows += r['payouts']; cursor = r.get('cursor')\n    if not cursor:\n        break",
    }, {"failure_cause": FAILURE}),
    ("failure-api-change-truncated", "api_change", {
        "change": CHANGE_PAYOUTS,
        "run": {"verdict": "exited", "exit_code": 0, "stdout": "synced 100 payouts",
                "check": "every payout exactly once, compared with v1",
                "check_result": "failed: 100 records, 2331 missing"},
        "code": "rows = get(f'{B}/v2/payouts')['payouts']",
    }, {"failure_cause": FAILURE}),
    ("failure-unrelated-bug", "unrelated_bug", {
        "change": CHANGE_PAYOUTS,
        "run": {"verdict": "exited", "exit_code": 1,
                "stderr": "Traceback (most recent call last):\n  File \"payout_sync.py\", line 41, in main\n    print(f\"average payout {total / len(by_merchant)}\")\nZeroDivisionError: division by zero",
                "check": "every payout exactly once, compared with v1",
                "check_result": "passed: payouts.jsonl has 2431 records, each exactly once (written before the crash)"},
        "code": "total = sum(p['amount_cents'] for p in rows)\nby_merchant = {}  # filled later, not yet implemented\nprint(f\"average payout {total / len(by_merchant)}\")",
    }, {"failure_cause": FAILURE}),
    ("failure-flaky", "flaky", {
        "change": CHANGE_PAYOUTS,
        "run": {"verdict": "exited", "exit_code": 1,
                "stderr": "ConnectionResetError: [Errno 104] Connection reset by peer (while reading window 7 of 25)",
                "history": "the same code, unchanged, passed the check on the previous two runs and on the next run"},
        "code": "with urllib.request.urlopen(url, timeout=30) as r:\n    return json.load(r)",
    }, {"failure_cause": FAILURE}),
    ("failure-test-setup", "test_setup", {
        "change": CHANGE_PAYOUTS,
        "run": {"verdict": "exited", "exit_code": 1,
                "stderr": "urllib.error.URLError: <urlopen error [Errno 111] Connection refused> (http://203.0.113.7:18090/v2/payouts)",
                "sandbox": "network allowlist: 198.51.100.4/32 tcp 18090; the API under test is at 203.0.113.7"},
        "code": "r = get(f'{B}/v2/payouts?limit=1000')",
    }, {"failure_cause": FAILURE}),
    # calls_changed_operation: several code hits in one request, as the code search sends them
    ("calls-changed-operation", {"hit_v1_call": "yes", "hit_comment": "no", "hit_table_name": "no", "hit_v2_already": "yes"}, {
        "change": CHANGE_PAYOUTS,
        "hits": {
            "hit_v1_call": "payout_sync.py:9    with urllib.request.urlopen(f\"{base_url}/v1/payouts\", timeout=30) as resp:",
            "hit_comment": "ledger_load.py:3    # payouts.jsonl comes from payout-sync; see /v1/payouts in its README",
            "hit_table_name": "ledger_load.py:12   PAYOUTS_TABLE = \"payouts\"",
            "hit_v2_already": "reconcile.py:27    r = session.get(f\"{api}/v2/payouts\", params={\"limit\": 500})",
        },
    }, {k: {"type": "noul", "instructions": f"Does the code at hits.{k} call the operation described in change?"}
        for k in ("hit_v1_call", "hit_comment", "hit_table_name", "hit_v2_already")}),
    ("calls-changed-operation-graphql", {"hit_query": "yes", "hit_other_query": "no"}, {
        "change": CHANGE_SETTLEMENTS,
        "hits": {
            "hit_query": "settlement_reconcile.py:6    QUERY = \"{ settlements { id batchDate amountCents currency status } }\"",
            "hit_other_query": "refunds.py:4    QUERY = \"{ refunds { id settlementId amountCents } }\"",
        },
    }, {k: {"type": "noul", "instructions": f"Does the code at hits.{k} call the operation described in change?"}
        for k in ("hit_query", "hit_other_query")}),
    # lesson_applies
    ("lesson-applies", {"to_settlements": "yes", "to_rename": "no", "to_refunds_connection": "yes"}, {
        "lesson": LESSON,
        "changes": {
            "to_settlements": CHANGE_SETTLEMENTS,
            "to_rename": "Payout.amount was renamed to Payout.amount_cents; GET /v2/payouts is otherwise unchanged and still returns every payout in one response.",
            "to_refunds_connection": "Query.refunds changed from [Refund!]! to refunds(first, after) returning nodes and pageInfo { endCursor: String!, hasNextPage }.",
        },
    }, {k: {"type": "noul", "instructions": f"Does the lesson apply to the change at changes.{k}?"}
        for k in ("to_settlements", "to_rename", "to_refunds_connection")}),
]


def post(body):
    req = urllib.request.Request(URL, data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, json.load(r), int((time.monotonic() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}"), int((time.monotonic() - t0) * 1000)


index = []
for name, expect, state, questions in CASES:
    body = {"model": "clef", "state": state, "questions": questions}
    status, resp, ms = post(body)
    (OUT / f"{name}.request.json").write_text(json.dumps(body, indent=1) + "\n")
    (OUT / f"{name}.response.json").write_text(json.dumps({"status": status, "ms": ms, "body": resp}, indent=1) + "\n")
    answers = resp.get("answers", {})
    if isinstance(expect, str):
        got = answers.get("failure_cause", {}).get("choice")
        index.append({"case": name, "expect": expect, "got": got, "ms": ms, "status": status})
    else:
        got = {k: round(answers.get(k, {}).get("noul", -1), 3) for k in expect}
        index.append({"case": name, "expect": expect, "got_p_yes": got, "ms": ms, "status": status})
    print(json.dumps(index[-1]))
(OUT / "index.json").write_text(json.dumps(index, indent=1) + "\n")
