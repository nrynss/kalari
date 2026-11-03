# settlement-reconcile

Pulls daily settlement batches from the Clearwell Settlements API (GraphQL) into `settlements.jsonl`, one settlement per line, for reconciliation against the bank. Every settlement must arrive exactly once: a missing one fails the day's reconciliation, a duplicate double-counts money.

```bash
python3 settlement_reconcile.py --base-url https://settlements.example.test    # writes settlements.jsonl
```

No dependencies beyond the Python standard library.

- `specs/schema-v1.graphql`, `specs/schema-v2.graphql`: Clearwell's published schemas.
- `docs/clearwell-settlements-api.md`: Clearwell's developer guide.
