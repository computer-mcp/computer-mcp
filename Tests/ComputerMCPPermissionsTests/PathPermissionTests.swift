import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ComputerMCPPermissionsPathTests {
  @Test func projectInsideDownloadsNeedsOnlyProject() throws {
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let rules = try granted([(.project("project"), .read)])
    #expect(
      resolver.evaluate(
        path("/people/me/Downloads/repo/file"), operation: .read,
        principal: client, permissions: rules) == .allowed)
    if case .request(let content) = resolver.evaluate(
      path("/people/me/Downloads/other"), operation: .read,
      principal: client, permissions: rules)
    {
      #expect(content.requirement.permission == .filesAndFolders(.downloads))
    } else {
      Issue.record("Files outside the project need Downloads")
    }
  }

  @Test func categoryAncestorIsTraversableUnlessExplicitlyDenied() throws {
    let resolver = PathPermissions(environment: TestPathEnvironment())
    var rules = try granted([(.project("project"), .read)])
    for operation in [PathOperation.openDirectory, .listDirectory] {
      #expect(
        resolver.evaluate(
          path("/people/me/Downloads"), operation: operation,
          principal: client, permissions: rules) == .allowed)
    }
    if case .request = resolver.evaluate(
      path("/people/me/Downloads/other"), operation: .read,
      principal: client, permissions: rules)
    {
    } else {
      Issue.record("Traversal must not grant siblings")
    }
    try rules.set(.denied, for: .filesAndFolders(.downloads))
    #expect(
      resolver.evaluate(
        path("/people/me/Downloads"), operation: .listDirectory,
        principal: client, permissions: rules)
        == .denied(.permissionDenied(.filesAndFolders(.downloads))))
    #expect(
      resolver.evaluate(
        path("/people/me/Downloads/repo/file"), operation: .read,
        principal: client, permissions: rules) == .allowed)
  }

  @Test func deniedProjectOverridesReadableCategoryAndDevelopmentLocation() throws {
    var environment = TestPathEnvironment()
    environment.developerLocations = [path("/people/me/Downloads")]
    let resolver = PathPermissions(environment: environment)
    var rules = try granted([(.filesAndFolders(.downloads), .read), (.project("*"), .write)])
    try rules.set(.denied, for: .project("project"))
    #expect(
      resolver.evaluate(
        path("/people/me/Downloads/repo/file"), operation: .read,
        principal: client, permissions: rules) == .denied(.permissionDenied(.project("project"))))
    #expect(
      resolver.evaluate(
        path("/people/me/Downloads/other"), operation: .read,
        principal: client, permissions: rules) == .allowed)
  }

  @Test(
    arguments: [
      "/people/me/Downloads/repo/host", "/people/me/Downloads/host",
      "/people/me/toolchains/swift/host",
      "/system/host", "/outside/host", "/people/me/tasks/job/host",
    ], [ExecutionMode.sandbox, .fullAccess(.standing)])
  func hostDataWinsEverywhere(location: String, mode: ExecutionMode) throws {
    var environment = TestPathEnvironment()
    environment.hostDataLocations = [path(location)]
    let rules = try granted([(.project("*"), .write), (.filesAndFolders(.downloads), .read)])
    let resolver = PathPermissions(environment: environment)
    for operation in [PathOperation.read, .write, .openDirectory, .listDirectory] {
      #expect(
        resolver.evaluate(
          path(location + "/secret"), operation: operation,
          principal: client, permissions: rules, mode: mode) == .denied(.hostData))
    }
  }

  @Test func ancestorsAreDirectoryOnlyAndDoNotOpenSiblings() throws {
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let rules = try granted([(.project("project"), .read)])
    for ancestor in ["/people", "/people/me", "/people/me/tasks", "/people/me/toolchains"] {
      for operation in [PathOperation.openDirectory, .listDirectory] {
        #expect(
          resolver.evaluate(
            path(ancestor), operation: operation, principal: client, permissions: rules) == .allowed
        )
      }
      #expect(
        resolver.evaluate(path(ancestor), operation: .read, principal: client, permissions: rules)
          == .denied(.userData))
      #expect(
        resolver.evaluate(
          path(ancestor + "/private-file"), operation: .read,
          principal: client, permissions: rules) == .denied(.userData))
    }
  }

  @Test func explicitDenialsWinOverDirectoryTraversalAndDevelopmentLocations() throws {
    var environment = TestPathEnvironment()
    environment.deniedLocations = [path("/people/me/tasks"), path("/people/me/toolchains")]
    let resolver = PathPermissions(environment: environment)
    let rules = try granted([(.project("project"), .read)])
    #expect(
      resolver.evaluate(
        path("/people/me/tasks"), operation: .listDirectory,
        principal: client, permissions: rules) == .denied(.deniedLocation))
    #expect(
      resolver.evaluate(
        path("/people/me/toolchains/swift/compiler"), operation: .read,
        principal: client, permissions: rules) == .denied(.deniedLocation))
    let limits = ManagedLimits(
      machine: .available(ManagedPolicy(deniedReadLocations: [path("/people")])))
    #expect(
      resolver.evaluate(
        path("/people"), operation: .openDirectory,
        principal: client, permissions: rules, limits: limits) == .denied(.managedLimit([.machine]))
    )
  }

  @Test func sandboxDeniedReadsAndMainCheckoutWrites() throws {
    let resolver = PathPermissions(environment: TestPathEnvironment())
    let rules = try granted([(.project("project"), .write)])
    let main = path("/people/me/Downloads/repo/file")
    let derived = path("/people/me/tasks/job/file")
    #expect(
      resolver.evaluate(main, operation: .write, principal: client, permissions: rules)
        == .denied(.mainProjectWrite))
    #expect(
      resolver.evaluate(derived, operation: .write, principal: client, permissions: rules)
        == .allowed)
    #expect(
      resolver.evaluate(
        main, operation: .write, principal: client, permissions: rules,
        mode: .fullAccess(.standing)) == .allowed)
    let settings = SandboxSettings(deniedReadLocations: [path("/people/me/tasks")])
    #expect(
      resolver.evaluate(
        derived, operation: .read, principal: client, permissions: rules,
        sandbox: settings) == .denied(.deniedLocation))
    #expect(
      resolver.evaluate(
        derived, operation: .read, principal: client, permissions: rules,
        mode: .fullAccess(.standing), sandbox: settings) == .allowed)
  }

  @Test func readableSystemAndDevelopmentLocationsLeaveUserDataClosed() throws {
    let resolver = PathPermissions(environment: TestPathEnvironment())
    for location in [
      "/system/library", "/apps/editor", "/people/me/toolchains/swift/bin", "/runtime/lib",
    ] {
      #expect(
        resolver.evaluate(path(location), operation: .read, principal: client, permissions: .init())
          == .allowed)
      #expect(
        resolver.evaluate(
          path(location), operation: .write, principal: client, permissions: .init())
          == .denied(.readOnlyLocation))
    }
    #expect(
      resolver.evaluate(
        path("/people/me/secret"), operation: .read,
        principal: client, permissions: .init()) == .denied(.userData))
    #expect(
      resolver.evaluate(
        path("/volumes/private/file"), operation: .read,
        principal: client, permissions: .init()) == .denied(.userData))
    #expect(
      resolver.evaluate(
        path("/people/me/toolchains/swift-other/file"), operation: .read,
        principal: client, permissions: .init()) == .denied(.userData))
  }

  @Test func nestedProjectsAreProjectedIntoDerivedProjectsAndResolveLive() throws {
    var environment = TestPathEnvironment()
    environment.projects = try ProjectCatalog(
      environment.projects.projects + [
        RegisteredProject(id: "nested", root: path("/people/me/Downloads/repo/nested"))
      ])
    let resolver = PathPermissions(environment: environment)
    var rules = try granted([(.project("project"), .write)])
    try rules.set(.denied, for: .project("nested"))
    #expect(
      environment.projects.location(at: path("/people/me/tasks/job/nested/file"))?.projectID
        == "nested")
    #expect(
      resolver.evaluate(
        path("/people/me/tasks/job/nested/file"), operation: .read,
        principal: client, permissions: rules) == .denied(.permissionDenied(.project("nested"))))
    try rules.set(.granted(.read), for: .project("nested"))
    #expect(
      resolver.evaluate(
        path("/people/me/tasks/job/nested/file"), operation: .read,
        principal: client, permissions: rules) == .allowed)
    try rules.set(.denied, for: .project("project"))
    #expect(
      resolver.evaluate(
        path("/people/me/tasks/job/file"), operation: .read,
        principal: client, permissions: rules) == .denied(.permissionDenied(.project("project"))))
  }

  @Test func trackedNestedProjectsCannotBeNarrower() throws {
    let catalog = try ProjectCatalog([
      RegisteredProject(id: "outer", root: path("/repo")),
      RegisteredProject(id: "inner", root: path("/repo/inner")),
    ])
    let nesting = [TrackedProjectNesting(innerID: "inner", outerID: "outer")]
    var rules = try granted([(.project("outer"), .write), (.project("inner"), .read)])
    #expect(
      throws: PermissionModelError.narrowerNestedProject(
        inner: "inner", outer: "outer", principal: client)
    ) {
      try catalog.validate(nesting: nesting, permissions: [client: rules])
    }
    try catalog.validate(nesting: [], permissions: [client: rules])
    try rules.set(.granted(.write), for: .project("inner"))
    try catalog.validate(nesting: nesting, permissions: [client: rules])
  }

  @Test func derivedSandboxSettingsInheritPerPrincipalAtEachRead() throws {
    let projects = TestPathEnvironment().projects
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    var settings = ProjectSandboxSettings(entries: [key: SandboxSettings(network: .trusted)])
    #expect(
      try settings.settings(for: client, projectID: "derived", projects: projects).network
        .configuration
        == .trusted)
    #expect(
      try settings.settings(for: otherClient, projectID: "derived", projects: projects).network
        .configuration
        == .none)
    settings.entries[key] = SandboxSettings(network: .none, deniedReadLocations: [path("/secret")])
    #expect(
      try settings.settings(for: client, projectID: "derived", projects: projects)
        == settings.entries[key])
    #expect(throws: PermissionModelError.invalidProjectGraph) {
      try settings.settings(for: client, projectID: "missing", projects: projects)
    }
  }

  @Test(arguments: ["relative", "/a/../b", "/a/./b", "/a//b", "/a/", "/a\0b"])
  func rejectsNonCanonicalPaths(value: String) {
    #expect(throws: PermissionModelError.invalidPath) { try CanonicalPath(value) }
  }

  @Test func invalidProjectGraphsAreRejected() {
    #expect(throws: PermissionModelError.invalidProjectGraph) {
      try ProjectCatalog([RegisteredProject(id: "a", root: path("/a"), sourceID: "missing")])
    }
    #expect(throws: PermissionModelError.invalidProjectGraph) {
      try ProjectCatalog([
        RegisteredProject(id: "a", root: path("/a"), sourceID: "b"),
        RegisteredProject(id: "b", root: path("/b"), sourceID: "a"),
      ])
    }
  }
}
