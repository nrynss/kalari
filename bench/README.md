# The benchmark

How the comparison in [`../product.md`](../product.md) is run so that its result can be believed. The coding model is strong: DeepSeek V4.1 Flash fixed a plain paging upgrade on its first attempt, unprompted defences included ([`reference-paging/`](reference-paging/README.md)). So Kalari's edge can't rest on the model making obvious mistakes. It has to come from what a strong model **can't know** from the specs and docs it is given, and from what Kalari **enforces** rather than suggests.

## What a strong model can't know

It handles anything written in the spec or the docs. It can't handle behaviour that is:

1. **Not in the spec.** Paging rules usually live in prose docs, or nowhere.
2. **Visible only at scale or at the edges.** A record repeated at one page boundary in 25, a short page in the middle of the stream.
3. **Silent.** HTTP 200, plausible counts, exit 0.
4. **Uncheckable without the truth.** If the API never says how many records exist, 2,431 and 2,455 both look like success.

## Where Kalari's edge comes from

| Edge | Shows in | Needs memory |
|---|---|---|
| **Differential check against the old API.** The v1 API stays live during the migration (decided). Kalari runs the old consumer against v1 and the new one against v2 on the same data and compares the record sets: none missing, none extra, each exactly once. **Both arms can reach v1 and have its spec and docs**; only Kalari runs the comparison without being asked | Conditions 4 and 5 | No |
| **Lessons carry behaviour the specs don't.** "Stop on the end flag, never on the token or a short or empty page; dedupe by ID" is learned by running | Condition 5 against 2 and 3 | Yes |
| **Enforcement, not suggestion.** A recalled lesson is a check that must pass, not a note the agent may ignore. Condition 6 (a baseline told to do the same checks) tests whether this matters | Condition 5 against 6 | Yes |
| **Containment.** The aashaan's time cap on a runaway loop; `--no-net` with IP rules; the reference arm's agent-chosen sandbox network | Every condition | No |

If the pilot shows the baseline doing the differential check on its own, or condition 6 matching Kalari, the edge narrows to what's left, and the result says so.

## Where lessons come from

A lesson is written from **what a verified run observed about the API**, not only from a failure. Otherwise a strong agent that passes upgrade one first time leaves nothing to learn, and condition 5 collapses into condition 4.

| Source | Example lesson |
|---|---|
| A failure Clef attributes to the API change, and the fix that passed | "The stream returned a token on its final page; the loop that stopped on the token never ended" |
| **A behaviour the differential check or the run logs observed**, even on a pass | "v2 returned 24 boundary records twice; the passing code deduped by ID" |
| A behaviour the passing code had to handle | "A page came back shorter than the requested limit mid-stream; the passing code ignored page length" |

Every lesson names the change kind (`pagination_changed`), the observation, the run that showed it, and a check. Lessons are only written from sandbox-verified runs.

## Behaviours, each from a documented real API

| Behaviour | The obvious code | Result | Real source |
|---|---|---|---|
| **B1. A token on every page, the last included; an end flag decides** | `while next_page:` | Never ends: the time cap kills it | Zendesk incremental export (an end-of-stream flag; the final cursor is kept for the next run). Microsoft Graph delta (the last page carries a link for the next sync) |
| **B2. Duplicates at page boundaries, on purpose** | Append every page | Extra records (24 in 2,431 at 100 a page) | Zendesk time-based export (duplicates "to prevent items … from being skipped"; dedupe advised). Graph delta ("the same item can appear on any page") |
| **B3. An empty page that still has a token** | `if not items: break` | Silent truncation | DynamoDB Query and Scan with a filter (zero items and a continuation key; only a missing key ends it). Graph delta (empty pages that still continue) |
| **B4. Page size silently capped** | `if len(items) < limit: break` | Truncation after page one | RIPE Atlas (any `limit` over 100 becomes 100). RevenueCat V2 (at most 100 a page, whatever `limit` says) |
| **B5. 429 with `Retry-After` partway** | No retry, or a retry that skips a page | A crash or a missing page | Universal. Held in reserve for the harder fallback |

Sources: [Zendesk: using the incremental export API](https://developer.zendesk.com/documentation/ticketing/managing-tickets/using-the-incremental-export-api/), [Zendesk: incremental exports reference](https://developer.zendesk.com/api-reference/ticketing/ticket-management/incremental_exports/), [Microsoft Graph: delta query overview](https://learn.microsoft.com/en-us/graph/delta-query-overview), [DynamoDB: paginating query results](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Query.Pagination.html), [RIPE Atlas: limit capped at 100](https://mailman.ripe.net/archives/list/ripe-atlas@ripe.net/thread/HFKJHGXLUQWBCHCXY2BJ6LO3CXA7MNBA/), [RevenueCat: max limit per page](https://community.revenuecat.com/general-questions-7/max-limit-value-to-paginate-the-next-page-6248?postid=21519).

**This table is for the benchmark's readers, never for the arms.** What an arm sees uses neutral field names and our own wording, so the model can't recognise a vendor and recall its behaviour from training. The vendors' docs are paraphrased for structure, never copied.

## The upgrade pair (proposed; the pilot decides)

| | Upgrade 1: teaches the lesson | Upgrade 2: measures the comparison |
|---|---|---|
| Domain | **Merchant payout ledger** (`payout-sync`): a lost record is an unpaid merchant, a duplicate is a double payment | **Settlement batches** (`settlement-reconcile`): reconciling daily settlements |
| Format | REST, OpenAPI 3.0. v1 returns every payout in one response; v2 is a time-windowed export | GraphQL. v1 returns a plain list; v2 is a Relay-style connection whose `endCursor` is never null |
| Behaviours | B1 + B2 + B4 | B1 + B2 (repeats across pages) + B3 (empty pages that continue) |
| Vimanam reports | `pagination_changed` on the payouts operation | `pagination_changed` on the settlements query |
| The lesson | A `constraint` on `pagination_changed`: "stop on the end flag, never on the token's presence or a short or empty page; dedupe by ID", with a check: exact count against v1, zero duplicate IDs | Recalled by traversal from `pagination_changed` before the first run in condition 5 |

The dataset is fixed for a run, so records are deduplicated by ID. Upgrade 2 adds B3, which the lesson covers ("never … an empty page") but which upgrade 1 never showed: a fair test of whether a lesson generalises, not just whether it is replayed.

## Conditions

Conditions 1–5 are in product.md. One control is added:

| # | Condition |
|---|---|
| **6** | **Reference setup with a better prompt:** the same task, plus "verify v2's records against v1's, record by record: none missing, none extra, each exactly once". Fresh session, no notes |

If condition 6 matches condition 5, Kalari's value is mostly a good prompt, and we say so. If it doesn't, the claim is stronger: Kalari enforces the check and remembers what it found; a prompt only asks.

## Measures

Defined once, the same for every arm:

| Measure | Definition |
|---|---|
| **Verdict** | The hidden grader's result on the consumer as it stands at the end of the session: every record exactly once, against the dataset's truth |
| **Right first time** | The first run of the consumer against v2, in any sandbox, already passes the grader (checked by grading the code as it stood at that run) |
| **Sandbox runs** | Runs of the consumer against v1 or v2, by the agent or by Kalari |
| **Wall time** | Session start to the agent's final answer, including time stuck in a hung run |
| **Time stuck** | Time spent in runs that ended by a timeout, the agent's or the aashaan's |
| **Tokens** | Input and output, from `/v1/usage` before and after the session |
| **Records lost or duplicated** | For a session whose consumer fails the grader: how many, so "it said done but lost 2,331 payouts" is a number |

Every session, in every arm, is capped at 20 minutes. Results are reported as counts ("4 of 5 against 1 of 5"), never as percentages or "always": five runs is a small sample.

## Protocol

1. **Same inputs for every arm:** the consumer repository, the v1 and v2 specs, **vendor-style prose docs** (decided) in which each behaviour is described somewhere, and the v1 and v2 endpoints. Conditions differ only as the table says.
2. **The same prompt:** "Upgrade this consumer from the v1 API to v2 and verify it against the v2 server." Condition 6 adds its one sentence.
3. **No arm can read the servers.** The v1 and v2 APIs run as their own service, outside every workspace and outside every path the agents may read. The workspace holds the consumer, the specs and the docs; never server code, never a changelog written for the task.
4. **The docs are the weakest point, so they are fixed first.** Written before the pilot, following the structure of the real vendor's docs, with a record (here, not in the docs) of which sentence describes each behaviour. Frozen with the pair. Never edited after seeing a result.
5. **The hidden grader** runs after each session in a fresh `--no-net` microVM. No arm sees it or is told what it checks.
6. **Pilot the baseline first.** The reference setup only: each behaviour alone in a fresh session, five runs each; then the proposed pair under conditions 1–3 and 6, five runs each. Record every measure.
7. **Freeze before Kalari runs.** Choose the pair from the pilot's numbers, then freeze and commit the APIs, the docs, the prompt and the grader before the Kalari arm's first run.
8. **Publish every run**, baseline passes included, with its log, verdict and measures.

## The network route (proved)

**Each API service runs in its own microVM, egress denied, with its port published on the VM's public IP.** Arms reach it at `<vm-public-ip>:<port>`. Proved on the VM with a host-process route (A) and the microVM route (B):

| From | API on host (A) | API in microVM (B) | VM's SSH | Loopback | VM's tailnet IP | Metadata | Internet |
|---|---|---|---|---|---|---|---|
| Reference arm (default network) | 200 | 200 | **open (banner)** | refused | refused | denied | open |
| Kalari arm (`--no-net` + `allow@<vm-public-ip>/32:tcp:<ports>`) | 200 | 200 | refused | refused | refused | denied | refused |
| The internet (laptop, public IP) | no answer | no answer | no answer | — | — | — | — |
| The tailnet (laptop) | refused | refused | — | — | — | — | — |

- **Route B is the choice**: the server's code lives only inside its microVM, so no arm and no agent tool on the host can read it, and its own egress is denied. Route A (a host process bound to the public IP) also works and is the fallback.
- **`--no-net` denies ingress too**, so a server started with it never answers its published port: the connection is accepted, then nothing. Start API microVMs with **`--net-default-egress deny`** (ingress stays allowed), then `-p <vm-public-ip>:<host-port>:<guest-port>`.
- **Bind to the VM's public IP, never `0.0.0.0`**: then the port isn't on loopback or the tailnet, and the Vultr firewall (no rules) drops it from the internet.
- **The Kalari arm's rule can name a port range**: `allow@<vm-public-ip>/32:tcp:18080-18081`.
- **The reference arm can also reach the VM's SSH** (hairpin traffic skips the Vultr firewall). Nothing else listens on the public IP, and SSH accepts keys only; record it as part of the containment comparison.
- A background server inside `msb exec` must redirect its output (`(python3 api.py >/dev/null 2>&1 &)`), or `exec` waits forever; and give it a moment to bind before the first request.

## Isolating the agent between runs

**OpenCode 2's `opencode run` starts a background daemon, `opencode serve --service`, that outlives the run** (re-parented to PID 1, with `microsandbox-mcp` under it). After the reference run it was still alive half an hour later, **with the inference key in its environment and in `microsandbox-mcp`'s**. The key was never written to disk (its database, logs and the run's output were scanned). It also keeps every session in one shared `~/.local/share/opencode/opencode.db`.

So every benchmark run:

- uses **`opencode run --standalone`** (a private server that exits with the run; verified: nothing left running);
- gets its **own `XDG_DATA_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME`** (verified: the shared database is untouched), so a "fresh session" is really fresh, and condition 1's continuous session is a deliberate `--session` on the same directory;
- ends with a check that no `opencode` or `microsandbox-mcp` process is left.

## If the baseline passes the pilot anyway

Both (decided, to revisit after the pilot):

- **Harder, still real behaviours.** Combine more of B1–B5 in one upgrade, or add B5. Nothing invented: every behaviour keeps a real source.
- **Lead with cost, attempts and containment** instead of the pass rate: sandbox runs, time stuck, wall time and tokens to a verified result, and what each arm's sandbox could reach while it worked.

## Budget

At the measured ~$0.05 a run for a small task, budgeting ~$0.25 for these:

- **Pilot:** each behaviour alone, fresh session, 5 runs: 25. The proposed pair under conditions 1–3 and 6, 5 runs each: ~40. About 65 runs, **~$16**.
- **Frozen comparison:** 6 conditions × 5 repeats: ~60 runs, **~$15**.

## Layout

```text
bench/
├── README.md                this design
├── reference-paging/        the stack check (not a comparison)
├── apis/                    built: the payouts (REST) and settlements (GraphQL) services, v1 and v2;
│                            QUIRKS.md per service; reference consumers; deploy.sh for the VM
├── workspaces/              built: what an arm gets (consumer, specs, vendor-style docs)
├── prompts/                 built: the shared prompt and condition 6's
├── graders/                 built: grade.py, the hidden grader
├── tests/quirks.sh          built, in the gate: every obvious consumer fails as predicted, the correct one passes
├── pilot/                   to build: pilot runs, scripts and results
└── runs/                    to build: the frozen comparison, every run with its log, verdict and measures
```
