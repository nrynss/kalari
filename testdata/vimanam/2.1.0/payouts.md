# API Diff: Tallyline Payouts API 1.4.0 → 2.0.0

**Summary:** 0 endpoints added, 0 removed, 1 moved, 1 changed; 2 breaking, 7 non-breaking, 0 to review

## Breaking changes (2)

| Change | Endpoint | Detail |
|--------|----------|--------|
| Endpoint moved | `GET /v2/payouts` | from `GET /v1/payouts` (matched by version segment) |
| operationId changed | `GET /v2/payouts` | `listPayouts` → `exportPayouts` |

## Non-breaking changes (7)

| Change | Endpoint | Detail |
|--------|----------|--------|
| Parameter added | `GET /v2/payouts` | `cursor` (query), optional |
| Parameter added | `GET /v2/payouts` | `limit` (query), optional |
| Response schema changed | `GET /v2/payouts` | 200 `/properties/cursor` added |
| Response schema changed | `GET /v2/payouts` | 200 `/properties/drained` added |
| Response schema changed | `GET /v2/payouts` | 200 `/properties/cursor` added to `required` |
| Response schema changed | `GET /v2/payouts` | 200 `/properties/drained` added to `required` |
| Response added | `GET /v2/payouts` | 400 |
