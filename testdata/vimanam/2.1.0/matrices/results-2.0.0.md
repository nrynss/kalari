## Matrix 1: version prefixes (Vimanam 2.0.0)

v1: `GET` returns `{items: [Item]}`, no paging. v2: adds `cursor` and `limit` query parameters and a `next_cursor` response field, which on an unchanged path is detected.

| Case | v1 path | v2 path | operationId | Change kinds | `pagination_changed` |
|---|---|---|---|---|---|
| control: same path | `/items` | `/items` | `listItems` → `listItems` | argument_added, argument_added, field_added, pagination_changed | **yes** |
| version in the path | `/v1/items` | `/v2/items` | `listItems` → `listItems` | operation_removed, operation_added | no |
| version in the path, under /api | `/api/v1/items` | `/api/v2/items` | `listItems` → `listItems` | operation_removed, operation_added | no |
| version in the path, operationId changed | `/v1/items` | `/v2/items` | `listItems` → `exportItems` | operation_removed, operation_added | no |
| version in the server URL | `/items` | `/items` | `listItems` → `listItems` | argument_added, argument_added, field_added, pagination_changed | **yes** |

## Matrix 2: continuation fields and request controls (Vimanam 2.0.0)

Same path `/items` in both. v1 returns `{items: [Item]}`. v2 adds the request parameters and the response field shown.

| Response continuation field | Request parameters | Seen in (examples) | `pagination_changed` |
|---|---|---|---|
| `next_cursor` | `cursor`, `limit` | Slack (`response_metadata.next_cursor` is nested; flat here) | **yes** |
| `nextCursor` | `cursor`, `limit` |  | **yes** |
| `next_page_token` | `page_token`, `page_size` | Google APIs (`nextPageToken`) | **yes** |
| `next_page` | `page` | Zendesk incremental export | **yes** |
| `cursor` | `cursor`, `limit` | many cursor APIs | no |
| `next` | `cursor`, `limit` | many REST APIs | no |
| `after_cursor` | `cursor`, `limit` | Zendesk cursor export | no |
| `after` | `cursor`, `limit` |  | no |
| `continuation_token` | `cursor`, `limit` |  | no |
| `continuationToken` | `cursor`, `limit` | Azure (`continuationToken`) | no |
| `nextLink` | `cursor`, `limit` | Azure REST | no |
| `@odata.nextLink` | `cursor`, `limit` | Microsoft Graph | no |
| `LastEvaluatedKey` | `cursor`, `limit` | DynamoDB | no |
| `response_metadata.next_cursor` | `cursor`, `limit` | Slack (nested) | no |
| `links.next` | `cursor`, `limit` | JSON:API | no |
| `next_cursor` | `starting_after`, `limit` | Stripe-style request control | **yes** |
| `next_cursor` | `after`, `limit` | `after` as the request control | **yes** |

## Matrix 3: GraphQL connection shapes (Vimanam `main` at 491b02c)

v1: `items: [Item!]!`. v2: `items(<args>): ItemConnection!` with the connection fields shown.

| Connection fields | Arguments | Seen in (examples) | Change kinds | `pagination_changed` |
|---|---|---|---|---|
| `edges, pageInfo` | `first: Int, after: String` | Relay spec | pagination_changed, field_type_changed, type_added, argument_added, argument_added, type_added, type_added | **yes** (RELAY_CONNECTION_ADOPTED) |
| `nodes, pageInfo` | `first: Int, after: String` | GitHub (`nodes` shortcut), many APIs | field_type_changed, argument_added, argument_added, type_added, type_added | no |
| `edges, nodes, pageInfo` | `first: Int, after: String` | GitHub | pagination_changed, field_type_changed, type_added, argument_added, argument_added, type_added, type_added | **yes** (RELAY_CONNECTION_ADOPTED) |
| `edges, pageInfo (backward)` | `last: Int, before: String` | Relay spec | pagination_changed, field_type_changed, type_added, argument_added, type_added, type_added, argument_added | **yes** (RELAY_CONNECTION_ADOPTED) |
| `nodes, pageInfo, totalCount` | `first: Int, after: String` |  | field_type_changed, argument_added, argument_added, type_added, type_added | no |
| `items, nextCursor` | `limit: Int, cursor: String` | non-Relay cursor pages | field_type_changed, argument_added, type_added, type_added, argument_added | no |
| `edges, no pageInfo` | `first: Int, after: String` |  | field_type_changed, type_added, argument_added, argument_added, type_added, type_added | no |
