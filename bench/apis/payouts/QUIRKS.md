# Payouts v2: where each behaviour is documented (never shown to an arm)

| Behaviour | Server | Spec (`openapi-v2.yaml`) | Developer guide (`tallyline-payouts-api.md`) |
|---|---|---|---|
| **B1** A fresh `cursor` on every response, the last included; `drained` ends it | `mint()` on every response; at the end the cursor points at the last payout again | `cursor` required; `drained`: "True when the export has caught up with the ledger" | "Knowing when you're done": "`drained: true` means the export has caught up … The response still carries a `cursor` … there's no need to request it again now." Also "expect a different value each time" |
| **B2** Windows overlap by one payout | The next window starts at the previous window's last payout | Not stated | "Windows and cursors": "Each window begins with the payout that ended the previous window, so that payout appears in both responses … deduplicate on `id`." |
| **B4** `limit` up to 1000, at most 100 returned | `min(limit, 100)` | `limit` maximum 1000 | "Window size": "Tallyline may return fewer than `limit` payouts … The number of payouts in a response doesn't tell you whether more remain; `drained` does." |

Real sources (bench/README.md): B1 Zendesk incremental export, Microsoft Graph delta; B2 Zendesk time-based export; B4 RIPE Atlas, RevenueCat.

**Truth:** 2,431 payouts, `po_00001` to `po_02431`. At 100 a window with a one-payout overlap: 25 windows, 24 boundary payouts seen twice (2,455 records if appended).

| The obvious code | Outcome |
|---|---|
| One v2 request | 100 of 2,431 |
| Stop when a response holds fewer than `limit` (with `limit` > 100) | 100 of 2,431 |
| `while cursor:` | Never ends; the last payout is appended again on every request |
| Stop on `drained`, append every window | 2,455 records, 24 duplicates |
| Stop on `drained`, dedupe on `id` | 2,431, exactly once |
