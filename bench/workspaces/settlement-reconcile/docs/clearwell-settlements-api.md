# Clearwell Settlements API: developer guide

## Versions

Version 2 pages the `settlements` query. Send queries as `POST /v2/graphql` with a JSON body `{"query": ..., "variables": ...}`. Version 1 (`POST /v1/graphql`) stays available while you migrate and will then be retired; requests to it will return `410 Gone`.

## Authentication

Requests in this environment need no credentials.

## Settlements

A settlement is one batch of card payments paid out to your bank account. Each has a unique `id`, the batch date, an amount in cents, a currency and a status.

## Paging (v2)

`settlements(first: Int = 50, after: String)` returns a `SettlementConnection`: the page's settlements in `nodes`, and `pageInfo`. Request up to 100 settlements a page with `first`, and pass the previous page's `pageInfo.endCursor` as `after` to get the next one.

```graphql
query Settlements($after: String) {
  settlements(first: 50, after: $after) {
    nodes { id batchDate amountCents currency status }
    pageInfo { endCursor hasNextPage }
  }
}
```

### When to stop

Keep requesting while `pageInfo.hasNextPage` is `true`. `endCursor` is always set, the last page included, so a later run can resume from where this one finished; its presence doesn't mean more pages remain.

### Short and empty pages

Pages are cut before voided settlements are removed from them. A page can therefore hold fewer than `first` settlements, or none at all, while `hasNextPage` is still `true`. Don't treat a short or empty page as the end.

### Amended settlements

When a settlement is amended after it was delivered, Clearwell delivers it again later in the same traversal. Treat `id` as the key, and keep the version you receive last.

### Cursors

Cursors are opaque: don't parse or construct them, and expect a different value each time, even for the same position. A malformed or expired cursor returns a GraphQL error; start again without `after`.

## Migrating from v1

| v1 | v2 |
|---|---|
| `settlements: [Settlement!]!` | `settlements(first, after): SettlementConnection!` |
| Every settlement in one response | One page per request, `nodes` plus `pageInfo` |

The `Settlement` type is unchanged.
