import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway

@Suite struct GatewayPermissionServiceTests {
  @Test func admissionsAndRepeatedViewsDoNotInvalidateOwnerAnswers() throws {
    let f = try PermissionServiceFixture()
    let request = try f.request()
    let revision = try f.view().revision
    _ = try f.admit(subject: f.subject("other"), requirements: f.requirements(.unifiedLogs))
    _ = try f.view()
    _ = try f.service.reconcilePolicy(now: f.now)
    #expect(try f.view().revision == revision)
    _ = try f.service.answerRequest(
      request.id, answer: .always, owner: f.owner,
      expectedRevision: revision, now: f.now)
    #expect(isAllowed(try f.admit()))
  }

  @Test(arguments: [false, true])
  func removedCallerRetiresOneTimeAndPendingAuthority(started: Bool) throws {
    let f = try PermissionServiceFixture()
    let request = try f.request()
    try f.answer(request.id, .onlyThisTime)
    guard case .allowed(let authorization) = try f.admit(retryIDs: [request.id]) else {
      throw PermissionServiceTestError.unexpected
    }
    let pending = try f.request(requirements: f.requirements(.unifiedLogs))
    let execution =
      try started
      ? f.store.transactionWithDatabase { _, ledger in
        try ledger.startExecution(
          owner: f.client.principal, authorizationIDs: [authorization.id], now: f.now)
      } : nil
    var profile = try #require(f.view().profiles.first)
    profile.allowedCallers = []
    try f.update(profile)
    #expect(try f.view().requests.first { $0.request.id == pending.id }?.request.status == .revoked)
    #expect(throws: GatewayPermissionError.invalidBinding) { try f.answer(pending.id, .always) }
    if let execution {
      let revoked = try f.service.reconcilePolicy(now: f.now)
      #expect(revoked.executionsToTerminate.contains(execution.id))
      let access = try f.store.transactionWithDatabase { _, ledger in
        ledger.executionAccess(
          execution.id, principal: f.client.principal, operation: .readResult, now: f.now)
      }
      #expect(access == .denied(.authorizationRevoked))
    } else {
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try f.store.transactionWithDatabase { _, ledger in
          try ledger.startExecution(
            owner: f.client.principal, authorizationIDs: [authorization.id], now: f.now)
        }
      }
    }
  }

  @Test(arguments: [
    "concrete", "fallback-removal", "full-access", "network", "trusted", "network-removal",
  ])
  func ownerEditsCannotExceedFreshManagedLimits(change: String) throws {
    let f = try PermissionServiceFixture()
    var profile = try #require(f.view().profiles.first)
    if change == "fallback-removal" {
      try profile.permissions.set(.granted(.write), for: .project("*"))
      try profile.permissions.set(.denied, for: .project("secret"))
      try f.update(profile)
    }
    if change == "network-removal" {
      profile.projectNetworks["*"] = .full
      profile.projectNetworks["secret"] = NetworkAccess.none
      try f.update(profile)
    }
    f.reader.set(
      .machineFile,
      .available(
        Data("remote_full_access = false\nnetwork = 'none'\n[projects]\nsecret = 'deny'".utf8)))
    profile = try #require(f.view().profiles.first)
    switch change {
    case "concrete": try profile.permissions.set(.granted(.read), for: .project("secret"))
    case "fallback-removal": profile.permissions.removeEntry(for: .project("secret"))
    case "full-access": profile.fullAccess = true
    case "network": profile.projectNetworks["secret"] = .full
    case "trusted": profile.projectNetworks["secret"] = .trusted
    default: profile.projectNetworks["secret"] = nil
    }
    #expect(throws: GatewayPermissionError.managedLimit) { try f.update(profile) }
  }

  @Test func resourceCeilingEditsPreserveAuthorityAndRetainedOutput() throws {
    let f = try PermissionServiceFixture()
    f.reader.set(.machineFile, .available(Data("[execution]\ntime_ms = 3000".utf8)))
    guard case .allowed(let authorization) = try f.admit(requirements: .init()) else {
      throw PermissionServiceTestError.unexpected
    }
    let execution = try f.store.transactionWithDatabase { _, ledger in
      try ledger.startExecution(
        owner: f.client.principal, authorizationIDs: [authorization.id], now: f.now)
    }
    f.reader.set(
      .machineFile, .available(Data("[execution]\ntime_ms = 1500\noutput_bytes = 4096".utf8)))
    #expect(try f.service.reconcilePolicy(now: f.now).executionsToTerminate.isEmpty)
    try f.store.transactionWithDatabase { _, ledger in
      #expect(ledger.executions[execution.id]?.limits.timeMilliseconds == 1500)
      #expect(ledger.executions[execution.id]?.limits.outputBytes == 4096)
      #expect(
        ledger.executionAccess(
          execution.id, principal: f.client.principal, operation: .readResult, now: f.now)
          == .allowed)
    }
    #expect(
      try f.service.reconcilePolicy(now: f.now.addingTimeInterval(2)).executionsToTerminate
        .contains(execution.id))
    try f.store.transactionWithDatabase { _, ledger in
      #expect(
        ledger.executionAccess(
          execution.id, principal: f.client.principal, operation: .readResult,
          now: f.now.addingTimeInterval(2)) == .allowed)
    }
  }

  @Test func ownerPolicyTighteningRevokesRunningExecution() throws {
    let f = try PermissionServiceFixture()
    try f.answer(f.request().id, .always)
    guard case .allowed(let authorization) = try f.admit() else {
      throw PermissionServiceTestError.unexpected
    }
    let execution = try f.store.transactionWithDatabase { _, ledger in
      try ledger.startExecution(
        owner: f.client.principal, authorizationIDs: [authorization.id], now: f.now)
    }
    let result = try f.service.setOwnerPolicy(
      Data("[permissions]\nscreen = 'deny'".utf8),
      profileID: .chatGPTOperate, owner: f.owner, expectedRevision: f.view().revision, now: f.now)
    #expect(result.executionsToTerminate.contains(execution.id))
  }

  @Test func unadoptedProfilesAreVisibleAndCanBeNarrowedDuringConfirmation() throws {
    let f = try PermissionServiceFixture()
    try f.answer(f.request().id, .always)
    try f.connection.writer.write {
      try $0.execute(sql: "UPDATE permissionProfiles SET authorityEpoch = NULL")
    }
    #expect(try f.admit() == .denied(.authoritySuspended))
    let view = try f.view()
    #expect(view.unconfirmedProfileIDs == [.chatGPTOperate])
    var edited = try #require(view.profiles.first)
    try edited.permissions.set(.denied, for: .screen)
    try f.service.confirmAuthority(
      owner: f.owner, epoch: #require(view.epoch),
      expectedRevision: view.revision, profileEdits: [edited], now: f.now)
    #expect(try f.admit() == .denied(.permissionDenied(.screen)))
    #expect(try f.view().unconfirmedProfileIDs.isEmpty)
  }

  @Test func sourceReadsDoNotHoldTheDatabaseWriter() throws {
    let f = try PermissionServiceFixture()
    let reader = ReentrantPermissionPolicyReader(connection: f.connection)
    let service = GatewayPermissionService(store: f.store, policyReader: reader)
    _ = try service.view(owner: f.owner, now: f.now)
  }

  @Test func deniedPolicyPathsResolveAliasesBeforeCommit() throws {
    let f = try PermissionServiceFixture()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let alias = root.appendingPathComponent("alias")
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    f.reader.set(.machineFile, .available(Data("denied_read_locations = ['\(alias.path)']".utf8)))
    _ = try f.admit()
    let limits = try #require(f.view().subjects.first?.limits)
    #expect(limits.denying(try CanonicalPath(target.resolvingSymlinksInPath().path)) == [.machine])
  }

  @Test func missingDeduplicatesAndDenyDoesNotRequest() throws {
    let f = try PermissionServiceFixture()
    let first = try f.request()
    #expect(try f.request().id == first.id)
    _ = try f.service.revokePermission(
      .screen, profileID: .chatGPTOperate, owner: f.owner, expectedRevision: f.view().revision,
      now: f.now)
    #expect(try f.admit() == .denied(.permissionDenied(.screen)))
    #expect(try f.view().requests.first { $0.request.id == first.id }?.request.status == .revoked)
  }

  @Test func requestsExpireAfterOneDay() throws {
    let f = try PermissionServiceFixture()
    let request = try f.request()
    #expect(request.expiresAt == f.now.addingTimeInterval(86_400))
    #expect(throws: PermissionModelError.expiredRequest) {
      try f.service.answerRequest(
        request.id, answer: .onlyThisTime, owner: f.owner, expectedRevision: f.view().revision,
        now: request.expiresAt)
    }
    #expect(throws: PermissionModelError.expiredRequest) {
      try f.admit(retryIDs: [request.id], now: request.expiresAt)
    }
  }

  @Test func oneTimeRequiresExactPrincipalDigestAndDependencyGroup() throws {
    let f = try PermissionServiceFixture()
    let requirements = try InvocationRequirements(actions: [
      PermissionAction(requirement: .init(.screen, .access)),
      PermissionAction(requirement: .init(.unifiedLogs, .access)),
    ])
    guard case .requests(let requests) = try f.admit(requirements: requirements) else {
      throw PermissionServiceTestError.unexpected
    }
    #expect(requests.count == 2)
    for request in requests { try f.answer(request.id, .onlyThisTime) }
    let ids = Set(requests.map(\.id))
    let other = try f.subject("other")
    #expect(throws: PermissionModelError.retryMismatch) {
      try f.admit(subject: other, requirements: requirements, retryIDs: ids)
    }
    #expect(throws: PermissionModelError.retryMismatch) {
      try f.admit(arguments: "different", requirements: requirements, retryIDs: ids)
    }
    #expect(isAllowed(try f.admit(requirements: requirements, retryIDs: ids)))
    #expect(throws: (any Error).self) { try f.admit(requirements: requirements, retryIDs: ids) }
    #expect(try f.view().profiles[0].permissions.state(for: .screen) == .notGranted)
  }

  @Test func alwaysUpdatesSharedProfileAndFutureBindings() throws {
    let f = try PermissionServiceFixture()
    let second = try f.subject("second")
    _ = try f.admit(subject: second)
    let request = try f.request()
    let view = try f.view()
    #expect(view.requests.first { $0.request.id == request.id }?.alwaysIsShared == true)
    try f.answer(request.id, .always)
    #expect(isAllowed(try f.admit()))
    #expect(isAllowed(try f.admit(subject: second)))
    #expect(isAllowed(try f.admit(subject: f.subject("future"))))
    #expect(try f.view().profiles[0].authorizationRevision == 2)
  }

  @Test func readToWriteRequestsAndAlwaysPreservesStrongerGrant() throws {
    let f = try PermissionServiceFixture()
    var profile = try #require(f.view().profiles.first)
    try profile.permissions.set(.granted(.read), for: .project("project"))
    try f.update(profile)
    let requirement = try InvocationRequirements(actions: [
      .init(requirement: .init(.project("project"), .write))
    ])
    let request = try f.request(requirements: requirement)
    try f.answer(request.id, .always)
    #expect(isAllowed(try f.admit(requirements: requirement)))
    #expect(
      try f.view().profiles[0].permissions.state(for: .project("project")) == .granted(.write))
  }

  @Test func freshPolicyBlocksOpenDialogAndPreservesLocalDiagnostics() throws {
    let f = try PermissionServiceFixture()
    let request = try f.request()
    let revision = try f.view().revision
    f.reader.set(.machineFile, .available(Data("[permissions]\nscreen = 'deny'".utf8)))
    #expect(throws: GatewayPermissionError.managedLimit) {
      try f.service.answerRequest(
        request.id, answer: .always, owner: f.owner, expectedRevision: revision, now: f.now)
    }
    let view = try f.view()
    #expect(view.profiles[0].permissions.state(for: .screen) == .notGranted)
    #expect(
      view.subjects[0].limits.restrictingSources(for: try .init(.screen, .access)) == [.machine])
    #expect(try f.admit() == .denied(.managedLimit([.machine])))
    f.reader.set(.machineFile, .unreadable("Unavailable fixture"))
    #expect(try f.view().sources.first { $0.source == .machine }?.failure != nil)
    _ = try f.service.revokePermission(
      .screen, profileID: .chatGPTOperate, owner: f.owner, expectedRevision: f.view().revision,
      now: f.now)
  }

  @Test(arguments: [0, 1, 2])
  func absentUnreadableAndMalformedSourcesRemainDistinct(kind: Int) throws {
    let f = try PermissionServiceFixture()
    let status: ManagedPolicyReadStatus =
      kind == 0
      ? .absent : kind == 1 ? .unreadable("fixture") : .available(Data("invalid = [".utf8))
    f.reader.set(.managedPreferences, status)
    let decision = try f.admit()
    if kind == 0 {
      guard case .requests = decision else { throw PermissionServiceTestError.unexpected }
    } else {
      #expect(decision == .denied(.managedLimit([.managedPreferences])))
    }
    #expect(
      (try f.view().sources.first { $0.source == .managedPreferences }?.failure != nil)
        == (kind != 0))
  }

  @Test func perSourceFallbackIsResolvedBeforeStrictIntersection() throws {
    let f = try PermissionServiceFixture()
    f.reader.set(
      .machineFile,
      .available(
        Data("[projects]\n'*' = 'read'\nconcrete = 'write'\n[execution]\ntime_ms = 3000".utf8)))
    f.reader.set(
      .managedPreferences,
      .available(Data("[projects]\nconcrete = 'read'\n[execution]\ntime_ms = 1500".utf8)))
    _ = try f.admit()
    let limits = try #require(f.view().subjects.first?.limits)
    #expect(
      limits.restrictingSources(for: try .init(.project("concrete"), .write)) == [
        .managedPreferences
      ])
    #expect(limits.restrictingSources(for: try .init(.project("other"), .write)) == [.machine])
    #expect(limits.restrictingSources(for: try .init(.project("concrete"), .read)).isEmpty)
  }

  @Test func ownerPolicyIsDurableAndIndependentOfMachineSources() throws {
    let f = try PermissionServiceFixture()
    _ = try f.admit()
    _ = try f.service.setOwnerPolicy(
      Data("[permissions]\nscreen = 'deny'".utf8), profileID: .chatGPTOperate, owner: f.owner,
      expectedRevision: f.view().revision, now: f.now)
    let second = GatewayPermissionService(store: f.store, policyReader: f.reader)
    #expect(
      try second.admit(
        subject: f.client, tool: "fixture", projectID: nil, argumentsDigest: "digest",
        requirements: f.requirements(), now: f.now) == .denied(.managedLimit([.owner])))
    #expect(
      try second.view(owner: f.owner, now: f.now).sources.contains {
        $0.source == .owner && $0.profileID == .chatGPTOperate
      })
  }

  @Test func concurrentOwnerEditsUseOneSharedRevision() async throws {
    let f = try PermissionServiceFixture()
    let a = try f.request()
    let b = try f.request(requirements: f.requirements(.unifiedLogs))
    let revision = try f.view().revision
    let successes = await withTaskGroup(of: Bool.self) { group in
      for id in [a.id, b.id] {
        group.addTask {
          (try? f.service.answerRequest(
            id, answer: .always, owner: f.owner, expectedRevision: revision, now: f.now)) != nil
        }
      }
      var count = 0
      for await value in group where value { count += 1 }
      return count
    }
    #expect(successes == 1)
  }

  @Test func restoredDatabaseCannotReloadSharedGrantsBeforeOwnerConfirmation() throws {
    let f = try PermissionServiceFixture()
    try f.answer(f.request().id, .always)
    #expect(isAllowed(try f.admit()))
    f.counter.forget()
    #expect(try f.admit() == .denied(.authoritySuspended))
    let suspended = try f.view()
    #expect(suspended.suspended)
    let epoch = try #require(suspended.epoch)
    try f.store.transactionWithDatabase { _, ledger in try ledger.acknowledgeEpochRecovery(epoch) }
    try f.service.confirmAuthority(
      owner: f.owner, epoch: epoch, expectedRevision: f.view().revision, now: f.now)
    #expect(isAllowed(try f.admit()))
    #expect(try f.view().requests.isEmpty)
  }

  @Test func ownerProofIsLocalAndRecheckedInsideCommit() throws {
    let f = try PermissionServiceFixture()
    #expect(throws: GatewayPermissionError.localOwnerRequired) {
      try GatewayPermissionOwner(
        context: .init(caller: .secureTunnel, profileID: .localAdmin, trustedPrincipalID: "owner"),
        validate: {})
    }
    #expect(throws: GatewayPermissionError.unauthenticated) {
      try GatewayPermissionSubject(
        context: .init(caller: .secureTunnel, profileID: .chatGPTOperate))
    }
    let request = try f.request()
    let stale = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
      validate: { throw PermissionServiceTestError.expiredOwner })
    #expect(throws: PermissionServiceTestError.expiredOwner) {
      try f.service.answerRequest(
        request.id, answer: .always, owner: stale, expectedRevision: f.view().revision, now: f.now)
    }
    #expect(try f.view().profiles[0].permissions.state(for: .screen) == .notGranted)
  }

  @Test func registeredPluginPurposeIsBoundToTheExactRetry() throws {
    let f = try PermissionServiceFixture()
    let requirement = try InvocationRequirements(actions: [
      .init(
        requirement: .init(.screen, .access), pluginPurpose: "Registered plugin reads the screen")
    ])
    let request = try f.request(requirements: requirement)
    guard case .permission(let content) = request.content else {
      throw PermissionServiceTestError.unexpected
    }
    #expect(content.pluginPurpose == "Registered plugin reads the screen")
    try f.answer(request.id, .onlyThisTime)
    guard
      case .requests(let changed) = try f.admit(
        requirements: f.requirements(), retryIDs: [request.id])
    else { throw PermissionServiceTestError.unexpected }
    #expect(!changed.isEmpty)
    #expect(changed.allSatisfy { $0.id != request.id })
    #expect(isAllowed(try f.admit(requirements: requirement, retryIDs: [request.id])))
  }

  @Test func networkAlwaysPreservesAccessFallbackAndSharesOnlyTheNamedHost() throws {
    let f = try PermissionServiceFixture()
    var profile = try #require(f.view().profiles.first)
    try profile.permissions.set(.granted(.read), for: .project("*"))
    profile.projectNetworks["*"] = NetworkAccess.none
    try f.update(profile)
    let requirements = try InvocationRequirements(
      actions: [.init(requirement: .init(.project("project"), .read))],
      networks: [.init(host: "api.example.com", projectID: "project", isLocalNetwork: false)],
      sandboxProjectID: "project")
    let request = try f.request(requirements: requirements)
    try f.answer(request.id, .always)
    #expect(isAllowed(try f.admit(requirements: requirements, retryIDs: [request.id])))
    #expect(isAllowed(try f.admit(subject: f.subject("future"), requirements: requirements)))
    let saved = try #require(f.view().profiles.first)
    #expect(saved.permissions.entries[.project("project")] == nil)
    #expect(saved.projectNetworks["project"]?.allows("api.example.com", trustedHosts: []) == true)
    #expect(
      saved.projectNetworks["project"]?.allows("other.example.com", trustedHosts: []) == false)
  }

  @Test func lateDiscoveredNeedsRetainTheCompleteRetryChain() throws {
    let f = try PermissionServiceFixture()
    let original = InvocationRequirements(sandboxProjectID: "project", execution: .background)
    guard case .allowed(let authorization) = try f.admit(requirements: original) else {
      throw PermissionServiceTestError.unexpected
    }
    let execution = try f.store.transactionWithDatabase { _, ledger in
      try ledger.startExecution(
        owner: f.client.principal, authorizationIDs: [authorization.id], now: f.now)
    }
    let first = try f.store.transactionWithDatabase { _, ledger in
      try ledger.recordDiscoveredNeeds(
        executionID: execution.id, principal: f.client.principal,
        needs: [
          .network(.init(host: "one.example.com", projectID: "project", isLocalNetwork: false))
        ], now: f.now)
    }
    guard case .requests(let firstRequests) = first else {
      throw PermissionServiceTestError.unexpected
    }
    for request in firstRequests { try f.answer(request.id, .onlyThisTime) }
    let second = try f.store.transactionWithDatabase { _, ledger in
      try ledger.recordDiscoveredNeeds(
        executionID: execution.id, principal: f.client.principal,
        needs: [
          .network(.init(host: "two.example.com", projectID: "project", isLocalNetwork: false))
        ], now: f.now)
    }
    guard case .requests(let allRequests) = second else {
      throw PermissionServiceTestError.unexpected
    }
    for request in allRequests where request.status == .pending {
      try f.answer(request.id, .onlyThisTime)
    }
    guard
      case .allowed(let retry) = try f.admit(
        requirements: original, retryIDs: Set(allRequests.map(\.id)))
    else { throw PermissionServiceTestError.unexpected }
    #expect(Set(retry.requirements.networks.map(\.host)) == ["one.example.com", "two.example.com"])
  }

  @Test func revokedCallerAndProfileGrantRetireExistingAuthority() throws {
    let f = try PermissionServiceFixture()
    try f.answer(f.request().id, .always)
    guard case .allowed(let authorization) = try f.admit() else {
      throw PermissionServiceTestError.unexpected
    }
    var profile = try #require(f.view().profiles.first)
    profile.allowedCallers = []
    try f.update(profile)
    #expect(throws: (any Error).self) {
      try f.store.transactionWithDatabase { _, ledger in
        try ledger.startExecution(
          owner: f.client.principal, authorizationIDs: [authorization.id], now: f.now)
      }
    }
  }
}

private func isAllowed(_ decision: AuthorizationDecision) -> Bool {
  if case .allowed = decision { true } else { false }
}
private enum PermissionServiceTestError: Error { case unexpected, expiredOwner }
private final class PermissionServiceFixture: @unchecked Sendable {
  let connection: GatewayDatabaseConnection
  let store: SQLitePermissionStore
  let reader = TestManagedPolicyReader()
  let counter = TestAuthorizationEpochCounter()
  let service: GatewayPermissionService
  let owner: GatewayPermissionOwner
  let client: GatewayPermissionSubject
  let now = Date(timeIntervalSince1970: 1_750_000_000)
  init() throws {
    connection = try GatewayDatabaseConnection(inMemory: ())
    store = SQLitePermissionStore(connection: connection, counter: counter)
    service = GatewayPermissionService(store: store, policyReader: reader)
    owner = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
      validate: {})
    client = try GatewayPermissionSubject(
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "client"))
    try store.transactionWithDatabase { _, ledger in
      try ledger.acknowledgeEpochRecovery(#require(ledger.authorizationEpochID))
    }
    let view = try service.view(owner: owner, now: now)
    try service.confirmAuthority(
      owner: owner, epoch: #require(view.epoch), expectedRevision: view.revision, now: now)
    let profile = PermissionProfile(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
    try service.updateProfile(
      profile, owner: owner, expectedProfileRevision: nil,
      expectedRevision: service.view(owner: owner, now: now).revision, now: now)
  }
  func subject(_ identity: String) throws -> GatewayPermissionSubject {
    try .init(
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: identity))
  }
  func view() throws -> GatewayPermissionView { try service.view(owner: owner, now: now) }
  func requirements(_ permission: Permission = .screen) throws -> InvocationRequirements {
    try .init(actions: [.init(requirement: .init(permission, .access))])
  }
  func admit(
    subject: GatewayPermissionSubject? = nil, arguments: String = "digest",
    requirements: InvocationRequirements? = nil, retryIDs: Set<UUID> = [], now: Date? = nil
  ) throws -> AuthorizationDecision {
    try service.admit(
      subject: subject ?? client, tool: "fixture", projectID: nil, argumentsDigest: arguments,
      requirements: requirements ?? self.requirements(), retryIDs: retryIDs, now: now ?? self.now)
  }
  func request(requirements: InvocationRequirements? = nil) throws -> PermissionRequest {
    guard case .requests(let requests) = try admit(requirements: requirements),
      let request = requests.first
    else { throw PermissionServiceTestError.unexpected }
    return request
  }
  func answer(_ id: UUID, _ answer: PermissionAnswer) throws {
    _ = try service.answerRequest(
      id, answer: answer, owner: owner, expectedRevision: view().revision, now: now)
  }
  func update(_ profile: PermissionProfile) throws {
    try service.updateProfile(
      profile, owner: owner, expectedProfileRevision: profile.authorizationRevision,
      expectedRevision: view().revision, now: now)
  }
}

private struct ReentrantPermissionPolicyReader: ManagedPolicyReading {
  let connection: GatewayDatabaseConnection
  func readSources() -> [ManagedPolicySourceSnapshot] {
    do {
      _ = try connection.writer.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM permissionProfiles")
      }
    } catch { Issue.record(error) }
    return ManagedPolicySourceID.allCases.map {
      .init(source: $0, location: "fixture", status: .absent)
    }
  }
  func canonicalPolicyPath(_ path: String) throws -> String { path }
}
