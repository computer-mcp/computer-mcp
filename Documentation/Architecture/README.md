# Architecture

These documents state the current architecture truth for `computer-mcp`.

## Documents

- [Package](Package.md): SwiftPM products, targets, dependencies, and command
  ownership.
- [Runtime](Runtime.md): App socket, execution planes, and tool dispatch.
- [App Control Plane](ControlPlane.md): shared SwiftUI/CLI operations and the
  local administration boundary.
- [Gateway](Gateway.md): product topology, workspace model, and policy routing.
- [Capability Ownership](Ownership.md): gateway, Codex, Apple-provider, and
  builtin admission boundaries.
- [Security and Privacy](SecurityAndPrivacy.md): profiles, workspaces, secrets,
  TCC, logging, and Full Shell boundaries.
- [Documentation](Documentation.md): repository documentation role model.
- [Naming](Naming.md): frozen product, runtime, protocol, and Validation terms.

Decision records in `Documentation/Decisions/` explain why current choices were
made. They do not replace the current architecture stated here.
