# The benchmark

How the comparison in [`../product.md`](../product.md) is run so that its result can be believed. The coding model is strong: DeepSeek V4.1 Flash fixed a plain paging upgrade on its first attempt, unprompted defences included ([`reference-paging/`](reference-paging/README.md)). So Kalari's edge can't rest on the model making obvious mistakes. It has to come from what a strong model **can't know** from the specs and docs it is given.

## What a strong model can't know

It handles anything written in the spec or the docs. It can't handle behaviour that is:

1. **Not in the spec.** Paging rules usually live in prose docs, or nowhere.
2. **Visible only at scale or at the edges.** A record repeated at one page boundary in 25, a short page in the middle of the stream.
3. **Silent.** HTTP 200, plausible counts, exit 0.
4. **Uncheckable without the truth.** If the API never says how many records exist, 2,431 and 2,455 both look like success.

## Where Kalari's edge comes from

| Edge | Shows in | Needs memory |
|---|---|---|
| **Differential check against the old API.** The v1 API stays live during the migration (decided). Kalari runs the old consumer against v1 and the new one against v2 on the same data and compares the record sets: none missing, none extra, each exactly once | Condition 4 | No |
| **Lessons carry behaviour the specs don't.** "Stop on the end flag, never on the token or a short page; dedupe by ID and version" is learned by running | Condition 5 against 2 and 3 | Yes |
| **Containment.** The aashaan's time cap on a runaway loop; `--no-net` with IP rules; the reference arm's agent-chosen sandbox network | Every condition | No |

If the pilot shows the baseline doing the differential check on its own, the edge narrows to memory and containment, and the result says so.

## Behaviours, each from a documented real API

| Behaviour | The obvious code | Result | Real source |
|---|---|---|---|
| **B1. A token on every page, the last included; an end flag decides** | `while next_page:` | Never ends: the time cap kills it | Zendesk incremental export (`end_of_stream`; the final cursor is kept for the next run). Microsoft Graph delta (the last page carries a `deltaLink` for the next sync) |
| **B2. Duplicates at page boundaries, on purpose** | Append every page | Extra records (24 in 2,431 at 100 a page) | Zendesk time-based export ("contain duplicate items to prevent items … from being skipped"; dedupe on `id` + `updated_at`). Graph delta ("the same item can appear on any page") |
| **B3. An empty page that still has a token** | `if not items: break` | Silent truncation | DynamoDB Query and Scan with a filter (zero items and a `LastEvaluatedKey`; only a missing key ends it). Graph delta (empty pages with a `nextLink`) |
| **B4. Page size silently capped** | `if len(items) < limit: break` | Truncation after page one | RIPE Atlas (any `limit` over 100 becomes 100). RevenueCat V2 (at most 100 a page, whatever `limit` says) |
| **B5. 429 with `Retry-After` partway** | No retry, or a retry that skips a page | A crash or a missing page | Universal |

Sources: [Zendesk: using the incremental export API](https://developer.zendesk.com/documentation/ticketing/managing-tickets/using-the-incremental-export-api/), [Zendesk: incremental exports reference](https://developer.zendesk.com/api-reference/ticketing/ticket-management/incremental_exports/), [Microsoft Graph: delta query overview](https://learn.microsoft.com/en-us/graph/delta-query-overview), [DynamoDB: paginating query results](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Query.Pagination.html), [RIPE Atlas: limit capped at 100](https://mailman.ripe.net/archives/list/ripe-atlas@ripe.net/thread/HFKJHGXLUQWBCHCXY2BJ6LO3CXA7MNBA/), [RevenueCat: max limit per page](https://community.revenuecat.com/general-questions-7/max-limit-value-to-paginate-the-next-page-6248?postid=21519).

Each mock says in its docs which real API it copies. No live third-party API is ever called.

## The upgrade pair (proposed; the pilot decides)

| | Upgrade 1: teaches the lesson | Upgrade 2: measures the comparison |
|---|---|---|
| Domain | **Merchant payout ledger** (`payout-sync`): a lost record is an unpaid merchant, a duplicate is a double payment | **Settlement batches** (`settlement-reconcile`): reconciling daily settlements |
| Format | REST, OpenAPI 3.0. v1 `GET /v1/payouts` returns every payout; v2 is a time-windowed export modelled on Zendesk | GraphQL. v1 `settlements: [Settlement!]!`; v2 `settlements(first, after): SettlementConnection` with `pageInfo { endCursor: String!, hasNextPage }` |
| Behaviours | B1 + B2 + B4 | B1 (`endCursor` never null) + B2 (repeats across pages, Graph-style) + B3 (empty pages, DynamoDB-style) |
| Vimanam reports | `pagination_changed` on the payouts operation | `pagination_changed` on `Query.settlements` |
| The lesson | A `constraint` on `pagination_changed`: "stop on the end flag, never on the token's presence or a short or empty page; dedupe by ID and version", with a check: exact count against v1, zero duplicate IDs | Recalled by traversal from `pagination_changed` before attempt 1 in condition 5 |

Upgrade 2 adds B3, which the lesson covers ("never … an empty page") but which upgrade 1 never showed. That is a fair test of whether a lesson generalises, not just whether it is replayed.

## Protocol

1. **Same inputs for both arms:** the consumer repository, the v1 and v2 specs, and **vendor-style prose docs** (decided) in which each behaviour is described somewhere, as the real vendors do. "It was in the docs and the agent still missed it" is the stronger result.
2. **The same prompt for both arms:** "Upgrade this consumer from the v1 API to v2 and verify it against the v2 server."
3. **No arm can read the servers.** The v1 and v2 APIs run as their own service, in their own microVM, reachable only through IP allow rules. The workspace holds the consumer, the specs and the docs; never server code, never a changelog written for the task.
4. **The hidden grader** runs after each attempt in a fresh `--no-net` microVM: every record exactly once, against the dataset's truth. No arm sees it or is told what it checks.
5. **Pilot the baseline first.** The reference setup only: each behaviour alone in a fresh session, five runs each; then the proposed pair under conditions 1–3, five runs each. Record failure rates, attempts, tokens and outcomes.
6. **Freeze before Kalari runs.** Choose the pair from the pilot's numbers, then freeze the APIs, the docs, the prompt and the grader, and commit them before the Kalari arm's first run.
7. **Publish every run**, baseline passes included, with its log, verdict and tokens.

## If the baseline passes the pilot anyway

Both (decided, to revisit after the pilot):

- **Harder, still real behaviours.** Combine more of B1–B5 in one upgrade, or add B5. Nothing invented: every behaviour keeps a real source.
- **Lead with cost, attempts and containment** instead of the pass rate: runs, retries, seconds and tokens to a verified result, and what each arm's sandbox could reach while it worked.

## Budget

At the measured ~$0.05 a run for a small task, budgeting ~$0.25 for these:

- **Pilot:** each behaviour alone, fresh session (condition 3), 5 runs: 25 runs. The proposed pair, conditions 1–3, 5 runs each (conditions 1 and 2 span both upgrades): ~30 runs. About 55 runs, **~$14**.
- **Frozen comparison:** 5 conditions × 5 repeats, both upgrades: ~50 runs, **~$13**.

Step 5 of the protocol states the pilot's shape; this is its cost.

## Layout (to build)

```text
bench/
├── README.md                this design
├── reference-paging/        the stack check (not a comparison)
├── apis/                    the mock v1 and v2 services, one per upgrade, each naming its real source
├── workspaces/              what an arm gets: consumer, specs, docs
├── graders/                 the hidden graders
├── pilot/                   pilot runs: scripts and results
└── runs/                    the frozen comparison: every run, its log, verdict and tokens
```
