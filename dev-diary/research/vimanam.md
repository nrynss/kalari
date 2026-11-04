# Vimanam on the benchmark specs (T0.3)

Kalari's `what_changed` rests on Vimanam reporting `pagination_changed`, and condition 5 rests on Lambo finding the lesson by that change kind. **On the benchmark specs as built, Vimanam reports it for neither upgrade.** Recordings are in [`../../testdata/vimanam/`](../../testdata/vimanam/README.md).

## Versions

- **Vimanam 2.0.0** (crates.io, the latest release): OpenAPI and protobuf. **No GraphQL**: GraphQL support ([noemaforge/vimanam#133](https://github.com/noemaforge/vimanam/pull/133), closing #125) was merged about an hour after the 2.0.0 release was tagged. It's on `main`, unreleased. *An earlier note here said all three formats shipped in 2.0.0; that was wrong for GraphQL.*
- `main` at `491b02c` builds as `vimanam 2.0.0` (the version wasn't bumped), which makes the two easy to confuse. Check `vimanam diff --help`, or try a `.graphql` file: 2.0.0 tries to parse it as OpenAPI.
- `~/.local/bin/vimanam` (1.7.0) and an old `target/release` build (1.4.2) predate both. The 1.7.0 binary's `vimanam diff --help` is `vimanam diff [OPTIONS] [OLD] [NEW]`. It has `--from-ref` and `--to-ref`. It does not list `--context` or `--max-tokens`. The runner emits those two flags only for a GraphQL pair (T3.1a). An OpenAPI diff does not get them. Git refs are not wired from the 1.7.0 flags.

## Results

| Spec | Vimanam | Change kinds | `pagination_changed` |
|---|---|---|---|
| Payouts as built: `/v1/payouts` → `/v2/payouts`, response field `cursor` | 2.0.0, `main` | `operation_removed`, `operation_added`, `type_added` | **No** |
| Payouts, same path `/payouts` (version in the server URL) | 2.0.0 | `operation_renamed`, `argument_added` ×2, `field_added` ×2, `field_required_changed` ×2, `result_added`, `type_added` | No |
| Payouts, same path + response field `next_cursor` | 2.0.0 | as above + `pagination_changed` | **Yes**: `review`, `pagination_inferred`, confidence `inferred` |
| Settlements as built: `nodes` + `pageInfo` | 2.0.0 | parse error (not OpenAPI) | — |
| Settlements as built | `main` | `field_type_changed` (list → `SettlementConnection!`), `argument_added` ×2, `type_added` ×2 | **No** |
| Settlements + `edges { node cursor }` | `main` | as above + `pagination_changed` | **Yes**: `RELAY_CONNECTION_ADOPTED`, confidence `declared` |

## Why: the rules

**OpenAPI** (`src/contract/openapi.rs`, `pagination()`): reported only when **the same method and path** exist in both versions, the operation has a query parameter from `page, size, pageSize, page_size, pageToken, page_token, cursor, limit, offset`, and a 2xx response has an array property plus a continuation property named exactly **`nextPageToken`, `next_page_token`, `nextPage`, `next_page`, `nextCursor` or `next_cursor`**. Termination flags (`has_more`, `drained`, an end-of-stream marker) aren't considered.

**GraphQL** (`src/contract/graphql.rs`, `pagination_evidence()`): a Relay connection needs a named object or interface result with `pageInfo` and **`edges` whose type has `node`**, plus `first`/`after` (or `last`/`before`). A `nodes` list, the shortcut GitHub's API offers beside `edges`, doesn't qualify.

## The gaps, filed

Filed with test matrices (every case a real run) and the benchmark specs inline: [vimanam#136](https://github.com/noemaforge/vimanam/issues/136) (a release with GraphQL), [vimanam#137](https://github.com/noemaforge/vimanam/issues/137) (version prefixes), [vimanam#138](https://github.com/noemaforge/vimanam/issues/138) (continuation fields), [vimanam#139](https://github.com/noemaforge/vimanam/issues/139) (`nodes` connections). The matrices showed more than the two cases first hit: a versioned path hides every change even with the `operationId` unchanged; 4 of 15 real-world continuation names are detected and no nested one is; `edges`, forward or backward, is detected and `nodes` alone never is.

The issue text as first drafted:

**1. OpenAPI: an operation moved to a new version prefix is reported as removed and added.**
Many real APIs version in the path (`/v1/payouts` → `/v2/payouts`). Vimanam matches operations by method and path, so a versioned upgrade yields only `operation_removed` and `operation_added`: no argument, field or pagination changes, which is exactly what a consumer upgrading needs. Proposed: match across a version prefix (`/v\d+/`, or a `--version-prefix` pattern), or by an unchanged `operationId`, and report `operation_moved` with the field-level changes beneath it. Reproduce: `bench/workspaces/payout-sync/specs/openapi-v1.yaml` against `openapi-v2.yaml`.

**2. OpenAPI: the continuation-field list misses common names, and ignores end flags.**
`cursor`, `next`, `after`, `after_cursor`, `continuation_token`, `nextLink`, `@odata.nextLink`, `LastEvaluatedKey` and similar don't count, so `pagination_changed` is missed on real APIs that use them. Proposed: a wider list, with the match recorded in `details` so consumers can judge it; and termination flags (`has_more`, `hasMore`, `end_of_stream`, `drained`, `is_last`) as supporting evidence. Reproduce: `testdata/vimanam/probes/payouts-samepath-*.yaml` (a same-path spec with `cursor` isn't detected; renamed to `next_cursor`, it is).

**3. GraphQL: a connection with `nodes` and no `edges` isn't recognised.**
A connection exposing `nodes: [T!]!` and `pageInfo`, with `first`/`after`, is a common shape (GitHub's API offers `nodes` beside `edges`; some APIs offer only `nodes`). Vimanam requires `edges { node }`, so a list-to-connection upgrade reports only `field_type_changed`. Proposed: accept `nodes` plus `pageInfo` as a connection, with confidence `declared` if `pageInfo` has `hasNextPage` and `endCursor`. Reproduce: `bench/workspaces/settlement-reconcile/specs/schema-v1.graphql` against `schema-v2.graphql` (and `testdata/vimanam/probes/settlements-edges-*.graphql` with `edges` added, which is detected).

**Also:** a release including #133, so a GraphQL-capable Vimanam can be a declared dependency rather than a build of `main`. Bumping the version on `main` past 2.0.0 would also stop the two from being confused.

## Vimanam 2.1.0: both specs detected, as built (T0.6)

Released with fixes for all four issues (closed). On the benchmark specs, **unchanged**:

| Spec | Change kinds | `pagination_changed` |
|---|---|---|
| Payouts (OpenAPI) | `operation_moved`, `operation_renamed`, `argument_added` ×2, `field_added` ×2, `field_required_changed` ×2, `result_added`, `type_added`, `pagination_changed` | **Yes**: `pagination_inferred`, continuation `cursor` marked generic, end flag `drained` as evidence |
| Settlements (GraphQL) | `argument_added` ×2, `type_added` ×2, `field_type_changed`, `pagination_changed` | **Yes**: `RELAY_CONNECTION_ADOPTED`, `declared`, `connection_fields: "nodes"` |

The issue matrices on 2.1.0: version prefixes 5/5 (as `operation_moved` with the inner changes, `--exact-paths` restores exact matching), continuation fields 17/17 including nested ones, Relay connections 5/5 with `nodes` (the two controls still not detected). Recordings in `testdata/vimanam/2.1.0/`.

**REST focused context is the change facts alone (T3.1a).** `--context` is GraphQL-only in 2.1.0. On an OpenAPI diff it fails with "--context is GraphQL-only; OpenAPI and protobuf diffs do not support it", and it cannot be combined with `--format json` because `--context` renders Markdown. `diff` has no other focused-context flag. `--overview-max-tokens` limits a conversion's split index or `SKILL.md`. It is not a `diff` flag. The `vimanam` on PATH is 1.7.0. Its `diff --help` lists neither `--context` nor `--overview-max-tokens`. A GraphQL pair still uses `vimanam diff --context --max-tokens <n> <old> <new>`, which is the command behind `testdata/vimanam/2.1.0/settlements.context.md`. For REST, `what_changed` shows the JSON change facts and does not pass `--context`.

**Kalari depends on Vimanam 2.1.0.** Built with `cargo install vimanam --version 2.1.0 --locked`.

## Decided: wait for Vimanam

**The specs stay as built**, and Kalari waits for Vimanam to detect them (#136–#139) rather than bending the benchmark to today's rules. The pilot (T5.2) runs only once a Vimanam release reports `pagination_changed` on both workspaces, so the specs the baseline is measured on are the ones the Kalari arm reads. Re-record `testdata/vimanam/` on that release.

## The options that were weighed

The specs aren't frozen yet (the pilot hasn't run), so there are three ways forward, which can be combined:

1. **Fix Vimanam:** file issues 1–3 and cut a release. Kalari then reads the specs as built. Benchmark readers are told plainly which Vimanam version produced each change list.
2. **Use spec shapes real APIs use that today's Vimanam detects:** the version in the server URL, `next_cursor`, and `edges` beside `nodes`. All common in real APIs; both arms see the same specs, so neither arm gains. Changes the workspaces and the APIs' response field names; must happen before the pilot.
3. **Both:** option 2 now, so the pilot isn't held up, and option 1 for Vimanam's own sake.

Not an option, by the dev-diary's rules: Kalari working around Vimanam (guessing pagination from `operation_removed` plus `operation_added`) instead of the gap being fixed where it lives.
