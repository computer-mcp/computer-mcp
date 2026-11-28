import Foundation
import Testing

@testable import ComputerMCPPermissions

struct ProviderSandboxSettingsTests {
  private let provider = PluginIdentity.package("example")
  private var principal: Principal { .plugin(provider) }

  private func ledger() throws -> PermissionLedger {
    var result = PermissionLedger()
    var environment = PermissionEnvironment()
    environment.paths = try .init(
      projects: [
        .init(id: "a", root: path("/projects/a")),
        .init(id: "derived", root: path("/worktrees/a"), sourceID: "a"),
        .init(id: "b", root: path("/projects/b")),
      ],
      rules: [
        .init(root: path("/people"), kind: .userData),
        .init(root: path("/host"), kind: .hostData),
      ])
    _ = try result.reconcile(environment: environment, expectedRevision: result.revision)
    return result
  }

  private func exception(_ target: String = "/people/me/.config") throws -> ApprovedReadException {
    try .init(
      declaredPath: "~/.config", path: path(target), filesystemIdentity: Data("identity".utf8),
      isDirectory: true, purpose: "Read configuration")
  }

  @Test func omittedOverridesInheritAndEmptyOverridesReplaceAcrossWorktrees() throws {
    var ledger = try ledger()
    _ = try ledger.setProviderSandboxSettings(
      .init(
        defaults: .init(network: .trusted, readExceptions: [exception()]),
        projects: ["a": .init(network: NetworkAccess.none, readExceptions: [])]),
      for: provider, expectedRevision: ledger.revision)
    let catalog = try #require(ledger.environment.paths?.projects)
    let settings = ledger.sandboxSettings
    #expect(
      try settings.settings(for: principal, projectID: "derived", projects: catalog).network
        .configuration == .none)
    #expect(
      try settings.settings(for: principal, projectID: "derived", projects: catalog).readExceptions
        .isEmpty)
    #expect(
      try settings.settings(for: principal, projectID: "b", projects: catalog).network.configuration
        == .trusted)
    #expect(settings.settings(for: principal, sourceProjectID: nil).readExceptions.count == 1)
    #expect(
      settings.settings(for: .plugin(.localServer("example")), sourceProjectID: "b") == .init())
    #expect(
      try JSONDecoder().decode(PermissionLedger.self, from: JSONEncoder().encode(ledger))
        .sandboxSettings == settings)
  }

  @Test func approvedReadsRetainIdentityAndNeverReopenFixedDenials() throws {
    var ledger = try ledger()
    _ = try ledger.setProviderSandboxSettings(
      .init(defaults: .init(readExceptions: [exception()])),
      for: provider, expectedRevision: ledger.revision)
    func read(_ target: String, in ledger: inout PermissionLedger) throws -> AuthorizationDecision {
      try ledger.authorize(
        invocation: .init(
          principal: principal, tool: "read", projectID: nil, argumentsDigest: target),
        requirements: .init(paths: [.init(path: path(target), operation: .read)]), now: instant)
    }
    let accepted = try authorization(from: read("/people/me/.config/value", in: &ledger))
    let outside = try read("/people/me/private", in: &ledger)
    #expect(outside == .denied(.userData))
    var environment = ledger.environment
    environment.paths?.pathRules.insert(
      .init(root: path("/people/me/.config/secret"), kind: .hostData))
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    #expect(try read("/people/me/.config/secret", in: &ledger) == .denied(.hostData))
    var settings = try #require(ledger.sandboxSettings.providers[provider])
    settings.defaults.readExceptions = []
    _ = try ledger.setProviderSandboxSettings(
      settings, for: provider, expectedRevision: ledger.revision)
    #expect(throws: PermissionModelError.invalidAuthorization) {
      try ledger.invocationAccess(accepted.id)
    }
    #expect(try read("/people/me/.config/value", in: &ledger) == .denied(.userData))
    #expect(
      !ledger.canApproveReadException(
        at: path("/host/credentials"), for: provider, settings: .init(), limits: .init()))
    #expect(
      !ledger.canApproveReadException(
        at: path("/projects/a"), for: provider, settings: .init(), limits: .init()))
    #expect(
      !ledger.canApproveReadException(
        at: path("/people/me/.config"), for: provider, settings: .init(),
        limits: .init(owner: .available(.init(deniedReadLocations: [path("/people")])))))
  }

  @Test func purposeEditsPreserveReadEvidenceAndFilesDoNotOpenDescendants() throws {
    var ledger = try ledger()
    let file = try ApprovedReadException(
      declaredPath: "~/file", path: path("/people/me/file"), filesystemIdentity: Data("file".utf8),
      isDirectory: false, purpose: "Read file")
    _ = try ledger.setProviderSandboxSettings(
      .init(defaults: .init(readExceptions: [file])), for: provider,
      expectedRevision: ledger.revision)
    let admitted = try authorization(
      from: ledger.authorize(
        invocation: .init(
          principal: principal, tool: "read", projectID: nil, argumentsDigest: "file"),
        requirements: .init(paths: [.init(path: file.path, operation: .read)]), now: instant))
    var settings = try #require(ledger.sandboxSettings.providers[provider])
    var approved = try #require(settings.defaults.readExceptions.first)
    let identity = approved.identity
    approved.purpose = "Read the existing file"
    settings.defaults.readExceptions = [approved]
    _ = try ledger.setProviderSandboxSettings(
      settings, for: provider, expectedRevision: ledger.revision)
    #expect(
      ledger.sandboxSettings.providers[provider]?.defaults.readExceptions.first?.identity
        == identity)
    #expect(try ledger.invocationAccess(admitted.id).id == admitted.id)
    let below = try ledger.authorize(
      invocation: .init(
        principal: principal, tool: "read", projectID: nil, argumentsDigest: "below"),
      requirements: .init(paths: [.init(path: path("/people/me/file/child"), operation: .read)]),
      now: instant)
    #expect(below == .denied(.userData))
    let write = try ledger.authorize(
      invocation: .init(
        principal: principal, tool: "write", projectID: nil, argumentsDigest: "write"),
      requirements: .init(paths: [.init(path: file.path, operation: .write)]), now: instant)
    #expect(write == .denied(.readOnlyLocation))
  }

  @Test func declarationNetworkCeilingKeepsBothOwnerSelectionAndTrustedDependency() throws {
    var ledger = try ledger()
    var environment = ledger.environment
    environment.trustedHosts = [HostRule("allowed.test"), HostRule("other.test")]
    _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    let selected = NetworkAccess.custom(
      hosts: ["allowed.test", "not-trusted.test"], includesTrusted: false)
    _ = try ledger.setProviderSandboxSettings(
      .init(defaults: .init(network: selected, networkCeiling: .trusted)), for: provider,
      expectedRevision: ledger.revision)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: .init(
          principal: principal, tool: "discover", projectID: nil, argumentsDigest: "network"),
        requirements: .init(), now: instant))
    #expect(
      try ledger.prepareExecutionPermissions(proof.id).network
        == .custom(hosts: ["allowed.test"], includesTrusted: false))
    var settings = try #require(ledger.sandboxSettings.providers[provider])
    settings.defaults.networkCeiling = NetworkAccess.none
    _ = try ledger.setProviderSandboxSettings(
      settings, for: provider, expectedRevision: ledger.revision)
    #expect(throws: PermissionModelError.self) { try ledger.invocationAccess(proof.id) }
  }

  @Test func removingAnOverrideInvalidatesOnlyItsDependentSandbox() throws {
    var ledger = try ledger()
    _ = try ledger.setProviderSandboxSettings(
      .init(defaults: .init(), projects: ["a": .init(network: .trusted)]),
      for: provider, expectedRevision: ledger.revision)
    func admit(_ project: String) throws -> InvocationAuthorization {
      try authorization(
        from: ledger.authorize(
          invocation: .init(
            principal: principal, tool: "process", projectID: project, argumentsDigest: project),
          requirements: .init(sandboxProjectID: project), now: instant))
    }
    let a = try admit("a")
    let b = try admit("b")
    _ = try ledger.prepareExecutionPermissions(a.id)
    _ = try ledger.prepareExecutionPermissions(b.id)
    var settings = try #require(ledger.sandboxSettings.providers[provider])
    settings.projects["a"] = nil
    _ = try ledger.setProviderSandboxSettings(
      settings, for: provider, expectedRevision: ledger.revision)
    #expect(throws: PermissionModelError.invalidAuthorization) { try ledger.invocationAccess(a.id) }
    #expect(try ledger.invocationAccess(b.id).id == b.id)
  }

  @Test func projectlessProjectionCannotBorrowOneTimeProjectAuthority() throws {
    var ledger = try ledger()
    let invocation = InvocationIdentity(
      principal: principal, tool: "discover", projectID: nil, argumentsDigest: "projectless")
    let requirements = InvocationRequirements(actions: [
      .init(requirement: try PermissionRequirement(.project("a"), .read))
    ])
    let pending = try request(
      from: ledger.authorize(
        invocation: invocation, requirements: requirements, now: instant))
    try ledger.answer(pending.id, with: .onlyThisTime, now: instant)
    let proof = try authorization(
      from: ledger.authorize(
        invocation: invocation, requirements: requirements, retryIDs: [pending.id], now: instant))
    let projection = try ledger.prepareExecutionPermissions(proof.id)
    let project = path("/projects/a")
    #expect(
      !projection.readablePaths.contains {
        $0.path.contains(project)
          && !($0.excludedSubtrees ?? []).contains { $0.contains(project) }
      })
  }
}
