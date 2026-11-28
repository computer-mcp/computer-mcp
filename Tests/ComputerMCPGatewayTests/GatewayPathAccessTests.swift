import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite struct GatewayPathAccessTests {
  @Test(arguments: [PermissionAnswer.onlyThisTime, .always])
  func discoveredFolderNeedsRequireAnExplicitExactRetry(answer: PermissionAnswer) throws {
    let f = try DurablePathFixture()
    let id = try f.authorize(f.project, operation: .read, once: true)
    let checker = GatewayPathAccess(store: f.store, authorizationID: id)
    let scope = ProjectScope(
      configuration: .init(projectDirectory: f.root), toolMeta: nil,
      pathAccess: checker)
    let target = f.root.appendingPathComponent("downloads/notes.txt")
    let proof = try f.store.readWithDatabase { _, ledger in
      try #require(ledger.authorizations[id])
    }
    var requests: [PermissionRequest] = []
    do {
      _ = try scope.resolvedProjectURL(target.path)
      Issue.record("An ungranted folder must fail the original operation")
    } catch GatewayPermissionCallError.required(let pending, _, let afterDispatch) {
      requests = pending
      #expect(afterDispatch)
      #expect(
        GatewayPermissionCallError.required(pending, afterDispatch: afterDispatch).fields[
          "call_dispatched"] == .bool(true))
      #expect(pending.count == 1)
      #expect(pending.first?.invocation == proof.invocation)
    }
    let retry = try f.store.transactionWithDatabase { _, ledger in
      for request in requests { _ = try ledger.answer(request.id, with: answer, now: Date()) }
      #expect(ledger.authorizations[id]?.basis == proof.basis)
      try ledger.finishInvocation(id)
      #expect(throws: PermissionModelError.retryMismatch) {
        _ = try ledger.authorize(
          invocation: .init(
            principal: f.principal, tool: "file.read", projectID: "project",
            argumentsDigest: "different"),
          requirements: proof.requirements, retryIDs: Set(requests.map(\.id)), now: Date())
      }
      let decision = try ledger.authorize(
        invocation: proof.invocation, requirements: proof.requirements,
        retryIDs: Set(requests.map(\.id)), now: Date())
      guard case .allowed(let retried) = decision else {
        throw PermissionModelError.invalidAuthorization
      }
      return retried.id
    }
    #expect(throws: (any Error).self) { try checker.check(target, operation: .read) }
    let retried = GatewayPathAccess(store: f.store, authorizationID: retry)
    try retried.check(target, operation: .read)
    try retried.check(f.project.appendingPathComponent("file"), operation: .read)
    if case .onlyThisTime = answer {
      #expect(throws: (any Error).self) {
        try retried.check(f.root.appendingPathComponent("downloads/sibling"), operation: .read)
      }
    }
  }

  @Test func listingFiltersUngrantableAndUngrantedChildrenWithoutRequests() throws {
    let f = try DurablePathFixture()
    let id = try f.authorize(f.project, operation: .read, once: false)
    let downloads = f.project.deletingLastPathComponent()
    try Data("private".utf8).write(to: downloads.appendingPathComponent("private.txt"))
    let checker = GatewayPathAccess(store: f.store, authorizationID: id)
    let children = try HostPathAccess.$current.withValue(checker) {
      try sortedDirectoryChildren(downloads, includeHidden: true)
    }
    #expect(children.map(\.lastPathComponent) == ["repo"])
    #expect(try f.store.readWithDatabase { _, ledger in ledger.requests.isEmpty })
  }

  @Test func fixedAndExplicitDenialsNeverCreateFolderRequests() throws {
    let f = try DurablePathFixture()
    let id = try f.authorize(f.project, operation: .read, once: false)
    let checker = GatewayPathAccess(store: f.store, authorizationID: id)
    let before = try f.store.readWithDatabase { _, ledger in ledger.requests.count }
    for path in ["host/token", "downloads/repo/inner/secret", "private/data"] {
      #expect(throws: (any Error).self) {
        try checker.check(f.root.appendingPathComponent(path), operation: .read)
      }
    }
    #expect(try f.store.readWithDatabase { _, ledger in ledger.requests.count } == before)
  }

  @Test(arguments: [false, true])
  func oneTimePathGrantsCoverDescendantsButNotSiblings(write: Bool) throws {
    let f = try DurablePathFixture()
    let root = write ? f.derived : f.project
    let operation: PathOperation = write ? .write : .read
    let id = try f.authorize(root, operation: operation, once: true)
    let checker = GatewayPathAccess(store: f.store, authorizationID: id)
    try checker.check(root.appendingPathComponent("file"), operation: .read)
    if write {
      try checker.check(root.appendingPathComponent("file"), operation: .write)
    } else {
      #expect(throws: (any Error).self) {
        try checker.check(root.appendingPathComponent("file"), operation: .write)
      }
    }
    #expect(throws: (any Error).self) {
      try checker.check(f.root.appendingPathComponent("private"), operation: .read)
    }
    try f.store.transactionWithDatabase { _, ledger in
      _ = try ledger.revoke(
        principal: f.principal, permission: .project("project"), expectedRevision: ledger.revision)
    }
    #expect(throws: (any Error).self) {
      try checker.check(root.appendingPathComponent("file"), operation: .read)
    }
  }

  @Test(.nativeIntegration) func exactFileWriteTraversesParentsWithoutOpeningSiblings() throws {
    let f = try DurablePathFixture()
    let target = f.derived.appendingPathComponent("new-file")
    let id = try f.authorize(target, operation: .write, once: true)
    let checker = GatewayPathAccess(store: f.store, authorizationID: id)
    let administration = ExecutionAdministration(
      mode: .fullAccess, environment: try .init(fullAccessVariables: ["PATH": systemUtilityPath]))
    let files = try ExecutionAdministration.$current.withValue(administration) {
      try ProjectFileAccess(
        project: f.derived, launcher: testExecutionLauncher(), pathAccess: checker)
    }
    try files.write(Data("created".utf8), to: target)
    #expect(try Data(contentsOf: target) == Data("created".utf8))
    #expect(throws: (any Error).self) {
      try files.write(Data("denied".utf8), to: f.derived.appendingPathComponent("sibling"))
    }
    #expect(throws: (any Error).self) { try checker.check(f.derived, operation: .read) }
  }

  @Test func traversalCannotImportAnotherProjectsGrant() throws {
    let f = try DurablePathFixture()
    let id = try f.authorize(f.project, operation: .read, once: false)
    let other = f.root.appendingPathComponent("other/project")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try f.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      var paths = environment.paths!
      try paths.setProjects(
        paths.registeredProjects + [
          .init(id: "other", root: CanonicalPath(other.path))
        ])
      environment.paths = paths
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      _ = try ledger.setPermission(
        .granted(.read), for: .project("other"), principal: f.principal,
        expectedRevision: ledger.revision)
    }
    let checker = GatewayPathAccess(store: f.store, authorizationID: id)
    #expect(throws: (any Error).self) {
      try checker.check(other.deletingLastPathComponent(), operation: .listDirectory)
    }
    #expect(throws: (any Error).self) { try checker.check(other, operation: .read) }
    try checker.check(f.project, operation: .read)
  }

  @Test func directoryTraversalDoesNotRequireFolderRead() throws {
    let f = try DurablePathFixture()
    let id = try f.authorize(f.project, operation: .read, once: false)
    let checker = GatewayPathAccess(store: f.store, authorizationID: id)
    try checker.check(f.project.deletingLastPathComponent(), operation: .listDirectory)
    try checker.check(f.root.appendingPathComponent("tasks"), operation: .openDirectory)
    #expect(throws: (any Error).self) {
      try checker.check(f.project.deletingLastPathComponent(), operation: .read)
    }
    #expect(throws: (any Error).self) {
      try checker.check(f.root.appendingPathComponent("tasks/private"), operation: .read)
    }
  }

  @Test func fullAccessHostReadsStillRespectProjectAndHostDataDenials() throws {
    let f = try DurablePathFixture()
    let id = try f.authorize(f.project, operation: .read, once: false, fullAccess: true)
    let checker = GatewayPathAccess(store: f.store, authorizationID: id)
    try checker.check(f.project.appendingPathComponent("file"), operation: .read)
    #expect(throws: (any Error).self) {
      try checker.check(f.root.appendingPathComponent("host/token"), operation: .read)
    }
    #expect(throws: (any Error).self) {
      try checker.check(f.project.appendingPathComponent("inner/secret"), operation: .read)
    }
  }
}

final class DurablePathFixture {
  let temporary: ScopedTemporaryDirectory
  let root: URL
  let project: URL
  let derived: URL
  let store: SQLitePermissionStore
  let counter = TestAuthorizationEpochCounter()
  let principal = Principal.client("files")

  init() throws {
    temporary = try ScopedTemporaryDirectory()
    root = try ProjectPathResolver.canonicalProject(temporary.url)
    project = root.appendingPathComponent("downloads/repo")
    derived = root.appendingPathComponent("tasks/job")
    for directory in [project, derived, root.appendingPathComponent("host")] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    store = SQLitePermissionStore(
      connection: try .init(inMemory: ()), counter: counter)
    try store.transactionWithDatabase { _, ledger in
      let epoch = try #require(ledger.authorizationEpochID)
      try ledger.acknowledgeEpochRecovery(epoch)
      try ledger.confirmSuspendedAuthority(epochID: epoch, expectedRevision: ledger.revision)
      ledger.register(principal)
      var environment = PermissionEnvironment()
      environment.paths = try .init(
        projects: [
          .init(id: "project", root: CanonicalPath(project.path)),
          .init(id: "inner", root: CanonicalPath(project.appendingPathComponent("inner").path)),
          .init(id: "derived", root: CanonicalPath(derived.path), sourceID: "project"),
        ],
        rules: [
          .init(root: CanonicalPath(root.path), kind: .userData),
          .init(root: CanonicalPath(root.appendingPathComponent("host").path), kind: .hostData),
          .init(
            root: CanonicalPath(root.appendingPathComponent("downloads").path),
            kind: .folder(.downloads)),
        ])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      _ = try ledger.setPermission(
        .denied, for: .project("inner"), principal: principal, expectedRevision: ledger.revision)
    }
  }

  func authorize(_ root: URL, operation: PathOperation, once: Bool, fullAccess: Bool = false) throws
    -> UUID
  {
    try store.transactionWithDatabase { _, ledger in
      if !once {
        _ = try ledger.setPermission(
          .granted(.write), for: .project("project"), principal: principal,
          expectedRevision: ledger.revision)
      }
      if fullAccess {
        let consent = ledger.consent(for: principal, mode: .fullAccess(.standing))
        var environment = ledger.environment
        environment.modes[principal] = consent
        _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      }
      let call = InvocationIdentity(
        principal: principal, tool: "file.read",
        projectID: root.path.hasPrefix(derived.path) ? "derived" : "project",
        argumentsDigest: "digest")
      let requirements = InvocationRequirements(
        paths: [.init(path: try CanonicalPath(root.path), operation: operation)],
        mode: fullAccess ? .fullAccess(.standing) : .sandbox, sandboxProjectID: "project")
      var result = try ledger.authorize(invocation: call, requirements: requirements, now: Date())
      if case .requests(let requests) = result {
        for request in requests {
          _ = try ledger.answer(request.id, with: .onlyThisTime, now: Date())
        }
        result = try ledger.authorize(
          invocation: call, requirements: requirements, retryIDs: Set(requests.map(\.id)),
          now: Date())
      }
      guard case .allowed(let proof) = result else {
        throw PermissionModelError.invalidAuthorization
      }
      return proof.id
    }
  }
}
