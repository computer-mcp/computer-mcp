import ComputerMCPPermissions
import Foundation
import Testing

struct ComputerMCPPermissionsEnvironmentIdentityTests {
  private func restore(_ ledger: PermissionLedger, when enabled: Bool) throws -> PermissionLedger {
    enabled
      ? try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger)) : ledger
  }

  @Test(arguments: [false, true])
  func consumedRetryCannotLoseEnvironmentRevocation(restored: Bool) throws {
    var ledger = PermissionLedger()
    var environment = PermissionEnvironment()
    environment.trustedHosts = [HostRule("service")]
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .trusted),
      for: SandboxSettingsKey(principal: client, projectID: "project"),
      expectedRevision: ledger.revision)
    let pending = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(), host: "service",
        sourceProjectID: "project", isLocalNetwork: true, now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(), host: "service",
        sourceProjectID: "project", isLocalNetwork: true, retryIDs: [pending.id], now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    ledger = try restore(ledger, when: restored)
    environment.trustedHosts = []
    #expect(
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
        .executionsToTerminate == [execution.id])
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.authorizeNetwork(
        invocation: invocation(), host: "service", sourceProjectID: "project",
        isLocalNetwork: true, retryIDs: [pending.id], now: instant)
    }
    #expect(throws: PermissionModelError.unknownRequest) {
      try ledger.answer(UUID(), with: .always, now: instant)
    }
    #expect(throws: PermissionModelError.unknownAuthorization) {
      try ledger.startExecution(owner: client, authorizationIDs: [UUID()])
    }
    ledger = try restore(ledger, when: restored)
    #expect(
      ledger.executionAccess(execution.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
    #expect(ledger.pendingExecutionTerminations == [execution.id])
  }

  @Test(arguments: [false, true], ["permission", "path", "network", "sandbox", "projectOrder"])
  func consentPinsEveryProfileDimension(restored: Bool, dimension: String) throws {
    var ledger = PermissionLedger()
    var environment = PermissionEnvironment()
    let projects = [
      RegisteredProject(id: "A", root: path("/a")),
      RegisteredProject(id: "C", root: path("/a/x/y")),
      RegisteredProject(id: "B", root: path("/b")),
      RegisteredProject(id: "E", root: path("/b/y")),
      RegisteredProject(id: "DA", root: path("/d"), sourceID: "A"),
      RegisteredProject(id: "DB", root: path("/d/x"), sourceID: "B"),
    ]
    environment.paths = try PathEnvironmentSnapshot(projects: projects)
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    let consent = ledger.consent(for: client, mode: .fullAccess(.standing))
    environment.modes[client] = consent
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    let originalEnvironment = environment
    let allowed = try authorization(
      from: ledger.authorize(invocation: invocation(), actions: [action(.skills)], now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    ledger = try restore(ledger, when: restored)
    switch dimension {
    case "permission":
      try ledger.setPermission(
        .granted(.access), for: .screen, principal: client, expectedRevision: ledger.revision)
    case "path":
      environment.paths!.pathRules.insert(PathRule(root: path("/tools"), kind: .developer))
    case "network": environment.trustedHosts.insert(HostRule("service"))
    case "sandbox":
      _ = try ledger.setSandboxSettings(
        SandboxSettings(deniedReadLocations: [path("/secret")]),
        for: SandboxSettingsKey(principal: client, projectID: "unrelated"),
        expectedRevision: ledger.revision)
    default:
      var reordered = environment.paths!.registeredProjects
      reordered.swapAt(4, 5)
      #expect(environment.paths!.projects.location(at: path("/d/x/y"))?.projectID == "C")
      try environment.paths!.setProjects(reordered)
      #expect(environment.paths!.projects.location(at: path("/d/x/y"))?.projectID == "E")
    }
    #expect(
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
        .executionsToTerminate == [execution.id])
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    }
    ledger = try restore(ledger, when: restored)
    #expect(
      try ledger.authorize(
        invocation: invocation(digest: "fresh"), actions: [action(.skills)], now: instant)
        == .denied(.authorizationRevoked))
    // Publishing the original environment cannot renew a retired consent.
    try ledger.reconcile(environment: originalEnvironment, expectedRevision: ledger.revision)
    #expect(
      try ledger.authorize(invocation: invocation(), actions: [action(.skills)], now: instant)
        == .denied(.authorizationRevoked))
    environment = ledger.environment
    environment.modes[client] = ledger.consent(for: client, mode: .fullAccess(.standing))
    #expect(environment.modes[client]?.identity != consent.identity)
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    let fresh = try authorization(
      from: ledger.authorize(
        invocation: invocation(digest: "fresh"), actions: [action(.skills)], now: instant))
    _ = try ledger.startExecution(owner: client, authorizationIDs: [fresh.id])
    #expect(ledger.pendingExecutionTerminations == [execution.id])
  }

  @Test(arguments: [false, true], ["full", "trusted", "custom"])
  func effectiveNetworkKeepsPendingRequestsAndEvidenceStable(restored: Bool, source: String) throws
  {
    var ledger = PermissionLedger()
    var environment = PermissionEnvironment()
    environment.trustedHosts = [HostRule("service")]
    environment.limits[client] = ManagedLimits(owner: .available(ManagedPolicy(network: .full)))
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    let network: NetworkAccess =
      source == "full"
      ? .full
      : source == "trusted" ? .trusted : .custom(hosts: ["service"], includesTrusted: false)
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: network),
      for: SandboxSettingsKey(principal: client, projectID: "project"),
      expectedRevision: ledger.revision)
    let first = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(), host: "service",
        sourceProjectID: "project", isLocalNetwork: true, now: instant))
    ledger = try restore(ledger, when: restored)
    let repeated = try request(
      from: ledger.authorizeNetwork(
        invocation: invocation(), host: "service",
        sourceProjectID: "project", isLocalNetwork: true, now: instant))
    #expect(first.id == repeated.id)
    #expect(ledger.requests.count == 1)
    try ledger.answer(first.id, with: .onlyThisTime, now: instant)
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(), host: "service",
        sourceProjectID: "project", isLocalNetwork: true, retryIDs: [first.id], now: instant))
    let basis = allowed.basis
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    for _ in 0..<3 {
      try ledger.reconcile(environment: ledger.environment, expectedRevision: ledger.revision)
      #expect(
        ledger.executionAccess(
          execution.id, principal: client, operation: .readResult, now: instant) == .allowed)
    }
    #expect(ledger.authorizations[allowed.id]?.basis == basis)
    #expect(ledger.pendingExecutionTerminations.isEmpty)
  }

  @Test(
    arguments: [false, true],
    [
      "custom", "trusted", "trustedSelector", "full", "managedCustom", "managedTrusted",
      "managedFull", "managedEntry",
    ])
  func recreatedNetworkEvidenceCannotAuthorizeOldExecution(restored: Bool, source: String) throws {
    var ledger = PermissionLedger()
    var environment = PermissionEnvironment()
    environment.trustedHosts = [HostRule("service")]
    var policy = ManagedPolicy(
      network: source == "managedFull"
        ? .full
        : source == "managedTrusted"
          ? .trusted : .custom(hosts: ["service"], includesTrusted: false))
    if source.hasPrefix("managed") {
      environment.limits[client] = ManagedLimits(owner: .available(policy))
    }
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    if case .available(let committed) = environment.limits[client]?.sources[.owner] {
      policy = committed
    }
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    let network: NetworkAccess =
      source.hasPrefix("trusted")
      ? .trusted : source == "full" ? .full : .custom(hosts: ["service"], includesTrusted: false)
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: network), for: key, expectedRevision: ledger.revision)
    let allowed = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(), host: "service",
        sourceProjectID: "project", isLocalNetwork: false, now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    ledger = try restore(ledger, when: restored)
    switch source {
    case "trusted":
      let old = try #require(environment.trustedHosts.first)
      environment.trustedHosts = [HostRule("service")]
      #expect(environment.trustedHosts.first?.identity != old.identity)
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      environment = ledger.environment
    case "managedCustom", "managedTrusted", "managedFull":
      let original = policy.identity
      policy.network =
        source == "managedFull"
        ? .full
        : source == "managedTrusted"
          ? .trusted : policy.network.removing("service").adding("service")
      #expect(policy.identity.id == original.id)
      #expect(policy.identity.generation == original.generation)
      environment.limits[client] = ManagedLimits(owner: .available(policy))
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      environment = ledger.environment
      if case .available(let committed) = environment.limits[client]?.sources[.owner] {
        #expect(committed.identity.id == original.id)
        #expect(committed.identity.generation > original.generation)
      }
    case "managedEntry":
      environment.limits[client] = ManagedLimits(
        owner: .available(
          ManagedPolicy(network: .custom(hosts: ["service"], includesTrusted: false))))
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      environment = ledger.environment
    default:
      let replacement: NetworkAccess =
        source == "full"
        ? .full
        : source == "trustedSelector" ? .trusted : network.removing("service").adding("service")
      _ = try ledger.setSandboxSettings(
        SandboxSettings(network: replacement), for: key, expectedRevision: ledger.revision)
    }
    #expect(ledger.pendingExecutionTerminations == [execution.id])
    ledger = try restore(ledger, when: restored)
    #expect(
      ledger.executionAccess(execution.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
    let fresh = try authorization(
      from: ledger.authorizeNetwork(
        invocation: invocation(digest: "fresh"), host: "service",
        sourceProjectID: "project", isLocalNetwork: false, now: instant))
    _ = try ledger.startExecution(owner: client, authorizationIDs: [fresh.id])
  }

  @Test(
    arguments: [false, true],
    [
      "project", "folder", "developer", "system", "userData", "outside", "exclusion",
      "deniedExclusion",
    ])
  func recreatedPathEvidenceRetiresExecutions(restored: Bool, source: String) throws {
    var ledger = PermissionLedger()
    let root = path("/root")
    let kind: PathRule.Kind =
      source == "folder"
      ? .folder(.documents)
      : source == "system" ? .systemOrApplication : source == "userData" ? .userData : .developer
    var rule = PathRule(root: root, kind: kind)
    var excluded = PathRule(
      root: path("/root/private"),
      kind: source == "deniedExclusion" ? .denied : .hostData)
    var paths = try PathEnvironmentSnapshot(rules: [rule])
    if source == "project" { try paths.setProjects([RegisteredProject(id: "project", root: root)]) }
    if source == "outside" { paths.pathRules = [] }
    if source == "userData" {
      paths.pathRules.insert(PathRule(root: path("/root/tools"), kind: .developer))
    }
    if source == "exclusion" || source == "deniedExclusion" { paths.pathRules.insert(excluded) }
    var environment = PermissionEnvironment()
    environment.paths = paths
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    paths = try #require(environment.paths)
    rule = paths.pathRules.first { $0.root == root && $0.kind == kind } ?? rule
    excluded =
      paths.pathRules.first { $0.root == excluded.root && $0.kind == excluded.kind } ?? excluded
    try ledger.setPermission(
      .granted(.read), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    try ledger.setPermission(
      .granted(.read), for: .filesAndFolders(.documents), principal: client,
      expectedRevision: ledger.revision)
    let requirements = InvocationRequirements(paths: [
      PathRequirement(path: root, operation: source == "userData" ? .listDirectory : .read)
    ])
    let allowed = try authorization(
      from: ledger.authorize(invocation: invocation(), requirements: requirements, now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    ledger = try restore(ledger, when: restored)
    switch source {
    case "project": try paths.setProjects([RegisteredProject(id: "project", root: root)])
    case "outside": paths = try PathEnvironmentSnapshot()
    case "exclusion", "deniedExclusion":
      paths.pathRules.remove(excluded)
      paths.pathRules.insert(PathRule(root: excluded.root, kind: excluded.kind))
    default:
      paths.pathRules.remove(rule)
      paths.pathRules.insert(PathRule(root: root, kind: kind))
    }
    environment.paths = paths
    #expect(
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
        .executionsToTerminate == [execution.id])
    ledger = try restore(ledger, when: restored)
    #expect(
      ledger.executionAccess(execution.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
    _ = try authorization(
      from: ledger.authorize(
        invocation: invocation(digest: "fresh"), requirements: requirements, now: instant))
  }

  @Test(arguments: [false, true])
  func requestsPermitsAndGrantsHaveDistinctCreationIdentities(restored: Bool) throws {
    var ledger = PermissionLedger()
    let first = try request(
      from: ledger.authorize(invocation: invocation(), actions: [action()], now: instant))
    try ledger.answer(first.id, with: .onlyThisTime, now: instant)
    let firstPermit = try #require(ledger.requests[first.id]?.permitIdentity)
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action()], retryIDs: [first.id], now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    _ = try ledger.revokeAuthorization(allowed.id)
    ledger = try restore(ledger, when: restored)
    let second = try request(
      from: ledger.authorize(invocation: invocation(), actions: [action()], now: instant))
    try ledger.answer(second.id, with: .onlyThisTime, now: instant)
    #expect(first.identity != second.identity)
    #expect(firstPermit != ledger.requests[second.id]?.permitIdentity)
    let fresh = try authorization(
      from: ledger.authorize(
        invocation: invocation(), actions: [action()], retryIDs: [second.id], now: instant))
    #expect(allowed.identity != fresh.identity)
    #expect(ledger.pendingExecutionTerminations == [execution.id])
    _ = try ledger.startExecution(owner: client, authorizationIDs: [fresh.id])
  }
  @Test(arguments: [false, true], [FullAccessScope.standing, .connection("connection")])
  func sameScopeConsentIsANewBasis(restored: Bool, scope: FullAccessScope) throws {
    var ledger = PermissionLedger()
    var environment = PermissionEnvironment()
    let consent = ledger.consent(for: client, mode: .fullAccess(scope))
    environment.modes[client] = consent
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    let allowed = try authorization(
      from: ledger.authorize(invocation: invocation(), actions: [action(.skills)], now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    ledger = try restore(ledger, when: restored)
    environment.modes[client] = ledger.consent(for: client, mode: .fullAccess(scope))
    #expect(environment.modes[client]?.identity != consent.identity)
    #expect(
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
        .executionsToTerminate == [execution.id])
    environment.modes[client] = consent
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    ledger = try restore(ledger, when: restored)
    #expect(
      try ledger.authorize(invocation: invocation(), actions: [action(.skills)], now: instant)
        == .denied(.authorizationRevoked))
  }

  @Test(arguments: [false, true], ["host", "path", "project", "grant"])
  func editsKeepUUIDAndAdvanceGeneration(restored: Bool, source: String) throws {
    var ledger = PermissionLedger()
    var environment = PermissionEnvironment()
    var host = HostRule("service")
    var rule = PathRule(root: path("/tools"), kind: .developer)
    var project = RegisteredProject(id: "project", root: path("/project"))
    environment.trustedHosts = [host]
    environment.paths = try PathEnvironmentSnapshot(projects: [project], rules: [rule])
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    host = try #require(environment.trustedHosts.first)
    rule = try #require(environment.paths?.pathRules.first)
    project = try #require(environment.paths?.registeredProjects.first)
    try ledger.setPermission(
      .granted(.write), for: .project("project"), principal: client,
      expectedRevision: ledger.revision)
    _ = try ledger.setSandboxSettings(
      SandboxSettings(network: .trusted),
      for: SandboxSettingsKey(principal: client, projectID: "project"),
      expectedRevision: ledger.revision)
    let requirements: InvocationRequirements
    switch source {
    case "host":
      requirements = InvocationRequirements(networks: [
        NetworkRequirement(host: "service", projectID: "project", isLocalNetwork: false)
      ])
    case "path":
      requirements = InvocationRequirements(paths: [
        PathRequirement(path: rule.root, operation: .read)
      ])
    case "project":
      requirements = InvocationRequirements(paths: [
        PathRequirement(path: project.root, operation: .read)
      ])
    default: requirements = InvocationRequirements(actions: [action(.project("project"), .read)])
    }
    let allowed = try authorization(
      from: ledger.authorize(invocation: invocation(), requirements: requirements, now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    ledger = try restore(ledger, when: restored)
    switch source {
    case "host":
      var edited = host
      edited.host = "other"
      edited.host = host.host
      #expect(edited.identity.id == host.identity.id)
      #expect(edited.identity.generation == host.identity.generation)
      environment.trustedHosts = [edited]
    case "path":
      var edited = rule
      edited.root = path("/other")
      edited.root = rule.root
      #expect(edited.identity.id == rule.identity.id)
      #expect(edited.identity.generation == rule.identity.generation)
      environment.paths!.pathRules = [edited]
    case "project":
      var edited = project
      edited.root = path("/other")
      edited.root = project.root
      #expect(edited.identity.id == project.identity.id)
      #expect(edited.identity.generation == project.identity.generation)
      try environment.paths!.setProjects([edited])
    default:
      try ledger.setPermission(
        .granted(.read), for: .project("project"), principal: client,
        expectedRevision: ledger.revision)
      let fresh = try authorization(
        from: ledger.authorize(
          invocation: invocation(digest: "fresh"), requirements: requirements, now: instant))
      func grant(_ authorization: InvocationAuthorization) throws -> BasisIdentity {
        try #require(
          authorization.basis.compactMap {
            if case .permission(let grant) = $0, case .standing(_, let identity) = grant.source {
              return identity
            }
            return nil
          }.first)
      }
      #expect(try grant(allowed).id == grant(fresh).id)
      #expect(try grant(fresh).generation > grant(allowed).generation)
    }
    #expect(
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
        .executionsToTerminate == [execution.id])
    let committed: BasisIdentity?
    let original: BasisIdentity?
    switch source {
    case "host":
      committed = ledger.environment.trustedHosts.first?.identity
      original = host.identity
    case "path":
      committed = ledger.environment.paths?.pathRules.first?.identity
      original = rule.identity
    case "project":
      committed = ledger.environment.paths?.registeredProjects.first?.identity
      original = project.identity
    default:
      committed = nil
      original = nil
    }
    if let committed, let original {
      #expect(committed.id == original.id)
      #expect(committed.generation > original.generation)
    }
    ledger = try restore(ledger, when: restored)
    #expect(
      ledger.executionAccess(execution.id, principal: client, operation: .readResult, now: instant)
        == .denied(.authorizationRevoked))
  }

  @Test(arguments: [false, true], [false, true])
  func recreatedDeniedReadRulesRetireExecution(restored: Bool, managed: Bool) throws {
    var ledger = PermissionLedger()
    let root = path("/secret")
    let key = SandboxSettingsKey(principal: client, projectID: "project")
    var environment = PermissionEnvironment()
    var policy = ManagedPolicy(deniedReadLocations: [root])
    var settings = SandboxSettings(deniedReadLocations: [root])
    if managed { environment.limits[client] = ManagedLimits(owner: .available(policy)) }
    try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    environment = ledger.environment
    if !managed {
      _ = try ledger.setSandboxSettings(settings, for: key, expectedRevision: ledger.revision)
    }
    if case .available(let committed) = ledger.environment.limits[client]?.sources[.owner] {
      policy = committed
    }
    if let committed = ledger.sandboxSettings.entries[key] { settings = committed }
    let allowed = try authorization(
      from: ledger.authorize(
        invocation: invocation(),
        actions: [action(.skills)], now: instant))
    let execution = try ledger.startExecution(owner: client, authorizationIDs: [allowed.id])
    ledger = try restore(ledger, when: restored)
    if managed {
      let identity = try #require(policy.deniedReadRules.first?.identity)
      policy.deniedReadLocations = []
      policy.deniedReadLocations = [root]
      #expect(policy.deniedReadRules.first?.identity != identity)
      environment.limits[client] = ManagedLimits(owner: .available(policy))
      try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      environment = ledger.environment
    } else {
      let identity = try #require(settings.deniedReadRules.first?.identity)
      settings.deniedReadLocations = []
      settings.deniedReadLocations = [root]
      #expect(settings.deniedReadRules.first?.identity != identity)
      _ = try ledger.setSandboxSettings(settings, for: key, expectedRevision: ledger.revision)
    }
    #expect(ledger.pendingExecutionTerminations == [execution.id])
    ledger = try restore(ledger, when: restored)
    #expect(
      ledger.executionAccess(
        execution.id, principal: client, operation: .readResult,
        now: instant) == .denied(.authorizationRevoked))
  }

  @Test func pathCatalogValidationSurvivesDecoding() throws {
    let project = RegisteredProject(id: "project", root: path("/project"))
    var paths = try PathEnvironmentSnapshot(projects: [project])
    #expect(throws: PermissionModelError.invalidProjectGraph) {
      try paths.setProjects([project, project])
    }
    #expect(paths.registeredProjects == [project])
    var encoded = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(paths)) as? [String: Any])
    let projects = try #require(encoded["registeredProjects"] as? [Any])
    encoded["registeredProjects"] = projects + projects
    let data = try JSONSerialization.data(withJSONObject: encoded)
    #expect(throws: PermissionModelError.invalidProjectGraph) {
      try JSONDecoder().decode(PathEnvironmentSnapshot.self, from: data)
    }
  }

}
