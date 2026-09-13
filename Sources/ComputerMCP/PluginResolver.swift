import Foundation

package enum IntegrationKind: String, Codable, Hashable, Sendable { case mcp, cli, skills }

package struct IntegrationRegistration: Codable, Hashable, Sendable {
  package let kind: IntegrationKind
  package let id: String
}

package struct PluginContributionOrigin: Codable, Equatable, Sendable {
  package let pluginID: String
  package let componentID: String
  package let version: PluginVersion
  package let source: PluginSource
}

package struct PluginResolutionDiagnostic: Codable, Equatable, Sendable {
  package enum Code: String, Codable, Sendable {
    case dependencyUnavailable, executableUnavailable, executableUnverified, hostIncompatible
  }
  package let pluginID: String
  package let componentID: String?
  package let code: Code
  package let dependencyID: String?
  package let instructions: String?
  package var executable: ExecutableInspection? = nil
}

package struct ResolvedPlugin: Sendable {
  package let id: String
  package let mcpServers: [MCPServerConfig]
  package let cliCommands: [CLICommandConfig]
  package let skillRoots: [SkillRootConfig]
  package let origins: [IntegrationRegistration: PluginContributionOrigin]
  package let diagnostics: [PluginResolutionDiagnostic]
}

package enum PluginResolver {
  package static func registrationID(pluginID: String, componentID: String, override: String?)
    -> String
  {
    override ?? "plugin-\(pluginID.utf8.count)-\(pluginID)-\(componentID)"
  }
  /// Bindings are resolved by the host; a manifest cannot choose an arbitrary external path.
  package static func resolve(
    package plugin: PluginPackage,
    source: PluginSource,
    settings: PluginSettings,
    dependencyExecutables: [String: URL] = [:],
    hostVersion: PluginVersion,
    architecture: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> ResolvedPlugin {
    try settings.validate()
    guard try WorkspacePathResolver.canonicalWorkspace(source.root) == plugin.root else {
      throw PluginManifestError.invalid("Source root does not match the loaded package.")
    }
    let manifest = plugin.manifest
    var mcp: [MCPServerConfig] = []
    var cli: [CLICommandConfig] = []
    var skills: [SkillRootConfig] = []
    var origins: [IntegrationRegistration: PluginContributionOrigin] = [:]
    var diagnostics: [PluginResolutionDiagnostic] = []

    func result() -> ResolvedPlugin {
      ResolvedPlugin(
        id: manifest.id, mcpServers: mcp, cliCommands: cli, skillRoots: skills,
        origins: origins, diagnostics: diagnostics)
    }
    guard settings.enabled else { return result() }
    if let compatibility = manifest.compatibility,
      !compatibility.permits(host: hostVersion, architecture: architecture)
    {
      diagnostics.append(
        .init(
          pluginID: manifest.id, componentID: nil,
          code: .hostIncompatible, dependencyID: nil, instructions: nil))
      return result()
    }

    func registrationID(_ component: String, override: String?) throws -> String {
      // Length-prefixing keeps identities injective even when IDs contain separators.
      let id = Self.registrationID(
        pluginID: manifest.id, componentID: component, override: override)
      guard !id.isEmpty, !id.contains("\0") else {
        throw ConfigurationError.invalid("Plugin registration ID is empty or contains NUL.")
      }
      return id
    }

    func record(_ component: String, kind: IntegrationKind, id: String) throws {
      let key = IntegrationRegistration(kind: kind, id: id)
      guard origins[key] == nil else {
        throw ConfigurationError.invalid("Duplicate plugin contribution registration '\(id)'.")
      }
      origins[key] = PluginContributionOrigin(
        pluginID: manifest.id, componentID: component,
        version: manifest.version, source: source)
    }

    func path(_ relative: String?) throws -> String? {
      try relative.map { try WorkspacePathResolver.resolve($0, relativeTo: plugin.root).path }
    }

    func executable(_ reference: PluginExecutable, componentID: String, cwd: String?) throws
      -> String?
    {
      let inspection = try Self.inspectExecutable(
        reference, package: plugin, dependencyExecutables: dependencyExecutables,
        workingDirectory: URL(fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath),
        environment: environment)
      if inspection?.status != .passed {
        let unavailable = inspection?.hasKnownFailure ?? true
        diagnostics.append(
          .init(
            pluginID: manifest.id, componentID: componentID,
            code: unavailable
              ? (reference.dependency == nil ? .executableUnavailable : .dependencyUnavailable)
              : .executableUnverified,
            dependencyID: reference.dependency,
            instructions: manifest.dependencies.first { $0.id == reference.dependency }?
              .instructions,
            executable: inspection))
      }
      return inspection?.hasKnownFailure == false ? inspection?.path : nil
    }

    for contribution in manifest.mcp {
      let choice = settings.mcp[contribution.id] ?? PluginMCPSettings()
      guard choice.enabled else { continue }
      try choice.authentication?.validate(
        endpoint: contribution.url, transport: contribution.transport)
      guard contribution.transport == .stdio || (choice.args == nil && !choice.hostServices) else {
        throw ConfigurationError.invalid(
          "HTTP MCP contributions do not accept launch arguments or inherited host services.")
      }
      let id = try registrationID(contribution.id, override: choice.registrationID)
      let command: String?
      if let reference = contribution.executable {
        guard
          let resolved = try executable(
            reference, componentID: contribution.id, cwd: path(contribution.cwd))
        else {
          continue
        }
        command = resolved
      } else {
        command = nil
      }
      let server = MCPServerConfig(
        id: id, transport: contribution.transport,
        url: contribution.url, command: command, args: choice.args ?? contribution.args,
        cwd: try path(contribution.cwd), exposure: choice.exposure,
        prefix: choice.prefix ?? contribution.prefix ?? id,
        capabilities: contribution.capabilities, allowedTools: choice.allowedTools,
        allowAnyTool: choice.allowAnyTool, toolRisks: choice.toolRisks,
        hostServices: choice.hostServices, authentication: choice.authentication)
      try record(contribution.id, kind: .mcp, id: id)
      mcp.append(server)
    }
    for contribution in manifest.cli {
      let choice = settings.cli[contribution.id] ?? PluginCLISettings()
      guard choice.enabled else { continue }
      let id = try registrationID(contribution.id, override: choice.registrationID)
      guard
        let command = try executable(
          contribution.executable, componentID: contribution.id, cwd: path(contribution.cwd))
      else { continue }
      // A declared tree's constraints must also govern generic cli.exec.
      guard contribution.tree == nil || !choice.allowAnyArgs else {
        throw ConfigurationError.invalid(
          "CLI '\(id)' declares a command tree and cannot grant unrestricted arguments.")
      }
      var tree: CLITreeSource?
      if let source = contribution.tree {
        let helper: String?
        if let reference = source.helper {
          guard
            let resolved = try executable(
              reference, componentID: contribution.id, cwd: path(contribution.cwd))
          else {
            continue
          }
          helper = resolved
        } else {
          helper = nil
        }
        tree = CLITreeSource(
          kind: source.kind == .file ? .file : (source.kind == .helper ? .helper : .introspection),
          path: try path(source.path), helper: helper, args: source.args)
        tree?.packageRoot = plugin.root
      }
      cli.append(
        CLICommandConfig(
          id: id, executable: command, description: contribution.description,
          cwd: try path(contribution.cwd), allowAnyArgs: choice.allowAnyArgs, tree: tree))
      try record(contribution.id, kind: .cli, id: id)
    }
    for contribution in manifest.skills {
      let choice = settings.skills[contribution.id] ?? PluginSkillSettings()
      guard choice.enabled else { continue }
      let id = try registrationID(contribution.id, override: choice.registrationID)
      try PluginPackageFiles(root: plugin.root).validate(contribution.path, kind: .directory)
      let root = try WorkspacePathResolver.resolve(contribution.path, relativeTo: plugin.root)
      skills.append(SkillRootConfig(id: id, path: root.path, description: contribution.description))
      try record(contribution.id, kind: .skills, id: id)
    }
    return result()
  }

  static func inspectExecutable(
    _ reference: PluginExecutable, package plugin: PluginPackage,
    dependencyExecutables: [String: URL], workingDirectory: URL, environment: [String: String]
  ) throws -> ExecutableInspection? {
    let command: String?
    if let relative = reference.path {
      try PluginPackageFiles(root: plugin.root).validate(relative, kind: .executable)
      command = try WorkspacePathResolver.resolve(relative, relativeTo: plugin.root).path
    } else if let id = reference.dependency {
      command = dependencyExecutables[id].flatMap { $0.isFileURL ? $0.path : nil }
    } else {
      throw PluginManifestError.invalid("Executable has no ownership reference.")
    }
    return command.map {
      ExecutableInspection.inspect($0, workingDirectory: workingDirectory, environment: environment)
    }
  }
}

/// The source config remains exportable; expanded registrations exist only in this runtime value.
package struct GatewayPluginComposition: Sendable {
  package let sourceConfiguration: GatewayConfiguration
  package let runtimeConfiguration: GatewayConfiguration
  package let origins: [IntegrationRegistration: PluginContributionOrigin]
  package let diagnostics: [PluginResolutionDiagnostic]

  package init(configuration: GatewayConfiguration, plugins: [ResolvedPlugin]) throws {
    var effective = configuration
    var origins: [IntegrationRegistration: PluginContributionOrigin] = [:]
    var identities = Set<String>()
    var registrations = Set(
      configuration.mcp.servers.map { IntegrationRegistration(kind: .mcp, id: $0.id) }
        + configuration.cli.commands.map { IntegrationRegistration(kind: .cli, id: $0.id) }
        + configuration.skills.roots.map { IntegrationRegistration(kind: .skills, id: $0.id) })
    for plugin in plugins {
      guard identities.insert(plugin.id).inserted else {
        throw ConfigurationError.invalid("Multiple selected sources for plugin '\(plugin.id)'.")
      }
      for (key, origin) in plugin.origins {
        guard registrations.insert(key).inserted else {
          throw ConfigurationError.invalid(
            "Plugin registration conflicts with existing \(key.kind.rawValue) '\(key.id)'.")
        }
        origins[key] = origin
      }
      effective.mcp.servers += plugin.mcpServers
      effective.cli.commands += plugin.cliCommands
      effective.skills.roots += plugin.skillRoots
      if !plugin.skillRoots.isEmpty { effective.skills.enabled = true }
    }
    if !plugins.isEmpty { try effective.validate() }
    sourceConfiguration = configuration
    runtimeConfiguration = effective
    self.origins = origins
    diagnostics = plugins.flatMap(\.diagnostics)
  }
}
