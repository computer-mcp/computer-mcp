import Combine
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPPermissions
import Foundation

@MainActor
protocol ProfilePermissionManaging {
  func fetchProfilePermissionOptions(id: GatewayProfileID) async throws -> ProfilePermissionOptions
  func saveProfilePermissions(_ grant: ProfileGrant, reviewed: ProfilePermissionOptions)
    async throws
}

extension ProfilePermissionManaging {
  func fetchProfilePermissionOptions(id: GatewayProfileID) async throws -> ProfilePermissionOptions
  {
    throw AppControlPlaneError.unavailable(
      "Permission choices are unavailable. Close and try again.")
  }
  func saveProfilePermissions(_ grant: ProfileGrant, reviewed: ProfilePermissionOptions)
    async throws
  {
    throw AppControlPlaneError.unavailable(
      "Permission choices are unavailable. Close and try again.")
  }
}

struct ProfilePermissionsDraft {
  let options: ProfilePermissionOptions
  var grant: ProfileGrant
  var customHostText: [String: String] = [:]

  init(options: ProfilePermissionOptions) {
    self.options = options
    self.grant = options.grant
  }

  var projectIDs: [String] {
    objectIDs { if case .project(let id) = $0 { id } else { nil } }
      .union(options.projects.map(\.id)).union(options.grant.projectNetworks.keys)
      .union(grant.projectNetworks.keys).subtracting(["*"]).sorted()
  }

  var pluginIDs: [String] {
    objectIDs { if case .plugin(let id) = $0 { id } else { nil } }
      .union(options.plugins.map(\.id)).subtracting(["*"]).sorted()
  }

  var serverIDs: [String] {
    objectIDs { if case .mcpServer(let id) = $0 { id } else { nil } }
      .union(options.integrations.map(\.id)).subtracting(["*"]).sorted()
  }

  var automationTargets: [String] {
    Set(options.grant.automation.keys).union(grant.automation.keys).sorted()
  }

  private func objectIDs(_ select: (Permission) -> String?) -> Set<String> {
    Set(options.grant.permissions.entries.keys.compactMap(select))
      .union(grant.permissions.entries.keys.compactMap(select))
  }

  func validateNetworks() throws {
    for network in grant.projectNetworks.values {
      guard case .custom(let hosts, _) = network.configuration else { continue }
      for host in hosts {
        do {
          _ = try NetworkHost.normalize(host.hasPrefix("*.") ? String(host.dropFirst(2)) : host)
        } catch {
          throw AppControlPlaneError.unavailable(
            "Enter valid host names or IP addresses for custom network access.")
        }
      }
    }
  }

}

@MainActor
final class ProfilePermissionsModel: ObservableObject {
  @Published var draft: ProfilePermissionsDraft?
  @Published private(set) var isLoading = false
  @Published private(set) var isSaving = false
  @Published private(set) var errorMessage: String?
  private let profileID: GatewayProfileID
  private let controlPlane: any ProfilePermissionManaging

  init(profileID: GatewayProfileID, controlPlane: any ProfilePermissionManaging) {
    self.profileID = profileID
    self.controlPlane = controlPlane
  }

  func load() async {
    guard draft == nil, !isLoading, !isSaving else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let options = try await controlPlane.fetchProfilePermissionOptions(id: profileID)
      try Task.checkCancellation()
      draft = .init(options: options)
      errorMessage = nil
    } catch { errorMessage = AppLocalization.errorDescription(error) }
  }

  func save() async -> Bool {
    guard let draft, !isLoading, !isSaving else { return false }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      try Task.checkCancellation()
      try draft.validateNetworks()
      try await controlPlane.saveProfilePermissions(draft.grant, reviewed: draft.options)
      return true
    } catch {
      // A failed write leaves the exact reviewed draft intact; reopening obtains new choices.
      errorMessage = AppLocalization.errorDescription(error)
      return false
    }
  }
}
