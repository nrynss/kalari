# disbursement-sync

Copies merchant disbursements from the Meridian Disbursements API into `disbursements.jsonl`, one disbursement per line, for the finance ledger to load. Every disbursement must arrive exactly once: a missing disbursement is a merchant who isn't paid, a duplicate is one who is paid twice.

```bash
python3 disbursement_sync.py --base-url https://disbursements.example.test     # writes disbursements.jsonl
```

No dependencies beyond the Python standard library.

- `specs/openapi-v1.yaml`, `specs/openapi-v2.yaml`: Meridian's published specs.
- `docs/meridian-disbursements-api.md`: Meridian's developer guide.
