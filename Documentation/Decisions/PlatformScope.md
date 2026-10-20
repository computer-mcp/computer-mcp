# Platform Scope

## Status

Accepted.

## Decision

Computer MCP ships for macOS only. The gateway is structured as a
platform-neutral core with platform adapters, so a second platform can be added
without restructuring the core:

- The core, tool domains, gateway and control plane depend only on platform
  protocols, and are built and tested on Linux in CI as they are extracted from
  the shared implementation target.
- `ComputerMCPPlatformPOSIX` holds POSIX implementations shared by macOS and a
  future Linux host: process groups and signals, Unix-domain sockets and peer
  credentials, file locks and path resolution.
- `ComputerMCPPlatformDarwin` holds macOS implementations: Keychain, security
  bookmarks, Launch Services, TCC and Accessibility probes, login items, Finder
  and media frameworks, and the system, network and macOS command probes.
- The macOS composition root assembles these implementations for the App and the
  CLI.

The next platform, when one is planned, is a headless Linux gateway administered
through the CLI. It reuses the neutral modules and `ComputerMCPPlatformPOSIX`
and adds Linux implementations for secrets, workspace grants, login services and
system probes.

Windows is out of scope. Windows implementations, Windows CI and Windows release
artifacts are removed from the host and the plugins.

## Rationale

About four fifths of the gateway logic is platform neutral, but it shared one
module with macOS framework calls, so nothing enforced the boundary. A Linux
compile check keeps the boundary honest at low cost, and Linux shares POSIX
process and socket semantics with macOS. SwiftNIO and swift-subprocess support
Linux; GRDB builds there with community support rather than upstream testing,
so the Linux CI job is what keeps that combination working.

A Windows host would be a separate product: SwiftUI is unavailable, the
SwiftNIO-based transports lack complete Windows support, and secrets, workspace
grants, desktop automation and distribution all need Windows-specific
implementations. The Windows code that existed served no shipping host.

If Windows is reconsidered, the Swift path is the neutral core plus Windows
adapters (Credential Manager, ACL-based workspace grants, UI Automation, named
pipes) and a native WinUI 3 interface through `swift-winrt`, delivered as its own
product decision.

## Consequences

- Neutral modules do not import macOS frameworks or reference macOS executable
  paths. The module graph check, the package boundary check and a Linux CI job
  enforce this as targets are extracted; see
  [Module Architecture](ModuleArchitecture.md).
- Plugin manifests keep the generic `platforms` and `architectures`
  compatibility fields; they are package metadata, not a Windows feature.
- Plugin archives are extracted through an archive extractor interface whose
  only implementation uses the macOS system `libarchive`; the Linux build has no
  implementation until a Linux host is planned. Plugin private staging directories,
  directory identity capture/matching, application lookup and archive worker lock-
  descriptor inheritance also have only macOS implementations.
- Until a Linux host adopts a backpressured HTTP client, the Linux streaming
  bridge fails when more than 32 MiB of response bytes wait in its own queue.
  The triggering callback can overshoot by one chunk. Foundation buffers
  redirect bodies internally on both platforms, outside this queue bound.
