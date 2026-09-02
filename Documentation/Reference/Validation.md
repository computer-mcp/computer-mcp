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
/usr/bin/swift build --package-path Tools/Validation
/usr/bin/swift test --package-path Tools/Validation
/usr/bin/swift run --package-path Tools/Validation \
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
computer-mcp-validate report generate|verify
computer-mcp-validate report verification-record generate|verify
computer-mcp-validate report release-manifest|verify-release-manifest
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
/usr/bin/swift run --package-path Tools/Validation \
  computer-mcp-validate test-case validate
/usr/bin/swift run --package-path Tools/Validation \
  computer-mcp-validate runbook generate --output validation-runbook.md
```

Real ChatGPT, Safari, OpenAI Secure MCP Tunnel, Cloudflare Tunnel, installed
App, and external provider actions belong only in Validation Runs. They never
become automated Swift tests.

Automated fixtures use repository-local ignored build storage or a uniquely
created temporary directory. They never use Desktop, Documents, iCloud Drive,
or another user-content directory. Codex App lifecycle fixtures create
ephemeral threads and run reviews inline. Exec and MCP checks that require a
persisted upstream session archive every created thread before the run can
pass. Cleanup failure fails the Validation Run instead of leaving an active test
task in the user's Codex task list.

## Evidence contract

Validation Evidence Bundle schema 2 uses three layers:

- `contract`: static inventory and schema identity;
- `runtime`: transport request, execution, audit, and independent result;
- `external_consumer`: consumer result correlated across its transport to the
  same gateway request, audit record, and result.

The consumer is represented by `consumer.kind` and `transport`, so the schema
supports ChatGPT, a standard MCP client behind Cloudflare, and future external
consumers without consumer-specific evidence fields.

Correlation starts from a strict schema-2 **Validation Observation Bundle**.
Every observation supplies the Test Case, explicit assertion IDs, the Gateway
request ID returned by Computer MCP, and independently observed cleanup/result
digests. External-consumer observations additionally supply
`consumer_result_id`, such as a stable result item in the maintained ChatGPT
response. `transport_request_id` is required for runtime observations and
optional for an external consumer whose UI does not expose its MCP JSON-RPC ID.
The local audit must still contain the transport request when that transport
can observe it. No local value is presented as if ChatGPT supplied it.

Schema 2 records the reviewed result class explicitly. `passed` requires one
exact `allowed` audit row without an error. `expected_denial` requires one exact
policy `denied` row with a stable error code. `expected_failure` is reserved for
a deliberately exercised fail-closed execution path whose independent semantic
check passed; it requires one exact `failed` row with a stable error code. A raw
`failed` outcome never proves acceptance. This keeps lifecycle tools that have
no outstanding request distinguishable from authorization denials and from
unexpected failures. The schema-2 validator permits `expected_failure` only for
the reviewed no-active-request paths of `codex.app.requests.respond` and
`codex.mcp.approval.respond` in `catalog.dynamic_full_coverage`; every other
capability fails closed.

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
`probe app call --observations ...`. An authenticated full-catalog runtime probe
may use the OpenAI Secure MCP Tunnel identity only when the audit-derived Tunnel
instance, Tunnel profile, and Gateway Socket connection are all present; it
remains runtime evidence and cannot claim a ChatGPT consumer result. Named and
development-only Cloudflare HTTP calls can use `probe http call --observations
...`; the selected outer transport remains distinct from the inner loopback
`streamable_http` audit. `evidence correlate` then queries exactly one audit row
for every Gateway request and seals the canonical Evidence Bundle.

The mandatory release catalog contains 22 publisher-verifiable Test Cases. It
includes the isolated Quick Tunnel boundary plus automated named-tunnel
lifecycle, authentication, cleanup, and profile-separation coverage. A live
Cloudflare named deployment is deliberately outside the mandatory release
catalog because its account, domain, public hostname, and runtime token are
owned by the deploying user. The Cloudflare runbook remains the deployment
acceptance procedure when a user chooses that transport.

The full-catalog probe still calls every advertised tool and requires one
correlated audit row per call. `codex.app.apps.list` requests a cached bounded
page and must normally return its `data` array within the dedicated App-list
deadline. A timeout is never admissible. The sole environment-dependent
exception is an HTTP 403 returned in a structured `codex.app.request_failed`
result; it may be recorded as a reviewed `expected_failure` only when its exact
audit row has decision `failed` and error code `gateway.execution_failed`. This
identifies an upstream ChatGPT
connector-directory challenge; it does not classify the local App, loopback
gateway, user content, or Shell as scraping or hostile traffic. Any other
failure remains inadmissible and blocks readiness.

PASS fails closed unless every applicable Test Case, capability, profile,
transport, request, audit record, and independent result correlation is
present. Evidence generated only by probes remains pending.

## Artifacts

Raw run data and secrets stay outside the repository. The repository may
contain only a redacted Production Readiness Report and a SHA256 manifest for
its external Validation Evidence Bundles.

Generate both report formats:

```sh
/usr/bin/swift run --package-path Tools/Validation \
  computer-mcp-validate report generate \
  --inventory capability-inventory.json \
  --fixture capability-fixture.json \
  --evidence-bundle validation-evidence.json \
  --json production-readiness-report.json \
  --markdown production-readiness-report.md
```

The command exits unsuccessfully when the report is not ready.

After the same final App, embedded CLI, notarized DMG, private evidence archive,
and all five redacted journey/platform verification records pass, generate the
public summary-only manifest with `report release-manifest`. The command accepts
every Evidence Bundle used by the ready report, verifies that each bundle is
bound to the final App and CLI digests, requires all 22 canonical Test Cases,
and emits
`Computer-MCP-<version>-EvidenceManifest.json`. It publishes hashes, Test Case IDs,
transports, and profiles only; request IDs, audit IDs, consumer result IDs,
credentials, raw inputs/outputs, and local paths remain in the private archive.

The five required `--verification-record id=path` IDs are:

- `journey.local`
- `journey.chatgpt`
- `journey.cloudflare`
- `platform.apple_silicon_native`
- `platform.rosetta_x86_64`

Create each record with `report verification-record generate`. The command
hashes separate redacted procedure, result, and cleanup records, binds those
hashes to the final App executable, embedded CLI, DMG, version, build, commit,
and Team ID, and writes a sealed schema-1 document. It never copies the source
records into its JSON or terminal output. Use `report verification-record
verify` before packaging private evidence; arbitrary files are not accepted by
`report release-manifest` as verification records.

Keep the final redacted evidence directory outside the repository with this
layout:

```text
production-readiness-report.json
evidence-bundles/*.json
verification-records/journey.local.json
verification-records/journey.chatgpt.json
verification-records/journey.cloudflare.json
verification-records/platform.apple_silicon_native.json
verification-records/platform.rosetta_x86_64.json
```

Additional redacted supporting records may sit below the same directory. Seal
the directory without copying it into the repository:

```sh
Scripts/package-validation-evidence.sh \
  --source <external-redacted-evidence-directory> \
  --output <external-private-evidence-archive.tar.gz>
```

The packager verifies the ready report, every Evidence Bundle, the exact five
verification records, candidate consistency, report-to-bundle membership, and
secret/path redaction. It rejects symlinks, special files, empty files, and
credential-like filenames, then writes a separate `.sha256` receipt. The
resulting private archive is the file passed to `report release-manifest`.
