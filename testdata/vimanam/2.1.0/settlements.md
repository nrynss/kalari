# GraphQL schema changes

## Breaking (2)

- `Query.settlements` — `RELAY_CONNECTION_ADOPTED` (pagination_changed): `{"after":{"connection":"SettlementConnection","controls":{"after":{"default":null,"type":"String"},"first":{"default":"50","type":"Int"}},"item":"Settlement","shape":"connection"},"before":{"item":"Settlement","shape":"list"},"confidence":"declared","connection_fields":"nodes"}`
- `Query.settlements` — `FIELD_TYPE_CHANGED` (field_type_changed): `{"after":"SettlementConnection!","before":"[Settlement!]!"}`

## Non-breaking (4)

- `PageInfo` — `TYPE_ADDED` (type_added): `{"kind":"OBJECT"}`
- `Query.settlements(after:)` — `ARG_ADDED_OPTIONAL` (argument_added): `{"after":{"default":null,"deprecated":false,"deprecation_reason":null,"required":false,"type":"String"}}`
- `Query.settlements(first:)` — `ARG_ADDED_OPTIONAL` (argument_added): `{"after":{"default":"50","deprecated":false,"deprecation_reason":null,"required":false,"type":"Int"}}`
- `SettlementConnection` — `TYPE_ADDED` (type_added): `{"kind":"OBJECT"}`

