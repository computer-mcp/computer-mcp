import Foundation

package enum PluginCheckStatus: String, Codable, Sendable {
  case passed, failed, unverified
}

package struct PluginDoctorCheck: Codable, Sendable, Identifiable {
  package enum Kind: String, Codable, Sendable { case source, compatibility, executable, resources }
  package let id: String
  package let kind: Kind
  package let status: PluginCheckStatus
  package let message: String
  package var componentID: String? = nil
  package var dependencyID: String? = nil
  package var enabled: Bool? = nil
  package var workingDirectory: String? = nil
  package var inspection: ExecutableInspection? = nil
}

package struct PluginDoctorDependency: Codable, Sendable, Identifiable {
  package let declaration: PluginDependency
  package let executable: String?
  package let resolutionSource: String
  package var id: String { declaration.id }
}

/// A read-only observation. No contribution, version probe, permission prompt or connection is started.
package struct PluginDoctorReport: Codable, Sendable {
  package let pluginID: String
  package let revision: Int64
  package let checkedAt: Date
  package let enabled: Bool
  package let source: PluginSource?
  package let version: PluginVersion?
  package let checks: [PluginDoctorCheck]
  package let dependencies: [PluginDoctorDependency]
  package let status: PluginCheckStatus
  package let scope: String
  package let notChecked: [String]

  package static func inspect(
    pluginID: String, state: PluginStoreSnapshot, bundled: BundledPlugins,
    hostVersion: PluginVersion, architecture: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    applicationURL: (String) -> URL? = PluginDependencyResolver.applicationURL
  ) throws -> Self {
    try Task.checkCancellation()
    try state.validate()
    try validatePluginID(pluginID)
    guard
      state.settings[pluginID] != nil
        || state.installations.contains(where: { $0.pluginID == pluginID })
        || bundled.packages.contains(where: { $0.manifest.id == pluginID })
        || bundled.issues.contains(where: { $0.pluginID == pluginID })
    else { throw GatewayToolError.invalidArguments("Unknown plugin '\(pluginID)'.") }
    let checkedAt = Date()
    let settings = state.settings[pluginID] ?? PluginSettings()
    var source = state.installations.first { $0.id == state.selectedInstallations[pluginID] }?
      .source
    var version: PluginVersion?
    var checks: [PluginDoctorCheck] = []
    var dependencies: [PluginDoctorDependency] = []
    func report() -> Self {
      Self(
        pluginID: pluginID, revision: state.revision, checkedAt: checkedAt,
        enabled: settings.enabled, source: source, version: version,
        checks: checks, dependencies: dependencies,
        status: checks.contains(where: { $0.status == .failed })
          ? .failed
          : (checks.contains(where: { $0.status == .unverified }) ? .unverified : .passed),
        scope: "configuration_and_files",
        notChecked: ["runtime_version", "binary_compatibility", "connection", "system_permissions"])
    }
    let plugin: PluginPackage
    do {
      guard
        let selected = try PluginStore.selectedPackage(
          pluginID, in: state, bundled: bundled.packages)
      else {
        let message =
          bundled.issues.first { $0.pluginID == pluginID }?.message
          ?? "No selected or bundled source is available. Select an installed source or register a package."
        checks.append(.init(id: "source", kind: .source, status: .failed, message: message))
        return report()
      }
      plugin = selected.0
      source = selected.1
      version = plugin.manifest.version
      checks.append(
        .init(
          id: "source", kind: .source, status: .passed,
          message: "Selected package and declaration identity were validated."))
    } catch {
      checks.append(
        .init(id: "source", kind: .source, status: .failed, message: error.localizedDescription))
      return report()
    }
    let compatible =
      plugin.manifest.compatibility?.permits(host: hostVersion, architecture: architecture) ?? true
    checks.append(
      .init(
        id: "compatibility", kind: .compatibility, status: compatible ? .passed : .failed,
        message: compatible
          ? "The declaration permits this host version and architecture."
          : "The declaration excludes this host version or architecture. Select a compatible package."
      ))
    let resolvedDependencies = PluginDependencyResolver.resolve(
      for: plugin, settings: settings,
      searchDirectories: PluginHost.searchDirectories(environment: environment),
      applicationURL: applicationURL)
    let bindings = resolvedDependencies.mapValues(\.executable)
    dependencies = plugin.manifest.dependencies.map {
      PluginDoctorDependency(
        declaration: $0, executable: bindings[$0.id]?.path,
        resolutionSource: resolvedDependencies[$0.id]?.source ?? "unresolved")
    }

    var referencedDependencies = Set<String>()
    func inspectExecutable(
      _ reference: PluginExecutable, checkID: String, componentID: String?, enabled: Bool?,
      cwd: String?
    ) throws {
      try Task.checkCancellation()
      if let dependency = reference.dependency { referencedDependencies.insert(dependency) }
      do {
        let directory =
          try cwd.map { try WorkspacePathResolver.resolve($0, relativeTo: plugin.root) }
          ?? workingDirectory
        let inspection = try PluginResolver.inspectExecutable(
          reference, package: plugin, dependencyExecutables: bindings,
          workingDirectory: directory, environment: environment)
        let status: PluginCheckStatus =
          inspection?.status == .passed
          ? .passed
          : (inspection?.hasKnownFailure ?? true ? .failed : .unverified)
        checks.append(
          .init(
            id: checkID, kind: .executable, status: status,
            message: inspection?.message
              ?? "No executable was resolved for this dependency. Follow its setup instructions or set a host binding.",
            componentID: componentID, dependencyID: reference.dependency, enabled: enabled,
            workingDirectory: directory.path, inspection: inspection))
      } catch {
        checks.append(
          .init(
            id: checkID, kind: .executable, status: .failed, message: error.localizedDescription,
            componentID: componentID, dependencyID: reference.dependency, enabled: enabled))
      }
    }
    for contribution in plugin.manifest.mcp {
      if let executable = contribution.executable {
        try inspectExecutable(
          executable, checkID: "mcp:\(contribution.id):executable", componentID: contribution.id,
          enabled: settings.enabled && (settings.mcp[contribution.id]?.enabled ?? true),
          cwd: contribution.cwd)
      }
    }
    for contribution in plugin.manifest.cli {
      let enabled = settings.enabled && (settings.cli[contribution.id]?.enabled ?? true)
      try inspectExecutable(
        contribution.executable, checkID: "cli:\(contribution.id):executable",
        componentID: contribution.id,
        enabled: enabled, cwd: contribution.cwd)
      if let helper = contribution.tree?.helper {
        try inspectExecutable(
          helper, checkID: "cli:\(contribution.id):helper", componentID: contribution.id,
          enabled: enabled, cwd: contribution.cwd)
      }
    }
    for dependency in plugin.manifest.dependencies
    where !referencedDependencies.contains(dependency.id) {
      let reference = try PluginExecutable(dependency: dependency.id)
      try inspectExecutable(
        reference, checkID: "dependency:\(dependency.id)", componentID: nil, enabled: nil, cwd: nil)
    }
    for contribution in plugin.manifest.skills {
      try Task.checkCancellation()
      checks.append(
        .init(
          id: "skills:\(contribution.id)", kind: .resources, status: .passed,
          message:
            "The declared Skills directory passed package path validation. Skill contents and scripts were not executed.",
          componentID: contribution.id,
          enabled: settings.enabled && (settings.skills[contribution.id]?.enabled ?? true)))
    }
    return report()
  }
}
