import Foundation

package enum AppControlSurface: String, Codable, Sendable {
  case appAndCLI = "app_and_cli"
  case cli
}

package struct AppControlCapability: Codable, Equatable, Sendable, Identifiable {
  package var id: String
  package var cliCommand: String
  package var summary: String
  package var surface: AppControlSurface
  package var readOnly: Bool
  package var destructive: Bool
  package var idempotent: Bool
  package var localOnly: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case cliCommand = "cli_command"
    case summary
    case surface
    case readOnly = "read_only"
    case destructive
    case idempotent
    case localOnly = "local_only"
  }
}

package enum AppControlCapabilityCatalog {
  package static let all: [AppControlCapability] = [
    item(
      "app.capabilities", "computer-mcp app capabilities",
      "List this control-plane capability contract.", surface: .cli, readOnly: true),
    item(
      "app.status", "computer-mcp app status", "Read App and gateway control-plane status.",
      readOnly: true),
    item("app.start", "computer-mcp app start", "Start the App-owned gateway."),
    item("app.stop", "computer-mcp app stop", "Stop the App-owned gateway."),
    item(
      "app.restart", "computer-mcp app restart",
      "Restart the App-owned gateway and restore desired compatible Tunnels."),
    item(
      "app.launch_at_login", "computer-mcp app launch-at-login",
      "Enable or disable launch at login."),
    item(
      "readiness", "computer-mcp doctor", "Evaluate one non-mutating product journey.",
      readOnly: true),
    item(
      "config.path", "computer-mcp config path", "Print the active App manifest path.",
      surface: .cli, readOnly: true),
    item("config.show", "computer-mcp config show", "Read the active manifest.", readOnly: true),
    item(
      "config.validate", "computer-mcp config validate",
      "Validate a manifest without activating it.", readOnly: true),
    item(
      "config.export", "computer-mcp config export", "Export the effective secret-free manifest.",
      surface: .cli, readOnly: true),
    item(
      "config.history", "computer-mcp config history", "List bounded manifest revision history.",
      readOnly: true),
    item(
      "config.rollback", "computer-mcp config rollback",
      "Activate a prior manifest revision with runtime rollback on failure.", destructive: true),
    item(
      "config.import", "computer-mcp config import",
      "Preview or digest-guard an App manifest activation."),
    item(
      "workspace.list", "computer-mcp workspace list", "List registered workspace roots.",
      readOnly: true),
    item(
      "workspace.add", "computer-mcp workspace add", "Register one canonical local workspace root."),
    item(
      "workspace.deduplicate", "computer-mcp workspace deduplicate",
      "Preview or digest-guard duplicate registration repair.", destructive: true),
    item(
      "workspace.remove", "computer-mcp workspace remove",
      "Remove a registration and its profile grants without deleting user files.", destructive: true
    ),
    item(
      "workspace.enable", "computer-mcp workspace enable",
      "Enable or disable one workspace for one profile."),
    item(
      "profile.list", "computer-mcp profile list", "List profile grants and runtime state.",
      readOnly: true),
    item("profile.show", "computer-mcp profile show", "Read one profile grant.", readOnly: true),
    item(
      "profile.activate", "computer-mcp profile activate",
      "Activate a compatible gateway profile with rollback on failure."),
    item(
      "profile.grant", "computer-mcp profile grant",
      "Grant or revoke one workspace for one profile."),
    item(
      "profile.shell", "computer-mcp profile shell",
      "Enable or disable Full Shell for an eligible profile."),
    item(
      "provider.list", "computer-mcp providers list", "List recorded provider health.",
      readOnly: true),
    item(
      "provider.doctor", "computer-mcp providers doctor", "Refresh bounded provider diagnostics.",
      readOnly: true),
    item(
      "permissions.status", "computer-mcp permissions status",
      "Read current macOS permission status without prompting.", readOnly: true),
    item(
      "audit.list", "computer-mcp audit list", "List bounded redacted audit events.", readOnly: true
    ),
    item(
      "tools.list", "computer-mcp tools list", "List gateway tools visible to local-admin.",
      surface: .cli, readOnly: true),
    item(
      "tools.inspect", "computer-mcp tools inspect", "Inspect one local-admin gateway tool.",
      surface: .cli, readOnly: true),
    item(
      "tools.call", "computer-mcp tools call",
      "Call one local-admin gateway tool through policy and audit.", surface: .cli,
      destructive: true, idempotent: false),
    item(
      "tunnel.openai.list", "computer-mcp tunnel openai list",
      "List OpenAI Tunnel configurations and status.", readOnly: true),
    item(
      "tunnel.openai.doctor", "computer-mcp tunnel openai doctor",
      "Diagnose one OpenAI Tunnel without starting it.", readOnly: true),
    item(
      "tunnel.openai.start", "computer-mcp tunnel openai start",
      "Start one OpenAI Tunnel and its compatible gateway."),
    item(
      "tunnel.openai.reconnect", "computer-mcp tunnel openai reconnect",
      "Reconnect one OpenAI Tunnel and its compatible gateway."),
    item(
      "tunnel.openai.provision", "computer-mcp tunnel openai provision",
      "Provision the local Tunnel client profile.", destructive: true),
    item("tunnel.openai.stop", "computer-mcp tunnel openai stop", "Stop one OpenAI Tunnel."),
    item(
      "tunnel.openai.logs", "computer-mcp tunnel openai logs",
      "Read bounded redacted OpenAI Tunnel logs.", readOnly: true),
    item(
      "tunnel.openai.save", "computer-mcp tunnel openai save",
      "Create or update an OpenAI Tunnel configuration and Keychain credential."),
    item(
      "tunnel.openai.remove", "computer-mcp tunnel openai remove",
      "Remove an OpenAI Tunnel configuration and Keychain credential.", destructive: true),
    item(
      "tunnel.cloudflare.list", "computer-mcp tunnel cloudflare list",
      "List Cloudflare Tunnel configurations and status.", readOnly: true),
    item(
      "tunnel.cloudflare.doctor", "computer-mcp tunnel cloudflare doctor",
      "Diagnose one Cloudflare Tunnel without starting it.", readOnly: true),
    item(
      "tunnel.cloudflare.start", "computer-mcp tunnel cloudflare start",
      "Start one named Cloudflare Tunnel."),
    item(
      "tunnel.cloudflare.stop", "computer-mcp tunnel cloudflare stop",
      "Stop one named Cloudflare Tunnel."),
    item(
      "tunnel.cloudflare.logs", "computer-mcp tunnel cloudflare logs",
      "Read bounded redacted Cloudflare Tunnel logs.", readOnly: true),
    item(
      "tunnel.cloudflare.save", "computer-mcp tunnel cloudflare save",
      "Create or update a named Cloudflare Tunnel and Keychain credentials."),
    item(
      "tunnel.cloudflare.remove", "computer-mcp tunnel cloudflare remove",
      "Remove a Cloudflare Tunnel configuration and Keychain credentials.", destructive: true),
  ].sorted { $0.id < $1.id }

  package static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

  private static func item(
    _ id: String,
    _ cliCommand: String,
    _ summary: String,
    surface: AppControlSurface = .appAndCLI,
    readOnly: Bool = false,
    destructive: Bool = false,
    idempotent: Bool = true
  ) -> AppControlCapability {
    AppControlCapability(
      id: id,
      cliCommand: cliCommand,
      summary: summary,
      surface: surface,
      readOnly: readOnly,
      destructive: destructive,
      idempotent: idempotent,
      localOnly: true
    )
  }
}
