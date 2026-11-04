# GraphQL schema changes

## Breaking (2)

- `Query.settlements` — `RELAY_CONNECTION_ADOPTED` (pagination_changed): `{"after":{"connection":"SettlementConnection","controls":{"after":{"default":null,"type":"String"},"first":{"default":"50","type":"Int"}},"item":"Settlement","shape":"connection"},"before":{"item":"Settlement","shape":"list"},"confidence":"declared","connection_fields":"nodes"}`
- `Query.settlements` — `FIELD_TYPE_CHANGED` (field_type_changed): `{"after":"SettlementConnection!","before":"[Settlement!]!"}`

## Non-breaking (4)

- `PageInfo` — `TYPE_ADDED` (type_added): `{"kind":"OBJECT"}`
- `Query.settlements(after:)` — `ARG_ADDED_OPTIONAL` (argument_added): `{"after":{"default":null,"deprecated":false,"deprecation_reason":null,"required":false,"type":"String"}}`
- `Query.settlements(first:)` — `ARG_ADDED_OPTIONAL` (argument_added): `{"after":{"default":"50","deprecated":false,"deprecation_reason":null,"required":false,"type":"Int"}}`
- `SettlementConnection` — `TYPE_ADDED` (type_added): `{"kind":"OBJECT"}`

## Focused context

# GraphQL schema

Native GraphQL schema. Operation selectors use the root keyword and schema coordinate (for example `QUERY Query.user`); schemas use GraphQL type names.

API Version: 

## Services

- [Query](#query)
  * [Query.settlements](#query-query-query-settlements)

## Query {#query}

GraphQL query root
### Query.settlements {#query-query-query-settlements}
**Operation:** QUERY Query.settlements
**Description:** GraphQL query field `Query.settlements` returning `SettlementConnection!`
**Operation ID:** `Query.settlements`

#### Arguments
| Name | In | Required | Description |
|------|----|---------:|-------------|
| `first` | argument | No | `Int`; default `50` |
| `after` | argument | No | `String` |

#### Result
| Result | Type | Description |
|------|------|-------------|
| result | graphql | `SettlementConnection!` |

#### Request Schema
*No request schema available*

#### Response Schema
| Field | Type | Required | Description |
|------|------|---------:|-------------|
| `response` | [SettlementConnection](#schema-settlementconnection) | - | GraphQL object |

## Schema Definitions

### SettlementConnection {#schema-settlementconnection}
| Field | Type | Required | Description |
|------|------|---------:|-------------|
| `SettlementConnection` | object | - | GraphQL object |
| `SettlementConnection.nodes` | array<ref Settlement> | Yes | `[Settlement!]!` |
| `SettlementConnection.nodes[]` | [Settlement](#schema-settlement) | - | GraphQL object |
| `SettlementConnection.pageInfo` | [PageInfo](#schema-pageinfo) | Yes | GraphQL object |

### Settlement {#schema-settlement}
| Field | Type | Required | Description |
|------|------|---------:|-------------|
| `Settlement` | object | - | GraphQL object |
| `Settlement.id` | ID | Yes | `ID!` |
| `Settlement.batchDate` | String | Yes | `String!` |
| `Settlement.amountCents` | Int | Yes | `Int!` |
| `Settlement.currency` | String | Yes | `String!` |
| `Settlement.status` | [SettlementStatus](#schema-settlementstatus) | Yes | GraphQL enum |

### PageInfo {#schema-pageinfo}
| Field | Type | Required | Description |
|------|------|---------:|-------------|
| `PageInfo` | object | - | GraphQL object |
| `PageInfo.endCursor` | String | Yes | Where this page ended. Pass it as `after` to continue. (`String!`) |
| `PageInfo.hasNextPage` | Boolean | Yes | Whether more settlements remain after this page. (`Boolean!`) |

### SettlementStatus {#schema-settlementstatus}
| Field | Type | Required | Description |
|------|------|---------:|-------------|
| `SettlementStatus` | enum | - | GraphQL enum |

