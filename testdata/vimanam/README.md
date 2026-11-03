# Vimanam recordings (T0.3)

What `vimanam diff --format json` (contract v2) returns on the benchmark specs, for `Kalari/Vimanam.lean` (T3.1) to replay. Findings in `dev-diary/research/vimanam.md`.

| File | Specs | Vimanam |
|---|---|---|
| `payouts.json`, `payouts.md` | `bench/workspaces/payout-sync/specs/openapi-v1.yaml` → `openapi-v2.yaml`, as built | 2.0.0 (crates.io) |
| `settlements.json`, `settlements.md` | `bench/workspaces/settlement-reconcile/specs/schema-v1.graphql` → `schema-v2.graphql`, as built | `main` at `491b02c` (GraphQL isn't in 2.0.0) |
| `probes/payouts-samepath.json` | same path `/payouts`, version in the server URL | 2.0.0 |
| `probes/payouts-samepath-nextcursor.json` | same path, response field `next_cursor`: **`pagination_changed`** | 2.0.0 |
| `probes/settlements-edges.json` | `edges { node cursor }` beside `nodes`: **`pagination_changed`** (`RELAY_CONNECTION_ADOPTED`) | `main` |

The probe specs sit beside their outputs. Re-record if the benchmark specs change (they freeze at T5.3).
