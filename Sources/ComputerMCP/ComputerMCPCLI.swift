import Foundation

/// CLI metadata shared by the executable and library documentation.
package enum ComputerMCPCLI {
  /// Current package CLI version.
  package static let version = "1.0.6"

  /// Current package build number.
  package static let build = "7"

  /// Version string exposed by the command-line executable.
  package static let releaseVersion = "\(version) (\(build))"

  /// Short usage text for documentation and fallback diagnostics.
  package static let help = """
    computer-mcp \(releaseVersion)

    Usage:
      computer-mcp app status
      computer-mcp config path|show|validate|export|import
      computer-mcp workspace list|add|remove|enable
      computer-mcp profile list|show|grant
      computer-mcp tunnel openai list|doctor|start|stop|logs
      computer-mcp tunnel cloudflare list|doctor|start|stop|logs
      computer-mcp tools list|inspect|call
      computer-mcp install cli|codex
      computer-mcp uninstall cli
      computer-mcp serve stdio|http --config <path>
      computer-mcp bridge [--socket <path>]
      computer-mcp --version
      computer-mcp --help

    Commands:
      app        Inspect the running App Control Plane.
      config     Inspect, validate, export, or import the current schema-1 manifest.
      workspace  Manage App-owned workspace authorization.
      profile    Inspect profiles and grant workspace access.
      tunnel     Diagnose and control OpenAI and Cloudflare Tunnel lifecycles.
      tools      List, inspect, or call gateway tools.
      install    Install the embedded CLI or Codex integration.
      uninstall  Remove the user-owned CLI link.
      serve      Run an explicit standalone development gateway.
      bridge     Bridge MCP stdio to the App-owned Gateway Socket.
    """
}
