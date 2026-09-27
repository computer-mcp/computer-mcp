import Foundation

/// Configuration writes discovered by runtime preparation, applied only at publication.
struct GatewayConfigurationResolution: Equatable, Sendable {
  struct Workspace: Equatable, Sendable {
    let original: RegisteredWorkspace
    let resolved: RegisteredWorkspace
  }

  var workspaces: [Workspace] = []
  var profiles: [ProfileGrant] = []

  mutating func merge(_ other: Self) throws {
    for workspace in other.workspaces {
      if let existing = workspaces.first(where: { $0.original.id == workspace.original.id }) {
        var comparable = workspace.resolved
        comparable.bookmarkData = existing.resolved.bookmarkData
        comparable.updatedAt = existing.resolved.updatedAt
        guard existing.original == workspace.original, existing.resolved == comparable else {
          throw GatewayDatabaseError.configurationChanged
        }
      } else {
        workspaces.append(workspace)
      }
    }
    for profile in other.profiles {
      if let existing = profiles.first(where: { $0.id == profile.id }) {
        guard existing == profile else { throw GatewayDatabaseError.configurationChanged }
      } else {
        profiles.append(profile)
      }
    }
  }
}

struct GatewayRuntimePreparation: Sendable {
  let runtime: GatewayRuntime
  let resolution: GatewayConfigurationResolution
}

/// Discovery is allowed before publication; tool execution and child sessions are not.
final class GatewayRuntimePublication: @unchecked Sendable {
  private let lock = NSLock()
  private var published = false

  func publish() { lock.withLock { published = true } }

  func requirePublished() throws {
    guard lock.withLock({ published }) else {
      throw GatewayToolError.disabled("The runtime configuration has not been published.")
    }
  }
}
