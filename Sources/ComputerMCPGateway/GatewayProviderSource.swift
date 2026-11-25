import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPPlugins
import Foundation

/// Resolves a selected contribution from host configuration, independently of tool metadata.
package struct GatewayProviderSource: Sendable {
  let review: GatewayProviderReview
  let registrationID: String
  let workingDirectory: String?
  /// The verified launch path of an MCP contribution. Launch uses exactly this file.
  let executable: String?
  let resources: [VerifiedFileIdentity]
  let validate: @Sendable () throws -> Void
  let scopedTool: MCPToolReference?

  init(
    review: GatewayProviderReview, registrationID: String, workingDirectory: String?,
    executable: String?, resources: [VerifiedFileIdentity],
    validate: @escaping @Sendable () throws -> Void,
    scopedTool: MCPToolReference? = nil
  ) {
    self.review = review
    self.registrationID = registrationID
    self.workingDirectory = workingDirectory
    self.executable = executable
    self.resources = resources
    self.validate = validate
    self.scopedTool = scopedTool
  }

  static func resolve(
    registration: IntegrationRegistration, configuration: GatewayConfiguration,
    origins: [IntegrationRegistration: PluginContributionOrigin], database: GatewayDatabase,
    tool: MCPToolReference? = nil, resolvedPlugins: PluginStoreSnapshot? = nil
  ) throws -> Self {
    #if os(Linux)
      throw GatewayToolError.executionFailed("Linux provider activation is unavailable")
    #else
      let state = try database.configurationState()
      let knownServers = Set(configuration.mcp.servers.map(\.id))
      let knownPlugins = Set(origins.values.map(\.pluginID))
      let directory: String?
      switch registration.kind {
      case .mcp:
        guard let server = configuration.mcp.servers.first(where: { $0.id == registration.id }),
          server.enabled, server.transport == .stdio
        else { throw GatewayPermissionError.invalidBinding }
        directory = server.cwd
      case .cli:
        guard let command = configuration.cli.commands.first(where: { $0.id == registration.id })
        else { throw GatewayPermissionError.invalidBinding }
        directory = command.cwd
      case .skills: throw GatewayPermissionError.invalidBinding
      }
      let review: GatewayProviderReview
      let resources: [VerifiedFileIdentity]
      let validate: @Sendable () throws -> Void
      let launch = try Self.launch(registration, configuration: configuration)
      var scopedTool: MCPToolReference?
      if let origin = origins[registration] {
        let package = try PluginPackage.load(at: origin.source.root)
        guard package.manifest.id == origin.pluginID,
          origin.reviewedRequirements?.sourceDigest
            == (try PluginStore.manifestDigest(package.manifest))
        else { throw GatewayPermissionError.invalidBinding }
        review = try GatewayProviderReview(
          package: package, configuration: state,
          knownPluginIDs: knownPlugins, knownServerIDs: knownServers)
        let root = try VerifiedFileIdentity.capture(package.root)
        resources = [root] + launch.identities
        let digest = review.sourceDigest
        let scopedSelection = try Self.scopedSelection(
          tool: tool, registration: registration, origin: origin, manifest: package.manifest,
          digest: digest, configuration: configuration, resolved: resolvedPlugins,
          current: state.plugins)
        if scopedSelection != nil {
          guard launch.executable != nil, !launch.identities.isEmpty else {
            throw GatewayPermissionError.invalidBinding
          }
          scopedTool = tool
        }
        validate = {
          try root.verify(origin.source.root)
          for identity in launch.identities {
            try identity.verify(URL(fileURLWithPath: identity.path))
          }
          let current = try PluginPackage.load(at: origin.source.root)
          guard try PluginStore.manifestDigest(current.manifest) == digest else {
            throw GatewayPermissionError.invalidBinding
          }
          let selection = try database.configurationState().plugins
          try scopedSelection?(selection)
          guard selection.settings[origin.pluginID] == state.plugins.settings[origin.pluginID]
          else {
            throw GatewayPermissionError.invalidBinding
          }
          if let id = selection.selectedInstallations[origin.pluginID] {
            guard selection.settings[origin.pluginID]?.enabled == true,
              selection.installations.contains(where: {
                $0.id == id && $0.source.root == origin.source.root && $0.manifestDigest == digest
              })
            else { throw GatewayPermissionError.invalidBinding }
          } else if state.plugins.selectedInstallations[origin.pluginID] != nil {
            throw GatewayPermissionError.invalidBinding
          }
        }
      } else {
        guard registration.kind == .mcp,
          let server = configuration.mcp.servers.first(where: { $0.id == registration.id })
        else { throw GatewayPermissionError.invalidBinding }
        review = try GatewayProviderReview(
          server: server, configuration: state,
          knownPluginIDs: knownPlugins, knownServerIDs: knownServers)
        resources = launch.identities
        validate = {
          for identity in launch.identities {
            try identity.verify(URL(fileURLWithPath: identity.path))
          }
        }
      }
      try validate()
      return Self(
        review: review, registrationID: registration.id,
        workingDirectory: directory == "project" ? nil : directory, executable: launch.executable,
        resources: resources, validate: validate, scopedTool: scopedTool)
    #endif
  }

  private static func scopedSelection(
    tool: MCPToolReference?, registration: IntegrationRegistration,
    origin: PluginContributionOrigin,
    manifest: PluginManifest, digest: String, configuration: GatewayConfiguration,
    resolved: PluginStoreSnapshot?, current: PluginStoreSnapshot
  ) throws -> (@Sendable (PluginStoreSnapshot) throws -> Void)? {
    guard registration.kind == .mcp, let tool, tool.serverID == registration.id,
      let server = configuration.mcp.servers.first(where: { $0.id == registration.id }),
      server.transport == .stdio, server.hostServices, server.permitsTool(tool.toolName),
      let settings = resolved?.settings[origin.pluginID], settings.enabled,
      let choice = settings.mcp[origin.componentID], choice.enabled, choice.hostServices,
      choice.allowAnyTool || choice.allowedTools.contains(tool.toolName),
      PluginResolver.registrationID(
        pluginID: origin.pluginID, componentID: origin.componentID, override: choice.registrationID
      ) == registration.id,
      manifest.version == origin.version,
      manifest.mcp.contains(where: { $0.id == origin.componentID && $0.transport == .stdio })
    else { return nil }
    let pluginID = origin.pluginID
    let selected = resolved?.selectedInstallations[pluginID]
    let installation = resolved?.installations.first { $0.id == selected }
    if let selected {
      guard let installation, installation.id == selected, installation.pluginID == pluginID,
        installation.source == origin.source, installation.manifestDigest == digest,
        installation.version == origin.version
      else { throw GatewayPermissionError.invalidBinding }
    } else {
      guard origin.source.kind == .bundled else { return nil }
    }
    let validate: @Sendable (PluginStoreSnapshot) throws -> Void = { state in
      guard state.selectedInstallations[pluginID] == selected,
        state.installations.first(where: { $0.id == selected }) == installation,
        let current = state.settings[pluginID], current.enabled,
        current.mcp[origin.componentID] == choice,
        current.dependencyExecutables == settings.dependencyExecutables
      else { throw GatewayPermissionError.invalidBinding }
    }
    try validate(current)
    return validate
  }

  /// Resolves the launch executable, a CLI tree helper and every interpreter they
  /// name once, from the registration's own environment and interpreter bindings.
  private static func launch(
    _ registration: IntegrationRegistration, configuration: GatewayConfiguration
  ) throws -> (executable: String?, identities: [VerifiedFileIdentity]) {
    func identities(_ executable: ExecutableInspection) throws -> [VerifiedFileIdentity] {
      guard !executable.hasKnownFailure, let path = executable.path else {
        throw GatewayToolError.executionFailed(
          "Provider executable is unavailable: \(executable.message)")
      }
      return try [VerifiedFileIdentity.capture(URL(fileURLWithPath: path))]
        + executable.interpreters.flatMap { try identities($0) }
    }
    func environment(_ overrides: [String: String]) -> [String: String] {
      ["PATH": "/usr/bin:/bin"].merging(overrides) { _, value in value }
    }
    switch registration.kind {
    case .mcp:
      guard let server = configuration.mcp.servers.first(where: { $0.id == registration.id })
      else { throw GatewayPermissionError.invalidBinding }
      let inspection = ExecutableInspection.inspect(
        server.command ?? "",
        workingDirectory: server.resolvedWorkingDirectory(base: configuration.projectDirectory),
        environment: environment(server.env))
      return (inspection.path, try identities(inspection))
    case .cli:
      guard let command = configuration.cli.commands.first(where: { $0.id == registration.id })
      else { throw GatewayPermissionError.invalidBinding }
      let directory =
        command.resolvedWorkingDirectory(base: configuration.projectDirectory)
        ?? configuration.projectDirectory
      let executables = [command.executable] + (command.tree?.helper.map { [$0] } ?? [])
      return (
        nil,
        try executables.flatMap {
          try identities(
            ExecutableInspection.invocation(
              $0, workingDirectory: directory, environment: environment(command.env),
              interpreterBindings: command.interpreterBindings
            ).inspection)
        }
      )
    case .skills: throw GatewayPermissionError.invalidBinding
    }
  }
}
