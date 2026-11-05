# Frozen benchmark pair

The user chose this pair for the frozen comparison.
Payouts runs B1 plus B2 plus B4 plus B5.
Settlements runs B1 plus B2 plus B3 plus B5.
B5 in both upgrades is the final hardness change.
We make no further behaviour change after this freeze.

We freeze the code and data under test at commit 8b8e0f3bb0834549bc5be6acc94e840fe6674fe3.
You must recompute every hash below before any Kalari arm run.
The frozen runs count only when all hashes match.
The baseline passed all 50 harder pair sessions first time.
The measured edge will come from cost and attempts and containment, not from pass rate.
We report HTTP retry attempts apart from sandbox runs.
If condition 1 or condition 6 matches condition 5, we say so.

## Frozen files

The table lists every frozen file with its SHA-256 hash.

| Path | SHA-256 |
|---|---|
| bench/apis/payouts/server.py | 163d3900088b058052bbbf276e4bddf361e1482d23ed1e5a91f39c5a4cd28ae1 |
| bench/apis/payouts/data.py | 214b85de246d993e5ab8208e3e2639f7d54e6754e43ec35c017934831273ada1 |
| bench/apis/settlements/server.py | abefa27709c79ef276cd7c9dc09180b4a94e6acdabb3b7a836fa57c2b54387bd |
| bench/apis/settlements/data.py | 41c3510ee373b0c1bf59124fce5240a176782be7aecb45bc3462e1a060b01d91 |
| bench/apis/vendor/graphql_core-3.3.1-py3-none-any.whl | 43ebcd0d9a0662a71b1a2f6562ba863d253057ec11cbc45835b2e2683a0a3770 |
| bench/workspaces/payout-sync/payout_sync.py | 3d2882a46b7c053f5df5c4ac919e16b9f716d2c4974bef7c005fae9f90aa6967 |
| bench/workspaces/payout-sync/README.md | 8750085a3ce333e7450cbd78aee5ce4a3cd448aaaf848c0f32fe7249493350fd |
| bench/workspaces/payout-sync/specs/openapi-v1.yaml | b2fa9848a9365a368c65c44aaca9261c849282d18302eaf71795dc49c0742538 |
| bench/workspaces/payout-sync/specs/openapi-v2.yaml | 8bc12248a675fab1864aa2a3ca6cc00419a89128063e6a557f114b06ae93c2a4 |
| bench/workspaces/payout-sync/docs/tallyline-payouts-api.md | cb13d6b88e06fb4a8a2ca4844c8a269c831a734d823972bdde3d8607ce25b4de |
| bench/workspaces/settlement-reconcile/settlement_reconcile.py | 1e26ed522a13f1cfd95573f43dbd1fcdd033fe63e7a1643b073e63dfcd141b1e |
| bench/workspaces/settlement-reconcile/README.md | 8c887cc00c4854147b3021be75f34d732318307e6bf6dbee903e3ea9e217489c |
| bench/workspaces/settlement-reconcile/specs/schema-v1.graphql | 2200b661addda9ed7865ad7c40c2edf544c62a9a46063971264d37b8953049c3 |
| bench/workspaces/settlement-reconcile/specs/schema-v2.graphql | d42a800d094266eba77445c69ce5def034df3f1ad2ec7e2eb761ff25394ee97c |
| bench/workspaces/settlement-reconcile/docs/clearwell-settlements-api.md | c3ba9091abf3821456321a77aa4547c3bb196572544e4c128096bf6606fa85c4 |
| bench/prompts/upgrade.txt | bacb74600b84e75ee1fc0536ea71c15486354d5c52d2669a725e95d23e59f4a4 |
| bench/prompts/condition-6.txt | 8c4aedc83c1dec9bfd79f7dd35477b8f88ed049f922140637b1265baa5ffcdab |
| bench/graders/grade.py | 7d3de76006421e23faab6d8b7f2522d7ef16345975a6ae89ab87d704cecc3cc6 |
| bench/harness/grade_runner.py | 58a7ff9ff92d65504a9ed84006c7a9082d1266f6a146352444da03c89294bcb6 |

## How to verify

Run the command below from the repo root.
It prints each hash again.
Compare its output with the table.
Stop when any hash differs.
Do not run the Kalari arm with changed files.

```bash
sha256sum bench/apis/payouts/server.py bench/apis/payouts/data.py bench/apis/settlements/server.py bench/apis/settlements/data.py bench/apis/vendor/graphql_core-3.3.1-py3-none-any.whl bench/workspaces/payout-sync/payout_sync.py bench/workspaces/payout-sync/README.md bench/workspaces/payout-sync/specs/openapi-v1.yaml bench/workspaces/payout-sync/specs/openapi-v2.yaml bench/workspaces/payout-sync/docs/tallyline-payouts-api.md bench/workspaces/settlement-reconcile/settlement_reconcile.py bench/workspaces/settlement-reconcile/README.md bench/workspaces/settlement-reconcile/specs/schema-v1.graphql bench/workspaces/settlement-reconcile/specs/schema-v2.graphql bench/workspaces/settlement-reconcile/docs/clearwell-settlements-api.md bench/prompts/upgrade.txt bench/prompts/condition-6.txt bench/graders/grade.py bench/harness/grade_runner.py
```

## Frozen versus live

We freeze only the files in the table.
Docs prose stays live.
The bench README and product prose can still change.
QUIRKS notes stay outside the freeze.
Reference consumers stay outside the freeze.
Deploy scripts stay outside the freeze.
The vendor license and vendor readme stay outside the freeze.
All other harness scripts stay outside the freeze.
Only grade_runner.py from the harness is frozen.
The old pilot rows and the harder pilot rows stay published and unchanged.
