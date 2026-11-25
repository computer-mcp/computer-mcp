import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway

@Suite struct GatewayProjectRequestTests {
  @Test func allowCommitsRegistrationGrantAndCatalogTogether() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let pending = try f.request()
    #expect(try f.projects().isEmpty)
    #expect(
      try f.store.readWithDatabase { _, ledger in
        ledger.environment.paths?.registeredProjects.isEmpty
      } == true)
    #expect(throws: PermissionModelError.invalidRegistrationAnswer) {
      try f.service.answerRequest(
        pending.id, answer: .onlyThisTime, owner: f.owner, expectedRevision: f.view().revision)
    }
    let project = try #require(try f.answer(pending.id, allow: true))
    #expect(try f.projects().map(\.id) == [project.id])
    #expect(
      try f.view().profiles.first?.permissions.state(for: .project(project.id)) == .granted(.read))
    #expect(
      try f.store.readWithDatabase { _, ledger in
        ledger.environment.paths?.registeredProjects.contains(where: { $0.id == project.id })
      } == true)
    #expect(
      try f.service.requestProject(
        subject: f.client, path: f.folder.path, access: .read, argumentsDigest: "request")
        == .registered(project.id))
  }

  @Test func unrelatedUnavailableProjectDoesNotBlockRegistration() throws {
    let runner = RecordingCommandRunner()
    let f = try ProjectRequestFixture(nestingInspector: {
      try GatewayTrackedProjectNesting.inspect(
        $0, gitExecutable: "/fixture/tools/git", runner: runner)
    })
    defer { f.remove() }
    let stale = ComputerMCPCore.RegisteredProject(
      id: "unavailable", displayName: "Unavailable",
      rootPath: f.root.appendingPathComponent("unmounted/project").path)
    try f.store.transactionWithDatabase { database, ledger in
      _ = try GatewayDatabase.registerProjectIdempotently(stale, in: database)
      var environment = ledger.environment
      environment.paths = try PathEnvironmentSnapshot(projects: [
        .init(id: stale.id, root: CanonicalPath(stale.rootPath))
      ])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    let registered = try #require(try f.answer(f.request().id, allow: true))
    #expect(try f.projects().contains(where: { $0.id == registered.id }))
    #expect(try f.projects().contains(where: { $0.id == stale.id }))
    #expect(runner.calls.isEmpty)
  }

  @Test func registrationRetriesKeepTheirOriginalDecisionAndCurrentAuthority() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let request = try f.request()
    let pending = try f.service.requestProject(
      subject: f.client, path: f.folder.path, access: .read, argumentsDigest: "request",
      retryIDs: [request.id])
    #expect(pending == .request(request))
    #expect(try f.view().requests.count == 1)
    _ = try f.answer(request.id, allow: false)
    guard case .projectRegistration(let content) = request.content else { return }
    #expect(
      try f.service.requestProject(
        subject: f.client, path: f.folder.path, access: .read, argumentsDigest: "request",
        retryIDs: [request.id])
        == .denied(.permissionDenied(.project(content.projectID))))
    #expect(try f.view().requests.count == 1)
    let allowedRequest = try f.request()
    let project = try #require(try f.answer(allowedRequest.id, allow: true))
    #expect(
      try f.service.requestProject(
        subject: f.client, path: f.folder.path, access: .read, argumentsDigest: "request",
        retryIDs: [allowedRequest.id])
        == .registered(project.id))
    _ = try f.service.revokePermission(
      .project(project.id), profileID: f.client.profileID, owner: f.owner,
      expectedRevision: f.view().revision)
    #expect(
      try f.service.requestProject(
        subject: f.client, path: f.folder.path, access: .read, argumentsDigest: "request",
        retryIDs: [allowedRequest.id])
        == .denied(.authorizationRevoked))
    #expect(try f.view().requests.count == 2)
  }

  @Test func registrationRetryIDsCannotSelectAnotherInvocation() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let request = try f.request()
    let other = try GatewayPermissionSubject(
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "other-client"))
    for test in ["principal", "path", "access", "digest", "unknown", "multiple"] {
      #expect(throws: PermissionModelError.retryMismatch) {
        try f.service.requestProject(
          subject: test == "principal" ? other : f.client,
          path: test == "path" ? f.root.path : f.folder.path,
          access: test == "access" ? .write : .read,
          argumentsDigest: test == "digest" ? "changed" : "request",
          retryIDs: test == "unknown"
            ? [UUID()] : test == "multiple" ? [request.id, UUID()] : [request.id])
      }
      #expect(try f.view().requests.count == 1)
    }
  }

  @Test func removingCallerAutomaticallyRetiresItsRegistrationRequests() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let request = try f.request()
    var profile = try #require(try f.view().profiles.first)
    profile.allowedCallers = []
    try f.service.updateProfile(
      profile, owner: f.owner, expectedProfileRevision: profile.authorizationRevision,
      expectedRevision: f.view().revision)
    let remaining = try #require(
      try f.view().requests.first(where: { $0.request.id == request.id }))
    #expect(remaining.request.status == .revoked)
    #expect(try f.view().requests.allSatisfy { $0.request.status != .pending })
    #expect(try f.projects().isEmpty)
  }

  @Test func dontAllowLeavesFolderUnregisteredAndUngranted() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let request = try f.request()
    #expect(try f.answer(request.id, allow: false) == nil)
    #expect(try f.projects().isEmpty)
    #expect(try f.view().requests.first?.request.status == .declined)
  }

  @Test func canonicalReplacementAndStaleBookmarkFailWithoutAuthority() throws {
    for stale in [false, true] {
      let f = try ProjectRequestFixture(staleBookmark: stale)
      defer { f.remove() }
      let request = try f.request()
      if !stale {
        try FileManager.default.moveItem(at: f.folder, to: f.root.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
      }
      #expect(throws: (any Error).self) { try f.answer(request.id, allow: true) }
      #expect(try f.projects().isEmpty)
      #expect(try f.view().requests.first?.request.status == .pending)
      guard case .projectRegistration(let content) = request.content else { return }
      #expect(
        try f.view().profiles.first?.permissions.state(for: .project(content.projectID))
          == .notGranted)
    }
  }

  @Test func concurrentDuplicateRequestsReuseReservedIdentity() async throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let requests = try await withThrowingTaskGroup(of: PermissionRequest.self) { group in
      for _ in 0..<12 { group.addTask { try f.request() } }
      var requests: [PermissionRequest] = []
      for try await request in group { requests.append(request) }
      return requests
    }
    #expect(Set(requests.map(\.id)).count == 1)
    #expect(try f.projects().isEmpty)
    #expect(try f.answer(requests[0].id, allow: true) != nil)
  }

  @Test func catalogValidationFailureRollsBackRegistrationAndGrant() throws {
    let f = try ProjectRequestFixture(rejectNesting: true)
    defer { f.remove() }
    let request = try f.request()
    #expect(throws: PermissionModelError.invalidProjectGraph) {
      try f.answer(request.id, allow: true)
    }
    #expect(try f.projects().isEmpty)
    #expect(try f.view().requests.first?.request.status == .pending)
    guard case .projectRegistration(let content) = request.content else { return }
    #expect(
      try f.view().profiles.first?.permissions.state(for: .project(content.projectID))
        == .notGranted)
  }

  @Test func replacedFolderCanProduceNewReservationWithoutRevivingOldRequest() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let old = try f.request()
    try FileManager.default.moveItem(at: f.folder, to: f.root.appendingPathComponent("old"))
    try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
    let current = try f.request()
    #expect(old.id != current.id)
    #expect(throws: (any Error).self) { try f.answer(old.id, allow: true) }
    #expect(try f.answer(current.id, allow: true) != nil)
  }

  @Test func expiredReservationCanBeRequestedAgain() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let old = try f.request()
    guard
      case .request(let current) = try f.service.requestProject(
        subject: f.client, path: f.folder.path, access: .read, argumentsDigest: "request",
        now: Date().addingTimeInterval(86_500))
    else {
      Issue.record("Expected a renewed registration request")
      return
    }
    #expect(current.id != old.id)
    #expect(try f.projects().isEmpty)
  }

  @Test func trackedNestedProjectCannotNarrowExistingOuterGrant() throws {
    let f = try ProjectRequestFixture(nestedOuterID: "outer")
    defer { f.remove() }
    let outer = ComputerMCPCore.RegisteredProject(
      id: "outer", displayName: "Outer", rootPath: f.root.path)
    try f.store.transactionWithDatabase { database, ledger in
      _ = try GatewayDatabase.registerProjectIdempotently(outer, in: database)
      var environment = ledger.environment
      environment.paths = try PathEnvironmentSnapshot(projects: [
        .init(id: outer.id, root: CanonicalPath(f.root.path))
      ])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    var profile = try #require(try f.view().profiles.first)
    try profile.permissions.set(.granted(.write), for: .project("outer"))
    try f.service.updateProfile(
      profile, owner: f.owner, expectedProfileRevision: profile.authorizationRevision,
      expectedRevision: f.view().revision)
    let request = try f.request()
    #expect(throws: (any Error).self) { try f.answer(request.id, allow: true) }
    #expect(try f.projects().map(\.id) == ["outer"])
    #expect(try f.view().requests.first?.request.status == .pending)
  }

  @Test func trackedNestingDiscoversRepositoryAboveRegisteredSubdirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let outer = root.appendingPathComponent("repo/docs")
    let inner = outer.appendingPathComponent("private")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    let runner = RecordingCommandRunner()
    runner.outputs = [.init(stdout: "true\n"), .init(stdout: "private/file.txt\0")]
    let nesting = try GatewayTrackedProjectNesting.inspect(
      [
        .init(id: "outer", displayName: "Outer", rootPath: outer.path),
        .init(id: "inner", displayName: "Inner", rootPath: inner.path),
      ], gitExecutable: "/fixture/tools/git", runner: runner)
    #expect(runner.calls.map(\.executable) == ["/fixture/tools/git", "/fixture/tools/git"])
    #expect(nesting.count == 1)
    #expect(nesting.first?.outerID == "outer")
    #expect(nesting.first?.innerID == "inner")
    #expect(runner.calls.first?.arguments.suffix(2) == ["rev-parse", "--is-inside-work-tree"])
    #expect(
      runner.calls.last?.arguments.suffix(4) == ["ls-files", "-z", "--", ":(literal)private"])
    #expect(runner.calls.allSatisfy { $0.arguments.contains("core.fsmonitor=false") })
    let failed = RecordingCommandRunner()
    failed.outputs = [
      .init(
        stdout: "", stderr: "fatal: bad config in /tmp/not a git repository/config", exitCode: 128)
    ]
    #expect(throws: (any Error).self) {
      try GatewayTrackedProjectNesting.inspect(
        [
          .init(id: "outer", displayName: "Outer", rootPath: outer.path),
          .init(id: "inner", displayName: "Inner", rootPath: inner.path),
        ], gitExecutable: "/fixture/tools/git", runner: failed)
    }
  }

  @Test func existingProjectRequestUpgradesAccessWithoutDuplicateRegistration() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let project = try #require(try f.answer(f.request().id, allow: true))
    guard
      case .request(let upgrade) = try f.service.requestProject(
        subject: f.client, path: f.folder.path, access: .write, argumentsDigest: "upgrade")
    else {
      Issue.record("Expected a write access request")
      return
    }
    #expect(try f.answer(upgrade.id, allow: true)?.id == project.id)
    #expect(try f.projects().count == 1)
    #expect(
      try f.view().profiles.first?.permissions.state(for: .project(project.id)) == .granted(.write))
  }

  @Test func derivedFolderRequestGrantsSourceAndKeepsDerivedRegistration() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let sourceRoot = f.root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    let source = ComputerMCPCore.RegisteredProject(
      id: "source", displayName: "Source", rootPath: sourceRoot.path)
    let derived = ComputerMCPCore.RegisteredProject(
      id: "derived", displayName: "Worktree", rootPath: f.folder.path)
    try f.store.transactionWithDatabase { database, ledger in
      _ = try GatewayDatabase.registerProjectIdempotently(source, in: database)
      _ = try GatewayDatabase.registerProjectIdempotently(derived, in: database)
      var environment = ledger.environment
      environment.paths = try PathEnvironmentSnapshot(projects: [
        .init(id: source.id, root: CanonicalPath(sourceRoot.path)),
        .init(
          id: derived.id, root: CanonicalPath(f.folder.path),
          sourceID: source.id),
      ])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    let request = try f.request()
    guard case .projectRegistration(let content) = request.content else { return }
    #expect(content.projectID == source.id)
    #expect(content.path.string == f.folder.path)
    let view = try #require(try f.view().requests.first(where: { $0.request.id == request.id }))
    #expect(view.registrationGrantRoot?.string == sourceRoot.path)
    #expect(view.registrationGrantName == "Source")
    #expect(try f.answer(request.id, allow: true)?.id == derived.id)
    #expect(try f.projects().count == 2)
    #expect(
      try f.view().profiles.first?.permissions.state(for: .project(source.id)) == .granted(.read))
    #expect(
      try f.view().profiles.first?.permissions.state(for: .project(derived.id)) == .notGranted)
    #expect(
      try f.store.readWithDatabase { _, ledger in
        ledger.environment.paths?.registeredProjects.first(where: { $0.id == derived.id })?.sourceID
      } == source.id)
    #expect(
      try f.service.requestProject(
        subject: f.client, path: f.folder.path, access: .read, argumentsDigest: "request")
        == .registered(derived.id))
  }

  @Test func sharedReservationRetainsLaterLiveRequest() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let instant = Date()
    _ = try f.service.requestProject(
      subject: f.client, path: f.folder.path, access: .read, argumentsDigest: "early", now: instant)
    let laterTime = instant.addingTimeInterval(23 * 3_600)
    guard
      case .request(let later) = try f.service.requestProject(
        subject: f.client, path: f.folder.path, access: .read, argumentsDigest: "later",
        now: laterTime)
    else {
      Issue.record("Expected later request")
      return
    }
    let answerTime = instant.addingTimeInterval(25 * 3_600)
    let another = f.root.appendingPathComponent("another")
    try FileManager.default.createDirectory(at: another, withIntermediateDirectories: true)
    _ = try f.service.requestProject(
      subject: f.client, path: another.path, access: .read, argumentsDigest: "another",
      now: answerTime)
    let revision = try f.service.view(owner: f.owner, now: answerTime).revision
    #expect(
      try f.service.answerProjectRequest(
        later.id, allow: true, owner: f.owner, expectedRevision: revision, now: answerTime) != nil)
  }

  @Test(arguments: ["profile", "catalog"])
  func nestingInspectionAllowsIndependentWritersAndRejectsTheirStaleSnapshot(mutation: String)
    async throws
  {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let written = DispatchSemaphore(value: 0)
    let runner = RecordingCommandRunner()
    runner.outputs = [.init(stdout: "true\n"), .init(stdout: "")]
    runner.onRun = { call in
      if call.arguments.contains("rev-parse") {
        started.signal()
        guard release.wait(timeout: .now() + 10) == .success else {
          throw PermissionModelError.invalidAuthorization
        }
      }
    }
    let f = try ProjectRequestFixture(nestingInspector: {
      try GatewayTrackedProjectNesting.inspect(
        $0, gitExecutable: "/fixture/tools/git", runner: runner)
    })
    defer { f.remove() }
    try FileManager.default.createDirectory(
      at: f.root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let concurrent = f.root.appendingPathComponent("concurrent")
    try FileManager.default.createDirectory(at: concurrent, withIntermediateDirectories: true)
    try f.store.transactionWithDatabase { database, ledger in
      _ = try GatewayDatabase.registerProjectIdempotently(
        .init(id: "outer", displayName: "Outer", rootPath: f.root.path), in: database)
      var environment = ledger.environment
      environment.paths = try PathEnvironmentSnapshot(projects: [
        .init(id: "outer", root: CanonicalPath(f.root.path))
      ])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    let request = try f.request()
    let view = try f.view()
    let profile = try #require(view.profiles.first)
    let answering = Task.detached { Result { try f.answer(request.id, allow: true) } }
    let inspecting = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: started.wait(timeout: .now() + 3) == .success)
      }
    }
    #expect(inspecting)
    let writing = Task.detached {
      let result = Result {
        if mutation == "profile" {
          var changed = profile
          try changed.permissions.set(.granted(.access), for: .screen)
          try f.service.updateProfile(
            changed, owner: f.owner, expectedProfileRevision: profile.authorizationRevision,
            expectedRevision: view.revision)
        } else {
          try f.store.transactionWithDatabase { database, _ in
            _ = try GatewayDatabase.registerProjectIdempotently(
              .init(id: "concurrent", displayName: "Concurrent", rootPath: concurrent.path),
              in: database)
          }
        }
      }
      written.signal()
      return result
    }
    let progressed = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: written.wait(timeout: .now() + 2) == .success)
      }
    }
    release.signal()
    #expect(progressed)
    try await writing.value.get()
    switch await answering.value {
    case .success: Issue.record("Registration committed an obsolete nesting inspection")
    case .failure(let error): #expect(error as? GatewayPermissionError == .revisionConflict)
    }
    guard case .projectRegistration(let content) = request.content else { return }
    #expect(try f.projects().allSatisfy { $0.id != content.projectID })
    #expect(
      try f.view().profiles.first?.permissions.state(for: .project(content.projectID))
        == .notGranted)
  }

  @Test func projectDeclarationsAreNeverExecutedByRegistration() throws {
    let f = try ProjectRequestFixture()
    defer { f.remove() }
    let declaration =
      "[mcp.servers.surprise]\ncommand = '/bin/sh'\narguments = ['-c', 'touch ran']\n"
    try declaration.write(
      to: f.folder.appendingPathComponent("computer-mcp.toml"), atomically: true, encoding: .utf8)
    _ = try f.answer(f.request().id, allow: true)
    #expect(!FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("ran").path))
  }
}

private final class ProjectRequestFixture: @unchecked Sendable {
  let root: URL
  let folder: URL
  let connection: GatewayDatabaseConnection
  let store: SQLitePermissionStore
  let service: GatewayPermissionService
  let owner: GatewayPermissionOwner
  let client: GatewayPermissionSubject

  init(
    staleBookmark: Bool = false, rejectNesting: Bool = false, nestedOuterID: String? = nil,
    nestingInspector: (
      @Sendable ([ComputerMCPCore.RegisteredProject]) throws -> [TrackedProjectNesting]
    )? = nil
  ) throws {
    let created = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: created.appendingPathComponent("project"), withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(created)
    folder = root.appendingPathComponent("project")
    connection = try GatewayDatabaseConnection(inMemory: ())
    store = SQLitePermissionStore(connection: connection, counter: TestAuthorizationEpochCounter())
    service = GatewayPermissionService(
      store: store, policyReader: TestManagedPolicyReader(),
      projectBookmarks: RequestBookmarks(stale: staleBookmark),
      projectNesting: { projects in
        if let nestingInspector { return try nestingInspector(projects) }
        if rejectNesting { throw PermissionModelError.invalidProjectGraph }
        if let outer = nestedOuterID {
          return projects.filter { $0.id != outer }.map { .init(innerID: $0.id, outerID: outer) }
        }
        return []
      })
    owner = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
      validate: {})
    client = try GatewayPermissionSubject(
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "client"))
    try store.transactionWithDatabase { _, ledger in
      try ledger.acknowledgeEpochRecovery(#require(ledger.authorizationEpochID))
    }
    let view = try service.view(owner: owner)
    try service.confirmAuthority(
      owner: owner, epoch: #require(view.epoch), expectedRevision: view.revision,
      profileEdits: view.profiles)
    try service.updateProfile(
      ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel]), owner: owner,
      expectedProfileRevision: nil, expectedRevision: service.view(owner: owner).revision)
    try store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.paths = try PathEnvironmentSnapshot()
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
  func view() throws -> GatewayPermissionView { try service.view(owner: owner) }
  func projects() throws -> [ComputerMCPCore.RegisteredProject] {
    try connection.writer.read { try GatewayDatabase.projects(in: $0) }
  }
  func request() throws -> PermissionRequest {
    guard
      case .request(let request) = try service.requestProject(
        subject: client, path: folder.path, access: .read, argumentsDigest: "request")
    else {
      throw PermissionModelError.invalidRegistrationAnswer
    }
    return request
  }
  func answer(_ id: UUID, allow: Bool) throws -> ComputerMCPCore.RegisteredProject? {
    try service.answerProjectRequest(
      id, allow: allow, owner: owner, expectedRevision: view().revision)
  }
}

private struct RequestBookmarks: ProjectBookmarkServicing {
  let stale: Bool
  func registerFolder(at url: URL, displayName: String?) throws -> ComputerMCPCore.RegisteredProject
  {
    .init(
      displayName: displayName ?? url.lastPathComponent, rootPath: url.path, bookmarkIsStale: stale)
  }
  func resolve(_ project: ComputerMCPCore.RegisteredProject) throws -> ResolvedProjectAccess {
    try .init(
      project: project, rootURL: URL(fileURLWithPath: project.rootPath),
      bookmarkWasRefreshed: false, stopAccessing: nil)
  }
}
