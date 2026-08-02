# Computer MCP Production Readiness Report

Report date: 2026-08-05 (Asia/Shanghai)

## Verdict

**Not ready for public distribution.** The current source and development
artifacts satisfy the local build, test, naming, configuration, CLI, and
distribution-structure gates. A bounded current-build OpenAI External Consumer
run is sealed and verified, but 21 of 23 Validation Test Cases remain pending,
the Cloudflare Remotely Managed transport has no configured Validation Run, the
artifacts are ad-hoc signed and not notarized, and `swift-codex` remains a local
path dependency.

This report is fail-closed. A missing Validation Test Case, transport, request,
audit row, or independent result remains pending; local tests and probes do not
replace external-consumer evidence.

## Current build

| Item | Result |
| --- | --- |
| Version / build | `1.0.0 (1)` |
| Root strict format and lint | passed |
| Root native build | passed |
| Root Swift Testing | 677/677 passed in 40 suites |
| Validation Suite strict format and lint | passed |
| Validation Suite native build | passed |
| Validation Suite Swift Testing | 45/45 passed in 8 suites |
| Validation Test Case catalog | 23 schema-1 cases validated |
| Capability inventory | 15 profiles, 289 unique tools, 5 declared static-inventory issues |
| Naming gate | passed |
| CLI hierarchy gate | passed |
| Public configuration validation | passed |
| Public repository hygiene gate | passed |
| App/embedded CLI/DMG structural verification | passed |
| Signing | ad-hoc development signature; not a release identity |
| Notarization | not performed |

Current development artifact SHA256 values:

| Artifact | SHA256 |
| --- | --- |
| App executable | `b78c5504fe30e94e4d23735adbd7ad2af84a7ba6b569a753b4dac5f4ded452c4` |
| Embedded CLI | `d97ff7bd2d5e39c744d7fedc2bf8ebe9db9577ce747fe1b15360ffc845f107a5` |
| Development DMG | `364ba5c7cb51e33d161a90a4bdcd38488d799aa414eda7556332da01ffab8131` |

## Validation status

The current machine-generated report is deliberately fail-closed:

| Result | Count |
| --- | ---: |
| Validation Test Cases passed | 2/23 |
| Validation Test Cases pending | 21/23 |
| Verified OpenAI External Consumer attempts | 14 |
| External Consumer capability rows passed | 13 |
| Contract capability rows passed | 2,875 |
| Report issues | 26 |

The two current-build PASS results are
`connector.openai.round_trip` and
`profile.operate_generic_execution_policy_denied`. The Evidence Bundle binds
each accepted attempt to the active App and embedded CLI digests, schema-1
manifest and profile, fixture and catalog digests, exact Secure MCP Tunnel
instance, Gateway Socket connection, Gateway request, GRDB audit event, and an
independent Computer Use or postcondition digest.

The 2026-08-02 run established a byte-verified change-impact baseline of
279/279 external ChatGPT calls and 17/17 security/lifecycle scenarios. It is
not accepted as a current-build PASS because the public schema, naming, and
executable identity subsequently changed.

A new dedicated ChatGPT conversation was created for the current build. Its
first Connector call exposed a real transport defect before reaching the
Gateway: the App-launched OpenAI Tunnel did not follow the active macOS proxy,
and its control-plane request failed before Gateway execution. The current
source now supports a credential-free `http_proxy`, gives explicit
configuration precedence, and otherwise resolves the fixed macOS HTTPS/HTTP
proxy at Tunnel launch. Unit, configuration, and supervisor tests cover this
behavior. After rebuilding and restarting the App and Tunnel, the same
Connector reached the Gateway successfully.

The bounded current-build external regression is intentionally limited to:

- OpenAI Connector catalog visibility and representative round trip;
- one deterministic policy denial without provider execution;
- one isolated file write, independent verification, and restoration;
- current TCC state and a bounded Computer Use call.

The sealed run includes representative workspace/system reads, Process and
Codex status, downstream MCP server/tool/resource/prompt discovery, CLI provider
discovery, a ticketed file write and exact restoration, a deterministic generic
execution policy denial, and a bounded Computer Use TCC refusal. It does not
repeat the historical 279-tool campaign. The canonical
`computer.tcc_state_enforced` Test Case remains pending because it declares the
observe profile; the current bounded TCC observation was intentionally made
under the active operate profile and contributes only to the round-trip case.

The independent raw archive contains 30 checksummed artifacts, including
Computer Use captures, 26 scoped Gateway audit rows, Tunnel status, diagnostics,
logs, health, readiness, metrics, process state, observations, the sealed
Evidence Bundle, verification result, and machine-readable/Markdown reports.
The repository contains only this redacted summary and hashes:

| External artifact | SHA256 |
| --- | --- |
| OpenAI Key Regression Evidence Bundle | `62cb5e54e24c9205eb8efee49f4b08a1833df4c4e1727db2aac14344f30c5465` |
| Evidence verification | `bfbf550fa52e27566e897d80583d39f70a235122c3a23612d218796946ac05bc` |
| Machine-readable readiness report | `993e5645539cf54c7f18b1d83f25b28bdec3afcbb2d908cfd1cb47a368febc40` |
| Markdown readiness report | `fdc13de3512872a148b09b6d4ba52c7ab9f564e562f6aa161599efd198d9a3bf` |
| External archive SHA256 manifest | `5ac59ba961a8e085bde03428935c7929f46d9dbdc302fd276886223c547c0621` |

## Transport status

| Transport | Status | Evidence consequence |
| --- | --- | --- |
| OpenAI Secure MCP Tunnel | current key regression sealed and verified; health and readiness returned 200 | two applicable current-build Test Cases pass; unexecuted cases remain pending |
| Cloudflare Tunnel — Remotely Managed | implementation and automated lifecycle tests passed; no named profile/token configured | `transport.cloudflare.named_tunnel` is unvalidated and public readiness remains false |
| Cloudflare Quick Tunnel | development-only historical Validation evidence | cannot substitute for the Remotely Managed release transport |

## Release blockers

1. Configure and validate a Remotely Managed Cloudflare Tunnel, or continue to
   report that release transport as unvalidated.
2. Build with a Developer ID Application identity, notarize, staple, and rerun
   distribution verification.
3. Publish `swift-codex`, select a fixed tag, replace the local path dependency
   with an exact remote dependency, and rerun GitHub CI.
4. Execute any remaining Validation Test Cases required by the eventual release
   scope; historical evidence cannot fill current-build gaps.

Until all applicable evidence and release gates pass, the accurate status is:
**local repository productionization complete; GitHub/public distribution
blocked by explicit external release gates**.
