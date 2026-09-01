# SwiftPM Package Baseline

## Status

Accepted.

## Context

The repository ships a macOS App, an embedded CLI, internal implementation
targets, and an independent Validation Suite. SwiftPM provides one repeatable
native build and Swift Testing path without maintaining a parallel Xcode
project graph.

## Decision

Use SwiftPM as the primary package, build, run, and test system. The root
package exposes only the `ComputerMCPApp` and `computer-mcp` executable
products. The `ComputerMCP` target is package-internal shared implementation,
not a supported Swift SDK. `Tools/Validation` is a separate Swift package and
never becomes a root target or distribution payload.

## Consequences

- `swift build` and `swift test` are the canonical component checks. They use
  SwiftPM's supported default build system rather than pinning a deprecated
  implementation flag.
- The App and CLI remain thin entry points over the internal `ComputerMCP`
  target and the same App Control Plane.
- `Scripts/build-app.sh` assembles and signs the App and embedded CLI;
  `Scripts/package-dmg.sh` creates the disk image.
- Real App, Tunnel, external-consumer, and installation checks belong to
  Validation Runs, not root automated tests.

## Alternatives Considered

- A parallel Xcode project: rejected because it would duplicate the SwiftPM
  dependency and target graph.
- Shell script wrapper only: rejected because the server needs typed Swift
  runtime code and tests.
- Public `ComputerMCP` library product: rejected because external Swift API
  compatibility is not a version 1 product contract and Validation must not
  force implementation details to remain public.

## Related Documentation

- [Package Architecture](../Architecture/Package.md)
- [CLI Reference](../Reference/CLI.md)
