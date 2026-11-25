import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPlugins
import ComputerMCPProcess
import Crypto
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
        !proposed.profiles.contains(where: { $0.grant.permissions.entries[.mcpServer(id)] != nil })
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

  var activatingLocalServer: MCPServerConfig? {
    guard let after, after.enabled, after.transport == .stdio, before != after else { return nil }
    return after
  }

  var enablementTarget: ProviderEnablementReview.Target {
    .registration(currentDigest: currentDigest, proposedDigest: proposedDigest)
  }
}

extension AppControlPlaneService {
  package func mcpRegistrations() throws -> MCPRegistrationSnapshot {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    let data = try Data(contentsOf: directories.manifest)
    guard let text = String(data: data, encoding: .utf8) else {
      throw ConfigurationError.invalid("The active manifest is not valid UTF-8.")
    }
    let configuration = try parseManifest(text)
    let resolved = try PluginHost.resolve(
      database.pluginStoreSnapshot(), bundled: bundledPlugins, applications: platform.applications)
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
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
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
    let admitted = try parseManifest(manifest)
    return (
      MCPRegistrationChangePreview(
        id: change.id, currentDigest: Self.manifestDigest(data),
        proposedDigest: Self.manifestDigest(Data(manifest.utf8)),
        before: configuration.mcp.servers.first { $0.id == change.id },
        after: admitted.mcp.servers.first { $0.id == change.id }),
      manifest
    )
  }

  package func reviewMCPRegistrationEnablement(
    _ change: MCPRegistrationChange, preview: MCPRegistrationChangePreview
  ) throws -> ProviderEnablementReview? {
    let prepared = try prepareMCPRegistrationChange(change)
    guard preview.enablementTarget == prepared.preview.enablementTarget else {
      throw AtomicManifestStoreError.staleDigest
    }
    guard let server = prepared.preview.activatingLocalServer else { return nil }
    let inputs = try gatewayInputs()
    let source = try localRegistrationReview(server, inputs: inputs)
    return try enablementReview(
      source: source, name: server.id, version: nil, inputs: inputs, server: server,
      target: prepared.preview.enablementTarget)
  }

  func prepareMCPRegistrationActivation(
    preview: MCPRegistrationChangePreview, approval: ProviderEnablementApproval?
  ) throws -> GatewayProviderActivation? {
    guard let server = preview.activatingLocalServer else {
      guard approval == nil else { throw GatewayPermissionError.revisionConflict }
      return nil
    }
    guard let approval else { throw ProviderEnablementError.reviewRequired }
    let inputs = try gatewayInputs()
    guard approval.target == preview.enablementTarget,
      approval.provider.sourceReview == (try localRegistrationReview(server, inputs: inputs))
    else { throw GatewayPermissionError.revisionConflict }
    return try requirePermissionControl().prepareProviderActivation(approval)
  }

  private func localRegistrationReview(_ server: MCPServerConfig, inputs: GatewayInputs)
    throws -> GatewayProviderReview
  {
    try GatewayProviderReview(
      server: server, configuration: inputs.persisted,
      knownPluginIDs: Set(bundledPlugins.packages.map { $0.manifest.id }),
      knownServerIDs: Set(inputs.configuration.mcp.servers.map(\.id)))
  }

  private static func manifestDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension AppControlPlaneOperations {
  package func changeMCPRegistration(
    _ change: MCPRegistrationChange, apply: Bool = false, expectedCurrentDigest: String? = nil,
    approval: ProviderEnablementApproval? = nil
  ) async throws -> MCPRegistrationChangePreview {
    let prepared = try await controlPlane.prepareMCPRegistrationChange(change)
    var preview = prepared.preview
    if apply {
      guard expectedCurrentDigest == preview.currentDigest else {
        throw AtomicManifestStoreError.staleDigest
      }
      let activation = try await controlPlane.prepareMCPRegistrationActivation(
        preview: preview, approval: approval)
      preview.appliedRevision = try await gatewayService.changeManifest(
        prepared.manifest, expectedDigest: preview.currentDigest, providerActivation: activation
      ).id
    }
    return preview
  }
}
