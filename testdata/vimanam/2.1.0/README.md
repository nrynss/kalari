# Vimanam 2.1.0 recordings (T0.6)

The benchmark specs **as built**, diffed with Vimanam 2.1.0 (crates.io), the release that fixed vimanam#136–#139. Both now report `pagination_changed`. The runner's checks replay this directory. The 2.0.0/`main` recordings one level up stay, because `Kalari/Fake.lean` still replays them.

| File | Specs | `pagination_changed` |
|---|---|---|
| `payouts.json`, `payouts.md` | `payout-sync/specs/openapi-v1.yaml` → `openapi-v2.yaml` | **Yes**, after `operation_moved` (`GET /v1/payouts` → `GET /v2/payouts`): `pagination_inferred`, continuation `cursor` (generic), end flag `drained` |
| `settlements.json`, `settlements.md` | `settlement-reconcile/specs/schema-v1.graphql` → `schema-v2.graphql` | **Yes**: `RELAY_CONNECTION_ADOPTED`, confidence `declared`, `connection_fields: "nodes"` |
| `settlements.context.md` | the same, `--context --max-tokens 2000` | Focused context for the agent |
| `matrices/` | the three issue matrices: `results.md` (2.1.0), `results-2.0.0.md`, and `matrix.py` that generated both | 2.1.0: 5/5 version-prefix cases, 17/17 continuation fields, all 5 Relay shapes (the 2 controls still no, as the rule says) |

**`--context` is GraphQL-only in 2.1.0:** on the OpenAPI pair it fails with "--context is GraphQL-only; OpenAPI and protobuf diffs do not support it". REST focused context is the change facts. A GraphQL pair still uses `--context --max-tokens`, as in `settlements.context.md`.
