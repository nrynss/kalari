# Settlements v2: where each behaviour is documented (never shown to an arm)

| Behaviour | Server | Schema (`schema-v2.graphql`) | Developer guide (`clearwell-settlements-api.md`) |
|---|---|---|---|
| **B1** `endCursor` never null, the last page included; `hasNextPage` ends it | `mint(end)` on every page; after the end, an empty page and a new cursor | `endCursor: String!`; `hasNextPage`: "Whether more settlements remain" | "When to stop": "Keep requesting while `pageInfo.hasNextPage` is `true`. `endCursor` is always set, the last page included … its presence doesn't mean more pages remain." |
| **B2** Amended settlements delivered again later | Every 97th settlement re-emitted 230 settlements later (19 repeats) | Not stated | "Amended settlements": "Clearwell delivers it again later in the same traversal. Treat `id` as the key, and keep the version you receive last." |
| **B3** Short and empty pages while `hasNextPage` is true | Pages cut from the internal stream before 4 runs of 200 voided rows are filtered | Not stated | "Short and empty pages": "A page can therefore hold fewer than `first` settlements, or none at all, while `hasNextPage` is still `true`." |

Real sources (bench/README.md): B1 Microsoft Graph delta, Zendesk; B2 Microsoft Graph delta; B3 DynamoDB Query/Scan with a filter, Graph delta.

**Truth:** 1,873 settlements, `st_00001` to `st_01873`. The internal stream is 2,692 rows: 1,873 settlements, 19 repeats, 800 voided rows. Empty pages before the end: 4 at `first: 100`, 12 at 50, 28 at 25. The first empty page comes after about 400 settlements.

| The obvious code | Outcome |
|---|---|
| One v2 request | 50 or 100 of 1,873 |
| Stop on an empty page | 400 of 1,873, one of them twice (an amended repeat arrives before the first empty page) |
| `while endCursor:` | Never ends (empty pages after the end) |
| Stop on `hasNextPage`, append every page | 1,892 records, 19 duplicates |
| Stop on `hasNextPage`, keep the last version per `id` | 1,873, exactly once |
