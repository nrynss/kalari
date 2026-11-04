# Tallyline Payouts API: developer guide

## Versions

Version 2 replaces `GET /v1/payouts` with an export endpoint, `GET /v2/payouts`. Version 1 stays available while you migrate and will then be retired; requests to it will return `410 Gone`.

## Authentication

Requests in this environment need no credentials.

## Payouts

A payout records money sent to a merchant. Each payout has a unique `id` (for example `po_00042`), the merchant it went to, an amount in cents, a currency and the time it was created. Payouts are immutable once created.

## Exporting payouts (v2)

`GET /v2/payouts` returns payouts in creation order, a window at a time. Start without a `cursor` to begin at the first payout on the ledger.

### Windows and cursors

Every response includes a `cursor`. Pass it back as `?cursor=` to get the next window. The cursor is opaque: don't parse or construct it, and expect a different value each time, even for the same position.

Windows overlap at their edges. Each window begins with the payout that ended the previous window, so that payout appears in both responses. This keeps a window from ever splitting payouts created in the same instant. Payout `id`s are unique: deduplicate on `id`.

### Knowing when you're done

`drained: true` means the export has caught up with the ledger: there is nothing newer to return right now. The response still carries a `cursor`. Store it if you want to resume the export later and pick up payouts created since; there's no need to request it again now.

### Window size

`limit` (1 to 1000, default 100) is the most payouts a response will contain. Tallyline may return fewer than `limit` payouts, for example to keep responses fast under load. The number of payouts in a response doesn't tell you whether more remain. `drained` does.

### Errors

A malformed or expired cursor returns `400` with `{"error": "invalid_cursor"}`. Start the export again without a cursor. A `limit` outside 1 to 1000 returns `400` with `{"error": "invalid_limit"}`.

### Rate limits and retries

Under load a request can return `429 Too Many Requests` with a `Retry-After` header. The header holds the number of seconds to wait before you try again.

Treat a 429 as a transient transport failure. Wait for the delay and send the identical request again. A request is identical when the method, the path and the decoded query parameters are the same. Parameter order does not matter. A repeated parameter or a different value makes it a different request. Keep the same `cursor`, and do not move to the next window until the request succeeds.

## Migrating from v1

| v1 | v2 |
|---|---|
| `GET /v1/payouts` | `GET /v2/payouts`, then follow `cursor` |
| One response with every payout | One window per response |
| `{"payouts": [...]}` | `{"payouts": [...], "cursor": "...", "drained": false}` |

The `Payout` object is unchanged.
