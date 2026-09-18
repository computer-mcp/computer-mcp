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

The repository's `Scripts/verify-package-boundary.sh` and
`Scripts/verify-cli-interface.sh` gates require an executable ripgrep. They use
`rg` from the calling environment by default; set `RIPGREP_EXECUTABLE` to an
existing installation's executable path when it is not on that PATH. The scripts
do not install tools or change the user's PATH. A missing executable, failed
version check or search error fails validation; only ripgrep's ordinary no-match
status can establish that a forbidden pattern is absent.

`verify-cli-interface.sh` accepts `COMPUTER_MCP_TEST_CONTROL_SOCKET` as an
absolute isolated test Control Socket path. Without it, Doctor uses an absent
socket beneath the script's temporary directory and must return the valid
unavailable JSON contract. It never falls back to the production App. The
isolated local-permission CLI acceptance test covers a running host's success
path.

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

Actions against real ChatGPT, Safari, OpenAI Secure MCP Tunnel, Cloudflare
Tunnel, the installed App or user-owned provider sessions belong only in
Validation Runs. They never become automated Swift tests. Opt-in package
regressions may use an explicitly selected native executable against disposable
local state and loopback fixtures; they do not produce external-consumer or
production-readiness evidence.

Automated fixtures use repository-local ignored build storage or a uniquely
created temporary directory. They never use Desktop, Documents, iCloud Drive,
or another user-content directory. Codex lifecycle fixtures use ephemeral
threads or a newly created private Codex home, and run reviews inline. Checks
using shared upstream session storage archive every created thread before the
Validation Run can pass. Private homes are removed only after their owned
writers stop. Cleanup failure fails validation instead of leaving an active
test task in the user's Codex task list.

## Disposable GUI target

`Tests/ComputerMCPTests/Fixtures/gui_acceptance.swift` is an AppKit target for
manual Validation Runs. It exposes a counter and two buttons, writes its PID,
counter and running state to an explicitly supplied receipt, and closes after
120 seconds. It is a copied test resource, not an automatically launched test.
Build a private target from the repository root:

```sh
GUI_RUN=$(mktemp -d /tmp/computer-mcp-gui.XXXXXX)
GUI_APP="$GUI_RUN/GUI Fixture.app"
mkdir -p "$GUI_APP/Contents/MacOS"
cp Tests/ComputerMCPTests/Fixtures/gui_acceptance.plist "$GUI_APP/Contents/Info.plist"
/usr/bin/swiftc -swift-version 6 -parse-as-library \
  Tests/ComputerMCPTests/Fixtures/gui_acceptance.swift \
  -o "$GUI_APP/Contents/MacOS/GUIFixture" -framework AppKit
/usr/bin/open -n -W "$GUI_APP" --args "$GUI_RUN/state.json"
```

The final command waits for this target to exit. Drive it from a separate
terminal or authorized MCP client using a disposable Gateway configuration and
workspace rooted at `GUI_RUN`. Do not point acceptance commands at the normal
App control socket. Keep the receipt and raw results in the Validation Run.

For CUA, first discover the actual authorized catalog and observe this target
using its receipted PID. Perform one increment and observe the counter again.
For the AX path, query that PID with `computer.accessibility.query`; identify
`fixture-increment` from the returned references, perform its `AXPress`, then
query `fixture-counter` and verify `AXValue` equals `Count 1`. References come
from the current query, not a saved child path. Independently require the
receipt's counter to equal one. Use a fresh target for each provider path.

Record caller executable/signing identity, permission state, vendor errors and
whether a system authorization flow occurred. A successful catalog or AX test
does not prove CUA execution. If an action reports an error, observe the target
and receipt before considering a retry; an error may accompany an effective
action. Never automatically repeat an uncertain CUA action through AX.
Use the close button or the bounded automatic exit, and confirm both the
receipt's stopped state and the launched target's process exit before cleanup.
An error returned by the close action is not itself proof of failed cleanup.

## Isolated Codex plugin regressions

The host package can test a separately packaged adapter over standard MCP:

```sh
Scripts/verify-codex-plugin-host.sh /absolute/plugin/bin/codex-mcp-adapter
```

This verifies host grants, tickets, audit, dynamic tools, migration and actual
socket/HTTP teardown with a disposable vendor-protocol fixture. It does not
start the user's Codex installation by default.

To also verify a selected native Codex executable, opt in explicitly:

```sh
COMPUTER_MCP_REAL_CODEX_ACCEPTANCE=1 \
COMPUTER_MCP_REAL_CODEX_EXECUTABLE=/absolute/vendor/codex \
Scripts/verify-codex-plugin-host.sh /absolute/plugin/bin/codex-mcp-adapter
```

`RealCodexPluginAcceptanceTests` checks bounded skills/app queries, scoped
Git and loopback-network access before approval and after revocation, cold
thread/first-turn authorization, and three independent connections handing off
the same thread and Goal. The native process executes the test commands;
model responses come from a local fixture that rejects authentication.
Command results, available execution events, filesystem/network effects,
exact process exit and adapter database state are independently checked.

These tests create private Codex homes, databases, repositories and local
services. They do not use production host sockets, existing accounts/threads,
external model services, system-permission changes or public Git operations.
Successful cleanup removes the private state; failure retains isolated evidence
and reports its path. Native sandbox tool errors can lack a command-execution
event, so denial checks also require the exact native function-call result.

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
the reviewed paths of `codex.app.requests.respond` and `codex.app.apps.list` in `catalog.dynamic_full_coverage`; every other
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

Mutation probes inspect every prepared ticket's state before committing it.
The default runner never approves a pending ticket: it reports that local
approval is required and the target was not executed. Isolated acceptance code
can inject a resolver backed by its explicitly selected owner-only Control
Socket; the resolver must return the same ticket in `approved` state. There is
no production auto-approval flag. A standalone probe without a local approval
path cannot claim complete mutation coverage under a confirmation policy.

Cancellation delivery and downstream execution are distinct observations. The
downstream lifecycle fixture requires its task's cancellation marker as an
independent stopping postcondition and records the host execution receipt with
`mcp.requests.read` separately (`server`, `request_id`, bounded `offset` and
`max_bytes`); a sent notification alone does not pass that lifecycle case.

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
