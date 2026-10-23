# Third-Party Notices

Computer MCP original source is licensed under FSL-1.1-ALv2; see `LICENSE`.
Third-party components keep their own licenses.

Seatbelt proxy-port rules and the egress protocol flow are adapted from
[Anthropic sandbox-runtime](https://github.com/anthropics/sandbox-runtime/tree/aceba124fd725f4a43d7016ed3f5651d61f83115),
revision `aceba124fd725f4a43d7016ed3f5651d61f83115` (Apache-2.0).
Adaptations use Swift, execution-specific TCP listeners and route-aware address
checks. Source headers identify the adapted files. The complete license is in
`Licenses/sandbox-runtime-Apache-2.0.txt`; the upstream snapshot has no NOTICE file.

The App and embedded CLI statically link the following resolved packages:

- GRDB.swift, Yams, EventSource, swift-toml — MIT;
- swift-argument-parser, swift-atomics, swift-collections, swift-crypto,
  swift-log, swift-nio, swift-subprocess, and swift-system — Apache-2.0;
- Model Context Protocol Swift SDK — code covered by its upstream
  Apache-2.0/MIT transition notice.

`Scripts/generate-release-metadata.swift` derives the exact versions,
revisions, URLs, linked-versus-resolved-only classification, dependency
manifest, CycloneDX SBOM, and complete license/notice text from the locked
SwiftPM checkouts. The generated `ThirdPartyNotices.txt` is copied byte for
byte into both `Computer MCP.app/Contents/Resources` and the DMG root.

Bundled plugin archives carry their own dependency notices, including the
Codex adapter's swift-codex and vendored protocol schema notices. These are
separate from libraries linked into the host executables.

Packages present only because SwiftPM resolves the complete dependency graph
are recorded separately as `resolved_only`; they are not represented as code
linked into the App or embedded CLI.
