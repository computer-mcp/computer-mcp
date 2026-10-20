# Database schema fixture

`gateway-schema.json` is the ordered `sqlite_schema` projection (`type`, `name`,
`tbl_name` as `table`, `sql`) of a new database opened by `GatewayDatabase(path:)`
at host commit `7f29cea`, after all 21 migrations of that commit, without the
eight `codex*` tables and their indexes, which no host code uses.

`GatewayDatabaseSchemaTests` compares a new database with this fixture, including
implicit indexes, keys, nullability and SQL definitions. The fixture is the
regression baseline for the initial schema and is not regenerated from the
implementation under test to make a mismatch pass.
