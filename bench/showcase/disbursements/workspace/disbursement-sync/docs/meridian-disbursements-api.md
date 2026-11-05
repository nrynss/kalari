# Meridian Disbursements API: developer guide

## Versions

Version 2 replaces `GET /v1/disbursements` with an export endpoint, `GET /v2/disbursements`. Version 1 stays available while you migrate and will then be retired; requests to it will return `410 Gone`.

## Authentication

Requests in this environment need no credentials.

## Disbursements

A disbursement records money sent to a merchant. Each disbursement has a unique `id` (for example `ds_00042`), the merchant it went to, an amount in cents, a currency and the time it was created.

## Exporting disbursements (v2)

`GET /v2/disbursements` returns disbursements in creation order, a window at a time. Start without a `cursor` to begin at the first disbursement on the ledger.

### Windows and cursors

Every response includes a `cursor`. Pass it back as `?cursor=` to get the next window. The cursor is opaque: don't parse or construct it, and expect a different value each time, even for the same position.

Windows overlap at their edges. Each window begins with the disbursement that ended the previous window, so that disbursement appears in both responses. This keeps a window from ever splitting disbursements created in the same instant. Disbursement `id`s are unique: deduplicate on `id`.

### Knowing when you're done

`drained: true` means the export has caught up with the ledger: there is nothing newer to return right now. The response still carries a `cursor`. Store it if you want to resume the export later and pick up disbursements created since; there's no need to request it again now.

### Window size

`limit` (1 to 100, default 100) is the most disbursements a response will contain. Meridian may return fewer than `limit` disbursements, for example to keep responses fast under load. The number of disbursements in a response doesn't tell you whether more remain. `drained` does.

### Errors

A malformed or expired cursor returns `400` with `{"error": "invalid_cursor"}`. Start the export again without a cursor. A `limit` outside 1 to 100 returns `400` with `{"error": "invalid_limit"}`.

## Migrating from v1

| v1 | v2 |
|---|---|
| `GET /v1/disbursements` | `GET /v2/disbursements`, then follow `cursor` |
| One response with every disbursement | One window per response |
| `{"disbursements": [...]}` | `{"disbursements": [...], "cursor": "...", "drained": false}` |

The `Disbursement` object is unchanged.
