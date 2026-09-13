# Embedded Codex compatibility fixtures

These fixtures preserve the host database and MCP contracts accepted before
Codex execution moved to its independent plugin. They are test resources,
not an implementation or a tool authorization source.

The catalog was captured from the actual embedded provider with all three
execution paths configured. Each entry retains its tool and host capability.
The state fixtures were captured after a real disposable provider created a
thread, run, lease and worktree plan, stopped its owned protocol-fixture
process, and persisted released ownership. Both interrupted and pending
approval records are represented. The adapter imported both captures and
continued the run across two process generations before the captures were
adopted as compatibility fixtures.

Source identities (SHA-256):

- Embedded provider: `0d1d07f9e302cff22c3df350cbeee8529ea1848fe7d8dd0a0e80e8457864e7ae`
- Gateway database: `47c6c6409f4f344240f882d827c24a598588a08cad05fab91e9047c98f41a7a6`
- Raw catalog: `e612d274260f10e3143dcadbfc000fb86a5a259d7d3eeb1d713119c03bf01621`
- Raw interrupted state: `9d720859dfd699f42b91d769a24224764d34d98cd8d31d931fc738b91cdeec5b`
- Raw pending state: `16bb3ccfe99615cdfb82e4a0fd535e35e598a7e9eb2a1183ab513f45e4211f96`

Normalization replaces temporary roots and Git commit IDs with bindings, renews
the lease and plan expiry relative to each test, and replaces historical PIDs
with a non-live sentinel. All other schema, payload, SQL values and tool
metadata remain captured data. Workspace IDs and record IDs belong to each
isolated fixture. No user database, model, credential or production thread was
used. Golden data must not be regenerated from the plugin under test to make a
contract mismatch pass.
