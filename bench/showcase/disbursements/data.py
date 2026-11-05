"""The disbursement ledger's records: deterministic, so the server and the hidden grader agree.

Every record has one final version (`FINAL`, what v1 serves and the grader expects) and a
window-edge version (`edge`, what v2 serves once, at the end of the window the record closes).
The edge version carries the amount before a late adjustment; the final version, delivered
again at the start of the next window, carries the adjusted amount. A consumer that keeps the
first delivery per id keeps the unadjusted amount: the counts are right and only a
record-by-record comparison against v1 shows the difference.
"""
from datetime import datetime, timedelta, timezone

COUNT = 2341
_BASE = datetime(2026, 1, 5, 8, 0, 0, tzinfo=timezone.utc)
ADJUSTMENT_CENTS = 1250  # the late adjustment applied between the edge delivery and the final one


def disbursement(i: int) -> dict:
    return {
        "id": f"ds_{i + 1:05d}",
        "merchant_id": f"m_{(i * 43) % 197:03d}",
        "amount_cents": (i * 7919) % 500000 + 100,
        "currency": "USD",
        "created_at": (_BASE + timedelta(seconds=61 * i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def edge(r: dict) -> dict:
    """The window-edge delivery of a record: the amount before the late adjustment."""
    return dict(r, amount_cents=r["amount_cents"] + ADJUSTMENT_CENTS)


FINAL = [disbursement(i) for i in range(COUNT)]
