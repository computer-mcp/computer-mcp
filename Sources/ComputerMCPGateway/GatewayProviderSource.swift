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
  let resources: [VerifiedFileIdentity]
  let validate: @Sendable () throws -> Void

  static func resolve(
    registration: IntegrationRegistration, configuration: GatewayConfiguration,
    origins: [IntegrationRegistration: PluginContributionOrigin], database: GatewayDatabase
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
        resources = [root]
        let digest = review.sourceDigest
        validate = {
          try root.verify(origin.source.root)
          let current = try PluginPackage.load(at: origin.source.root)
          guard try PluginStore.manifestDigest(current.manifest) == digest else {
            throw GatewayPermissionError.invalidBinding
          }
          let selection = try database.configurationState().plugins
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
        let inspection = ExecutableInspection.inspect(
          server.command ?? "",
          workingDirectory: server.resolvedWorkingDirectory(base: configuration.projectDirectory),
          environment: ["PATH": "/usr/bin:/bin"].merging(server.env) { _, value in value })
        func identities(_ executable: ExecutableInspection) throws -> [VerifiedFileIdentity] {
          guard !executable.hasKnownFailure, let path = executable.path else {
            throw GatewayToolError.executionFailed(
              "Provider executable is unavailable: \(executable.message)")
          }
          return try [VerifiedFileIdentity.capture(URL(fileURLWithPath: path))]
            + executable.interpreters.flatMap { try identities($0) }
        }
        let executables = try identities(inspection)
        resources = executables
        validate = {
          for executable in executables {
            try executable.verify(URL(fileURLWithPath: executable.path))
          }
        }
      }
      try validate()
      return Self(
        review: review, registrationID: registration.id,
        workingDirectory: directory == "project" ? nil : directory, resources: resources,
        validate: validate)
    #endif
  }
}
