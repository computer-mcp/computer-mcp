import CryptoKit
import Foundation

package struct MCPRegistrationEntry: Codable, Equatable, Sendable, Identifiable {
  package var id: String { server.id }
  package let server: MCPServerConfig
  package let origin: PluginContributionOrigin?
}

package struct MCPRegistrationSnapshot: Codable, Equatable, Sendable {
  package let currentDigest: String
  package let registrations: [MCPRegistrationEntry]
}

package enum MCPRegistrationChange: Sendable {
  case add(MCPServerConfig)
  case configure(MCPServerConfig)
  case enabled(id: String, Bool)
  case remove(id: String)

  package var id: String {
    switch self {
    case .add(let server), .configure(let server): server.id
    case .enabled(let id, _), .remove(let id): id
    }
  }

  func applying(to configuration: GatewayConfiguration) throws -> GatewayConfiguration {
    var proposed = configuration
    let index = proposed.mcp.servers.firstIndex { $0.id == id }
    switch self {
    case .add(let server):
      guard index == nil else {
        throw ConfigurationError.invalid("MCP registration '\(id)' already exists; use configure.")
      }
      proposed.mcp.servers.append(server)
    case .configure(let server):
      guard let index else { throw GatewayToolError.unknownMCPServer(id) }
      proposed.mcp.servers[index] = server
    case .enabled(_, let enabled):
      guard let index else { throw GatewayToolError.unknownMCPServer(id) }
      proposed.mcp.servers[index].enabled = enabled
    case .remove:
      guard let index else { throw GatewayToolError.unknownMCPServer(id) }
      guard !proposed.tools.contains(where: { $0.source == id }),
        !proposed.profiles.contains(where: { $0.mcpServers.contains(id) })
      else {
        throw ConfigurationError.invalid(
          "MCP registration '\(id)' is referenced by tool mappings or profile grants. Disable it, or review and remove those references before removal."
        )
      }
      proposed.mcp.servers.remove(at: index)
    }
    try proposed.validate()
    return proposed
  }
}

package struct MCPRegistrationChangePreview: Codable, Equatable, Sendable {
  package let id: String
  package let currentDigest: String
  package let proposedDigest: String
  package let before: MCPServerConfig?
  package let after: MCPServerConfig?
  package var transportWillRestart: Bool = false
  package var appliedRevision: String?
}

extension AppControlPlaneService {
  package func mcpRegistrations() throws -> MCPRegistrationSnapshot {
    let data = try Data(contentsOf: directories.manifest)
    guard let text = String(data: data, encoding: .utf8) else {
      throw ConfigurationError.invalid("The active manifest is not valid UTF-8.")
    }
    let configuration = try parseManifest(text)
    let resolved = try PluginHost.resolve(database.pluginStoreSnapshot(), bundled: bundledPlugins)
    let composition = try GatewayPluginComposition(
      configuration: configuration, plugins: resolved.plugins)
    return MCPRegistrationSnapshot(
      currentDigest: Self.manifestDigest(data),
      registrations: composition.runtimeConfiguration.mcp.servers.map { server in
        MCPRegistrationEntry(
          server: server, origin: composition.origins[.init(kind: .mcp, id: server.id)])
      }.sorted { $0.id < $1.id })
  }

  func prepareMCPRegistrationChange(_ change: MCPRegistrationChange) throws
    -> (preview: MCPRegistrationChangePreview, manifest: String)
  {
    guard !pluginMutationInProgress else { throw PluginHostError.changeInProgress }
    let data = try Data(contentsOf: directories.manifest)
    guard let text = String(data: data, encoding: .utf8) else {
      throw ConfigurationError.invalid("The active manifest is not valid UTF-8.")
    }
    let configuration = try parseManifest(text)
    let state = try database.pluginStoreSnapshot()
      .includingBundledDefaults(bundledPlugins.packages.map(\.manifest))
    guard !state.knownMCPRegistrationIDs.contains(change.id) else {
      throw ConfigurationError.invalid(
        "MCP registration '\(change.id)' belongs to a plugin. Change its contribution through plugin settings."
      )
    }
    let proposed = try change.applying(to: configuration)
    let manifest = try proposed.exportedTOML()
    _ = try parseManifest(manifest)
    return (
      MCPRegistrationChangePreview(
        id: change.id, currentDigest: Self.manifestDigest(data),
        proposedDigest: Self.manifestDigest(Data(manifest.utf8)),
        before: configuration.mcp.servers.first { $0.id == change.id },
        after: proposed.mcp.servers.first { $0.id == change.id }),
      manifest
    )
  }

  private static func manifestDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension AppControlPlaneOperations {
  package func changeMCPRegistration(
    _ change: MCPRegistrationChange, apply: Bool = false, expectedCurrentDigest: String? = nil
  ) async throws -> MCPRegistrationChangePreview {
    let prepared = try await controlPlane.prepareMCPRegistrationChange(change)
    var preview = prepared.preview
    preview.transportWillRestart = await gatewayService.snapshot().state == .running
    if apply {
      guard expectedCurrentDigest == preview.currentDigest else {
        throw AtomicManifestStoreError.staleDigest
      }
      preview.appliedRevision = try await activateManifest(
        prepared.manifest, expectedDigest: preview.currentDigest
      ).id
    }
    return preview
  }
}
