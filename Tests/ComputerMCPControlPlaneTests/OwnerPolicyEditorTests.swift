import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import Foundation
import Testing

@testable import ComputerMCPControlPlane

@Suite struct OwnerPolicyEditorTests {
  private let target = GatewayOwnerPolicyTarget.profile(.chatGPTOperate)

  @Test func draftSurvivesParserAndRevisionFailures() async throws {
    let fixture = try OwnerAuditFixture()
    let service = OwnerPolicyEditorService(control: fixture.control)
    var editor = try await service.load(target)
    #expect(editor.savedText == nil)
    #expect(editor.canEdit)

    editor.draft = "[execution]\ntime_ms = -1"
    await #expect(throws: PermissionModelError.invalidExecutionLimits) {
      try await service.parse(editor.draft)
    }
    await #expect(throws: PermissionModelError.invalidExecutionLimits) {
      try await service.save(editor)
    }
    #expect(editor.draft == "[execution]\ntime_ms = -1")
    #expect(editor.isDirty)
    #expect(try await service.load(target).savedText == nil)

    editor.draft = "# retain formatting\n[execution]\ntime_ms = 3000\n"
    try await service.parse(editor.draft)
    var other = try await service.load(target)
    other.draft = "full_access = false\n"
    _ = try await service.save(other)
    await #expect(throws: GatewayPermissionError.revisionConflict) {
      try await service.save(editor)
    }
    await #expect(throws: GatewayPermissionError.revisionConflict) {
      try await service.clear(editor)
    }
    #expect(editor.isDirty)
    #expect(try await service.load(target).savedText == other.draft)

    editor = try await service.reload(editor, preservingDraft: true)
    #expect(editor.draft == "# retain formatting\n[execution]\ntime_ms = 3000\n")
    #expect(editor.savedText == other.draft)
    editor = try await service.save(editor)
    #expect(editor.savedText == editor.draft)
    #expect(editor.requiresReload)
    #expect(!editor.canEdit)
    #expect(!editor.isDirty)

    editor = try await service.reload(editor, preservingDraft: false)
    #expect(editor.canEdit)
    #expect(editor.draft == "# retain formatting\n[execution]\ntime_ms = 3000\n")
    editor = try await service.clear(editor)
    editor = try await service.reload(editor, preservingDraft: false)
    #expect(editor.savedText == nil)
    #expect(editor.draft.isEmpty)
    #expect(editor.reviewed.ownerSource?.revision == "absent")
  }

  @Test func editorRequiresLiveLocalOwnerProof() async throws {
    enum Failure: Error { case revoked }
    let fixture = try OwnerAuditFixture()
    let authorized = OwnerPolicyEditorService(control: fixture.control)
    var editor = try await authorized.load(target)
    editor.draft = "full_access = false"
    let owner = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "fixture"),
      validate: { throw Failure.revoked })
    let control = PermissionControlService(service: fixture.gateway, owner: { owner })
    let rejected = OwnerPolicyEditorService(control: control)

    await #expect(throws: Failure.revoked) { try await rejected.load(target) }
    await #expect(throws: Failure.revoked) { try await rejected.parse(editor.draft) }
    await #expect(throws: Failure.revoked) { try await rejected.save(editor) }
    await #expect(throws: Failure.revoked) { try await rejected.clear(editor) }
    #expect(try await authorized.load(target).savedText == nil)
  }

  @Test func exposesSavedOwnerLimitsAndReadOnlyManagedSources() async throws {
    let fixture = try OwnerAuditFixture()
    let service = OwnerPolicyEditorService(control: fixture.control)
    fixture.policyReader.set(
      .machineFile,
      .available(Data("[permissions]\nscreen = 'deny'\n[execution]\ntime_ms = 1000".utf8)))
    var editor = try await service.load(target)
    editor.draft = "[permissions]\nscreen = 'allow'\n[execution]\ntime_ms = 5000"
    editor = try await service.save(editor)
    editor = try await service.reload(editor, preservingDraft: false)
    let projection = try #require(editor.reviewed.limits.first)
    guard case .available(let saved) = projection.savedOwner else {
      Issue.record("Saved owner limits are missing")
      return
    }
    #expect(saved.permissionCeilings.state(for: .screen) == .granted(.access))
    let screen = try PermissionRequirement(.screen, .access)
    #expect(saved.executionLimits.timeMilliseconds == 5000)
    #expect(try projection.executionLimits(for: .foreground).timeMilliseconds == 1000)
    #expect(projection.caller == .secureTunnel)
    #expect(projection.effective.restrictingSources(for: screen) == [.machine])
    #expect(editor.reviewed.ownerSource?.source == .owner)
    #expect(Set(editor.reviewed.readOnlySources.map(\.source)) == [.machine, .managedPreferences])
    #expect(
      editor.reviewed.readOnlySources.first { $0.source == .managedPreferences }?.revision
        == "absent")

    fixture.policyReader.set(.machineFile, .unreadable("fixture unreadable"))
    editor = try await service.reload(editor, preservingDraft: false)
    #expect(editor.canEdit)
    let machine = editor.reviewed.readOnlySources.first { $0.source == .machine }
    #expect(machine?.failure == "fixture unreadable")
    #expect(editor.reviewed.limits.first?.effective.sources[.machine] == .unreadable)
    #expect(editor.reviewed.limits.first?.effective.restrictingSources(for: screen) == [.machine])
  }

  @Test func writesRequireCurrentEpochAndRetainSavedSourceDuringRestoreReview() async throws {
    let fixture = try OwnerAuditFixture()
    let service = OwnerPolicyEditorService(control: fixture.control)
    var editor = try await service.load(target)
    editor.draft = "full_access = false"
    let committed = try await service.save(editor)
    editor = try await service.reload(committed, preservingDraft: false)
    let oldEpoch = try #require(editor.reviewed.epoch)

    fixture.counter.forget()
    let restored = try await service.load(target)
    #expect(restored.reviewed.epoch != oldEpoch)
    #expect(!restored.canEdit)
    #expect(restored.savedText == "full_access = false")
    #expect(restored.reviewed.ownerSource?.failure != nil)
    #expect(restored.reviewed.limits.first?.effective.sources[.owner] == .unreadable)
    #expect(throws: GatewayPermissionError.revisionConflict) {
      try fixture.control.writeOwnerPolicy(
        nil, target: target, revision: restored.reviewed.revision, epoch: oldEpoch)
    }
    editor.draft = "full_access = true"
    await #expect(throws: GatewayPermissionError.revisionConflict) {
      try await service.save(editor)
    }
    #expect(editor.isDirty)
    #expect(try await service.load(target).savedText == restored.savedText)
  }

  @Test func providerPolicyUsesItsOwnSourceAndLeavesProfilePolicyIntact() async throws {
    let fixture = try OwnerAuditFixture()
    let service = OwnerPolicyEditorService(control: fixture.control)
    let database = GatewayDatabase(connection: fixture.connection)
    let review = try GatewayProviderReview(
      server: .init(id: "local", transport: .stdio, command: "/bin/false"),
      configuration: database.configurationState())
    let view = try fixture.control.view()
    var permissions = Permissions.newPrincipal
    try permissions.set(.granted(.access), for: .screen)
    _ = try fixture.control.approveProvider(
      review, permissions: permissions, fullAccess: false,
      expectedProviderRevision: nil, expectedRevision: view.revision,
      expectedEpoch: #require(view.epoch))
    let providerTarget = GatewayOwnerPolicyTarget.provider(review.identity)
    var editor = try await service.load(providerTarget)
    #expect(throws: GatewayPermissionError.revisionConflict) {
      try fixture.control.writeOwnerPolicy(
        nil, target: providerTarget, revision: editor.reviewed.revision, epoch: UUID())
    }
    editor.draft = "[permissions]\nscreen = 'deny'"
    let committed = try await service.save(editor)
    editor = try await service.reload(committed, preservingDraft: false)
    #expect(editor.reviewed.ownerSource?.provider == .localServer("local"))
    #expect(editor.reviewed.ownerSource?.profileID == nil)
    let limit = try #require(editor.reviewed.limits.first)
    #expect(limit.caller == nil)
    #expect(limit.effective.restrictingSources(for: try .init(.screen, .access)) == [.owner])
    #expect(
      try fixture.control.view().providers.first?.permissions.state(for: .screen)
        == .granted(.access))
    #expect(try await service.load(target).savedText == nil)
    _ = try await service.clear(editor)
    #expect(try await service.load(providerTarget).savedText == nil)
  }
}
