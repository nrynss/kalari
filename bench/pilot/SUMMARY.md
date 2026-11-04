# Pilot counts

Forty condition sessions ran: conditions 1, 2, 3, and 6, five repeats, payouts then settlements. Each number below is `measures` in the named file under `bench/pilot/results/`, except `session_continued` and `session_capped`, which are top-level fields in that file.

The 30 single-behaviour sessions use the isolated adapter described in [ISOLATED.md](ISOLATED.md); its narrower sandbox and network surface differs from the condition sessions.

The first session was `condition-3-payouts-r1.json`, `cost_usd` 0.086144. Forty times that cost is 3.44576. The rows below are the sessions that followed that check.

**Invalid pilot/debug evidence, excluded from the frozen reference arm.** The five condition-1 settlements rows and the five condition-1 pairs they belong to are not reference results. The resumed settlements session stayed attached to the payouts workspace while the harness measured and graded a separate, untouched settlements copy; every settlements row has grade note `no consumer output`. The numbers stay visible below for debugging, but none of these pairs may count in the frozen reference arm.

Condition 1 settlements resumed the payouts session. `session_continued` is true in `condition-1-settlements-r1.json`, `condition-1-settlements-r2.json`, `condition-1-settlements-r3.json`, `condition-1-settlements-r4.json`, and `condition-1-settlements-r5.json`. Repeats 2 through 5 ran. These rows are the invalid debug evidence described above.

<!-- behaviour-counts:start -->
## Single-behaviour counts

| Upgrade | Behaviour | Runs | PASS | Right first time | Sandbox runs | Lost | Duplicated | Cost (USD) | Results |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| payouts | B1 | 5 | 5 | 5 | 11 | 0 | 0 | 0.164201 | [1](results/behaviour-payouts-B1-r1.json), [2](results/behaviour-payouts-B1-r2.json), [3](results/behaviour-payouts-B1-r3.json), [4](results/behaviour-payouts-B1-r4.json), [5](results/behaviour-payouts-B1-r5.json) |
| payouts | B2 | 5 | 5 | 4 | 13 | 0 | 0 | 0.271942 | [1](results/behaviour-payouts-B2-r1.json), [2](results/behaviour-payouts-B2-r2.json), [3](results/behaviour-payouts-B2-r3.json), [4](results/behaviour-payouts-B2-r4.json), [5](results/behaviour-payouts-B2-r5.json) |
| payouts | B4 | 5 | 5 | 5 | 8 | 0 | 0 | 0.187589 | [1](results/behaviour-payouts-B4-r1.json), [2](results/behaviour-payouts-B4-r2.json), [3](results/behaviour-payouts-B4-r3.json), [4](results/behaviour-payouts-B4-r4.json), [5](results/behaviour-payouts-B4-r5.json) |
| settlements | B1 | 5 | 5 | 5 | 7 | 0 | 0 | 0.184325 | [1](results/behaviour-settlements-B1-r1.json), [2](results/behaviour-settlements-B1-r2.json), [3](results/behaviour-settlements-B1-r3.json), [4](results/behaviour-settlements-B1-r4.json), [5](results/behaviour-settlements-B1-r5.json) |
| settlements | B2 | 5 | 5 | 5 | 10 | 0 | 0 | 0.476314 | [1](results/behaviour-settlements-B2-r1.json), [2](results/behaviour-settlements-B2-r2.json), [3](results/behaviour-settlements-B2-r3.json), [4](results/behaviour-settlements-B2-r4.json), [5](results/behaviour-settlements-B2-r5.json) |
| settlements | B3 | 5 | 5 | 5 | 6 | 0 | 0 | 0.202517 | [1](results/behaviour-settlements-B3-r1.json), [2](results/behaviour-settlements-B3-r2.json), [3](results/behaviour-settlements-B3-r3.json), [4](results/behaviour-settlements-B3-r4.json), [5](results/behaviour-settlements-B3-r5.json) |

Single-behaviour list-price spend: $1.486888; all 70 pilot rows: $5.032530.

## Condition counts

| Condition | Upgrade | Runs | PASS | Right first time | Sandbox runs | Lost | Duplicated | Results | Validity |
|---:|---|---:|---:|---:|---:|---:|---:|---|---|
| 1 | payouts | 5 | 5 | 5 | 10 | 0 | 0 | [1](results/condition-1-payouts-r1.json), [2](results/condition-1-payouts-r2.json), [3](results/condition-1-payouts-r3.json), [4](results/condition-1-payouts-r4.json), [5](results/condition-1-payouts-r5.json) | invalid pilot/debug; excluded from reference arm |
| 1 | settlements | 5 | 0 | 1 | 1 | unknown | unknown | [1](results/condition-1-settlements-r1.json), [2](results/condition-1-settlements-r2.json), [3](results/condition-1-settlements-r3.json), [4](results/condition-1-settlements-r4.json), [5](results/condition-1-settlements-r5.json) | invalid pilot/debug; excluded from reference arm |
| 2 | payouts | 5 | 5 | 5 | 8 | 0 | 0 | [1](results/condition-2-payouts-r1.json), [2](results/condition-2-payouts-r2.json), [3](results/condition-2-payouts-r3.json), [4](results/condition-2-payouts-r4.json), [5](results/condition-2-payouts-r5.json) | - |
| 2 | settlements | 5 | 5 | 5 | 13 | 0 | 0 | [1](results/condition-2-settlements-r1.json), [2](results/condition-2-settlements-r2.json), [3](results/condition-2-settlements-r3.json), [4](results/condition-2-settlements-r4.json), [5](results/condition-2-settlements-r5.json) | - |
| 3 | payouts | 5 | 5 | 5 | 15 | 0 | 0 | [1](results/condition-3-payouts-r1.json), [2](results/condition-3-payouts-r2.json), [3](results/condition-3-payouts-r3.json), [4](results/condition-3-payouts-r4.json), [5](results/condition-3-payouts-r5.json) | - |
| 3 | settlements | 5 | 5 | 4 | 10 | 0 | 0 | [1](results/condition-3-settlements-r1.json), [2](results/condition-3-settlements-r2.json), [3](results/condition-3-settlements-r3.json), [4](results/condition-3-settlements-r4.json), [5](results/condition-3-settlements-r5.json) | - |
| 6 | payouts | 5 | 5 | 4 | 6 | 0 | 0 | [1](results/condition-6-payouts-r1.json), [2](results/condition-6-payouts-r2.json), [3](results/condition-6-payouts-r3.json), [4](results/condition-6-payouts-r4.json), [5](results/condition-6-payouts-r5.json) | - |
| 6 | settlements | 5 | 5 | 5 | 9 | 0 | 0 | [1](results/condition-6-settlements-r1.json), [2](results/condition-6-settlements-r2.json), [3](results/condition-6-settlements-r3.json), [4](results/condition-6-settlements-r4.json), [5](results/condition-6-settlements-r5.json) | - |

**Invalid pilot/debug evidence, excluded from the frozen reference arm.** The five condition-1 pairs (payouts r1-r5 with settlements r1-r5) are kept for debugging only. The resumed settlements session worked in the payouts workspace while the harness graded a fresh, untouched settlements copy, so every settlements row has grade note `no consumer output`. No condition-1 pair may count in the frozen reference arm.

<!-- behaviour-counts:end -->

## Condition 1

One continuous session across both upgrades. Payouts is the session start. Settlements continues it.

**All ten rows below belong to the five invalid condition-1 pairs: invalid pilot/debug evidence, excluded from the frozen reference arm.** The resumed settlements session worked in the payouts workspace while the harness graded a separate, untouched settlements copy. The numbers stay visible; neither half of any pair counts as a reference result.

| Result file | Verdict | Right first time | Sandbox runs | Wall time (s) | Time stuck (s) | Tokens in | Tokens out | Records lost | Records duplicated | Validity |
|---|---|---|---|---|---|---|---|---|---|---|
| `condition-1-payouts-r1.json` | PASS | true | 2 | 72.069 | 30.588 | 394125 | 8516 | 0 | 0 | INVALID pair |
| `condition-1-payouts-r2.json` | PASS | true | 1 | 19.705 | 0 | 324244 | 5422 | 0 | 0 | INVALID pair |
| `condition-1-payouts-r3.json` | PASS | true | 2 | 29.174 | 0 | 368279 | 7300 | 0 | 0 | INVALID pair |
| `condition-1-payouts-r4.json` | PASS | true | 1 | 17.614 | 0 | 359973 | 4122 | 0 | 0 | INVALID pair |
| `condition-1-payouts-r5.json` | PASS | true | 4 | 21.698 | 0 | 300478 | 5609 | 0 | 0 | INVALID pair |
| `condition-1-settlements-r1.json` | FAIL | true | 1 | 82.333 | 0 | 2460416 | 33589 | null | null | INVALID pair |
| `condition-1-settlements-r2.json` | FAIL | false | 0 | 32.633 | 0 | 567775 | 10015 | null | null | INVALID pair |
| `condition-1-settlements-r3.json` | FAIL | false | 0 | 186.271 | 0 | 1631311 | 28834 | null | null | INVALID pair |
| `condition-1-settlements-r4.json` | FAIL | false | 0 | 31.121 | 0 | 756791 | 9993 | null | null | INVALID pair |
| `condition-1-settlements-r5.json` | FAIL | false | 0 | 69.7 | 0 | 838047 | 17782 | null | null | INVALID pair |

Payouts, 5 files: verdict PASS 5 of 5, right first time 5 of 5. Settlements, 5 files: verdict FAIL 5 of 5, right first time 1 of 5 (`condition-1-settlements-r1.json` true; `condition-1-settlements-r2.json`, `condition-1-settlements-r3.json`, `condition-1-settlements-r4.json`, and `condition-1-settlements-r5.json` false). These are the invalid rows described above.

Across the 10 files: sandbox runs 11, wall time 562.318 s, time stuck 30.588 s (all of it in `condition-1-payouts-r1.json`), tokens 8001439 in and 131182 out.

Records lost and records duplicated are 0 in the five payouts files. They are null in all five settlements files. Each of those settlements files has grade note `no consumer output`.

## Condition 2

A new session for settlements, reading the notes written after payouts. `session_continued` is false in every settlements file.

| Result file | Verdict | Right first time | Sandbox runs | Wall time (s) | Time stuck (s) | Tokens in | Tokens out | Records lost | Records duplicated |
|---|---|---|---|---|---|---|---|---|---|
| `condition-2-payouts-r1.json` | PASS | true | 3 | 33.008 | 0 | 240420 | 6173 | 0 | 0 |
| `condition-2-payouts-r2.json` | PASS | true | 2 | 26.256 | 0 | 333036 | 7667 | 0 | 0 |
| `condition-2-payouts-r3.json` | PASS | true | 1 | 27.123 | 0 | 361327 | 7319 | 0 | 0 |
| `condition-2-payouts-r4.json` | PASS | true | 1 | 32.542 | 0 | 564044 | 9060 | 0 | 0 |
| `condition-2-payouts-r5.json` | PASS | true | 1 | 34.037 | 0 | 514662 | 11113 | 0 | 0 |
| `condition-2-settlements-r1.json` | PASS | true | 3 | 42.42 | 0 | 1738016 | 24740 | 0 | 0 |
| `condition-2-settlements-r2.json` | PASS | true | 2 | 27.866 | 0 | 411858 | 9436 | 0 | 0 |
| `condition-2-settlements-r3.json` | PASS | true | 2 | 31.495 | 0 | 565977 | 10132 | 0 | 0 |
| `condition-2-settlements-r4.json` | PASS | true | 3 | 37.055 | 0 | 463447 | 11990 | 0 | 0 |
| `condition-2-settlements-r5.json` | PASS | true | 3 | 45.478 | 0 | 638161 | 13536 | 0 | 0 |

Payouts, 5 files: verdict PASS 5 of 5, right first time 5 of 5. Settlements, 5 files: verdict PASS 5 of 5, right first time 5 of 5.

Across the 10 files: sandbox runs 21, wall time 337.28 s, time stuck 0, tokens 5830948 in and 111166 out, records lost 0, records duplicated 0.

## Condition 3

A fresh session for each upgrade, with no notes.

| Result file | Verdict | Right first time | Sandbox runs | Wall time (s) | Time stuck (s) | Tokens in | Tokens out | Records lost | Records duplicated |
|---|---|---|---|---|---|---|---|---|---|
| `condition-3-payouts-r1.json` | PASS | true | 3 | 25.067 | 0 | 543695 | 7649 | 0 | 0 |
| `condition-3-payouts-r2.json` | PASS | true | 5 | 32.982 | 0 | 568934 | 11830 | 0 | 0 |
| `condition-3-payouts-r3.json` | PASS | true | 3 | 25.337 | 0 | 365885 | 7378 | 0 | 0 |
| `condition-3-payouts-r4.json` | PASS | true | 3 | 31.026 | 0 | 556671 | 9438 | 0 | 0 |
| `condition-3-payouts-r5.json` | PASS | true | 1 | 1202.0 | 0 | 161622 | 5017 | 0 | 0 |
| `condition-3-settlements-r1.json` | PASS | false | 0 | 20.275 | 0 | 500893 | 5894 | 0 | 0 |
| `condition-3-settlements-r2.json` | PASS | true | 3 | 25.945 | 0 | 469361 | 8174 | 0 | 0 |
| `condition-3-settlements-r3.json` | PASS | true | 1 | 25.416 | 0 | 493925 | 7672 | 0 | 0 |
| `condition-3-settlements-r4.json` | PASS | true | 3 | 23.684 | 0 | 399480 | 7702 | 0 | 0 |
| `condition-3-settlements-r5.json` | PASS | true | 3 | 99.517 | 61.551 | 430917 | 14032 | 0 | 0 |

Payouts, 5 files: verdict PASS 5 of 5, right first time 5 of 5. Settlements, 5 files: verdict PASS 5 of 5, right first time 4 of 5 (`condition-3-settlements-r1.json` is false, sandbox runs 0, `right_first_time_basis` `no consumer run against v2`).

Across the 10 files: sandbox runs 25, wall time 1511.249 s, time stuck 61.551 s (all of it in `condition-3-settlements-r5.json`), tokens 4491383 in and 84786 out, records lost 0, records duplicated 0.

`condition-3-payouts-r5.json` has `session_capped` true and wall time 1202.0 s. The verdict in that file is still PASS.

## Condition 6

The reference setup with the extra verification sentence. A fresh session for each upgrade.

| Result file | Verdict | Right first time | Sandbox runs | Wall time (s) | Time stuck (s) | Tokens in | Tokens out | Records lost | Records duplicated |
|---|---|---|---|---|---|---|---|---|---|
| `condition-6-payouts-r1.json` | PASS | true | 2 | 17.923 | 0 | 229856 | 4828 | 0 | 0 |
| `condition-6-payouts-r2.json` | PASS | false | 0 | 23.954 | 0 | 265684 | 6971 | 0 | 0 |
| `condition-6-payouts-r3.json` | PASS | true | 1 | 27.973 | 0 | 364782 | 6526 | 0 | 0 |
| `condition-6-payouts-r4.json` | PASS | true | 1 | 31.373 | 0 | 471114 | 7095 | 0 | 0 |
| `condition-6-payouts-r5.json` | PASS | true | 2 | 25.299 | 0 | 313614 | 6727 | 0 | 0 |
| `condition-6-settlements-r1.json` | PASS | true | 2 | 42.975 | 0 | 458458 | 10719 | 0 | 0 |
| `condition-6-settlements-r2.json` | PASS | true | 1 | 19.015 | 0 | 226581 | 5304 | 0 | 0 |
| `condition-6-settlements-r3.json` | PASS | true | 2 | 42.123 | 0 | 432738 | 10648 | 0 | 0 |
| `condition-6-settlements-r4.json` | PASS | true | 2 | 30.671 | 0 | 326783 | 8561 | 0 | 0 |
| `condition-6-settlements-r5.json` | PASS | true | 2 | 40.624 | 0 | 597808 | 12095 | 0 | 0 |

Payouts, 5 files: verdict PASS 5 of 5, right first time 4 of 5 (`condition-6-payouts-r2.json` is false, sandbox runs 0, `right_first_time_basis` `no consumer run against v2`). Settlements, 5 files: verdict PASS 5 of 5, right first time 5 of 5.

Across the 10 files: sandbox runs 15, wall time 301.93 s, time stuck 0, tokens 3687418 in and 79474 out, records lost 0, records duplicated 0.
