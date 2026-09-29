import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ComputerMCP
@testable import ComputerMCPApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ProfilePermissionsTests {
  @Test
  func broadDefaultsBecomeExplicitCurrentSelectionsWithoutFullAccess() {
    var grant = ProfileGrant.localAdmin
    grant.id = .chatGPTOperate
    grant.allowedCallers = [.secureTunnel]
    let options = permissionOptions(grant: grant)
    let draft = ProfilePermissionsDraft(options: options)
    let saved = draft.savedGrant
    #expect(draft.replacesBroadGrants)
    #expect(saved.mode == .workspaceOperations && !saved.fullShellEnabled)
    #expect(saved.workspaceIDs == ["project"])
    #expect(saved.mcpServerIDs == ["notes"])
    #expect(
      saved.capabilityIDs
        == Set(["system.time", "file.write"]).union(ProfilePermissionSelection.supportCapabilities))
    #expect(saved.allowedCallers == [.secureTunnel])
    #expect(saved.authorizationRevision == grant.authorizationRevision)
  }

  @Test
  func deselectingIntegrationAlsoRevokesItsIndividualVisibleTools() {
    let grant = ProfileGrant(
      id: .chatGPTOperate, capabilityIDs: ["notes.search", "custom.unavailable"],
      allowedCallers: [.secureTunnel], mcpServerIDs: ["notes"], mode: .workspaceOperations)
    var draft = ProfilePermissionsDraft(options: permissionOptions(grant: grant))
    draft.selectIntegration("notes", selected: false)
    #expect(draft.savedGrant.mcpServerIDs.isEmpty)
    #expect(!draft.savedGrant.capabilityIDs.contains("notes.search"))
    #expect(draft.savedGrant.capabilityIDs.contains("custom.unavailable"))
    #expect(!draft.savedGrant.allowedCallers.contains(.localMCP))
  }

  @Test
  func observeCanNeverSaveAnArbitraryExecutionGrant() {
    var draft = ProfilePermissionsDraft(options: permissionOptions())
    draft.grant.mode = .readOnly
    draft.grant.fullShellEnabled = true
    draft.grant.capabilityIDs.formUnion(["*", "shell.run", "mcp.tools.call"])
    let saved = draft.savedGrant
    #expect(saved.mode == .readOnly && !saved.fullShellEnabled)
    #expect(saved.capabilityIDs.isDisjoint(with: ["*", "shell.run", "mcp.tools.call"]))
    #expect(!saved.permitsRisk(.workspaceWrite) && !saved.permitsRisk(.fullShell))
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
        name: dark ? "restricted-permissions-dark" : "restricted-permissions-light")
      try render(
        ProfilePermissionsEditor(model: model), size: .init(width: 660, height: 740),
        appearance: try #require(NSAppearance(named: dark ? .darkAqua : .aqua)),
        name: dark ? "restricted-projects-dark" : "restricted-projects-light", scrollToBottom: true)
    }
    #expect(service.writes.isEmpty)
  }
}

private func permissionOptions(grant: ProfileGrant = .operate) -> ProfilePermissionOptions {
  let workspace = RegisteredWorkspace(
    id: "project", displayName: "My Project", rootPath: "/tmp/project")
  return .init(
    grant: grant,
    capabilities: [
      .init(
        id: "system.time", title: "Current Time", summary: "Read the system clock.",
        descriptor: .init(id: "system.time", risk: .readOnly)),
      .init(
        id: "file.write", title: "Write File", summary: "Write a file in a selected project.",
        descriptor: .init(id: "file.write", risk: .workspaceWrite)),
      .init(
        id: "notes.search", title: "Search Notes", summary: "Find notes in the connected account.",
        descriptor: .init(
          id: "notes.search", risk: .readOnly,
          mcpReference: .init(serverID: "notes", toolName: "search"))),
    ],
    integrations: [.init(id: "notes", title: "Notes", isEnabled: true)],
    workspaces: [workspace],
    inputs: .init(
      configuration: GatewayConfiguration(workspaceDirectory: URL(fileURLWithPath: "/tmp")),
      persisted: .init(
        workspaces: [workspace], workspaceAliases: [:], profiles: [], plugins: .init())))
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
