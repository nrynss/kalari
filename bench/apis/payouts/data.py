"""The payout ledger's records: deterministic, so the server and the hidden grader agree on the truth."""
from datetime import datetime, timedelta, timezone

COUNT = 2431
_BASE = datetime(2026, 1, 5, 8, 0, 0, tzinfo=timezone.utc)


def payout(i: int) -> dict:
    return {
        "id": f"po_{i + 1:05d}",
        "merchant_id": f"m_{(i * 37) % 211:03d}",
        "amount_cents": (i * 7919) % 500000 + 100,
        "currency": "USD",
        "created_at": (_BASE + timedelta(seconds=61 * i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


PAYOUTS = [payout(i) for i in range(COUNT)]
