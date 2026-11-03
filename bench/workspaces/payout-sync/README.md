# payout-sync

Copies merchant payouts from the Tallyline Payouts API into `payouts.jsonl`, one payout per line, for the finance ledger to load. Every payout must arrive exactly once: a missing payout is a merchant who isn't paid, a duplicate is one who is paid twice.

```bash
python3 payout_sync.py --base-url https://payouts.example.test     # writes payouts.jsonl
```

No dependencies beyond the Python standard library.

- `specs/openapi-v1.yaml`, `specs/openapi-v2.yaml`: Tallyline's published specs.
- `docs/tallyline-payouts-api.md`: Tallyline's developer guide.
