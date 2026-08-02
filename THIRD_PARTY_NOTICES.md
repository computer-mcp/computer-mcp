# Third-Party Notices

Computer MCP original source is governed by the proprietary source-visible
terms in `LICENSE`. Third-party components keep their own licenses.

The App and embedded CLI statically link the following resolved packages:

- GRDB.swift, Yams, EventSource, swift-toml — MIT;
- swift-argument-parser, swift-atomics, swift-collections, swift-log,
  swift-nio, swift-subprocess, and swift-system — Apache-2.0;
- swift-codex — MIT, with its vendored OpenAI Codex protocol schema under
  Apache-2.0; and
- Model Context Protocol Swift SDK — code covered by its upstream
  Apache-2.0/MIT transition notice.

`Scripts/generate-release-metadata.swift` derives the exact versions,
revisions, URLs, linked-versus-resolved-only classification, dependency
manifest, CycloneDX SBOM, and complete license/notice text from the locked
SwiftPM checkouts. The generated `ThirdPartyNotices.txt` is copied byte for
byte into both `Computer MCP.app/Contents/Resources` and the DMG root.

Packages present only because SwiftPM resolves the complete dependency graph
are recorded separately as `resolved_only`; they are not represented as code
linked into the App or embedded CLI.
