import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPPlugins
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPPermissions
@testable import ComputerMCPPersistence

struct GatewayProviderApprovalTests {
  @Test func missingProviderApprovalReportsTheRequiredOwnerAction() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let server = MCPServerConfig(id: "unapproved", transport: .stdio, command: "/bin/false")
    let review = try GatewayProviderReview(
      server: server, configuration: f.database.configurationState())
    try f.store.readWithDatabase { database, ledger in
      do {
        _ = try GatewayPermissionService.executionApproval(
          review: review, database: database, ledger: ledger)
        Issue.record("An unapproved provider was admitted")
      } catch let error as GatewayToolError {
        #expect(error.localizedDescription.contains("[provider.approval_required]"))
        #expect(error.localizedDescription.contains("owner approval"))
      }
      #expect(try ProviderAuthorityRecord.fetchCount(database) == 0)
    }
  }

  @Test func admissionAuditKeepsDistinctProviderPolicyRevisions() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    for name in ["one", "two"] {
      let server = MCPServerConfig(id: name, transport: .stdio, command: "/bin/false")
      _ = try f.approve(
        .init(server: server, configuration: f.database.configurationState()),
        permissions: .newPrincipal)
    }
    _ = try f.view()
    try f.store.readWithDatabase { database, ledger in
      let evidence = try GatewayPermissionAuditEvidence(
        database: database, ledger: ledger, profileID: .localAdmin)
      let rows = try Row.fetchAll(
        database, sql: "SELECT source, payload FROM permissionPolicySources")
      var providers = 0
      for row in rows {
        let view = try JSONDecoder().decode(
          GatewayManagedPolicyView.self, from: row["payload"] as Data)
        if view.provider != nil {
          providers += 1
          #expect(evidence.policyRevisions[row["source"] as String] == view.revision)
        }
      }
      #expect(providers == 2)
    }
  }

  #if os(Linux)
    @Test func linuxExplicitlyRefusesProviderActivation() throws {
      let f = try ProviderApprovalFixture()
      defer { f.remove() }
      let server = MCPServerConfig(id: "linux", transport: .stdio, command: "/bin/false")
      _ = try f.approve(
        .init(server: server, configuration: f.database.configurationState()),
        permissions: .newPrincipal)
      do {
        _ = try GatewayProviderSource.resolve(
          registration: .init(kind: .mcp, id: server.id),
          configuration: .init(mcp: .init(servers: [server])), origins: [:], database: f.database)
        Issue.record("Linux activated a local provider")
      } catch {
        #expect(error.localizedDescription.contains("Linux provider activation is unavailable"))
      }
    }
  #endif

  @Test(arguments: [true, false])
  func callbackEffectsRequireBothAuthoritiesAndExplicitRetry(missingProvider: Bool) throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let server = MCPServerConfig(id: "callbacks", transport: .stdio, command: "/bin/false")
    var permissions = Permissions.newPrincipal
    if !missingProvider { try permissions.set(.granted(.access), for: .screen) }
    _ = try f.approve(
      .init(server: server, configuration: f.database.configurationState()),
      permissions: permissions)
    let source = GatewayProviderSource(
      review: try .init(server: server, configuration: f.database.configurationState()),
      registrationID: server.id, workingDirectory: nil, executable: nil, resources: [],
      validate: {})
    let caller = Principal.client("callback-caller")
    let delegation = PermissionAction(requirement: try .init(.mcpServer(server.id), .all))
    let parent = try f.store.transactionWithDatabase { database, ledger in
      try ledger.setPermission(
        .granted(.all), for: .mcpServer(server.id), principal: caller,
        expectedRevision: ledger.revision)
      if missingProvider {
        try ledger.setPermission(
          .granted(.access), for: .screen, principal: caller,
          expectedRevision: ledger.revision)
      }
      let (_, optionalAdmission) = try GatewayPermissionService.admitProviderCall(
        source: source,
        invocation: .init(
          principal: caller, tool: "run", projectID: nil,
          argumentsDigest: "parent"), requirements: .init(actions: [delegation]),
        retryIDs: [], connectionID: nil, now: Date(), database: database, ledger: &ledger)
      let admitted = try #require(optionalAdmission)
      return try ledger.startExecution(
        owner: caller, delegatedTo: admitted.identity,
        authorizationIDs: admitted.authorizationIDs)
    }
    let requestID = try f.store.transactionWithDatabase { database, ledger in
      let (decision, admitted) = try GatewayPermissionService.admitProviderCall(
        source: source,
        invocation: .init(
          principal: caller, tool: "screen.capture", projectID: nil,
          argumentsDigest: "callback"),
        requirements: .init(actions: [delegation, .init(requirement: .init(.screen, .access))]),
        retryIDs: [], connectionID: nil, now: Date(), database: database, ledger: &ledger,
        callbackExecutionID: parent.id)
      #expect(admitted == nil)
      guard case .requests(let requests) = decision else {
        throw PermissionModelError.invalidAuthorization
      }
      let request = try #require(requests.first)
      #expect(
        request.invocation.principal
          == (missingProvider ? .plugin(.localServer(server.id)) : caller))
      try ledger.answer(request.id, with: .onlyThisTime, now: Date())
      return request.id
    }
    try f.store.transactionWithDatabase { database, ledger in
      let (_, optionalBinding) = try GatewayPermissionService.admitProviderCall(
        source: source,
        invocation: .init(
          principal: caller, tool: "screen.capture", projectID: nil,
          argumentsDigest: "callback"),
        requirements: .init(actions: [delegation, .init(requirement: .init(.screen, .access))]),
        retryIDs: [requestID], connectionID: nil, now: Date(), database: database, ledger: &ledger,
        callbackExecutionID: parent.id)
      let binding = try #require(optionalBinding)
      #expect(binding.providerAuthorization.basis.contains(.execution(parent.id)))
      #expect(binding.delegatingAuthorization?.basis.contains(.execution(parent.id)) == true)
      let child = try ledger.startExecution(
        owner: caller, delegatedTo: binding.identity,
        authorizationIDs: binding.authorizationIDs)
      try ledger.interruptExecution(parent.id)
      #expect(!ledger.pendingExecutionTerminations.contains(child.id))
      #expect(ledger.executions[child.id]?.isRunning == true)
    }
  }

  @Test func providerRequestDoesNotConsumeTheDelegatorsOneTimeGrant() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let server = MCPServerConfig(id: "atomic", transport: .stdio, command: "/bin/false")
    let initial = try GatewayProviderReview(
      server: server, configuration: f.database.configurationState())
    _ = try f.approve(initial, permissions: .newPrincipal)
    let source = GatewayProviderSource(
      review: try .init(server: server, configuration: f.database.configurationState()),
      registrationID: server.id, workingDirectory: nil, executable: nil, resources: [],
      validate: {})
    let principal = Principal.client("atomic-caller")
    let invocation = InvocationIdentity(
      principal: principal, tool: "screen", projectID: nil,
      argumentsDigest: "atomic")
    let requirements = InvocationRequirements(actions: [
      .init(requirement: try .init(.mcpServer(server.id), .all)),
      .init(requirement: try .init(.screen, .access)),
    ])
    let clientRequest = try f.store.transactionWithDatabase { _, ledger in
      try ledger.setPermission(
        .granted(.access), for: .screen, principal: principal,
        expectedRevision: ledger.revision)
      guard
        case .requests(let requests) = try ledger.authorize(
          invocation: invocation,
          requirements: requirements, now: Date()), let request = requests.first
      else {
        throw PermissionModelError.invalidAuthorization
      }
      try ledger.answer(request.id, with: .onlyThisTime, now: Date())
      return request.id
    }
    let providerRequest = try f.store.transactionWithDatabase { database, ledger in
      let (decision, binding) = try GatewayPermissionService.admitProviderCall(
        source: source, invocation: invocation, requirements: requirements,
        retryIDs: [clientRequest], connectionID: nil, now: Date(), database: database,
        ledger: &ledger)
      #expect(binding == nil)
      #expect(ledger.requests[clientRequest]?.status == .onlyThisTime)
      guard case .requests(let requests) = decision, let request = requests.first else {
        throw PermissionModelError.invalidAuthorization
      }
      #expect(request.invocation.principal == .plugin(.localServer(server.id)))
      return request.id
    }
    _ = try f.service.answerRequest(
      providerRequest, answer: .onlyThisTime, owner: f.owner,
      expectedRevision: f.view().revision)
    try f.store.transactionWithDatabase { database, ledger in
      let (decision, binding) = try GatewayPermissionService.admitProviderCall(
        source: source, invocation: invocation, requirements: requirements,
        retryIDs: [clientRequest, providerRequest], connectionID: nil, now: Date(),
        database: database, ledger: &ledger)
      let provider = try #require(binding)
      guard case .allowed(let caller) = decision else {
        throw PermissionModelError.invalidAuthorization
      }
      #expect(ledger.requests[clientRequest]?.status == .consumed(caller.id))
      #expect(
        ledger.requests[providerRequest]?.status == .consumed(provider.providerAuthorization.id))
      let execution = try ledger.startExecution(
        owner: principal, delegatedTo: provider.identity,
        authorizationIDs: provider.authorizationIDs)
      #expect(execution.authorizationIDs.count == 2)
    }
  }

  @Test(arguments: [
    "expired", "finished", "active", "terminated", "interrupted", "revoked", "registration",
    "source", "callerStopped", "wrongExecution", "wrongProof", "retryIDs", "wrongGeneration",
    "wrongAuthorizationSet", "unavailablePolicy", "suspended",
  ])
  func discoveryReplacementRequiresCurrentSelectedAuthority(scenario: String) throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let server = MCPServerConfig(id: "discovery", transport: .stdio, command: "/bin/false")
    let initial = try GatewayProviderReview(
      server: server, configuration: f.database.configurationState())
    let approval = try f.approve(initial, permissions: .newPrincipal)
    let review = try GatewayProviderReview(
      server: server, configuration: f.database.configurationState())
    let binding = try f.service.authorizeProviderExecution(
      review: review, registrationID: server.id, caller: nil, retryIDs: [])
    let additional =
      scenario == "wrongAuthorizationSet"
      ? try f.service.authorizeProviderExecution(
        review: review, registrationID: server.id, caller: nil, retryIDs: []) : nil
    let execution = try f.store.transactionWithDatabase { _, ledger in
      let start =
        scenario == "active" || scenario == "terminated" || scenario == "interrupted"
        ? Date() : Date().addingTimeInterval(-121)
      let execution = try ledger.startExecution(
        owner: .plugin(review.identity),
        authorizationIDs: binding.authorizationIDs.union(additional?.authorizationIDs ?? []),
        now: start)
      if scenario == "finished" { try ledger.finishInvocation(binding.providerAuthorization.id) }
      if scenario == "terminated" { try ledger.terminateExecution(execution.id) }
      if scenario == "interrupted" { try ledger.interruptExecution(execution.id) }
      if scenario != "active" && scenario != "terminated" && scenario != "interrupted" {
        _ = ledger.reconcileExecutionLimits(now: Date())
      }
      return execution
    }
    let selectedBinding: ProviderExecutionBinding
    if scenario == "wrongProof" {
      selectedBinding = try f.service.authorizeProviderExecution(
        review: review, registrationID: server.id, caller: nil, retryIDs: [])
    } else if scenario == "wrongGeneration" {
      let proof = binding.providerAuthorization
      let stale = InvocationAuthorization(
        identity: .init(id: proof.id, generation: proof.identity.generation + 1),
        invocation: proof.invocation, requirements: proof.requirements, basis: proof.basis)
      selectedBinding = try ProviderExecutionBinding(
        identity: binding.identity, registrationID: binding.registrationID,
        sourceDigest: binding.sourceDigest, providerAuthorization: stale,
        delegatingAuthorization: nil)
    } else {
      selectedBinding = binding
    }
    let selectedID = scenario == "wrongExecution" ? UUID() : execution.id
    let selection = try #require(
      GatewayDiscoverySelection(executionID: selectedID, binding: selectedBinding))
    if scenario == "revoked" {
      _ = try f.service.revokeProvider(
        approval.identity, owner: f.owner, expectedProviderRevision: approval.revision,
        expectedRevision: f.view().revision)
    }
    if scenario == "unavailablePolicy" {
      f.reader.set(.machineFile, .unreadable("Unavailable fixture policy"))
    } else if scenario == "suspended" {
      f.counter.forget()
      try f.store.readWithDatabase { _, ledger in
        #expect(ledger.suspendedAuthority != nil)
        #expect(ledger.pendingEpochRecovery != nil)
      }
    }
    let caller = GatewayDiscoveryCaller(
      executionID: nil, authorizationIDs: [], check: {},
      checkLedger: { _, _ in
        if scenario == "callerStopped" { throw CancellationError() }
      })
    let replacement = GatewayDiscoveryReplacement(selected: selection, reuse: nil, caller: caller)
    let candidate =
      scenario == "source"
      ? try GatewayProviderReview(
        server: .init(id: server.id, transport: .stdio, command: "/bin/true"),
        configuration: f.database.configurationState()) : review
    let registration = scenario == "registration" ? "other" : server.id
    let before = try f.store.readWithDatabase { _, ledger in Set(ledger.authorizations.keys) }
    if scenario == "expired" || scenario == "finished" {
      let fresh = try f.service.authorizeProviderExecution(
        review: candidate, registrationID: registration, caller: nil, retryIDs: [],
        replacement: replacement)
      #expect(fresh.providerAuthorization.id != binding.providerAuthorization.id)
      #expect(fresh.providerAuthorization.requestIDs.isEmpty)
      let after = try f.store.readWithDatabase { _, ledger in Set(ledger.authorizations.keys) }
      #expect(after.subtracting(before) == [fresh.providerAuthorization.id])
    } else {
      #expect(throws: (any Error).self) {
        try f.service.authorizeProviderExecution(
          review: candidate, registrationID: registration, caller: nil,
          retryIDs: scenario == "retryIDs" ? [UUID()] : [], replacement: replacement)
      }
      let after = try f.store.readWithDatabase { _, ledger in Set(ledger.authorizations.keys) }
      #expect(after == before)
    }
  }

  @Test(arguments: [false, true])
  func delegatedProviderAuthorityCannotBecomeProjectlessDiscovery(projectBound: Bool) throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let server = MCPServerConfig(
      id: "delegated-discovery", transport: .stdio, command: "/bin/false")
    let initial = try GatewayProviderReview(
      server: server, configuration: f.database.configurationState())
    _ = try f.approve(initial, permissions: .newPrincipal)
    let review = try GatewayProviderReview(
      server: server, configuration: f.database.configurationState())
    let source = GatewayProviderSource(
      review: review, registrationID: server.id, workingDirectory: nil, executable: nil,
      resources: [], validate: {})
    let owner = Principal.client("delegating-client")
    let project = projectBound ? "fixture-project" : nil
    let requirements = InvocationRequirements(actions: [
      .init(requirement: try .init(.mcpServer(server.id), .all))
    ])
    let (binding, execution) = try f.store.transactionWithDatabase { database, ledger in
      try ledger.setPermission(
        .granted(.all), for: .mcpServer(server.id), principal: owner,
        expectedRevision: ledger.revision)
      let (_, binding) = try GatewayPermissionService.admitProviderCall(
        source: source,
        invocation: .init(
          principal: owner, tool: "provider.discovery", projectID: project,
          argumentsDigest: review.sourceDigest),
        requirements: requirements, retryIDs: [], connectionID: nil, now: Date(),
        database: database, ledger: &ledger)
      let admitted = try #require(binding)
      let execution = try ledger.startExecution(
        owner: owner, delegatedTo: admitted.identity, authorizationIDs: admitted.authorizationIDs,
        now: Date().addingTimeInterval(-121))
      _ = ledger.reconcileExecutionLimits(now: Date())
      return (admitted, execution)
    }
    #expect(execution.owner == owner && execution.delegatedTo == binding.identity)
    #expect(binding.providerAuthorization.invocation.projectID == project)
    #expect(GatewayDiscoverySelection(executionID: execution.id, binding: binding) == nil)
    if projectBound {
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try ProviderExecutionBinding(
          identity: binding.identity, registrationID: binding.registrationID,
          sourceDigest: binding.sourceDigest, providerAuthorization: binding.providerAuthorization,
          delegatingAuthorization: nil)
      }
    } else {
      let providerOnly = try ProviderExecutionBinding(
        identity: binding.identity, registrationID: binding.registrationID,
        sourceDigest: binding.sourceDigest, providerAuthorization: binding.providerAuthorization,
        delegatingAuthorization: nil)
      let selected = try #require(
        GatewayDiscoverySelection(executionID: execution.id, binding: providerOnly))
      let caller = GatewayDiscoveryCaller(context: .empty)
      let before = try f.store.readWithDatabase { _, ledger in Set(ledger.authorizations.keys) }
      #expect(throws: (any Error).self) {
        try f.service.authorizeProviderExecution(
          review: review, registrationID: server.id, caller: nil, retryIDs: [],
          replacement: .init(selected: selected, reuse: nil, caller: caller))
      }
      let after = try f.store.readWithDatabase { _, ledger in Set(ledger.authorizations.keys) }
      #expect(after == before)
    }
  }

  @Test func discoveryRenewalDoesNotTransferConsumedOnceEvidence() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let server = MCPServerConfig(id: "once-discovery", transport: .stdio, command: "/bin/false")
    let initial = try GatewayProviderReview(
      server: server, configuration: f.database.configurationState())
    let approval = try f.approve(initial, permissions: .newPrincipal)
    let review = try GatewayProviderReview(
      server: server, configuration: f.database.configurationState())
    let invocation = InvocationIdentity(
      principal: approval.principal, tool: "provider.discovery", projectID: nil,
      argumentsDigest: review.sourceDigest)
    let requirements = InvocationRequirements(actions: [
      .init(requirement: try .init(.screen, .access))
    ])
    let (requestID, proof, execution) = try f.store.transactionWithDatabase { _, ledger in
      guard
        case .requests(let requests) = try ledger.authorize(
          invocation: invocation, requirements: requirements, now: Date()),
        let request = requests.first
      else { throw PermissionModelError.invalidAuthorization }
      try ledger.answer(request.id, with: .onlyThisTime, now: Date())
      guard
        case .allowed(let proof) = try ledger.authorize(
          invocation: invocation, requirements: requirements, retryIDs: [request.id], now: Date())
      else { throw PermissionModelError.invalidAuthorization }
      let execution = try ledger.startExecution(
        owner: approval.principal, authorizationIDs: [proof.id],
        now: Date().addingTimeInterval(-121))
      _ = ledger.reconcileExecutionLimits(now: Date())
      return (request.id, proof, execution)
    }
    #expect(proof.requestIDs == [requestID])
    let binding = try ProviderExecutionBinding(
      identity: review.identity, registrationID: server.id, sourceDigest: review.sourceDigest,
      providerAuthorization: proof, delegatingAuthorization: nil)
    let selected = try #require(
      GatewayDiscoverySelection(executionID: execution.id, binding: binding))
    let caller = GatewayDiscoveryCaller(
      executionID: nil, authorizationIDs: [], check: {}, checkLedger: { _, _ in })
    let fresh = try f.service.authorizeProviderExecution(
      review: review, registrationID: server.id, caller: nil, retryIDs: [],
      replacement: .init(selected: selected, reuse: nil, caller: caller))
    #expect(fresh.providerAuthorization.id != proof.id)
    #expect(fresh.providerAuthorization.requestIDs.isEmpty)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.requests[requestID]?.status == .consumed(proof.id))
      #expect(ledger.authorizations[fresh.providerAuthorization.id]?.requestIDs.isEmpty == true)
    }
  }

  @Test func providerPreparationPinsReviewedSourceAndDiscoveryMode() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let initial = try f.install(requirement: "write")
    do {
      _ = try f.service.authorizeProviderExecution(
        review: initial, registrationID: "fixture", caller: nil, retryIDs: [])
      Issue.record("An unapproved provider received discovery authority")
    } catch let error as GatewayToolError {
      #expect(error.localizedDescription.contains("[provider.approval_required]"))
      #expect(error.localizedDescription.contains("owner approval"))
    }
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.authorizations.isEmpty && ledger.executions.isEmpty)
    }
    _ = try f.approve(initial, permissions: .newPrincipal)
    let review = try f.currentReview()
    let binding = try f.service.authorizeProviderExecution(
      review: review, registrationID: "fixture", caller: nil, retryIDs: [])
    #expect(binding.providerAuthorization.mode == .sandbox)
    #expect(binding.providerAuthorization.invocation.projectID == nil)
    #expect(binding.owner == .plugin(review.identity))
    #expect(binding.delegatingAuthorization == nil)
    try f.service.validateProviderExecution(binding)
    _ = try f.install(requirement: "read")
    #expect(throws: GatewayPermissionError.self) {
      try f.service.authorizeProviderExecution(
        review: review, registrationID: "fixture", caller: nil, retryIDs: [])
    }
  }

  @Test func pendingWideningKeepsTheApprovedRequirementBinding() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let approved = try f.approve(f.install(requirement: "write"), permissions: .newPrincipal)
    let initial = try f.store.readWithDatabase { _, ledger in
      try #require(ledger.environment.providerRequirements?[approved.identity])
    }
    #expect(initial.digest == approved.requirementDigest)
    _ = try f.install(requirement: "read")
    let pending = try #require(f.view().providers.first)
    #expect(pending.update == .widening)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.environment.providerRequirements?[approved.identity] == initial)
    }
    let replacement = try f.approve(
      f.currentReview(), permissions: .newPrincipal, previous: pending.revision)
    try f.store.readWithDatabase { _, ledger in
      let current = try #require(ledger.environment.providerRequirements?[approved.identity])
      #expect(
        current.digest == replacement.requirementDigest && current.identity != initial.identity)
    }
  }

  @Test func readReviewAndApprovalRetainOriginalPathsAndRejectReplacement() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let home = try ProjectPathResolver.canonicalProject(f.root).appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    let config = home.appendingPathComponent("config")
    try Data("config".utf8).write(to: config)
    try f.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.paths = try .init(
        projects: [], rules: [.init(root: .init(home.path), kind: .userData)])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    let review = try f.install(
      requirement: "write",
      sandbox: """
        [sandbox]
        network = 'trusted'
        purpose = 'Contact approved services'
        read_exceptions = [{path = '~/config', purpose = 'Read configuration'}, {path = '~/missing', purpose = 'Optional configuration'}]
        """)
    let entries = try review.readExceptions(userHome: home)
    #expect(entries.count == 2)
    #expect(entries.first { $0.declaredPath == "~/missing" }?.approval == nil)
    let selected = try #require(entries.first { $0.declaredPath == "~/config" }?.approval)
    let approved = try f.approve(
      review, permissions: .newPrincipal,
      sandboxSettings: .init(defaults: .init(network: .trusted, readExceptions: [selected])),
      userHome: home)
    #expect(approved.sandboxSettings?.defaults.readExceptions.first?.declaredPath == "~/config")
    #expect(approved.sandboxSettings?.defaults.network.configuration == .trusted)
    try Data("replacement".utf8).write(to: config, options: .atomic)
    #expect(throws: (any Error).self) {
      try GatewayProviderReadExceptions.verify([selected], userHome: home)
    }
    #expect(throws: (any Error).self) {
      try f.approve(
        f.currentReview(), permissions: .newPrincipal, previous: approved.revision,
        sandboxSettings: .init(defaults: .init(readExceptions: [selected])), userHome: home)
    }
  }

  @Test func explicitReplacementIsReresolvedAndCanonicalDuplicatesRefused() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let root = try ProjectPathResolver.canonicalProject(f.root)
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    let chosen = root.appendingPathComponent("chosen")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    try FileManager.default.createSymbolicLink(at: chosen, withDestinationURL: first)
    let review = try f.install(
      requirement: "write",
      sandbox: """
        [sandbox]
        read_exceptions = [{path = '~/one', purpose = 'One'}, {path = '~/two', purpose = 'Two'}]
        """)
    #expect(throws: GatewayPermissionError.self) {
      try review.readExceptions(
        replacements: ["~/one": .init(chosen.path), "~/two": .init(first.path)], userHome: f.root)
    }
    let entry = try #require(
      review.readExceptions(replacements: ["~/one": .init(chosen.path)], userHome: f.root).first {
        $0.declaredPath == "~/one"
      }?.approval)
    #expect(entry.ownerSelectedPath?.string == chosen.path && entry.path.string == first.path)
    try GatewayProviderReadExceptions.verify([entry], userHome: f.root)
    try FileManager.default.removeItem(at: chosen)
    try FileManager.default.createSymbolicLink(at: chosen, withDestinationURL: second)
    #expect(throws: (any Error).self) {
      try GatewayProviderReadExceptions.verify([entry], userHome: f.root)
    }
  }

  @Test func duplicateReadPathUpdatePreservesApproval() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let home = try ProjectPathResolver.canonicalProject(f.root).appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    let config = home.appendingPathComponent("config")
    try Data("config".utf8).write(to: config)
    let sandbox = "[sandbox]\nread_exceptions = [{path = '~/config', purpose = 'Read'}]\n"
    let review = try f.install(requirement: "write", sandbox: sandbox)
    try f.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.paths = try .init(
        projects: [], rules: [.init(root: .init(home.path), kind: .userData)])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    let exception = try #require(review.readExceptions(userHome: home).first?.approval)
    let original = try f.approve(
      review, permissions: .newPrincipal,
      sandboxSettings: .init(defaults: .init(readExceptions: [exception])), userHome: home)
    let view = try f.view()
    #expect(throws: PluginManifestError.self) {
      try f.install(
        requirement: "write",
        sandbox: sandbox.replacingOccurrences(
          of: "purpose = 'Read'}]",
          with: "purpose = 'Read'}, {path = '~/config', purpose = 'Again'}]"))
    }
    #expect(try f.view().revision == view.revision)
    #expect(try f.view().providers == [original])
  }

  @Test func canonicalReadDuplicatesRefuseApprovalAndUpdate() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let home = try ProjectPathResolver.canonicalProject(f.root).appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    let first = home.appendingPathComponent("first")
    let second = home.appendingPathComponent("second")
    let alias = home.appendingPathComponent("alias")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
    let sandbox = """
      [sandbox]
      read_exceptions = [{path = '~/first', purpose = 'First'}, {path = '~/alias', purpose = 'Alias'}]
      """
    let review = try f.install(requirement: "write", sandbox: sandbox)
    let initial = try f.view()
    #expect(throws: GatewayPermissionError.invalidBinding) {
      try f.approve(review, permissions: .newPrincipal, userHome: home)
    }
    #expect(try f.view().revision == initial.revision)
    #expect(try f.view().providers.isEmpty)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
    try f.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.paths = try .init(
        projects: [], rules: [.init(root: .init(home.path), kind: .userData)])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    let exceptions = try review.readExceptions(
      replacements: ["~/first": .init(first.path), "~/alias": .init(alias.path)], userHome: home)
    let original = try f.approve(
      review, permissions: .newPrincipal,
      sandboxSettings: .init(
        defaults: .init(readExceptions: Set(exceptions.compactMap(\.approval)))),
      userHome: home)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
    let view = try f.view()
    #expect(throws: GatewayPermissionError.invalidBinding) {
      try f.install(
        requirement: "write",
        sandbox: sandbox.replacingOccurrences(of: "'Alias'", with: "'Read alias'"))
    }
    #expect(try f.view().revision == view.revision)
    #expect(try f.view().providers == [original])
  }

  @Test func narrowingNetworkRequestsKeepsTheOwnerSelectionAndConstrainsIt() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let review = try f.install(
      requirement: "write", sandbox: "[sandbox]\nnetwork = 'full'\npurpose = 'Network'\n")
    let selected = ProviderSandboxSettings(
      defaults: .init(network: .custom(hosts: ["one.test", "two.test"], includesTrusted: false)))
    _ = try f.approve(review, permissions: .newPrincipal, sandboxSettings: selected)
    _ = try f.install(
      requirement: "write",
      sandbox:
        "[sandbox]\nnetwork = { level = 'custom', hosts = ['one.test'], include_trusted = false }\npurpose = 'Network'\n"
    )
    let approval = try #require(f.view().providers.first)
    #expect(approval.update == .narrowing)
    #expect(
      approval.sandboxSettings?.defaults.network.configuration
        == selected.defaults.network.configuration)
    #expect(
      approval.sandboxSettings?.defaults.networkCeiling?.configuration
        == .custom(hosts: ["one.test"], includesTrusted: false))
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.sandboxSettings.providers[approval.identity] == approval.sandboxSettings)
    }
    _ = try f.install(
      requirement: "write", sandbox: "[sandbox]\nnetwork = 'full'\npurpose = 'Network'\n")
    let pending = try #require(f.view().providers.first)
    #expect(pending.update == .widening && pending.sandboxSettings == approval.sandboxSettings)
  }

  @Test(arguments: ["declaration", "policy", "both"])
  func customNetworkApprovalRetainsDynamicTrustedCeilings(ceiling: String) throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    if ceiling != "declaration" {
      f.reader.set(.machineFile, .available(Data("network = 'trusted'".utf8)))
    }
    try f.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.paths = try .init(
        projects: [],
        rules: [
          .init(root: .init("/people"), kind: .userData),
          .init(root: .init("/host"), kind: .hostData),
        ])
      environment.trustedHosts = [HostRule("allowed.test"), HostRule("other.test")]
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    let requested = ceiling == "policy" ? "full" : "trusted"
    let review = try f.install(
      requirement: "write", sandbox: "[sandbox]\nnetwork = '\(requested)'\npurpose = 'Network'\n")
    let selected = ProviderSandboxSettings(
      defaults: .init(network: .custom(hosts: ["allowed.test"], includesTrusted: false)))
    let approved = try f.approve(review, permissions: .newPrincipal, sandboxSettings: selected)
    #expect(
      approved.sandboxSettings?.defaults.network.configuration
        == selected.defaults.network.configuration)
    #expect(
      approved.sandboxSettings?.defaults.networkCeiling?.configuration
        == (ceiling == "policy" ? .full : .trusted))
    try f.store.transactionWithDatabase { _, ledger in
      func admit(_ ledger: inout PermissionLedger) throws -> InvocationAuthorization {
        let decision = try ledger.authorize(
          invocation: .init(
            principal: approved.principal, tool: "discover", projectID: nil,
            argumentsDigest: "network"), requirements: .init(), now: Date())
        guard case .allowed(let authorization) = decision else {
          throw GatewayPermissionError.invalidBinding
        }
        return authorization
      }
      let initial = try admit(&ledger)
      #expect(
        try ledger.prepareExecutionPermissions(initial.id).network
          == .custom(hosts: ["allowed.test"], includesTrusted: false))
      var environment = ledger.environment
      environment.trustedHosts = [HostRule("other.test")]
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      #expect(throws: PermissionModelError.invalidAuthorization) {
        try ledger.invocationAccess(initial.id)
      }
      let narrowed = try admit(&ledger)
      #expect(try ledger.prepareExecutionPermissions(narrowed.id).network == .none)
      #expect(
        ledger.sandboxSettings.providers[approved.identity]?.defaults.network.configuration
          == selected.defaults.network.configuration)
    }
    #expect(throws: GatewayPermissionError.self) {
      try f.approve(
        f.currentReview(), permissions: .newPrincipal, previous: approved.revision,
        sandboxSettings: selected)
    }
    #expect(try f.view().providers == [approved])
  }

  @Test func approvalBindsSourceEpochRevisionsAndNeverCreatesProfile() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let review = try f.install(requirement: "write")
    var selected = Permissions.newPrincipal
    try selected.set(.granted(.write), for: .project("*"))
    try selected.set(.denied, for: .project("private"))
    let view = try f.view()
    let approval = try f.approve(review, permissions: selected)
    #expect(approval.identity == .package("test-package"))
    #expect(approval.permissions.entries == selected.entries)
    #expect(try f.view().profiles.isEmpty)
    #expect(try f.view().subjects.isEmpty)
    #expect(try f.database.pluginStoreSnapshot().settings["test-package"]?.enabled == true)
    #expect(throws: GatewayPermissionError.revisionConflict) {
      try f.service.approveProvider(
        review, permissions: selected, fullAccess: false, owner: f.owner,
        expectedProviderRevision: nil, expectedRevision: view.revision,
        expectedEpoch: #require(view.epoch))
    }
    let fresh = try f.currentReview()
    #expect(throws: GatewayPermissionError.revisionConflict) {
      try f.service.approveProvider(
        fresh, permissions: selected, fullAccess: false, owner: f.owner,
        expectedProviderRevision: approval.revision, expectedRevision: f.view().revision,
        expectedEpoch: UUID())
    }
    let resolved = try PluginResolver.resolve(
      package: PluginPackage.load(at: f.root), source: .init(kind: .development, root: f.root),
      settings: .init(enabled: true), hostVersion: PluginVersion("1.0.0"),
      architecture: PluginHost.architecture)
    #if os(macOS)
      #expect(resolved.mcpServers.count == 1)
      #expect(resolved.origins.values.allSatisfy { $0.reviewedRequirements != nil })
    #else
      #expect(resolved.mcpServers.isEmpty)
    #endif
    #expect(resolved.cliCommands.isEmpty && resolved.skillRoots.isEmpty)
  }

  @Test func widerUpdateRetainsEntireApprovalAndNarrowingPreservesDenies() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    var selected = Permissions.newPrincipal
    try selected.set(.granted(.write), for: .project("*"))
    try selected.set(.denied, for: .project("private"))
    let original = try f.approve(f.install(requirement: "write"), permissions: selected)
    let admitted = try f.store.transactionWithDatabase { _, ledger in
      let decision = try ledger.authorize(
        invocation: .init(
          principal: original.principal, tool: "edit", projectID: nil,
          argumentsDigest: "fixture"),
        actions: [.init(requirement: .init(.project("selected"), .write))], now: Date())
      guard case .allowed(let authorization) = decision else {
        throw GatewayPermissionError.invalidBinding
      }
      return authorization.id
    }
    _ = try f.install(requirement: "read", access: "read")
    let pending = try #require(f.view().providers.first)
    #expect(pending.update == .widening)
    #expect(pending.declarations == original.declarations)
    #expect(pending.permissions.entries == selected.entries)
    #expect(pending.sourceDigest == original.sourceDigest)
    #expect(pending.pendingSourceDigest != nil)
    #expect(pending.permissions == original.permissions)
    try f.store.readWithDatabase { _, ledger in
      var current = ledger
      #expect((try? current.invocationAccess(admitted)) != nil)
      #expect(ledger.permissions(for: original.principal) == original.permissions)
    }
    _ = try f.install(requirement: "write", access: "read")
    let narrowed = try #require(f.view().providers.first)
    #expect(narrowed.update == .narrowing)
    #expect(narrowed.permissions.state(for: .project("*")) == .granted(.read))
    #expect(narrowed.permissions.state(for: .project("private")) == .denied)
    #expect(narrowed.pendingSourceDigest == nil)
    _ = try f.install(requirement: "write", access: "read", purpose: "Read selected files")
    let renamed = try #require(f.view().providers.first)
    #expect(renamed.update == .purposeOnly)
    #expect(renamed.permissions == narrowed.permissions)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.permissions(for: renamed.principal) == renamed.permissions)
      var current = ledger
      #expect((try? current.invocationAccess(admitted)) == nil)
    }
    _ = try f.service.revokeProvider(
      renamed.identity, owner: f.owner, expectedProviderRevision: renamed.revision,
      expectedRevision: f.view().revision)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.permissions(for: renamed.principal).entries.isEmpty)
    }
    #expect(try f.view().providers.first?.enabled == false)
    _ = try f.install(requirement: "read", access: "write")
    #expect(try f.view().providers.first?.enabled == false)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.permissions(for: renamed.principal).entries.isEmpty)
    }
  }

  @Test func selectingTheApprovedSourceClearsItsSupersededPendingReview() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let original = try f.approve(f.install(requirement: "write"), permissions: .newPrincipal)
    _ = try f.install(requirement: "read")
    let pending = try #require(f.view().providers.first)
    #expect(pending.update == .widening && pending.pendingSourceDigest != nil)
    _ = try f.install(requirement: "write")
    let restored = try #require(f.view().providers.first)
    #expect(restored.update == .unchanged)
    #expect(restored.sourceDigest == original.sourceDigest)
    #expect(restored.declarations == original.declarations)
    #expect(restored.permissions.entries == original.permissions.entries)
    #expect(restored.pendingSourceDigest == nil && restored.pendingDeclarations == nil)
    #expect(restored.revision == pending.revision + 1)
  }

  @Test func unavailableDeclarationSnapshotRetiresTheApprovalRevision() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let original = try f.approve(f.install(requirement: "write"), permissions: .newPrincipal)
    _ = try f.install(requirement: "read", recordDeclarations: false)
    let retired = try #require(f.view().providers.first)
    #expect(!retired.enabled && retired.revision == original.revision + 1)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.permissions(for: original.principal).entries.isEmpty)
    }
  }

  @Test func providerRequestsStayOnTheProviderAndUnknownObjectsCannotBeSelected() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let package = try f.install(requirement: "write")
    var unknown = Permissions.newPrincipal
    try unknown.set(.granted(.write), for: .project("unregistered"))
    #expect(throws: PermissionModelError.invalidObject) {
      try f.approve(package, permissions: unknown)
    }
    let review = try GatewayProviderReview(
      server: .init(id: "local", transport: .stdio, command: "/bin/false"),
      configuration: f.database.configurationState())
    let approval = try f.approve(review, permissions: .newPrincipal)
    let request = try f.store.transactionWithDatabase { _, ledger in
      let decision = try ledger.authorize(
        invocation: .init(
          principal: approval.principal, tool: "screen", projectID: nil,
          argumentsDigest: "fixture"),
        actions: [.init(requirement: .init(.screen, .access))], now: Date())
      guard case .requests(let requests) = decision, let request = requests.first else {
        throw GatewayPermissionError.invalidBinding
      }
      return request
    }
    _ = try f.service.answerRequest(
      request.id, answer: .always, owner: f.owner, expectedRevision: f.view().revision)
    let view = try f.view()
    #expect(view.profiles.isEmpty && view.subjects.isEmpty)
    #expect(view.providers.first?.permissions.state(for: .screen) == .granted(.access))
  }

  @Test func localServersHaveIndependentPrincipalPoliciesAndLocalModeConsent() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let review = try GatewayProviderReview(
      server: .init(id: "local", transport: .stdio, command: "/bin/false"),
      configuration: f.database.configurationState())
    var permissions = Permissions.newPrincipal
    try permissions.set(.granted(.access), for: .screen)
    let approval = try f.approve(review, permissions: permissions, fullAccess: true)
    #expect(approval.identity == .localServer("local"))
    #expect(approval.fullAccessConsent != nil)
    _ = try f.service.setOwnerPolicy(
      Data("full_access = false\n[permissions]\nscreen = 'deny'".utf8),
      provider: approval.identity, owner: f.owner, expectedRevision: f.view().revision)
    let view = try f.view()
    #expect(view.profiles.isEmpty && view.subjects.isEmpty)
    #expect(view.sources.contains { $0.provider == approval.identity && $0.profileID == nil })
    try f.store.readWithDatabase { _, ledger in
      let limits = try #require(ledger.environment.limits[approval.principal])
      #expect(limits.restrictingSources(for: try .init(.screen, .access)) == [.owner])
    }
    #expect(throws: GatewayPermissionError.managedLimit) {
      try f.approve(review, permissions: permissions, fullAccess: true, previous: approval.revision)
    }
  }

  @Test func concurrentApprovalUsesOneRevisionAndRevocationCannotBeReplayed() async throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let review = try f.install(requirement: "write")
    let view = try f.view()
    let epoch = try #require(view.epoch)
    let accepted = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<2 {
        group.addTask {
          (try? f.service.approveProvider(
            review, permissions: .newPrincipal, fullAccess: false, owner: f.owner,
            expectedProviderRevision: nil, expectedRevision: view.revision,
            expectedEpoch: epoch)) != nil
        }
      }
      var count = 0
      for await success in group where success { count += 1 }
      return count
    }
    #expect(accepted == 1)
    let approval = try #require(f.view().providers.first)
    let revision = try f.view().revision
    _ = try f.service.revokeProvider(
      approval.identity, owner: f.owner, expectedProviderRevision: approval.revision,
      expectedRevision: revision)
    #expect(throws: GatewayPermissionError.revisionConflict) {
      try f.service.revokeProvider(
        approval.identity, owner: f.owner, expectedProviderRevision: approval.revision,
        expectedRevision: revision)
    }
  }

  @Test func reapprovalAfterRevocationCreatesFreshGrantIdentities() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let original = try f.approve(f.install(requirement: "write"), permissions: .newPrincipal)
    _ = try f.service.revokeProvider(
      original.identity, owner: f.owner, expectedProviderRevision: original.revision,
      expectedRevision: f.view().revision)
    let retired = try #require(f.view().providers.first)
    let renewed = try f.approve(
      f.currentReview(), permissions: retired.permissions, previous: retired.revision)
    #expect(renewed.permissions.entries == original.permissions.entries)
    #expect(renewed.permissions != original.permissions)
    #expect(renewed.enabled)
  }

  @Test func failedCommitCannotSplitEnablementAndGrants() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let review = try f.install(requirement: "write")
    let view = try f.view()
    let fail = ProviderFailureSwitch()
    let failingStore = SQLitePermissionStore(connection: f.database.connection, counter: f.counter)
    {
      stage in
      if stage == .afterCounterAdvance, fail.enabled { throw ProviderFixtureError.injected }
    }
    let service = GatewayPermissionService(store: failingStore, policyReader: f.reader)
    fail.enabled = true
    #expect(throws: ProviderFixtureError.injected) {
      try service.approveProvider(
        review, permissions: .newPrincipal, fullAccess: false, owner: f.owner,
        expectedProviderRevision: nil, expectedRevision: view.revision,
        expectedEpoch: #require(view.epoch))
    }
    fail.enabled = false
    #expect(try f.database.pluginStoreSnapshot().settings["test-package"]?.enabled == false)
    let count = try f.database.connection.writer.read { try ProviderAuthorityRecord.fetchCount($0) }
    #expect(count == 0)
    #expect(try f.view().suspended)
  }

  @Test func h12OrdinaryProviderEditsRetireOnlyDependentStandingWork() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let project = try ProjectPathResolver.canonicalProject(f.root)
    try f.database.saveProject(.init(id: "project", displayName: "Project", rootPath: project.path))
    try f.service.configureEnvironment(
      .init(projects: [.init(id: "project", root: .init(project.path))], rules: []),
      trustedHosts: [], expectedProjects: f.database.projects(), expectedConfigurationRevision: nil)
    let server = MCPServerConfig(id: "edit-scope", transport: .stdio, command: "/usr/bin/true")
    let review = try GatewayProviderReview(
      server: server, configuration: f.database.configurationState())
    var selection = Permissions()
    try selection.set(.granted(.access), for: .screen)
    try selection.set(.granted(.access), for: .unifiedLogs)
    let approved = try f.approve(review, permissions: selection)
    let (screen, logs, projectLogs) = try f.store.transactionWithDatabase { _, ledger in
      func start(_ permission: Permission, projectID: String? = nil) throws -> AuthorizedExecution {
        let decision = try ledger.authorize(
          invocation: .init(
            principal: approved.principal, tool: "owner-fixture", projectID: projectID,
            argumentsDigest: "standing"),
          requirements: .init(
            actions: [
              .init(requirement: try .init(permission, .access))
            ], sandboxProjectID: projectID), now: .now)
        guard case .allowed(let proof) = decision else {
          throw PermissionModelError.invalidAuthorization
        }
        return try ledger.startExecution(owner: approved.principal, authorizationIDs: [proof.id])
      }
      return (
        try start(.screen), try start(.unifiedLogs), try start(.unifiedLogs, projectID: "project")
      )
    }
    func edit(
      _ approval: GatewayProviderApproval, permissions: Permissions,
      settings: ProviderSandboxSettings
    )
      throws -> GatewayProviderApproval
    {
      let view = try f.view()
      return try f.service.approveProvider(
        review, permissions: permissions, fullAccess: false, sandboxSettings: settings,
        owner: f.owner, expectedProviderRevision: approval.revision,
        expectedRevision: view.revision, expectedEpoch: #require(view.epoch),
        editingApproval: true)
    }
    let network = try edit(
      approved, permissions: approved.permissions,
      settings: .init(projects: ["project": .init(network: .trusted)]))
    #expect(network.permissions == approved.permissions)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.executions[screen.id]?.isRunning == true)
      #expect(ledger.executions[logs.id]?.isRunning == true)
      #expect(ledger.pendingExecutionTerminations == [projectLogs.id])
    }
    try selection.set(.denied, for: .screen)
    _ = try edit(network, permissions: selection, settings: #require(network.sandboxSettings))
    try f.store.transactionWithDatabase { _, ledger in
      #expect(ledger.pendingExecutionTerminations.contains(screen.id))
      #expect(!ledger.pendingExecutionTerminations.contains(logs.id))
      let unaffected = try #require(logs.authorizationIDs.first)
      _ = try ledger.invocationAccess(unaffected)
    }
  }

  @Test func h12DefaultProviderGrantIdentitiesSurviveAdmissionAndNetworkEdit() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let server = MCPServerConfig(id: "default-grants", transport: .stdio, command: "/usr/bin/true")
    let review = try GatewayProviderReview(
      server: server, configuration: f.database.configurationState())
    let defaults = Permissions.newPrincipal
    let approved = try f.approve(review, permissions: defaults)
    #expect(approved.permissions.entries == defaults.entries)
    #expect(approved.permissions.grantIDs.values.allSatisfy { !$0.isDraft })
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.permissions(for: approved.principal) == approved.permissions)
    }

    let binding = try f.service.authorizeProviderExecution(
      review: review, registrationID: server.id, caller: nil, retryIDs: [])
    #expect(binding.providerAuthorization.invocation.principal == approved.principal)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.permissions(for: approved.principal) == approved.permissions)
    }

    let view = try f.view()
    let edited = try f.service.approveProvider(
      review, permissions: approved.permissions, fullAccess: false,
      sandboxSettings: .init(defaults: .init(network: .trusted)), owner: f.owner,
      expectedProviderRevision: approved.revision, expectedRevision: view.revision,
      expectedEpoch: #require(view.epoch), editingApproval: true)
    #expect(edited.sandboxSettings?.defaults.network.configuration == .trusted)
    #expect(edited.permissions == approved.permissions)
    #expect(try f.view().providers.first?.permissions == approved.permissions)
  }

  @Test func h12ReviewedSandboxChoicesReceiveFreshEvidenceAfterRestore() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let home = try ProjectPathResolver.canonicalProject(f.root).appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    try Data("configuration".utf8).write(to: home.appendingPathComponent("settings"))
    try f.service.configureEnvironment(
      .init(projects: [], rules: [.init(root: .init(home.path), kind: .userData)]),
      trustedHosts: [], expectedProjects: [], expectedConfigurationRevision: nil)
    let review = try f.install(
      requirement: "write",
      sandbox: """
        [sandbox]
        network = 'trusted'
        purpose = 'Use trusted services'
        read_exceptions = [{path = '~/settings', purpose = 'Read configuration'}]
        """)
    let exceptionReviews = try review.readExceptions(userHome: home)
    let selected = try #require(exceptionReviews.first?.approval)
    let settings = ProviderSandboxSettings(
      defaults: .init(network: .trusted, readExceptions: [selected]))
    let approved: GatewayProviderApproval
    do {
      approved = try f.approve(
        review, permissions: .newPrincipal, sandboxSettings: settings, userHome: home)
    } catch {
      Issue.record("Initial approval failed: \(error)")
      return
    }
    let saved = try #require(approved.sandboxSettings)
    let oldException = try #require(saved.defaults.readExceptions.first)

    f.counter.forget()
    try f.store.transactionWithDatabase { _, ledger in
      try ledger.acknowledgeEpochRecovery(#require(ledger.authorizationEpochID))
    }
    let suspended = try f.view()
    try f.service.confirmAuthority(
      owner: f.owner, epoch: #require(suspended.epoch), expectedRevision: suspended.revision,
      profileEdits: [])
    try GatewayProviderReadExceptions.verify(saved.defaults.readExceptions, userHome: home)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.sandboxSettings.providers[approved.identity] == nil)
      #expect(
        ledger.canApproveReadException(
          at: oldException.path, for: approved.identity, settings: saved.defaults, limits: .init()))
    }
    let restored = try f.approve(
      f.currentReview(), permissions: approved.permissions, previous: approved.revision,
      sandboxSettings: saved, userHome: home)
    let rebound = try #require(restored.sandboxSettings)
    let reboundException = try #require(rebound.defaults.readExceptions.first)
    #expect(restored.epoch != approved.epoch)
    #expect(rebound.defaults.network.configuration == saved.defaults.network.configuration)
    #expect(rebound.defaults.network != saved.defaults.network)
    #expect(reboundException.filesystemIdentity == oldException.filesystemIdentity)
    #expect(reboundException.identity != oldException.identity)
  }

  @Test func epochRecoveryDoesNotAdoptProviderThroughClientConfirmation() throws {
    let f = try ProviderApprovalFixture()
    defer { f.remove() }
    let approval = try f.approve(f.install(requirement: "write"), permissions: .newPrincipal)
    f.counter.forget()
    try f.store.transactionWithDatabase { _, ledger in
      try ledger.acknowledgeEpochRecovery(#require(ledger.authorizationEpochID))
    }
    let view = try f.view()
    try f.service.confirmAuthority(
      owner: f.owner, epoch: #require(view.epoch), expectedRevision: view.revision,
      profileEdits: [])
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.permissions(for: approval.principal).entries.isEmpty)
    }
    #expect(try f.view().providers.first?.epoch == approval.epoch)
  }
}

private enum ProviderFixtureError: Error { case injected }

private final class ProviderApprovalFixture: @unchecked Sendable {
  let database: GatewayDatabase
  let store: SQLitePermissionStore
  let reader = TestManagedPolicyReader()
  let counter = TestAuthorizationEpochCounter()
  let service: GatewayPermissionService
  let owner: GatewayPermissionOwner
  let root: URL

  init() throws {
    database = try GatewayDatabase(inMemory: ())
    store = database.permissionStore(counter: counter)
    service = GatewayPermissionService(store: store, policyReader: reader)
    owner = try .init(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
      validate: {})
    root = try pluginPackageFixture().resolvingSymlinksInPath()
    try store.transactionWithDatabase { _, ledger in
      try ledger.acknowledgeEpochRecovery(#require(ledger.authorizationEpochID))
    }
    let view = try service.view(owner: owner)
    try service.confirmAuthority(
      owner: owner, epoch: #require(view.epoch), expectedRevision: view.revision, profileEdits: [])
  }

  func view() throws -> GatewayPermissionView { try service.view(owner: owner) }
  func remove() { try? FileManager.default.removeItem(at: root) }
  func currentReview() throws -> GatewayProviderReview {
    try .init(package: PluginPackage.load(at: root), configuration: database.configurationState())
  }

  func install(
    requirement: String, access: String = "write", purpose: String = "Edit",
    recordDeclarations: Bool = true, sandbox: String = ""
  ) throws
    -> GatewayProviderReview
  {
    let text =
      PluginManifestFixture.header + sandbox + "\n" + """
        [[permissions]]
        id = 'project'
        access = '\(access)'
        purpose = '\(purpose)'
        [[mcp]]
        id = 'remote'
        transport = 'http'
        url = 'https://example.test/mcp'
        requirements = { project = '\(requirement)' }
        """
    try text.write(
      to: root.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8)
    let package = try PluginPackage.load(at: root)
    var state = try database.pluginStoreSnapshot()
    let record = PluginInstallationRecord(
      id: UUID().uuidString, pluginID: package.manifest.id, version: package.manifest.version,
      source: .init(kind: .development, root: package.root),
      manifestDigest: try PluginStore.manifestDigest(package.manifest),
      declarations: recordDeclarations ? PluginPermissionDeclarations(package.manifest) : nil,
      registeredAt: .now)
    state.installations.append(record)
    state.selectedInstallations[record.pluginID] = record.id
    if state.settings[record.pluginID] == nil { state.settings[record.pluginID] = .init() }
    let revision = state.revision
    state.revision += 1
    _ = try database.savePluginStoreSnapshot(state, expectedRevision: revision)
    return try currentReview()
  }

  func approve(
    _ review: GatewayProviderReview, permissions: Permissions,
    fullAccess: Bool = false, previous: Int64? = nil,
    sandboxSettings: ProviderSandboxSettings = .init(),
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> GatewayProviderApproval {
    let view = try view()
    return try service.approveProvider(
      review, permissions: permissions, fullAccess: fullAccess, sandboxSettings: sandboxSettings,
      userHome: userHome, owner: owner,
      expectedProviderRevision: previous, expectedRevision: view.revision,
      expectedEpoch: #require(view.epoch))
  }
}

private final class ProviderFailureSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var enabled: Bool {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}
