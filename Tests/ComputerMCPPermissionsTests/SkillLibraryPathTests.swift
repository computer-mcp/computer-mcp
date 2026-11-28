import Foundation
import Testing

@testable import ComputerMCPPermissions

@Suite struct SkillLibraryPathTests {
  private let library = path("/people/me/.agents/skills")

  private func environment(root: CanonicalPath? = nil) throws -> PathEnvironmentSnapshot {
    try PathEnvironmentSnapshot(rules: [
      PathRule(root: root ?? library, kind: .skillLibrary),
      PathRule(root: path("/people/me"), kind: .userData),
      PathRule(root: path("/people/me/.host"), kind: .hostData),
    ])
  }

  private func requirements(root: CanonicalPath? = nil, target: CanonicalPath? = nil)
    -> InvocationRequirements
  {
    .init(paths: [
      .init(
        path: target ?? library, operation: .read,
        purpose: .skillLibrary(root: root ?? library))
    ])
  }

  @Test func defaultSkillsReadRequiresTheRegisteredLibraryPurpose() throws {
    let resolver = PathPermissions(environment: try environment())
    let file = path(library.string + "/example/SKILL.md")
    #expect(
      resolver.evaluate(
        file, operation: .read, principal: client,
        permissions: .newPrincipal, purpose: .skillLibrary(root: library)) == .allowed)
    #expect(
      resolver.evaluate(
        file, operation: .read, principal: client,
        permissions: .newPrincipal) == .denied(.userData))
    #expect(
      resolver.evaluate(
        file, operation: .read, principal: client,
        permissions: .newPrincipal, pluginPurpose: library.string) == .denied(.userData))
    #expect(
      resolver.evaluate(
        file, operation: .read, principal: client,
        permissions: .newPrincipal, purpose: .skillLibrary(root: path("/people/me")))
        == .denied(.invalidPathRequirement))
  }

  @Test(arguments: [false, true])
  func actualHostReadsRetainOnlyTheAdmittedLibraryPurpose(restored: Bool) throws {
    let selected = path(library.string + "/example")
    let nested = path(selected.string + "/private-project")
    let secret = path(selected.string + "/host/token")
    let otherLibrary = path("/people/me/.codex/skills")
    var paths = try environment()
    try paths.setProjects([RegisteredProject(id: "private", root: nested)])
    paths.pathRules.insert(PathRule(root: secret, kind: .hostData))
    paths.pathRules.insert(PathRule(root: otherLibrary, kind: .skillLibrary))
    var permissions = Permissions.newPrincipal
    try permissions.set(.denied, for: .project("private"))
    var ledger = PermissionLedger()
    _ = try ledger.setPermissions(permissions, for: client, expectedRevision: ledger.revision)
    var state = ledger.environment
    state.paths = paths
    _ = try ledger.reconcile(environment: state, expectedRevision: ledger.revision)
    let admitted = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "skills.read"),
        requirements: requirements(target: selected), now: instant))
    _ = try ledger.prepareExecutionPermissions(admitted.id)
    if restored {
      ledger = try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
    }
    try ledger.authorizePathUse(
      admitted.id, path: path(selected.string + "/SKILL.md"), operation: .read)
    try ledger.authorizePathUse(
      admitted.id, path: path(selected.string + "/assets"), operation: .listDirectory)
    try ledger.authorizePathUse(
      admitted.id, path: path("/people/me/.agents"), operation: .openDirectory)
    for target in [
      path(library.string + "/sibling/SKILL.md"), path(otherLibrary.string + "/SKILL.md"),
      path(nested.string + "/SKILL.md"), secret, library,
    ] {
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try ledger.authorizePathUse(admitted.id, path: target, operation: .read)
      }
    }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.authorizePathUse(
        admitted.id, path: path(selected.string + "/SKILL.md"), operation: .write)
    }
  }

  @Test func registrationAndDirectoryTraversalCannotSupplyAReadPurpose() throws {
    var ledger = PermissionLedger()
    _ = try ledger.setPermissions(.newPrincipal, for: client, expectedRevision: ledger.revision)
    var state = ledger.environment
    state.paths = try environment()
    _ = try ledger.reconcile(environment: state, expectedRevision: ledger.revision)
    let unrelated = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "fixture"), requirements: .init(actions: [action(.skills)]),
        now: instant))
    _ = try ledger.prepareExecutionPermissions(unrelated.id)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.authorizePathUse(
        unrelated.id, path: path(library.string + "/SKILL.md"), operation: .read)
    }
    let listed = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "skills.list"),
        requirements: .init(paths: [
          .init(path: library, operation: .listDirectory, purpose: .skillLibrary(root: library))
        ]), now: instant))
    try ledger.authorizePathUse(listed.id, path: library, operation: .openDirectory)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.authorizePathUse(
        listed.id, path: path(library.string + "/SKILL.md"), operation: .read)
    }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.authorizePathUse(listed.id, path: library, operation: .read)
    }
  }

  @Test func groupedSkillsAndProjectRetryRetainsTheDeclaredPluginPurpose() throws {
    let local = path("/people/me/repo/.agents/skills")
    let selected = path(local.string + "/example")
    var paths = try environment(root: local)
    try paths.setProjects([RegisteredProject(id: "repo", root: path("/people/me/repo"))])
    var ledger = PermissionLedger()
    _ = try ledger.setPermissions(Permissions(), for: client, expectedRevision: ledger.revision)
    var state = ledger.environment
    state.paths = paths
    _ = try ledger.reconcile(environment: state, expectedRevision: ledger.revision)
    let conditions = InvocationRequirements(paths: [
      .init(
        path: selected, operation: .read, pluginPurpose: "Read the selected registered skill",
        purpose: .skillLibrary(root: local))
    ])
    let call = invocation(tool: "skills.read", project: "repo")
    guard
      case .requests(let pending) = try ledger.authorize(
        invocation: call, requirements: conditions, now: instant)
    else {
      Issue.record("Expected the grouped Skills and Project request")
      return
    }
    #expect(pending.count == 2)
    for request in pending { try ledger.answer(request.id, with: .onlyThisTime, now: instant) }
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.authorize(
        invocation: call, requirements: conditions, retryIDs: [pending[0].id], now: instant)
    }
    let ids = Set(pending.map(\.id))
    var changed = ledger
    #expect(throws: PermissionModelError.retryMismatch) {
      try changed.authorize(
        invocation: invocation(tool: "skills.read", project: "repo", digest: "different"),
        requirements: conditions, retryIDs: ids, now: instant)
    }
    #expect(pending.allSatisfy { ledger.requests[$0.id]?.status == .onlyThisTime })
    let admitted = try authorization(
      from: ledger.authorize(
        invocation: call, requirements: conditions, retryIDs: ids, now: instant))
    try ledger.authorizePathUse(
      admitted.id, path: path(selected.string + "/SKILL.md"), operation: .read)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.authorizePathUse(
        admitted.id, path: path(local.string + "/sibling/SKILL.md"), operation: .read)
    }
    #expect(pending.allSatisfy { ledger.requests[$0.id]?.status == .consumed(admitted.id) })
  }

  @Test func canonicalSymlinkTargetsOutsideTheLibraryRemainProtected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let libraryURL = root.appendingPathComponent("skills")
    try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
    let selected = try CanonicalPath(libraryURL.path)
    let paths = try PathEnvironmentSnapshot(rules: [
      PathRule(root: selected, kind: .skillLibrary),
      PathRule(root: try CanonicalPath(root.path), kind: .userData),
      PathRule(root: try CanonicalPath(root.appendingPathComponent("host").path), kind: .hostData),
    ])
    var ledger = PermissionLedger()
    _ = try ledger.setPermissions(.newPrincipal, for: client, expectedRevision: ledger.revision)
    var state = ledger.environment
    state.paths = paths
    _ = try ledger.reconcile(environment: state, expectedRevision: ledger.revision)
    let admitted = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "skills.read"),
        requirements: requirements(root: selected, target: selected), now: instant))
    for targetName in ["private", "host"] {
      let target = root.appendingPathComponent(targetName)
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      let alias = libraryURL.appendingPathComponent(targetName)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
      let escaped = try CanonicalPath(alias.resolvingSymlinksInPath().path)
      #expect(!selected.contains(escaped))
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try ledger.authorizePathUse(admitted.id, path: escaped, operation: .read)
      }
    }
  }

  @Test func aLibraryOutsideUserDataStillNeedsSkillsAndPurpose() throws {
    let root = path("/opt/skills")
    let resolver = PathPermissions(environment: try environment(root: root))
    #expect(
      resolver.evaluate(
        root, operation: .read, principal: client,
        permissions: .newPrincipal) == .denied(.userData))
    guard
      case .request(let content) = resolver.evaluate(
        root, operation: .read,
        principal: client, permissions: Permissions(), purpose: .skillLibrary(root: root))
    else {
      Issue.record("Expected the principal-wide Skills permission")
      return
    }
    #expect(content.requirement.permission == .skills)
    #expect(content.scope == .principal)
  }

  @Test func broadHomeRegistrationDoesNotGrantGeneralFileReads() throws {
    let home = path("/people/me")
    let resolver = PathPermissions(environment: try environment(root: home))
    #expect(
      resolver.evaluate(
        path("/people/me/private.txt"), operation: .read,
        principal: client, permissions: .newPrincipal) == .denied(.userData))
    #expect(
      resolver.evaluate(
        path("/people/me/.host/token"), operation: .read,
        principal: client, permissions: .newPrincipal, purpose: .skillLibrary(root: home))
        == .denied(.hostData))
    #expect(
      resolver.evaluate(
        path("/people/me/private.txt"), operation: .write,
        principal: client, permissions: .newPrincipal, purpose: .skillLibrary(root: home))
        == .denied(.invalidPathRequirement))
  }

  @Test func skillsAndExistingPathBoundariesAreRequiredTogether() throws {
    let local = path("/people/me/repo/.agents/skills")
    var paths = try environment(root: local)
    try paths.setProjects([RegisteredProject(id: "repo", root: path("/people/me/repo"))])
    var ledger = PermissionLedger()
    _ = try ledger.setPermissions(Permissions(), for: client, expectedRevision: ledger.revision)
    var state = ledger.environment
    state.paths = paths
    _ = try ledger.reconcile(environment: state, expectedRevision: ledger.revision)
    let result = try ledger.authorize(
      invocation: invocation(tool: "skills.read", project: "repo"),
      requirements: requirements(root: local, target: local), now: instant)
    guard case .requests(let requests) = result else {
      Issue.record("Expected both the library and project permissions")
      return
    }
    #expect(
      Set(
        requests.compactMap { request -> Permission? in
          if case .permission(let content) = request.content {
            return content.requirement.permission
          }
          return nil
        }) == [.skills, .project("repo")])
    var permissions = Permissions.newPrincipal
    try permissions.set(.denied, for: .project("repo"))
    #expect(
      PathPermissions(environment: paths).evaluate(
        local, operation: .read,
        principal: client, permissions: permissions, purpose: .skillLibrary(root: local))
        == .denied(.permissionDenied(.project("repo"))))
    paths.pathRules.insert(PathRule(root: path("/people/me/repo"), kind: .folder(.documents)))
    try paths.setProjects([])
    #expect(
      PathPermissions(environment: paths).evaluate(
        local, operation: .read,
        principal: client, permissions: .newPrincipal, purpose: .skillLibrary(root: local))
        == .request(
          PermissionRequestContent(
            principal: client,
            requirement: requirement(.filesAndFolders(.documents), .read), scope: .path(local))))
  }

  @Test func pendingCombinedRequestsPinTheLibraryRegistration() throws {
    let local = path("/people/me/repo/.agents/skills")
    var paths = try environment(root: local)
    try paths.setProjects([RegisteredProject(id: "repo", root: path("/people/me/repo"))])
    var ledger = PermissionLedger()
    _ = try ledger.setPermissions(Permissions(), for: client, expectedRevision: ledger.revision)
    var state = ledger.environment
    state.paths = paths
    _ = try ledger.reconcile(environment: state, expectedRevision: ledger.revision)
    guard
      case .requests(let requests) = try ledger.authorize(
        invocation: invocation(tool: "skills.read", project: "repo"),
        requirements: requirements(root: local, target: local), now: instant)
    else {
      Issue.record("Expected missing library permissions")
      return
    }
    state = ledger.environment
    state.paths!.pathRules = state.paths!.pathRules.filter { $0.kind != .skillLibrary }
    _ = try ledger.reconcile(environment: state, expectedRevision: ledger.revision, now: instant)
    #expect(requests.allSatisfy { ledger.requests[$0.id]?.status == .revoked })
  }

  @Test func explicitAndManagedSkillsDenialsCreateNoPathException() throws {
    let resolver = PathPermissions(environment: try environment())
    var permissions = Permissions.newPrincipal
    try permissions.set(.denied, for: .skills)
    #expect(
      resolver.evaluate(
        library, operation: .read, principal: client,
        permissions: permissions, purpose: .skillLibrary(root: library))
        == .denied(.permissionDenied(.skills)))
    let ceilings = try granted([(.skills, .access)])
    var denied = ceilings
    try denied.set(.denied, for: .skills)
    #expect(
      resolver.evaluate(
        library, operation: .read, principal: client,
        permissions: .newPrincipal,
        limits: ManagedLimits(machine: .available(ManagedPolicy(permissionCeilings: denied))),
        purpose: .skillLibrary(root: library)) == .denied(.managedLimit([.machine])))
  }

  @Test(arguments: [false, true])
  func removingOrReplacingRegistrationRevokesSerializedExecutionEvidence(replace: Bool) throws {
    var ledger = PermissionLedger()
    _ = try ledger.setPermissions(.newPrincipal, for: client, expectedRevision: ledger.revision)
    var state = ledger.environment
    state.paths = try environment()
    _ = try ledger.reconcile(environment: state, expectedRevision: ledger.revision)
    let admitted = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "skills.read"), requirements: requirements(), now: instant))
    let running = try ledger.startExecution(
      owner: client, authorizationIDs: [admitted.id], now: instant)
    ledger = try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
    state = ledger.environment
    state.paths!.pathRules = state.paths!.pathRules.filter { $0.kind != .skillLibrary }
    if replace { state.paths!.pathRules.insert(PathRule(root: library, kind: .skillLibrary)) }
    let result = try ledger.reconcile(
      environment: state, expectedRevision: ledger.revision, now: instant)
    #expect(result.executionsToTerminate.contains(running.id))
    state = ledger.environment
    state.paths!.pathRules.insert(PathRule(root: library, kind: .skillLibrary))
    _ = try ledger.reconcile(environment: state, expectedRevision: ledger.revision, now: instant)
    #expect(
      ledger.executionAccess(running.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
    _ = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "skills.read", digest: "fresh"),
        requirements: requirements(), now: instant))
  }

  @Test(arguments: [false, true])
  func processProjectionOpensOnlyAnExplicitLibraryRead(explicitLibrary: Bool) throws {
    var ledger = PermissionLedger()
    _ = try ledger.setPermissions(.newPrincipal, for: client, expectedRevision: ledger.revision)
    var state = ledger.environment
    state.paths = try environment()
    let otherLibrary = path("/people/me/.codex/skills")
    let credentials = path("/people/me/.codex/auth.json")
    state.paths!.pathRules.insert(PathRule(root: otherLibrary, kind: .skillLibrary))
    state.paths!.pathRules.insert(PathRule(root: credentials, kind: .hostData))
    _ = try ledger.reconcile(environment: state, expectedRevision: ledger.revision)
    let admitted = try authorization(
      from: ledger.authorize(
        invocation: invocation(tool: "fixture"),
        requirements: explicitLibrary ? requirements() : .init(actions: [action(.skills)]),
        now: instant))
    let projection = try ledger.prepareExecutionPermissions(admitted.id)
    func opens(_ target: CanonicalPath) -> Bool {
      projection.readablePaths.contains { entry in
        entry.path.contains(target)
          && !(entry.excludedSubtrees ?? []).contains(where: { $0.contains(target) })
      }
    }
    #expect(opens(library) == explicitLibrary)
    #expect(!opens(otherLibrary))
    #expect(!opens(credentials))
    if explicitLibrary {
      #expect(
        projection.readablePaths.contains {
          $0.path == library && $0.location == .skillLibrary(library)
            && $0.purpose == .skillLibrary(root: library)
        })
    }
  }
}
