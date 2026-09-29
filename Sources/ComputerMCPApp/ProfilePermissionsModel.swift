import Combine
import ComputerMCP
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
  let replacesBroadGrants: Bool

  init(options: ProfilePermissionOptions) {
    self.options = options
    var grant = options.grant
    let wildcard = grant.capabilityIDs.contains("*")
    let allIntegrations = wildcard || grant.capabilityIDs.contains("mcp.tools.call")
    replacesBroadGrants = wildcard || allIntegrations || grant.workspaceIDs.contains("*")
    grant.mode = grant.mode == .readOnly ? .readOnly : .workspaceOperations
    grant.fullShellEnabled = false
    if wildcard {
      grant.capabilityIDs = Set(
        options.capabilities.filter {
          $0.descriptor.mcpReference == nil && grant.permitsRisk($0.descriptor.risk)
        }.map(\.id))
    }
    grant.capabilityIDs.subtract(ProfileGrant.fullShellCapabilities)
    grant.capabilityIDs.subtract(ProfileGrant.mcpSurfaceCapabilities)
    grant.capabilityIDs.subtract(ProfilePermissionSelection.supportCapabilities)
    if allIntegrations { grant.mcpServerIDs.formUnion(options.integrations.map(\.id)) }
    if grant.workspaceIDs.remove("*") != nil {
      grant.workspaceIDs.formUnion(options.workspaces.map(\.id))
    }
    self.grant = grant
  }

  var savedGrant: ProfileGrant {
    var result = grant
    result.fullShellEnabled = false
    result.mode = grant.mode == .readOnly ? .readOnly : .workspaceOperations
    result.capabilityIDs.remove("*")
    result.capabilityIDs.subtract(ProfileGrant.fullShellCapabilities)
    result.capabilityIDs.subtract(ProfileGrant.mcpSurfaceCapabilities)
    result.capabilityIDs.formUnion(ProfilePermissionSelection.supportCapabilities)
    return result
  }

  mutating func selectIntegration(_ id: String, selected: Bool) {
    if selected {
      grant.mcpServerIDs.insert(id)
    } else {
      grant.mcpServerIDs.remove(id)
      grant.capabilityIDs.subtract(
        options.capabilities.filter {
          $0.descriptor.mcpReference?.serverID == id
        }.map(\.id))
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
      try await controlPlane.saveProfilePermissions(draft.savedGrant, reviewed: draft.options)
      return true
    } catch {
      // A failed write leaves the exact reviewed draft intact; reopening obtains new choices.
      errorMessage = AppLocalization.errorDescription(error)
      return false
    }
  }
}
