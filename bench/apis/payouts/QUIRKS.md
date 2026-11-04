# Payouts v2: where each behaviour is documented (never shown to an arm)

| Behaviour | Server | Spec (`openapi-v2.yaml`) | Developer guide (`tallyline-payouts-api.md`) |
|---|---|---|---|
| **B1** A fresh `cursor` on every response, the last included; `drained` ends it | `mint()` on every response; at the end the cursor points at the last payout again | `cursor` required; `drained`: "True when the export has caught up with the ledger" | "Knowing when you're done": "`drained: true` means the export has caught up … The response still carries a `cursor` … there's no need to request it again now." Also "expect a different value each time" |
| **B2** Windows overlap by one payout | The next window starts at the previous window's last payout | Not stated | "Windows and cursors": "Each window begins with the payout that ended the previous window, so that payout appears in both responses … deduplicate on `id`." |
| **B4** `limit` up to 1000, at most 100 returned | `min(limit, 100)` | `limit` maximum 1000 | "Window size": "Tallyline may return fewer than `limit` payouts … The number of payouts in a response doesn't tell you whether more remain; `drained` does." |
| **B5** One `429` with `Retry-After: 1` partway, the identical retry succeeds | The first request of a traversal at or past offset 1500 is throttled once. A fresh traversal id is minted with the first response and rides inside the signed cursor. A request clears the throttle only when its full fingerprint matches the failed one | Not stated; a 429 is a transport failure | "Rate limits and retries": "Treat a 429 as a transient transport failure … send the identical request again … the method, the path and every query parameter are the same" |

Real sources (bench/README.md): B1 Zendesk incremental export, Microsoft Graph delta; B2 Zendesk time-based export; B4 RIPE Atlas, RevenueCat; B5 universal.

**Truth:** 2,431 payouts, `po_00001` to `po_02431`. At 100 a window with a one-payout overlap: 25 windows, 24 boundary payouts seen twice (2,455 records if appended).

| The obvious code | Outcome |
|---|---|
| One v2 request | 100 of 2,431 |
| Stop when a response holds fewer than `limit` (with `limit` > 100) | 100 of 2,431 |
| `while cursor:` | Never ends; the last payout is appended again on every request |
| Stop on `drained`, append every window | 2,455 records, 24 duplicates |
| Stop on `drained`, dedupe on `id` | 2,431, exactly once |
| No retry on the 429 | The run crashes at the throttle and writes nothing |
| Treat the 429 as the end and exit 0 | 1,585 records, 846 missing |

## Retry journal (measurement only)

`--retry-journal PATH` writes one JSON event per request: timestamp, keyed client digest, HTTP status, request fingerprint digest, traversal digest, `throttled`, `retry_candidate`, `matching_retry`. It holds no cursor, no request body, no token and no address. The harness truncates it at a phase start and reads it at a phase end. A missing journal, a malformed event or an overflow marker is `unknown`, never zero. `retry_candidate` marks a request that presented the throttled cursor. `matching_retry` marks the one whose full fingerprint matched.
