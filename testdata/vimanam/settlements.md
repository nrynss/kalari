# GraphQL schema changes

## Breaking (1)

- `Query.settlements` — `FIELD_TYPE_CHANGED` (field_type_changed): `{"after":"SettlementConnection!","before":"[Settlement!]!"}`

## Non-breaking (4)

- `PageInfo` — `TYPE_ADDED` (type_added): `{"kind":"OBJECT"}`
- `Query.settlements(after:)` — `ARG_ADDED_OPTIONAL` (argument_added): `{"after":{"default":null,"deprecated":false,"deprecation_reason":null,"required":false,"type":"String"}}`
- `Query.settlements(first:)` — `ARG_ADDED_OPTIONAL` (argument_added): `{"after":{"default":"50","deprecated":false,"deprecation_reason":null,"required":false,"type":"Int"}}`
- `SettlementConnection` — `TYPE_ADDED` (type_added): `{"kind":"OBJECT"}`

