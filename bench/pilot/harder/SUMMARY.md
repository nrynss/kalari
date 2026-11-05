# Harder-pair pilot counts

Reference arm on the harder pair: payouts B1+B2+B4+B5, settlements B1+B2+B3+B5. Ten B5-only sessions (fresh condition-3, isolated adapter) diagnose retry alone; forty full-pair sessions (conditions 1, 2, 3, 6) answer the benchmark question. The 70 old-pilot rows under `bench/pilot/results/` are published separately and never merged here. B5-in-both remains the pair.

HTTP retries (B5 429 responses / matching retry attempts / successful matching retries, agent phase then grading phase) are reported separately from consumer sandbox runs. A `+` marks a total with an unknown phase (journal overflow or missing journal counts as unknown, never zero). One agent-phase window is unknown: `condition-6-payouts-r5.json` (journal overflow on the live API: the agent made more requests than the journal holds).

## B5-only counts (isolated adapter)

| Upgrade | Runs | PASS | Right first time | Sandbox runs | Lost | Duplicated | Agent 429/retries/matched | Grading 429/retries/matched | Cost (USD) | Results |
|---|---|---:|---:|---:|---:|---:|---|---|---:|---|
| payouts | 5 | 5 | 5 | 9 | 0 | 0 | 12/10/10 | 10/10/10 | 0.208079 | [1](results/behaviour-payouts-B5-r1.json), [2](results/behaviour-payouts-B5-r2.json), [3](results/behaviour-payouts-B5-r3.json), [4](results/behaviour-payouts-B5-r4.json), [5](results/behaviour-payouts-B5-r5.json) |
| settlements | 5 | 5 | 5 | 12 | 0 | 0 | 24/22/22 | 10/10/10 | 0.267897 | [1](results/behaviour-settlements-B5-r1.json), [2](results/behaviour-settlements-B5-r2.json), [3](results/behaviour-settlements-B5-r3.json), [4](results/behaviour-settlements-B5-r4.json), [5](results/behaviour-settlements-B5-r5.json) |

B5-only list-price spend: $0.475976; all 50 harder-pair rows: $3.736209.

## Condition counts (full pair, shared reference setup)

| Condition | Upgrade | Runs | PASS | Right first time | Sandbox runs | Lost | Duplicated | Agent 429/retries/matched | Grading 429/retries/matched | Results |
|---:|---|---:|---:|---:|---:|---:|---:|---|---|---|
| 1 | payouts | 5 | 5 | 5 | 12 | 0 | 0 | 9/7/7 | 10/10/10 | [1](results/condition-1-payouts-r1.json), [2](results/condition-1-payouts-r2.json), [3](results/condition-1-payouts-r3.json), [4](results/condition-1-payouts-r4.json), [5](results/condition-1-payouts-r5.json) |
| 1 | settlements | 5 | 5 | 5 | 8 | 0 | 0 | 17/15/15 | 10/10/10 | [1](results/condition-1-settlements-r1.json), [2](results/condition-1-settlements-r2.json), [3](results/condition-1-settlements-r3.json), [4](results/condition-1-settlements-r4.json), [5](results/condition-1-settlements-r5.json) |
| 2 | payouts | 5 | 5 | 5 | 9 | 0 | 0 | 14/10/10 | 10/10/10 | [1](results/condition-2-payouts-r1.json), [2](results/condition-2-payouts-r2.json), [3](results/condition-2-payouts-r3.json), [4](results/condition-2-payouts-r4.json), [5](results/condition-2-payouts-r5.json) |
| 2 | settlements | 5 | 5 | 5 | 13 | 0 | 0 | 22/18/18 | 10/10/10 | [1](results/condition-2-settlements-r1.json), [2](results/condition-2-settlements-r2.json), [3](results/condition-2-settlements-r3.json), [4](results/condition-2-settlements-r4.json), [5](results/condition-2-settlements-r5.json) |
| 3 | payouts | 5 | 5 | 5 | 13 | 0 | 0 | 16/14/14 | 10/10/10 | [1](results/condition-3-payouts-r1.json), [2](results/condition-3-payouts-r2.json), [3](results/condition-3-payouts-r3.json), [4](results/condition-3-payouts-r4.json), [5](results/condition-3-payouts-r5.json) |
| 3 | settlements | 5 | 5 | 5 | 9 | 0 | 0 | 11/11/11 | 10/10/10 | [1](results/condition-3-settlements-r1.json), [2](results/condition-3-settlements-r2.json), [3](results/condition-3-settlements-r3.json), [4](results/condition-3-settlements-r4.json), [5](results/condition-3-settlements-r5.json) |
| 6 | payouts | 5 | 5 | 5 | 9 | 0 | 0 | 9/9/9+ | 10/10/10 | [1](results/condition-6-payouts-r1.json), [2](results/condition-6-payouts-r2.json), [3](results/condition-6-payouts-r3.json), [4](results/condition-6-payouts-r4.json), [5](results/condition-6-payouts-r5.json) |
| 6 | settlements | 5 | 5 | 5 | 12 | 0 | 0 | 10/9/9 | 10/10/10 | [1](results/condition-6-settlements-r1.json), [2](results/condition-6-settlements-r2.json), [3](results/condition-6-settlements-r3.json), [4](results/condition-6-settlements-r4.json), [5](results/condition-6-settlements-r5.json) |

## Condition 1

| Result file | Verdict | Right first time | Sandbox runs | Wall (s) | Stuck (s) | Tokens in | Tokens out | Lost | Duplicated | Agent 429/ret/match | Grading 429/ret/match | Cost (USD) | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `condition-1-payouts-r1.json` | PASS | true | 5 | 55.896 | 0 | 411346 | 6933 | 0 | 0 | 2/2/2 | 2/2/2 | 0.065862 |  |
| `condition-1-payouts-r2.json` | PASS | true | 3 | 53.413 | 0 | 371423 | 9932 | 0 | 0 | 1/1/1 | 2/2/2 | 0.061673 |  |
| `condition-1-payouts-r3.json` | PASS | true | 2 | 53.943 | 0 | 379058 | 10119 | 0 | 0 | 2/1/1 | 2/2/2 | 0.062930 |  |
| `condition-1-payouts-r4.json` | PASS | true | 1 | 41.782 | 0 | 336174 | 8605 | 0 | 0 | 1/1/1 | 2/2/2 | 0.055589 |  |
| `condition-1-payouts-r5.json` | PASS | true | 1 | 57.237 | 0 | 604649 | 10052 | 0 | 0 | 3/2/2 | 2/2/2 | 0.096729 |  |
| `condition-1-settlements-r1.json` | PASS | true | 2 | 36.659 | 0 | 643905 | 8410 | 0 | 0 | 3/2/2 | 2/2/2 | 0.101632 | continued session |
| `condition-1-settlements-r2.json` | PASS | true | 2 | 72.889 | 0 | 663918 | 11165 | 0 | 0 | 4/4/4 | 2/2/2 | 0.106287 | continued session |
| `condition-1-settlements-r3.json` | PASS | true | 1 | 46.616 | 0 | 564393 | 11044 | 0 | 0 | 3/3/3 | 2/2/2 | 0.091285 | continued session |
| `condition-1-settlements-r4.json` | PASS | true | 2 | 56.974 | 0 | 655584 | 12528 | 0 | 0 | 4/3/3 | 2/2/2 | 0.105854 | continued session |
| `condition-1-settlements-r5.json` | PASS | true | 1 | 28.429 | 0 | 785103 | 8044 | 0 | 0 | 3/3/3 | 2/2/2 | 0.122592 | continued session |

## Condition 2

| Result file | Verdict | Right first time | Sandbox runs | Wall (s) | Stuck (s) | Tokens in | Tokens out | Lost | Duplicated | Agent 429/ret/match | Grading 429/ret/match | Cost (USD) | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `condition-2-payouts-r1.json` | PASS | true | 1 | 37.718 | 0 | 258978 | 8558 | 0 | 0 | 2/2/2 | 2/2/2 | 0.043981 |  |
| `condition-2-payouts-r2.json` | PASS | true | 2 | 36.858 | 0 | 345175 | 7741 | 0 | 0 | 3/2/2 | 2/2/2 | 0.056421 |  |
| `condition-2-payouts-r3.json` | PASS | true | 2 | 47.552 | 0 | 561376 | 11302 | 0 | 0 | 2/2/2 | 2/2/2 | 0.090988 |  |
| `condition-2-payouts-r4.json` | PASS | true | 1 | 55.445 | 0 | 535632 | 10302 | 0 | 0 | 1/1/1 | 2/2/2 | 0.086526 |  |
| `condition-2-payouts-r5.json` | PASS | true | 3 | 82.408 | 0 | 620136 | 12648 | 0 | 0 | 6/3/3 | 2/2/2 | 0.100609 |  |
| `condition-2-settlements-r1.json` | PASS | true | 1 | 69.106 | 0 | 320935 | 10973 | 0 | 0 | 3/2/2 | 2/2/2 | 0.054724 | notes attached |
| `condition-2-settlements-r2.json` | PASS | true | 3 | 78.217 | 0 | 580341 | 12781 | 0 | 0 | 5/5/5 | 2/2/2 | 0.094720 | notes attached |
| `condition-2-settlements-r3.json` | PASS | true | 3 | 94.293 | 0 | 477494 | 12456 | 0 | 0 | 4/3/3 | 2/2/2 | 0.079098 | notes attached |
| `condition-2-settlements-r4.json` | PASS | true | 2 | 48.624 | 0 | 502915 | 15346 | 0 | 0 | 3/2/2 | 2/2/2 | 0.084645 | notes attached |
| `condition-2-settlements-r5.json` | PASS | true | 4 | 65.41 | 0 | 895768 | 16936 | 0 | 0 | 7/6/6 | 2/2/2 | 0.144527 | notes attached |

## Condition 3

| Result file | Verdict | Right first time | Sandbox runs | Wall (s) | Stuck (s) | Tokens in | Tokens out | Lost | Duplicated | Agent 429/ret/match | Grading 429/ret/match | Cost (USD) | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `condition-3-payouts-r1.json` | PASS | true | 1 | 47.529 | 0 | 351570 | 11614 | 0 | 0 | 1/1/1 | 2/2/2 | 0.059704 |  |
| `condition-3-payouts-r2.json` | PASS | true | 6 | 59.546 | 0 | 710036 | 12604 | 0 | 0 | 1/1/1 | 2/2/2 | 0.114068 |  |
| `condition-3-payouts-r3.json` | PASS | true | 2 | 636.608 | 600.325 | 328000 | 7540 | 0 | 0 | 3/3/3 | 2/2/2 | 0.053724 |  |
| `condition-3-payouts-r4.json` | PASS | true | 3 | 57.631 | 0 | 623034 | 11233 | 0 | 0 | 7/7/7 | 2/2/2 | 0.100195 |  |
| `condition-3-payouts-r5.json` | PASS | true | 1 | 113.57 | 61.091 | 517782 | 9915 | 0 | 0 | 4/2/2 | 2/2/2 | 0.083616 |  |
| `condition-3-settlements-r1.json` | PASS | true | 2 | 47.328 | 0 | 351152 | 10584 | 0 | 0 | 2/2/2 | 2/2/2 | 0.059023 |  |
| `condition-3-settlements-r2.json` | PASS | true | 3 | 49.932 | 0 | 491308 | 9784 | 0 | 0 | 3/3/3 | 2/2/2 | 0.079567 |  |
| `condition-3-settlements-r3.json` | PASS | true | 1 | 43.289 | 0 | 291057 | 10221 | 0 | 0 | 1/1/1 | 2/2/2 | 0.049791 |  |
| `condition-3-settlements-r4.json` | PASS | true | 2 | 50.45 | 0 | 448741 | 11986 | 0 | 0 | 2/2/2 | 2/2/2 | 0.074503 |  |
| `condition-3-settlements-r5.json` | PASS | true | 1 | 55.878 | 0 | 382744 | 11500 | 0 | 0 | 3/3/3 | 2/2/2 | 0.064312 |  |

## Condition 6

| Result file | Verdict | Right first time | Sandbox runs | Wall (s) | Stuck (s) | Tokens in | Tokens out | Lost | Duplicated | Agent 429/ret/match | Grading 429/ret/match | Cost (USD) | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `condition-6-payouts-r1.json` | PASS | true | 1 | 55.62 | 0 | 419100 | 9039 | 0 | 0 | 4/4/4 | 2/2/2 | 0.068288 |  |
| `condition-6-payouts-r2.json` | PASS | true | 3 | 178.878 | 121.608 | 536610 | 10740 | 0 | 0 | 1/1/1 | 2/2/2 | 0.086935 |  |
| `condition-6-payouts-r3.json` | PASS | true | 1 | 39.383 | 0 | 284347 | 9128 | 0 | 0 | 1/1/1 | 2/2/2 | 0.048129 |  |
| `condition-6-payouts-r4.json` | PASS | true | 3 | 70.135 | 0 | 433782 | 13740 | 0 | 0 | 3/3/3 | 2/2/2 | 0.073311 |  |
| `condition-6-payouts-r5.json` | PASS | true | 1 | 182.351 | 0 | 497465 | 14723 | 0 | 0 | unknown | 2/2/2 | 0.083454 |  |
| `condition-6-settlements-r1.json` | PASS | true | 2 | 51.225 | 0 | 685901 | 13984 | 0 | 0 | 3/2/2 | 2/2/2 | 0.111276 |  |
| `condition-6-settlements-r2.json` | PASS | true | 1 | 45.06 | 0 | 412917 | 9042 | 0 | 0 | 2/2/2 | 2/2/2 | 0.067363 |  |
| `condition-6-settlements-r3.json` | PASS | true | 2 | 68.679 | 15.951 | 736884 | 13082 | 0 | 0 | 1/1/1 | 2/2/2 | 0.118382 |  |
| `condition-6-settlements-r4.json` | PASS | true | 2 | 54.954 | 0 | 491711 | 12149 | 0 | 0 | 2/2/2 | 2/2/2 | 0.081046 |  |
| `condition-6-settlements-r5.json` | PASS | true | 5 | 350.724 | 0 | 446283 | 16553 | 0 | 0 | 2/2/2 | 2/2/2 | 0.076874 |  |
