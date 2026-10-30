import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import Foundation

/// Configuration writes discovered by runtime preparation, applied only at publication.
package struct GatewayConfigurationResolution: Equatable, Sendable {
  package struct Project: Equatable, Sendable {
    let original: ComputerMCPCore.RegisteredProject
    let resolved: ComputerMCPCore.RegisteredProject
  }

  var projects: [Project] = []
  /// The complete explicit manifest source. An empty array removes its declarations.
  var profileDeclarations: [ProfileGrant]?
  var configurationPaths: Set<PathRule>?
  var localProviders: [MCPServerConfig]?

  package init(
    projects: [Project] = [], profileDeclarations: [ProfileGrant]? = nil,
    configurationPaths: Set<PathRule>? = nil, localProviders: [MCPServerConfig]? = nil
  ) {
    self.projects = projects
    self.profileDeclarations = profileDeclarations
    self.configurationPaths = configurationPaths
    self.localProviders = localProviders
  }

  package mutating func merge(_ other: Self) throws {
    if let incoming = other.localProviders {
      guard localProviders == nil || localProviders == incoming else {
        throw GatewayDatabaseError.configurationChanged
      }
      localProviders = incoming
    }
    if let incoming = other.configurationPaths {
      guard configurationPaths == nil || configurationPaths == incoming else {
        throw GatewayDatabaseError.configurationChanged
      }
      configurationPaths = incoming
    }
    for project in other.projects {
      if let existing = projects.first(where: { $0.original.id == project.original.id }) {
        var comparable = project.resolved
        comparable.bookmarkData = existing.resolved.bookmarkData
        comparable.updatedAt = existing.resolved.updatedAt
        guard existing.original == project.original, existing.resolved == comparable else {
          throw GatewayDatabaseError.configurationChanged
        }
      } else {
        projects.append(project)
      }
    }
    if let incoming = other.profileDeclarations {
      if let existing = profileDeclarations {
        guard
          try PermissionProfileManifest.encode(existing)
            == PermissionProfileManifest.encode(incoming)
        else {
          throw GatewayDatabaseError.configurationChanged
        }
      } else {
        profileDeclarations = incoming
      }
    }
  }
}

package struct GatewayRuntimePreparation: Sendable {
  package let runtime: GatewayRuntime
  package let resolution: GatewayConfigurationResolution
}

/// Discovery is allowed before publication; tool execution and child sessions are not.
final class GatewayRuntimePublication: @unchecked Sendable {
  private let lock = NSLock()
  private var published = false
  private var revisionID: String?

  func publish(revisionID: String? = nil) {
    lock.withLock {
      self.revisionID = revisionID
      published = true
    }
  }

  var configurationRevisionID: String? { lock.withLock { revisionID } }

  func requirePublished() throws {
    guard lock.withLock({ published }) else {
      throw GatewayToolError.disabled("The runtime configuration has not been published.")
    }
  }
}
