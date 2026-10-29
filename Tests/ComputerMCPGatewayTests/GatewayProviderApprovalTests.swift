import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPPlugins
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence

struct GatewayProviderApprovalTests {
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
    #expect(
      resolved.mcpServers.isEmpty && resolved.cliCommands.isEmpty && resolved.skillRoots.isEmpty)
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
