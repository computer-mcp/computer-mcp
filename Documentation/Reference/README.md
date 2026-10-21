# Reference

This directory contains detailed operational reference material.

## Documents

- [Quick Start](QuickStart.md): release installation, first launch, and local MCP.
- [CLI](CLI.md): command-line modes and exit behavior.
- [Config](Config.md): TOML source and policy configuration.
- [Control Plane Capabilities](ControlPlaneCapabilities.md): shared App/CLI
  management inventory, ownership, and secret-input rules.
- [Tools](Tools.md): complete gateway tool families and result contracts.
- [Isolated delivery](Delivery.md): declared scopes, edit-and-land tools, journals and recovery.
- [MCP Protocol](MCPProtocol.md): stdio transport and JSON-RPC examples.
- [Scoped Host Services](HostServices.md): inherited MCP callbacks, approval
  ownership, derived registrations, diagnostics and recovery.
- [CLI Trees](CLITrees.md): machine-readable command descriptors, argv/stdin
  encoding, projected tools, output validation, and coverage.
- [Plugin Packages](PluginPackages.md): immutable manifests, contribution
  sources, and package-directory validation boundaries.
- [ChatGPT Web Runbook](ChatGPTWebRunbook.md): App-managed Secure MCP Tunnel setup.
- [Cloudflare Runbook](CloudflareRunbook.md): named-tunnel onboarding,
  authentication, lifecycle, and verification.
- [Validation](Validation.md): Validation Test Cases, Capability Coverage,
  evidence correlation, and Production Readiness reporting.
- [Release](Release.md): protected candidate builds, Apple credentials,
  notarization, exact artifact acceptance, signed-tag publication, and local
  rehearsal scope.
- [Troubleshooting](Troubleshooting.md): common failures and checks.
- [简体中文](zh-CN/README.md): mirrored onboarding and recovery guides.

Keep current architecture truth in `Documentation/Architecture/`. Keep
accepted rationale in `Documentation/Decisions/`. Release history lives in
[CHANGELOG.md](../../CHANGELOG.md) and the GitHub Releases.
