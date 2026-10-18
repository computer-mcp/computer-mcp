import CryptoKit
import Foundation

/// Offline export of the host's embedded Codex configuration into separately owned inputs.
package struct CodexConfigurationMigration: Encodable, Sendable {
  package let sourceSHA256: String
  package let configurationDirectory: String
  package let hostTOML: String
  package let adapterConfiguration: [String: JSONValue]
  package let adapterConfigurationPath: String
  package let stateDirectory: String
  package let pluginID = "codex"
  package let pluginSettings: PluginSettings

  package init(
    text: String, baseURL: URL, adapterConfigurationPath: String, stateDirectory: String,
    knownPluginMCPServerIDs: Set<String> = []
  ) throws {
    for path in [adapterConfigurationPath, stateDirectory] {
      guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16_384 else {
        throw ConfigurationError.invalid(
          "Codex migration destinations must be absolute, NUL-free paths.")
      }
    }
    let adapterURL = URL(fileURLWithPath: adapterConfigurationPath).standardizedFileURL
    let stateURL = URL(fileURLWithPath: stateDirectory).standardizedFileURL
    guard adapterURL != stateURL,
      adapterURL != stateURL.appendingPathComponent("codex.sqlite")
    else {
      throw ConfigurationError.invalid(
        "Codex configuration and state destinations must be distinct.")
    }
    var host = try GatewayConfiguration.load(
      text: text, baseURL: baseURL, knownPluginMCPServerIDs: knownPluginMCPServerIDs)
    guard let original = host.codex else {
      throw ConfigurationError.invalid("The source has no [codex] configuration to migrate.")
    }
    guard !original.executable.contains("\0"),
      !original.executable.contains("/") || original.executable.hasPrefix("/")
    else {
      throw ConfigurationError.invalid(
        "Resolve codex.executable to an absolute path before export; a relative executable depends on the old host's launch directory."
      )
    }
    let registrationID = PluginResolver.registrationID(
      pluginID: "codex", componentID: "app-server", override: nil)
    guard !host.mcp.servers.contains(where: { $0.id == registrationID }),
      !knownPluginMCPServerIDs.contains(registrationID)
    else {
      throw ConfigurationError.invalid(
        "The Codex plugin registration already exists; reconcile its host settings before migration."
      )
    }
    var risks: [String: CapabilityRisk] = [:]
    if original.appServerEnabled { risks.merge(Self.appServerRisks) { _, new in new } }
    if original.execEnabled { risks.merge(Self.execRisks) { _, new in new } }
    pluginSettings = PluginSettings(
      enabled: original.enabled,
      mcp: [
        "app-server": PluginMCPSettings(
          exposure: .reexport, prefix: "", allowedTools: risks.keys.sorted(), toolRisks: risks,
          args: ["--config", adapterURL.path, "--state-directory", stateURL.path],
          hostServices: original.appServerEnabled)
      ])
    try pluginSettings.validate()
    host.codex = nil
    hostTOML = try host.exportedTOML()
    guard !original.enabled || original.appServerEnabled || original.execEnabled else {
      throw ConfigurationError.invalid(
        "Enable App Server or Exec before exporting execution settings.")
    }
    let encoded = try JSONEncoder().encode(original)
    var adapterSettings = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
    adapterSettings.removeValue(forKey: "mcp_enabled")
    adapterConfiguration = adapterSettings
    self.adapterConfigurationPath = adapterURL.path
    self.stateDirectory = stateURL.path
    configurationDirectory = baseURL.standardizedFileURL.path
    sourceSHA256 = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // This finite migration contract belongs to the embedded provider's historical
  // surface. Downstream annotations and future plugin tools cannot expand it.
  private static let appServerRisks: [String: CapabilityRisk] = [
    "codex.diagnostics.snapshot": .readOnly,
    "codex.app.status": .readOnly,
    "codex.app.runtimes.list": .readOnly,
    "codex.app.runtimes.history": .readOnly,
    "codex.app.runtimes.cleanup.preview": .readOnly,
    "codex.app.runtimes.cleanup.perform": .workspaceWrite,
    "codex.app.ownership.reconcile.preview": .readOnly,
    "codex.app.ownership.reconcile.perform": .workspaceWrite,
    "codex.app.runtimes.inspect": .readOnly,
    "codex.app.runtimes.stop": .workspaceWrite,
    "codex.app.methods.list": .readOnly,
    "codex.app.methods.describe": .readOnly,
    "codex.app.methods.call": .workspaceWrite,
    "codex.app.thread.start": .workspaceWrite,
    "codex.app.thread.list": .readOnly,
    "codex.app.thread.reclaim": .workspaceWrite,
    "codex.app.thread.loaded.list": .readOnly,
    "codex.app.thread.read": .readOnly,
    "codex.app.thread.recent": .readOnly,
    "codex.app.thread.fork": .workspaceWrite,
    "codex.app.thread.release": .workspaceWrite,
    "codex.app.handoff.diagnose": .readOnly,
    "codex.app.goal.get": .readOnly,
    "codex.app.goal.set": .workspaceWrite,
    "codex.app.goal.clear": .workspaceWrite,
    "codex.app.runtime.stop": .workspaceWrite,
    "codex.app.turn.start": .workspaceWrite,
    "codex.app.turn.steer": .workspaceWrite,
    "codex.app.turn.interrupt": .workspaceWrite,
    "codex.app.review.start": .workspaceWrite,
    "codex.app.models.list": .readOnly,
    "codex.app.skills.list": .readOnly,
    "codex.app.apps.list": .readOnly,
    "codex.app.events.read": .readOnly,
    "codex.app.requests.list": .readOnly,
    "codex.app.requests.respond": .workspaceWrite,
    "codex.app.approvals.list": .readOnly,
    "codex.app.approvals.read": .readOnly,
    "codex.app.approvals.respond": .workspaceWrite,
    "codex.run.create": .workspaceWrite,
    "codex.run.list": .readOnly,
    "codex.run.read": .readOnly,
    "codex.run.record": .workspaceWrite,
    "codex.run.evaluate": .workspaceWrite,
    "codex.run.accept": .workspaceWrite,
    "codex.run.transition": .workspaceWrite,
    "codex.run.reconcile": .workspaceWrite,
    "codex.worktree.leases.acquire": .workspaceWrite,
    "codex.worktree.leases.list": .readOnly,
    "codex.worktree.leases.read": .readOnly,
    "codex.worktree.leases.heartbeat": .workspaceWrite,
    "codex.worktree.leases.release": .workspaceWrite,
    "codex.worktree.leases.cleanup.preview": .readOnly,
    "codex.worktree.leases.cleanup.perform": .workspaceWrite,
    "codex.worktree.managed.list": .readOnly,
    "codex.worktree.managed.read": .readOnly,
    "codex.worktree.provision.plan": .workspaceWrite,
    "codex.worktree.provision.perform": .workspaceWrite,
    "codex.worktree.remove.plan": .workspaceWrite,
    "codex.worktree.remove.perform": .destructive,
  ]
  private static let execRisks: [String: CapabilityRisk] = [
    "codex.exec.start": .workspaceWrite,
    "codex.exec.resume": .workspaceWrite,
    "codex.exec.list": .readOnly,
    "codex.exec.events": .readOnly,
    "codex.exec.result": .readOnly,
    "codex.exec.cancel": .workspaceWrite,
  ]
}
