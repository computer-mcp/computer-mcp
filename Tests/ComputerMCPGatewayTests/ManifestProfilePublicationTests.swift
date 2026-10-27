import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@Suite struct ManifestProfilePublicationTests {
  @Test func sourceMergingRequiresCompleteCanonicalAgreement() throws {
    let original = try sourceProfile()
    var same = try sourceProfile()
    same.authorizationRevision = 999
    var resolution = GatewayConfigurationResolution(profileDeclarations: [original])
    try resolution.merge(.init(profileDeclarations: [same]))
    #expect(resolution.profileDeclarations == [original])
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try resolution.merge(.init(profileDeclarations: []))
    }
    var changed = original
    try changed.permissions.set(.denied, for: .screen)
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try resolution.merge(.init(profileDeclarations: [changed]))
    }
  }

  @Test func unchangedDeclarationPreservesLaterOwnerEdits() async throws {
    let f = try ProfilePublicationFixture()
    try await f.runtime.ready()
    var edited = try #require(f.database.profiles().first)
    try edited.permissions.set(.denied, for: .screen)
    try f.database.saveProfile(edited, expectedRevision: edited.authorizationRevision)
    let before = try f.database.configurationState()
    let controlRevision = try f.view().revision
    var sameSource = try sourceProfile()
    sameSource.authorizationRevision = 999
    let published = try f.publish([sameSource])
    #expect(published == before)
    #expect(try f.view().revision == controlRevision)
    try f.database.bootstrapPermissionProfiles([sameSource], declarations: [sameSource])
    #expect(try f.database.configurationState() == before)
    var changedSource = sameSource
    try changedSource.permissions.set(.granted(.access), for: .unifiedLogs)
    let changed = try f.publish([changedSource])
    let active = try #require(changed.profiles.first)
    #expect(active.permissions.state(for: .screen) == .granted(.access))
    #expect(active.permissions.state(for: .unifiedLogs) == .granted(.access))
    #expect(active.authorizationRevision == before.profiles[0].authorizationRevision + 1)
  }

  @Test(arguments: [false, true])
  func declarationChangeAndRemovalRevokeBoundWorkAndConsent(removing: Bool) async throws {
    var initial = try sourceProfile()
    initial.fullAccess = true
    let f = try ProfilePublicationFixture(declarations: [initial])
    try await f.runtime.ready()
    let subject = try f.subject(initial.id)
    try f.runtime.service.connect(subject: subject, id: "connection")
    try f.runtime.service.setConnectionConsent(subject: subject, id: "connection", allowed: true)
    let requirements = try InvocationRequirements(actions: [
      .init(requirement: .init(.screen, .access))
    ])
    guard
      case .allowed(let authorization) = try f.runtime.service.admit(
        subject: subject, tool: "fixture", projectID: nil, argumentsDigest: "digest",
        requirements: requirements, connectionID: "connection", now: f.now)
    else { throw ProfilePublicationFailure.unexpected }
    let execution = try f.runtime.store.transactionWithDatabase { _, ledger in
      try ledger.startExecution(
        owner: subject.principal, authorizationIDs: [authorization.id], now: f.now)
    }
    var changed = initial
    try changed.permissions.set(.denied, for: .screen)
    let before = try f.view().revision
    _ = try f.publish(removing ? [] : [changed])
    #expect(try f.view().revision == before + 1)
    try f.runtime.store.readWithDatabase { _, ledger in
      var inspected = ledger
      #expect(ledger.environment.connections["connection"]?.consent == nil)
      #expect(
        inspected.executionAccess(
          execution.id, principal: subject.principal, operation: .readResult, now: f.now)
          == .denied(.authorizationRevoked))
      if removing {
        #expect(ledger.environment.endedConnections.contains("connection"))
        #expect(ledger.permissions(for: subject.principal).entries.isEmpty)
      }
    }
    if removing {
      #expect(try f.database.profiles().isEmpty)
    } else {
      #expect(
        try f.runtime.service.admit(
          subject: subject, tool: "fixture", projectID: nil, argumentsDigest: "digest",
          requirements: requirements, now: f.now) == .denied(.permissionDenied(.screen)))
    }
  }

  @Test func newDeclarationsWaitForPublicationAndFailedCandidatesLeaveAuthorityUntouched()
    async throws
  {
    let f = try ProfilePublicationFixture()
    try await f.runtime.ready()
    let original = try sourceProfile()
    let added = try sourceProfile(id: .chatGPTObserve)
    let before = try f.database.configurationState()
    let revision = try f.view().revision
    let candidate = GatewayConfigurationResolution(profileDeclarations: [original, added])
    #expect(candidate.profileDeclarations?.count == 2)
    try f.database.bootstrapPermissionProfiles([original, added], declarations: [original, added])
    #expect(try f.database.configurationState() == before)
    #expect(throws: ProfilePublicationFailure.abort) {
      try f.publish([original, added]) { _ in throw ProfilePublicationFailure.abort }
    }
    #expect(try f.database.configurationState() == before)
    #expect(try f.view().revision == revision)
    let published = try f.publish([original, added])
    #expect(published.profiles.map(\.id).contains(added.id))
    #expect(try f.view().revision == revision + 1)
  }

  @Test func freshManagedPolicyCanRejectAChangedSourceAtPublication() async throws {
    let f = try ProfilePublicationFixture()
    try await f.runtime.ready()
    let before = try f.database.configurationState()
    let revision = try f.view().revision
    let added = try sourceProfile(id: .chatGPTObserve)
    #expect(throws: GatewayPermissionError.managedLimit) {
      try f.publish([try sourceProfile(), added]) { _ in
        f.reader.set(.machineFile, .available(Data("[permissions]\nscreen = 'deny'".utf8)))
      }
    }
    #expect(try f.database.configurationState() == before)
    #expect(try f.view().revision == revision)
  }

  @Test func staleSourceSnapshotCannotOverwriteAnOwnerOrPublicationChange() async throws {
    let f = try ProfilePublicationFixture()
    try await f.runtime.ready()
    let beforeOwner = try f.database.configurationState()
    var edited = try #require(beforeOwner.profiles.first)
    try edited.permissions.set(.denied, for: .screen)
    try f.database.saveProfile(edited, expectedRevision: edited.authorizationRevision)
    let afterOwner = try f.database.configurationState()
    var callbacks = 0
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try f.publish([try sourceProfile()], expected: beforeOwner) { _ in callbacks += 1 }
    }
    #expect(callbacks == 0)
    var changedSource = try sourceProfile()
    try changedSource.permissions.set(.denied, for: .screen)
    let published = try f.publish([changedSource])
    #expect(published.profiles == afterOwner.profiles)
    #expect(published.profileSource != afterOwner.profileSource)
    let revision = try f.view().revision
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try f.publish([try sourceProfile()], expected: afterOwner) { _ in callbacks += 1 }
    }
    #expect(callbacks == 0)
    #expect(try f.database.configurationState() == published)
    #expect(try f.view().revision == revision)
  }

  @Test func lateSQLFailureRollsBackProfilesProvenanceAndBoundAuthority() async throws {
    let f = try ProfilePublicationFixture()
    try await f.runtime.ready()
    let subject = try f.subject(sourceProfile().id)
    guard
      case .allowed(let authorization) = try f.runtime.service.admit(
        subject: subject, tool: "fixture", projectID: nil, argumentsDigest: "digest",
        requirements: .init(actions: [try .init(requirement: .init(.screen, .access))]), now: f.now)
    else { throw ProfilePublicationFailure.unexpected }
    let before = try f.database.configurationState()
    let revision = try f.view().revision
    try await f.database.connection.writer.write {
      try $0.execute(
        sql: """
          CREATE TRIGGER refuse_publication BEFORE INSERT ON configurationRevisions
          BEGIN SELECT RAISE(ABORT, 'fixture'); END
          """)
    }
    var changed = try sourceProfile()
    try changed.permissions.set(.denied, for: .screen)
    #expect(throws: DatabaseError.self) { try f.publish([changed]) }
    #expect(try f.database.configurationState() == before)
    #expect(try f.view().revision == revision)
    try f.runtime.store.transactionWithDatabase { _, ledger in
      _ = try ledger.invocationAccess(authorization.id)
    }
  }

  @Test(arguments: [false, true])
  func publicationCannotAdoptSuspendedOrUnconfirmedProfiles(suspended: Bool) async throws {
    let f = try ProfilePublicationFixture()
    try await f.runtime.ready()
    if suspended {
      f.counter.forget()
      _ = try f.view()
    } else {
      try await f.database.connection.writer.write {
        try $0.execute(sql: "UPDATE permissionProfiles SET authorityEpoch = NULL")
      }
    }
    let before = try f.database.configurationState()
    let revision = try f.view().revision
    var changed = try sourceProfile()
    try changed.permissions.set(.denied, for: .screen)
    if suspended {
      #expect(throws: PermissionModelError.authoritySuspended) { try f.publish([changed]) }
    } else {
      #expect(throws: GatewayPermissionError.profileUnavailable) { try f.publish([changed]) }
    }
    #expect(try f.database.configurationState() == before)
    #expect(try f.view().revision == revision)
    #expect(try f.view().unconfirmedProfileIDs == [changed.id])
  }

  @Test func removingAnExplicitBuiltinRestoresItsImplicitDefault() async throws {
    let explicit = try sourceProfile(id: .chatGPTOperate)
    let f = try ProfilePublicationFixture(declarations: [explicit], seeds: [explicit, .observe])
    try await f.runtime.ready()
    var implicit = try #require(f.database.profiles().first { $0.id == .chatGPTObserve })
    try implicit.permissions.set(.denied, for: .screen)
    try f.database.saveProfile(implicit, expectedRevision: implicit.authorizationRevision)
    let before = try #require(f.database.profiles().first { $0.id == .chatGPTObserve })
    let published = try f.publish([])
    #expect(published.profiles.first { $0.id == before.id } == before)
    let reset = try #require(published.profiles.first { $0.id == .chatGPTOperate })
    #expect(reset.permissions.state(for: .screen) == .notGranted)
    #expect(reset.permissions.state(for: .skills) == .granted(.access))
    #expect(reset.permissions.state(for: .machineInformation) == .granted(.access))
  }

  @Test func sourceChangesRequireAConfiguredManagedPolicyService() throws {
    let database = try GatewayDatabase(inMemory: ())
    let initial = try sourceProfile()
    try database.bootstrapPermissionProfiles([initial])
    let before = try database.configurationState()
    var changed = initial
    try changed.permissions.set(.denied, for: .screen)
    var callbacks = 0
    #expect(throws: GatewayPermissionError.invalidPolicySnapshot) {
      try database.activateConfigurationRevision(
        .init(digest: "fixture", manifest: "fixture"), expected: before,
        resolution: .init(profileDeclarations: [changed]), activeTunnelIDs: []
      ) { _ in callbacks += 1 }
    }
    #expect(callbacks == 0)
    #expect(try database.configurationState() == before)
  }
}

private func sourceProfile(id: GatewayProfileID? = nil) throws -> ProfileGrant {
  var profile = ProfileGrant(
    id: id ?? GatewayProfileID(rawValue: "source-profile")!, allowedCallers: [.secureTunnel])
  try profile.permissions.set(.granted(.access), for: .screen)
  return profile
}

private enum ProfilePublicationFailure: Error { case abort, unexpected }

private final class ProfilePublicationFixture {
  let directory: URL
  let database: GatewayDatabase
  let runtime: GatewayPermissionRuntime
  let reader = TestManagedPolicyReader()
  let counter = TestAuthorizationEpochCounter()
  let owner: GatewayPermissionOwner
  let now = Date(timeIntervalSince1970: 1_750_000_000)

  init(declarations: [ProfileGrant]? = nil, seeds: [ProfileGrant]? = nil) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    database = try GatewayDatabase(path: directory.appendingPathComponent("gateway.sqlite").path)
    _ = database.permissionStore(counter: counter)
    let declarations = try declarations ?? [sourceProfile()]
    try database.bootstrapPermissionProfiles(seeds ?? declarations, declarations: declarations)
    let unused = ProfilePublicationPlatform()
    runtime = try database.permissionRuntime(
      platform: .init(
        projectGrants: unused, pluginDirectories: unused,
        applications: TestApplicationBundleLocator(),
        toolProviders: unused, managementToolNames: [], executableSearchDirectories: [],
        gitExecutable: "/usr/bin/false",
        fileChanges: { _ in throw ProfilePublicationFailure.unexpected },
        permissionPolicyReader: reader))
    owner = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
      validate: {})
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  func subject(_ profile: GatewayProfileID) throws -> GatewayPermissionSubject {
    try .init(
      context: .init(caller: .secureTunnel, profileID: profile, trustedPrincipalID: "client"))
  }

  func view() throws -> GatewayPermissionView { try runtime.service.view(owner: owner, now: now) }

  @discardableResult
  func publish(
    _ declarations: [ProfileGrant], expected: GatewayDatabase.ConfigurationState? = nil,
    replace: (GatewayDatabase.ConfigurationState) throws -> Void = { _ in }
  ) throws -> GatewayDatabase.ConfigurationState {
    try database.activateConfigurationRevision(
      .init(digest: UUID().uuidString, manifest: PermissionProfileManifest.encode(declarations)),
      expected: expected ?? database.configurationState(),
      resolution: .init(profileDeclarations: declarations), activeTunnelIDs: [],
      replaceManifest: replace)
  }
}

private struct ProfilePublicationPlatform: ProjectBookmarkServicing, PluginArchiveDirectoryFactory,
  GatewayToolProviderFactory
{
  func registerFolder(at url: URL, displayName: String?) throws -> ComputerMCPCore.RegisteredProject
  {
    throw ProfilePublicationFailure.unexpected
  }
  func resolve(_ project: ComputerMCPCore.RegisteredProject) throws -> ResolvedProjectAccess {
    throw ProfilePublicationFailure.unexpected
  }
  func create(at url: URL) throws -> any PluginArchiveStagingDirectory {
    throw ProfilePublicationFailure.unexpected
  }
  func recover(_ identity: PluginDirectoryIdentity) throws -> any PluginArchiveStagingDirectory {
    throw ProfilePublicationFailure.unexpected
  }
  func identity(url: URL, status: stat, descriptor: Int32) throws -> PluginDirectoryIdentity {
    throw ProfilePublicationFailure.unexpected
  }
  func matches(_ identity: PluginDirectoryIdentity, status: stat, descriptor: Int32) throws -> Bool
  {
    throw ProfilePublicationFailure.unexpected
  }
  func renameExclusively(
    from source: String, in sourceDirectory: Int32, to destination: String,
    in destinationDirectory: Int32
  ) throws { throw ProfilePublicationFailure.unexpected }
  func makeProviders(
    configuration: GatewayConfiguration, commandRunner: any CommandRunning,
    processManager: any ProcessManaging, shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient, hostContext: MCPHostContext
  ) -> GatewayToolRegistry {
    .init(
      providers: { [] }, downstreamPolicy: { _, _ in throw ProfilePublicationFailure.unexpected })
  }
}
