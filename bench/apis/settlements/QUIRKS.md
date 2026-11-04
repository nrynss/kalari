# Settlements v2: where each behaviour is documented (never shown to an arm)

| Behaviour | Server | Schema (`schema-v2.graphql`) | Developer guide (`clearwell-settlements-api.md`) |
|---|---|---|---|
| **B1** `endCursor` never null, the last page included. `hasNextPage` ends it | `mint(end)` runs on every page. After the end, an empty page and a new cursor | `endCursor: String!`. `hasNextPage`: "Whether more settlements remain" | "When to stop": "Keep requesting while `pageInfo.hasNextPage` is `true`. `endCursor` is always set, the last page included … its presence doesn't mean more pages remain." |
| **B2** Amended settlements delivered again later | Every 97th settlement is first delivered in its version before the amendment, then again 230 settlements later in its final version (19 repeats). The final has `status: ADJUSTED` and 1,250 cents less. v1 and the grader's truth hold the final version | Not stated | "Amended settlements": "Clearwell delivers it again later in the same traversal. Treat `id` as the key, and keep the version you receive last." |
| **B3** Short and empty pages while `hasNextPage` is true | Pages are cut from the internal stream before 4 runs of 200 voided rows are filtered | Not stated | "Short and empty pages": "A page can therefore hold fewer than `first` settlements, or none at all, while `hasNextPage` is still `true`." |
| **B5** One `429` with `Retry-After: 1` partway. The identical retry succeeds | The server throttles the first request of a traversal at or past offset 1000 once. The first response mints a fresh traversal id and carries it inside the signed `after` cursor. A request clears the throttle only when the exact query text, the operation name and every variable match the failed one. A named or inline fragment resolves to the same field and gets the same throttle | Not stated. A 429 is a transport failure | "Rate limits and retries": "Treat a 429 as a transient transport failure … send the identical request again … the query text, the operation name and every variable are the same" |

Real sources (bench/README.md): B1 Microsoft Graph delta, Zendesk. B2 Microsoft Graph delta. B3 DynamoDB Query/Scan with a filter, Graph delta. B5 universal.

**Truth:** 1,873 settlements, `st_00001` to `st_01873`. The internal stream is 2,692 rows: 1,873 settlements, 19 repeats, 800 voided rows. Empty pages before the end: 4 at `first: 100`, 12 at 50, 28 at 25. The first empty page comes after about 400 settlements.

| The obvious code | Outcome |
|---|---|
| One v2 request | 50 or 100 of 1,873. At 100, `st_00097` in its old version |
| Stop on an empty page | 400 of 1,873, one of them twice. 4 in their old version (4 amended settlements before the first empty page, only 1 repeated in time) |
| `while endCursor:` | Never ends (empty pages after the end) |
| Stop on `hasNextPage`, append every page | 1,892 records, 19 duplicates, the 19 first copies old |
| Stop on `hasNextPage`, keep the first version per `id` (`if id not in seen`) | 1,873 once each, **19 with the old amount and status** |
| Stop on `hasNextPage`, keep the last version per `id` | 1,873, exactly once |
| No retry on the 429 | The run crashes at the throttle and writes nothing |
| Treat the 429 as the end and exit 0 | 795 records, 1,078 missing, 3 of them in their old version |

## Retry journal (measurement only)

`--retry-journal PATH` writes one JSON event per request: timestamp, keyed client digest, HTTP status, request fingerprint digest, traversal digest, `throttled`, `retry_candidate`, `matching_retry`. It holds no cursor, no query, no variable, no token and no address.

The harness truncates the journal at a phase start and reads it at a phase end. A missing journal, a malformed or wrong-typed event, an overflow marker or an eviction marker is `unknown`, never zero. The server writes the overflow marker on every request at or past the journal limit. A phase with a request after a truncate then reads as unknown. The server also marks the journal when the B5 state cap drops a traversal, because that traversal can see a second 429. `retry_candidate` marks a request that presented the throttled cursor. `matching_retry` marks the one whose exact query, operation name and variables matched.

A document with more than one settlements field that carries a non-null `after` is ambiguous, because the server cannot tell which traversal is paging. The server rejects it with 400 and starts no traversal. A field with a null `after` does not compete with the field that carries the paging cursor.

The grading read also rejects a live API that saw any grading-phase request and a grading API with more clients than the grading passes that ran, one or two. It reports unknown instead of a count.
