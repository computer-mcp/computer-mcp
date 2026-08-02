# Computer MCP Validation Suite

Computer MCP Validation Suite is the independent release-validation package at
`Tools/Validation`. Its executable is `computer-mcp-validate`; it is not a root
package target and is never embedded in the App, embedded CLI, or DMG.

The vocabulary is fixed:

- a **Validation Test Case** defines prerequisites, steps, expected results,
  evidence requirements, cleanup, and risk;
- a **Validation Run** is one execution of a Test Case;
- a **Validation Evidence Bundle** correlates observations from that run;
- **Capability Coverage** projects verified evidence over the generated tool
  inventory;
- a **Production Readiness Report** is the fail-closed JSON and Markdown result.

A probe is an auxiliary observation. It cannot independently produce PASS.

## Build and test

```sh
/usr/bin/swift build --package-path Tools/Validation --build-system native
/usr/bin/swift test --package-path Tools/Validation --build-system native
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate --help
```

## Command hierarchy

```text
computer-mcp-validate test-case list|validate
computer-mcp-validate runbook generate
computer-mcp-validate inventory generate
computer-mcp-validate fixture workspace generate
computer-mcp-validate fixture manifest generate
computer-mcp-validate fixture mcp serve
computer-mcp-validate probe app catalog|call|full-catalog
computer-mcp-validate probe provider discover
computer-mcp-validate probe http call
computer-mcp-validate probe downstream verify
computer-mcp-validate probe gateway verify
computer-mcp-validate probe codex verify
computer-mcp-validate evidence correlate|verify
computer-mcp-validate report generate
```

Use `--help` at every level for authoritative arguments.

The downstream HTTP Validation Test Case pins the official
`@modelcontextprotocol/server-everything` package at `2026.7.4` and runs its
`streamableHttp` transport on loopback. The Validation Run must record the package
version and registry integrity with its external evidence; do not use an unpinned
`latest` package in readiness evidence.

## Canonical Test Case catalog

`validation-test-cases.json` is the only maintained Test Case catalog. Swift
code does not duplicate scenario definitions. Its `schema_version` is 1 and
each Test Case contains exactly:

```text
id
category
transports
profiles
prerequisites
steps[{id,instruction}]
expected_results
evidence_requirements[{kind,correlation_key,description}]
cleanup_steps
risk_level
```

Generate a reviewable runbook from the catalog:

```sh
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate test-case validate
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate runbook generate --output validation-runbook.md
```

Real ChatGPT, Safari, OpenAI Secure MCP Tunnel, Cloudflare Tunnel, installed
App, and external provider actions belong only in Validation Runs. They never
become automated Swift tests.

## Evidence contract

Validation Evidence Bundle schema 1 uses three layers:

- `contract`: static inventory and schema identity;
- `runtime`: local request, execution, audit, and independent result;
- `external_consumer`: consumer result correlated across its transport to the
  same gateway request, audit record, and result.

The consumer is represented by `consumer.kind` and `transport`, so the schema
supports ChatGPT, a standard MCP client behind Cloudflare, and future external
consumers without consumer-specific evidence fields.

Correlation starts from a strict schema-1 **Validation Observation Bundle**.
Every observation supplies the Test Case, explicit assertion IDs, the Gateway
request ID returned by Computer MCP, and independently observed cleanup/result
digests. External-consumer observations additionally supply
`consumer_result_id`, such as a stable result item in the maintained ChatGPT
response. `transport_request_id` is required for local runtime observations and
optional for an external consumer whose UI does not expose its MCP JSON-RPC ID.
The local audit must still contain the transport request when that transport
can observe it. No local value is presented as if ChatGPT supplied it.

The lifecycle is:

```text
Validation Test Case
  -> consumer or runtime observation
  -> Validation Observation Bundle
  -> exact GRDB audit correlation
  -> sealed Validation Evidence Bundle
  -> fail-closed Production Readiness Report
```

For example, a ChatGPT observation uses `layer = external_consumer`,
`consumer.kind = chatgpt`, `transport = openai_secure_mcp_tunnel`, a stable
`consumer_result_id`, the returned `gateway_request_id`, Tunnel provenance,
explicit `step.*` and `expected_result.*` assertions, and an independently
captured `cleanup.*` postcondition. It does not invent a transport request ID
that Safari does not expose.

Local Control Socket and Gateway Socket calls can produce observations through
`probe app call --observations ...`. Named and development-only Cloudflare HTTP
calls can use `probe http call --observations ...`; the selected outer transport
remains distinct from the inner loopback `streamable_http` audit. `evidence
correlate` then queries exactly one audit row for every Gateway request and
seals the canonical Evidence Bundle.

PASS fails closed unless every applicable Test Case, capability, profile,
transport, request, audit record, and independent result correlation is
present. Evidence generated only by probes remains pending.

## Artifacts

Raw run data and secrets stay outside the repository. The repository may
contain only a redacted Production Readiness Report and a SHA256 manifest for
its external Validation Evidence Bundles.

Generate both report formats:

```sh
/usr/bin/swift run --package-path Tools/Validation --build-system native \
  computer-mcp-validate report generate \
  --inventory capability-inventory.json \
  --fixture capability-fixture.json \
  --evidence-bundle validation-evidence.json \
  --json production-readiness-report.json \
  --markdown production-readiness-report.md
```

The command exits unsuccessfully when the report is not ready.
