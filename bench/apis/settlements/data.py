"""The settlement batches: deterministic, so the server and the hidden grader agree on the truth.

`STREAM` is the v2 server's internal order: every settlement once, voided rows that are filtered
out after paging (B3), and amended settlements emitted a second time later on (B2)."""
from datetime import date, timedelta

COUNT = 1873
_STATUSES = ["SETTLED", "SETTLED", "SETTLED", "PENDING", "ADJUSTED"]
_BASE = date(2026, 1, 1)


def settlement(i: int) -> dict:
    return {
        "id": f"st_{i + 1:05d}",
        "batchDate": (_BASE + timedelta(days=i // 6)).isoformat(),
        "amountCents": (i * 104729) % 9_000_000 + 5_000,
        "currency": "USD",
        "status": _STATUSES[(i * 7) % len(_STATUSES)],
    }


SETTLEMENTS = [settlement(i) for i in range(COUNT)]

VOID_RUN_EVERY = 400   # after every 400 settlements, a run of voided rows
VOID_RUN_LENGTH = 200  # at least twice the largest page (first <= 100), so every page size meets an empty page
AMEND_EVERY = 97       # every 97th settlement was amended ...
AMEND_LAG = 230        # ... and is emitted again 230 settlements later


def _stream():
    out, amended = [], {}
    for i in range(COUNT):
        out.append(("s", i))
        if i % AMEND_EVERY == AMEND_EVERY - 1:
            amended.setdefault(min(i + AMEND_LAG, COUNT - 1), []).append(i)
        for j in amended.pop(i, []):
            out.append(("s", j))
        if i % VOID_RUN_EVERY == VOID_RUN_EVERY - 1:
            out.extend(("void", k) for k in range(VOID_RUN_LENGTH))
    return out


STREAM = _stream()
REPEATS = len([e for e in STREAM if e[0] == "s"]) - COUNT
