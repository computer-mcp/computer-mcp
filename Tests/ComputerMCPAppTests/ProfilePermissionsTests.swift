import AppKit
import ComputerMCPPermissions
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCPApp
@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProfilePermissionsTests {
  @Test
  func draftPreservesWildcardDenialsNetworksAndFullAccess() throws {
    var grant = ProfileGrant.operate
    try grant.permissions.set(.granted(.write), for: .project("*"))
    try grant.permissions.set(.denied, for: .project("private"))
    grant.projectNetworks["*"] = .custom(hosts: ["example.com"], includesTrusted: true)
    grant.fullAccess = true
    try grant.permissions.set(.granted(.use), for: .plugin("saved-plugin"))
    try grant.permissions.set(.granted(.all), for: .mcpServer("saved-server"))
    grant.automation["com.example.AutomationTarget"] = .allow
    grant.projectNetworks["network-only"] = .full
    let draft = ProfilePermissionsDraft(options: permissionOptions(grant: grant))
    #expect(draft.grant == grant)
    #expect(draft.projectIDs == ["network-only", "private", "project"])
    #expect(draft.pluginIDs.contains("saved-plugin"))
    #expect(draft.serverIDs.contains("saved-server"))
    #expect(draft.automationTargets == ["com.example.AutomationTarget"])
    #expect(draft.options.permissionRevision == 17)
    #expect(draft.options.grant.authorizationRevision == grant.authorizationRevision)
    #expect(draft.grant.permissions.state(for: .project("private")) == .denied)
    #expect(
      draft.grant.projectNetworks["*"]?.configuration == grant.projectNetworks["*"]?.configuration)
  }

  @Test
  func authorityReviewIncludesEverySavedRuleAndActualNetworkHosts() throws {
    var grant = ProfileGrant.operate
    try grant.permissions.set(.granted(.write), for: .project("*"))
    try grant.permissions.set(.denied, for: .plugin("unavailable-plugin"))
    try grant.permissions.set(.notGranted, for: .mcpServer("unavailable-server"))
    grant.projectNetworks["saved-project"] = .custom(
      hosts: ["api.example.com", "*.example.org"], includesTrusted: true)
    grant.automation["com.example.target"] = .allow
    let rows = ProfileAuthorityReviewRow.rows(for: grant)
    #expect(
      rows.count == grant.permissions.entries.count + grant.projectNetworks.count
        + grant.automation.count)
    #expect(rows.contains { $0.title.contains("unavailable-plugin") })
    #expect(rows.contains { $0.title.contains("unavailable-server") })
    #expect(
      rows.contains { $0.value.contains("api.example.com") && $0.value.contains("*.example.org") })
    #expect(rows.contains { $0.title.contains("com.example.target") })
  }

  @Test
  func authorityRowsShowKnownNamesAndStableIDsWithLocalizedPermissionLabels() throws {
    let names = PermissionObjectNames(
      projects: ["project-id": "My Project"], plugins: ["plugin-id": "My Plugin"],
      mcpServers: ["server-id": "My Server"])
    var profile = ProfileGrant.operate
    try profile.permissions.set(.granted(.read), for: .project("project-id"))
    try profile.permissions.set(.granted(.use), for: .plugin("plugin-id"))
    try profile.permissions.set(.granted(.read), for: .mcpServer("server-id"))
    let rows = ProfileAuthorityReviewRow.rows(for: profile, names: names)
    for (id, name) in [
      ("project-id", "My Project"), ("plugin-id", "My Plugin"), ("server-id", "My Server"),
    ] {
      #expect(rows.contains { $0.title.contains(id) && $0.title.contains(name) })
    }
    #expect(names.title(for: .screen) == AppLocalization.string("Screen"))
    #expect(names.title(for: .project("unknown-id")).contains("unknown-id"))
    #expect(PermissionObjectNames.profile(.chatGPTOperate).contains("chatgpt-operate"))
  }

  @Test
  func invalidCustomHostsDoNotPublishAProfile() async throws {
    let service = PermissionOptionsFake()
    let model = ProfilePermissionsModel(profileID: .chatGPTOperate, controlPlane: service)
    await model.load()
    model.draft?.grant.projectNetworks["saved-project"] = .custom(
      hosts: ["https://example.com/path"], includesTrusted: false)
    #expect(!(await model.save()))
    #expect(service.writes.isEmpty)
    #expect(model.errorMessage != nil)
    #expect(model.draft?.projectIDs.contains("saved-project") == true)
  }

  @Test
  func explicitRequestableOverrideSurvivesSaving() throws {
    var grant = ProfileGrant.operate
    try grant.permissions.set(.granted(.all), for: .mcpServer("*"))
    var draft = ProfilePermissionsDraft(options: permissionOptions(grant: grant))
    try draft.grant.permissions.set(.notGranted, for: .mcpServer("notes"))
    #expect(draft.grant.permissions.state(for: .mcpServer("notes")) == .notGranted)
    #expect(draft.grant.permissions.state(for: .mcpServer("other")) == .granted(.all))
  }

  @Test
  func failedSaveKeepsReviewedStateAndDoesNotRetryOrReload() async throws {
    let service = PermissionOptionsFake()
    let model = ProfilePermissionsModel(profileID: .chatGPTOperate, controlPlane: service)
    await model.load()
    let revision = try #require(model.draft?.options.grant.authorizationRevision)
    model.draft?.grant.allowedCallers.insert(.localMCP)
    service.fail = true
    #expect(!(await model.save()))
    await model.load()
    #expect(service.reads == 1 && service.writes.count == 1)
    #expect(model.errorMessage != nil)
    #expect(model.draft?.options.grant.authorizationRevision == revision)
    #expect(model.draft?.grant.allowedCallers.contains(.localMCP) == true)
    #expect(service.writes[0].allowedCallers.contains(.localMCP))
  }

  @Test
  func savingJoinsOnlyOneUserActionAndDoesNotRebaseDuringTheWrite() async throws {
    let service = PermissionOptionsFake()
    let model = ProfilePermissionsModel(profileID: .chatGPTOperate, controlPlane: service)
    await model.load()
    let (events, signal) = AsyncStream<Void>.makeStream()
    var release: CheckedContinuation<Void, Never>?
    service.onSave = {
      await withCheckedContinuation {
        release = $0
        signal.yield(())
      }
    }
    let saving = Task { await model.save() }
    var iterator = events.makeAsyncIterator()
    _ = await iterator.next()
    #expect(model.isSaving)
    #expect(!(await model.save()))
    await model.load()
    release?.resume()
    #expect(await saving.value)
    #expect(service.writes.count == 1 && service.reads == 1)
  }

  @Test
  func permissionSelectionRendersWithoutWrites() async throws {
    let service = PermissionOptionsFake()
    let model = ProfilePermissionsModel(profileID: .chatGPTOperate, controlPlane: service)
    await model.load()
    for dark in [false, true] {
      try render(
        ProfilePermissionsEditor(model: model), size: .init(width: 660, height: 740),
        appearance: try #require(NSAppearance(named: dark ? .darkAqua : .aqua)),
        name: dark ? "profile-permissions-dark" : "profile-permissions-light")
      try render(
        ProfilePermissionsEditor(model: model), size: .init(width: 660, height: 740),
        appearance: try #require(NSAppearance(named: dark ? .darkAqua : .aqua)),
        name: dark ? "profile-projects-dark" : "profile-projects-light", scrollToBottom: true)
    }
    #expect(service.writes.isEmpty)
  }
}

private func permissionOptions(grant: ProfileGrant = .operate) -> ProfilePermissionOptions {
  let project = ComputerMCPCore.RegisteredProject(
    id: "project", displayName: "My Project", rootPath: "/tmp/project")
  return .init(
    grant: grant,
    integrations: [.init(id: "notes", title: "Notes", isEnabled: true)],
    plugins: [.init(id: "tools", title: "Tools", isEnabled: true)],
    projects: [project], permissionRevision: 17,
    inputs: .init(
      configuration: GatewayConfiguration(projectDirectory: URL(fileURLWithPath: "/tmp")),
      persisted: .init(
        projects: [project], projectAliases: [:], profiles: [],
        plugins: .init())))
}

@MainActor
private final class PermissionOptionsFake: ProfilePermissionManaging {
  var reads = 0
  var writes: [ProfileGrant] = []
  var fail = false
  var onSave: (() async -> Void)?
  func fetchProfilePermissionOptions(id: GatewayProfileID) async throws -> ProfilePermissionOptions
  {
    reads += 1
    return permissionOptions()
  }
  func saveProfilePermissions(_ grant: ProfileGrant, reviewed: ProfilePermissionOptions)
    async throws
  {
    writes.append(grant)
    if let onSave { await onSave() }
    if fail { throw AppControlPlaneServiceError.gatewayInputsChanged }
  }
}
