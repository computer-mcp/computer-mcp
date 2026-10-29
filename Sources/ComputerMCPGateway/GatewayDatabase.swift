import ComputerMCPAuthorization
import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPPlugins
import ComputerMCPToolsProject
import ComputerMCPWorktrees
import Crypto
import Foundation
import GRDB

import struct ComputerMCPPermissions.CanonicalPath
import struct ComputerMCPPermissions.PathEnvironmentSnapshot
import struct ComputerMCPPermissions.PermissionLedger
import enum ComputerMCPPermissions.PermissionModelError
import struct ComputerMCPPermissions.Permissions
import struct ComputerMCPPermissions.RegisteredProject

package final class GatewayDatabase: OAuthStore, @unchecked Sendable {
  package let connection: GatewayDatabaseConnection
  package let worktreeStorage: WorktreeStorage?
  private var writer: any DatabaseWriter { connection.writer }
  private let profileChangeLock = NSLock()
  private var profileChangeBroadcasters: [GatewayProfileID: GatewayToolChangeBroadcaster] = [:]
  package var fileURL: URL? { connection.fileURL }
  private let transientOwnershipID = UUID()
  private let permissionStoreLock = NSLock()
  private var permissionStoreCache: SQLitePermissionStore?
  private let transientCounter = TransientAuthorizationEpochCounter()
  let permissionRuntimeLock = NSLock()
  var permissionRuntimeCache: GatewayPermissionRuntime?
  private var authorityChangeHandler: (@Sendable () -> Void)?

  package var transientAuthorizationEpochCounter: any AuthorizationEpochCounter { transientCounter }

  package var mcpProcessOwnershipRoot: URL? {
    fileURL.map {
      $0.deletingLastPathComponent().appendingPathComponent(
        $0.lastPathComponent + ".mcp-processes", isDirectory: true)
    }
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "computer-mcp-mcp-processes-" + transientOwnershipID.uuidString, isDirectory: true)
  }

  package var permissionExecutionRoot: URL {
    fileURL.map {
      $0.deletingLastPathComponent().appendingPathComponent(
        $0.lastPathComponent + ".executions", isDirectory: true)
    }
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "computer-mcp-executions-" + transientOwnershipID.uuidString, isDirectory: true)
  }

  package init(path: String, applicationSupportRoot: URL? = nil) throws {
    connection = try GatewayDatabaseConnection(path: path)
    worktreeStorage = WorktreeStorage(
      databaseURL: connection.fileURL, applicationSupportRoot: applicationSupportRoot)
  }

  package init(inMemory: Void) throws {
    connection = try GatewayDatabaseConnection(inMemory: ())
    worktreeStorage = nil
  }

  package init(connection: GatewayDatabaseConnection) {
    self.connection = connection
    worktreeStorage = WorktreeStorage(databaseURL: connection.fileURL)
  }

  /// Uses this database's writer so permission and project/profile mutations can
  /// share one durable transaction. Runtime dispatch follows a successful commit.
  package func permissionStore(counter: any AuthorizationEpochCounter) -> SQLitePermissionStore {
    permissionStoreLock.withLock {
      if let permissionStoreCache { return permissionStoreCache }
      let store = SQLitePermissionStore(connection: connection, counter: counter)
      permissionStoreCache = store
      return store
    }
  }

  package func configuredPermissionStore() throws -> SQLitePermissionStore {
    if let configured = permissionStoreLock.withLock({ permissionStoreCache }) { return configured }
    guard fileURL == nil else { throw AuthorizationEpochCounterError.unavailable }
    return permissionStore(counter: transientCounter)
  }

  package func setPermissionAuthorityChangeHandler(_ handler: @escaping @Sendable () -> Void) {
    permissionStoreLock.withLock { authorityChangeHandler = handler }
  }

  /// The caller holds the App manifest's publication lock from source read
  /// through activation. The returned report contains bounded dropped-grant facts.
  package func activatePermissionMigration(
    manifest: String, baseURL: URL, applications: any ApplicationBundleLocating,
    bundledPlugins: BundledPlugins = .current
  ) throws -> PermissionMigrationReport? {
    let migration = PermissionMigrationStore(
      connection: connection, store: try configuredPermissionStore())
    let schemaUpgrade = try ProjectManifestUpgrade.upgraded(manifest)
    func reporting(_ report: PermissionMigrationReport? = nil) -> PermissionMigrationReport? {
      guard report != nil || schemaUpgrade?.removedBuiltinIDs.isEmpty == false else { return nil }
      var result = report ?? PermissionMigrationReport(dropped: [], omittedCount: 0)
      result.removedBuiltinIDs = schemaUpgrade?.removedBuiltinIDs ?? []
      return result
    }
    let requiresUpgrade = try PermissionManifestUpgrade.isRequired(manifest: manifest)
    if try migration.isActivated() {
      if requiresUpgrade { try validatePermissionMigrationManifest(manifest) }
      return reporting()
    }
    let hasLegacy = try writer.read { try LegacyProfileRecord.fetchCount($0) > 0 }
    guard requiresUpgrade || hasLegacy else { return reporting() }
    let source: (configuration: GatewayConfiguration, profiles: [LegacyProfileGrant])
    if requiresUpgrade {
      source = try PermissionManifestUpgrade.source(manifest: manifest, baseURL: baseURL)
    } else {
      source = (
        try GatewayConfiguration.load(text: schemaUpgrade?.manifest ?? manifest, baseURL: baseURL),
        []
      )
    }
    let digest = Self.manifestDigest(manifest)
    let sourceProjects = source.configuration.manifestProjects
    func catalog() throws -> PermissionMigrationCatalog {
      try .capture(
        configuration: source.configuration, manifestProfiles: source.profiles,
        configurationDigest: digest, plugins: pluginStoreSnapshot(),
        applications: applications, bundledPlugins: bundledPlugins, manifestProjects: sourceProjects
      )
    }
    let preparedCatalog = try catalog()
    let (plan, state) = try migration.prepare(catalog: preparedCatalog)
    _ = try migration.apply(
      plan, expectedState: state, currentCatalog: catalog(), sourceManifestDigest: digest)
    return reporting(plan.report)
  }

  package func validatePermissionMigrationManifest(_ manifest: String) throws {
    let stored = try writer.read {
      try String.fetchOne($0, sql: "SELECT manifestDigest FROM permissionMigration WHERE id = 1")
    }
    guard stored == Self.manifestDigest(manifest) else {
      throw PermissionMigrationError.stateChanged
    }
  }

  private static func manifestDigest(_ manifest: String) -> String {
    SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// The first source establishes provenance while preserving saved owner edits.
  /// Later explicit source changes belong to atomic manifest publication.
  package func bootstrapPermissionProfiles(
    _ profiles: [ProfileGrant], declarations: [ProfileGrant]? = nil
  ) throws {
    let declarations = declarations ?? profiles
    _ = try Self.profileSource(declarations)
    let needsBootstrap = try writer.read { database in
      guard
        try LegacyProfileRecord.fetchCount(database) == 0
          || Int.fetchOne(database, sql: "SELECT version FROM permissionMigration WHERE id = 1")
            == 1
      else { throw PermissionMigrationError.activationRequired }
      if try Self.publishedProfileSource(in: database) == nil { return true }
      let explicitIDs = Set(declarations.map(\.id))
      let savedIDs = Set(try ProfileRecord.fetchAll(database).map(\.id))
      return profiles.contains {
        GatewayProfileID.builtIns.contains($0.id) && !explicitIDs.contains($0.id)
          && !savedIDs.contains($0.id.rawValue)
      }
    }
    guard needsBootstrap else { return }
    do {
      try permissionTransaction { database in
        let initialSource = try Self.publishedProfileSource(in: database) == nil
        let explicitIDs = Set(declarations.map(\.id))
        for profile in profiles
        where initialSource
          || GatewayProfileID.builtIns.contains(profile.id) && !explicitIDs.contains(profile.id)
        {
          guard try ProfileRecord.fetchOne(database, key: profile.id.rawValue) == nil else {
            continue
          }
          try Self.saveProfile(profile, updatedAt: Date(), expectedRevision: nil, in: database)
        }
        if initialSource { try Self.savePublishedProfileDeclarations(declarations, in: database) }
      }
    } catch PermissionModelError.authoritySuspended {
      // Local diagnostics must start so the owner can confirm a recovered epoch.
      // Missing profiles remain unconfigured until that confirmation is complete.
      return
    }
  }

  static func savePublishedProfileDeclarations(
    _ profiles: [ProfileGrant], in database: Database
  ) throws {
    try database.execute(
      sql: """
        INSERT INTO permissionProfilePublication (id, payload) VALUES (1, ?)
        ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
        """, arguments: [try profileSource(profiles)])
  }

  private static func profileSource(_ profiles: [ProfileGrant]) throws -> Data {
    guard Set(profiles.map(\.id)).count == profiles.count else {
      throw GatewayDatabaseError.configurationChanged
    }
    for profile in profiles { try profile.validate() }
    let payload = Data(try PermissionProfileManifest.encode(profiles).utf8)
    guard payload.count <= 4_194_304 else { throw PermissionPersistenceError.invalidCurrentState }
    return payload
  }

  private static func profileDeclarations(from source: Data?) throws -> [ProfileGrant] {
    guard let source else { return [] }
    guard source.count <= 4_194_304, let text = String(data: source, encoding: .utf8) else {
      throw PermissionPersistenceError.invalidCurrentState
    }
    return try PermissionProfileManifest.decode(text)
  }

  private static func publishedProfileSource(in database: Database) throws -> Data? {
    let source = try Data.fetchOne(
      database, sql: "SELECT payload FROM permissionProfilePublication WHERE id = 1")
    guard source == nil || source!.count <= 4_194_304 else {
      throw PermissionPersistenceError.invalidCurrentState
    }
    return source
  }

  private static func profiles(
    publishing declarations: [ProfileGrant]?, over state: ConfigurationState
  ) throws -> [ProfileGrant] {
    guard let declarations else { return state.profiles }
    _ = try profileSource(declarations)
    let previous = try profileDeclarations(from: state.profileSource)
    let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
    let proposedByID = Dictionary(uniqueKeysWithValues: declarations.map { ($0.id, $0) })
    var profiles = Dictionary(uniqueKeysWithValues: state.profiles.map { ($0.id, $0) })
    let defaults = Dictionary(
      uniqueKeysWithValues: [
        ProfileGrant.observe, .operate, .cloudflareObserve, .cloudflareOperate, .localAdmin,
      ].map { ($0.id, $0) })
    func replace(_ profile: ProfileGrant) throws {
      let current = profiles[profile.id]
      if let current, try profileSource([current]) == profileSource([profile]) { return }
      let revision = current?.authorizationRevision ?? 0
      guard revision < Int64.max else { throw PermissionMigrationError.revisionExhausted }
      var updated = profile
      updated.authorizationRevision = revision + 1
      profiles[profile.id] = updated
    }
    for profile in declarations {
      if let previous = previousByID[profile.id],
        try profileSource([previous]) == profileSource([profile])
      {
        continue
      }
      try replace(profile)
    }
    for removed in previous where proposedByID[removed.id] == nil {
      if let implicit = defaults[removed.id] {
        try replace(implicit)
      } else {
        profiles[removed.id] = nil
      }
    }
    return profiles.values.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  func permissionTransaction<Result>(
    authorizing authority: HostCallAuthoritySnapshot? = nil,
    managementAuthorization: GatewayManagementAuthorization? = nil,
    requiresProfilePolicy: Bool = false,
    _ body: (Database) throws -> Result
  ) throws -> Result {
    let store = try configuredPermissionStore()
    let service = permissionRuntimeLock.withLock { permissionRuntimeCache?.service }
    guard (!requiresProfilePolicy && managementAuthorization == nil) || service != nil else {
      throw GatewayPermissionError.invalidPolicySnapshot
    }
    func apply(
      _ database: Database, ledger: inout PermissionLedger,
      policies: GatewayPermissionPolicySnapshot?
    ) throws -> Swift.Result<Result, any Error> {
      let before = try ProfileRecord.fetchAll(database)
      let beforeConfiguration = try Self.configurationState(in: database)
      if before.isEmpty, try LegacyProfileRecord.fetchCount(database) == 0,
        try Int.fetchOne(database, sql: "SELECT count(*) FROM permissionSubjects") == 0,
        ledger.suspendedAuthority?.permissions.values.allSatisfy({ $0.entries.isEmpty }) != false,
        ledger.suspendedAuthority?.sandboxSettings.entries.isEmpty != false
      {
        if let recovery = ledger.pendingEpochRecovery, recovery.executionsToTerminate.isEmpty {
          try ledger.acknowledgeEpochRecovery(recovery.epochID)
        }
        if let epoch = ledger.authorizationEpochID, ledger.pendingEpochRecovery == nil,
          ledger.suspendedAuthority != nil
        {
          try ledger.confirmSuspendedAuthority(epochID: epoch, expectedRevision: ledger.revision)
        }
      }
      guard ledger.suspendedAuthority == nil, ledger.pendingEpochRecovery == nil,
        let epoch = ledger.authorizationEpochID
      else { throw PermissionModelError.authoritySuspended }
      if let service, let policies {
        _ = try service.refresh(database, ledger: &ledger, snapshot: policies, now: Date())
      }
      if let authority {
        guard let id = authority.authorizationID else {
          throw PermissionModelError.invalidAuthorization
        }
        do { _ = try ledger.invocationAccess(id) } catch {
          guard let proof = ledger.authorizations[id], let executionID = proof.executionID,
            ledger.executionAccess(
              executionID, principal: proof.invocation.principal,
              operation: .readResult, now: Date()) == .allowed
          else { throw error }
        }
      }
      do {
        try Self.requireManagementAuthorization(
          managementAuthorization, in: database, ledger: &ledger)
      } catch {
        // Preserve observed retirement without beginning the rejected management mutation.
        return .failure(error)
      }
      let value = try body(database)
      try GatewayPermissionService.reconcileProviderSources(
        database: database, ledger: &ledger, previous: beforeConfiguration.plugins)
      try Self.reconcileDerivedSources(in: database)
      for row in try ProfileRecord.fetchAll(database) {
        let previous = before.first { $0.id == row.id }
        guard
          previous?.payload != row.payload
            || previous?.authorizationRevision != row.authorizationRevision
        else { continue }
        guard previous == nil || previous?.authorityEpoch == epoch.uuidString else {
          throw GatewayPermissionError.profileUnavailable
        }
        let profile = try row.value()
        if requiresProfilePolicy, let policies {
          try GatewayPermissionService.validateEdit(
            profile, previous: try previous?.value(), snapshot: policies, ledger: ledger)
        }
        try ProfileRecord(profile, authorityEpoch: epoch).save(database)
        try GatewayPermissionService.synchronizeBound(profile, database: database, ledger: &ledger)
        try database.execute(
          sql: "DELETE FROM clientControlTrust WHERE profileID = ?", arguments: [row.id])
      }
      let remainingIDs = Set(try ProfileRecord.fetchAll(database).map(\.id))
      for removed in before where !remainingIDs.contains(removed.id) {
        let profile = try removed.value()
        try GatewayPermissionService.synchronizeBound(
          ProfileGrant(id: profile.id, allowedCallers: []), database: database, ledger: &ledger)
        try database.execute(
          sql: "DELETE FROM clientControlTrust WHERE profileID = ?", arguments: [removed.id])
        try database.execute(
          sql: "DELETE FROM permissionOwnerPolicies WHERE profileID = ?", arguments: [removed.id])
      }
      let sourceRules = try GatewayConfigurationPaths.read(
        GatewayConfigurationPaths.configurationKey, database: database)
      let platformRules = try GatewayConfigurationPaths.read(
        GatewayConfigurationPaths.platformKey, database: database)
      if ledger.environment.paths != nil || sourceRules != nil || platformRules != nil {
        var paths = try ledger.environment.paths ?? PathEnvironmentSnapshot()
        if sourceRules != nil || platformRules != nil {
          let proposed = (sourceRules ?? []).union(platformRules ?? [])
          paths.pathRules = Set(
            proposed.map { rule in
              paths.pathRules.first { $0.root == rule.root && $0.kind == rule.kind } ?? rule
            })
        }
        let prior = Dictionary(uniqueKeysWithValues: paths.registeredProjects.map { ($0.id, $0) })
        let derived = try Self.availableDerivedProjects(in: database)
        let projects = try Self.projects(in: database).map { project in
          let root = try CanonicalPath(
            ProjectPathResolver.resolve(
              project.rootPath, relativeTo: URL(fileURLWithPath: "/")
            ).path)
          let source = derived.first { $0.projectID == project.id }?.source
            .id
          var current =
            prior[project.id]
            ?? ComputerMCPPermissions.RegisteredProject(
              id: project.id, root: root, sourceID: source)
          current.root = root
          current.sourceID = source
          current.hostContentIdentity = try Self.hostContentIdentity(
            derived.first { $0.projectID == project.id })
          return current
        }
        try paths.setProjects(projects)
        var environment = ledger.environment
        environment.paths = paths
        if paths != ledger.environment.paths {
          _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
        }
      }
      try GatewayPermissionService.reconcileStandingConsents(database: database, ledger: &ledger)
      if try Self.configurationState(in: database) != beforeConfiguration {
        guard
          let revision = try Int64.fetchOne(
            database,
            sql: "SELECT revision FROM permissionControlRevision WHERE id = 1"),
          revision < Int64.max
        else { throw PermissionMigrationError.revisionExhausted }
        try database.execute(
          sql: "UPDATE permissionControlRevision SET revision = revision + 1 WHERE id = 1")
      }
      return .success(value)
    }
    let result: Swift.Result<Result, any Error>
    if let service {
      result = try service.transactionWithPolicy { database, ledger, policies in
        try apply(database, ledger: &ledger, policies: policies)
      }
    } else {
      result = try store.transactionWithDatabase { database, ledger in
        try apply(database, ledger: &ledger, policies: nil)
      }
      permissionStoreLock.withLock { authorityChangeHandler }?()
    }
    return try result.get()
  }

  func hostCallRecordStore() -> HostCallRecordStore { HostCallRecordStore(connection: connection) }

  /// Profile and persistent client trust are checked with the metadata write.
  func withHostAuthority<Result>(
    _ authority: HostCallAuthoritySnapshot, operation: () throws -> Result
  ) throws -> Result {
    try permissionTransaction(authorizing: authority) { database in
      try Self.requireHostAuthority(authority, database: database)
      return try operation()
    }
  }

  private static func requireHostAuthority(
    _ authority: HostCallAuthoritySnapshot, database: Database
  ) throws {
    let context = authority.context
    guard let profile = try ProfileRecord.fetchOne(database, key: context.profileID.rawValue),
      profile.authorizationRevision == authority.profileRevision
    else {
      throw HostCallAuthorityConflict.profileRevision
    }
    guard let consent = authority.consent, consent.lifetime == .alwaysAllowClient else { return }
    guard let id = consent.trustID, let revision = consent.trustRevision,
      let trust = try GatewayClientTrust.fetchOne(database, key: id),
      trust.fullAccessAllowed, trust.revision == revision,
      trust.principalID == context.trustedPrincipalID, trust.profileID == context.profileID,
      trust.caller == context.caller, trust.profile.hasSameAuthorization(as: consent.profile)
    else {
      throw MCPHostServiceError.denied("Client trust changed before this callback committed.")
    }
  }

  package func oauthTransaction<Result>(
    _ body: (any OAuthStoreTransaction) throws -> Result
  ) throws -> Result {
    try writer.write { try body(GatewayOAuthTransaction(database: $0)) }
  }

  package func reconcileOAuthTunnels(activeIDs: Set<String>) throws {
    try writer.write {
      try GatewayOAuthTransaction(database: $0).reconcileTunnels(activeIDs: activeIDs)
    }
  }

  /// Persisted inputs read under one SQLite snapshot. Alias bindings participate in
  /// comparison even though only canonical projects appear in the public directory.
  package struct ConfigurationState: Equatable, Sendable {
    package let projects: [ComputerMCPCore.RegisteredProject]
    package let projectAliases: [String: String]
    package let profiles: [ProfileGrant]
    package let plugins: PluginStoreSnapshot
    package let profileSource: Data?
    package let derivedProjects: [DerivedProjectRecord]

    package init(
      projects: [ComputerMCPCore.RegisteredProject], projectAliases: [String: String],
      profiles: [ProfileGrant], plugins: PluginStoreSnapshot, profileSource: Data? = nil,
      derivedProjects: [DerivedProjectRecord] = []
    ) {
      self.projects = projects
      self.projectAliases = projectAliases
      self.profiles = profiles
      self.plugins = plugins
      self.profileSource = profileSource
      self.derivedProjects = derivedProjects
    }
  }

  package func configurationState() throws -> ConfigurationState {
    try writer.read { try Self.configurationState(in: $0) }
  }

  package func prepareProjectChange(
    _ mutation: ProjectConfigurationMutation, expected: ConfigurationState
  ) throws -> PreparedProjectChange<ConfigurationState> {
    let timestamp = Date()
    let receiptID = UUID().uuidString
    return try writer.write { database in
      guard try Self.configurationState(in: database) == expected else {
        throw GatewayDatabaseError.configurationChanged
      }
      var prepared: PreparedProjectChange<ConfigurationState>?
      try database.inSavepoint {
        let result = try Self.applyProjectChange(
          mutation, expected: expected,
          timestamp: timestamp, receiptID: receiptID, in: database)
        prepared = PreparedProjectChange(
          mutation: mutation, expected: expected,
          proposed: try Self.configurationState(in: database),
          result: result, timestamp: timestamp,
          receiptID: receiptID)
        return .rollback
      }
      guard let prepared else { throw GatewayDatabaseError.configurationChanged }
      return prepared
    }
  }

  package func saveProjectChange(
    _ prepared: PreparedProjectChange<ConfigurationState>,
    resolution: GatewayConfigurationResolution,
    authorization: GatewayManagementAuthorization? = nil
  ) throws -> ConfigurationState {
    let committed = try permissionTransaction(managementAuthorization: authorization) { database in
      guard try Self.configurationState(in: database) == prepared.expected else {
        throw GatewayDatabaseError.configurationChanged
      }
      let result = try Self.applyProjectChange(
        prepared.mutation, expected: prepared.expected,
        timestamp: prepared.timestamp, receiptID: prepared.receiptID, in: database)
      guard result == prepared.result,
        try Self.configurationState(in: database) == prepared.proposed
      else { throw GatewayDatabaseError.configurationChanged }
      try Self.applyRuntimeResolution(resolution, in: database)
      return try Self.configurationState(in: database)
    }
    for profile in committed.profiles where !prepared.expected.profiles.contains(profile) {
      profileChangeLock.withLock { profileChangeBroadcasters[profile.id] }?.send()
    }
    return committed
  }

  private static func applyProjectChange(
    _ mutation: ProjectConfigurationMutation, expected: ConfigurationState,
    timestamp: Date, receiptID: String, in database: Database
  ) throws -> ProjectChangeResult {
    switch mutation {
    case .register(let project):
      let result = try registerProjectIdempotently(project, in: database)
      return .registered(result.project, created: result.created)
    case .repair(let project, _):
      guard let original = expected.projects.first(where: { $0.id == project.id }),
        original.createdAt == project.createdAt,
        expected.projectAliases[project.id] == nil
      else { throw GatewayDatabaseError.configurationChanged }
      if let existing = try registeredProject(
        canonicalRoot: canonicalProjectRoot(project.rootPath), in: database),
        existing.id != project.id
      {
        throw ProjectRepairError.rootAlreadyRegistered(projectID: existing.id)
      }
      try saveProject(project, in: database)
      let affectedIDs = Set(
        expected.projectAliases.filter { $0.value == project.id }.map(\.key) + [project.id])
      for stored in expected.profiles
      where affectedIDs.contains(where: {
        stored.permissions.state(for: .project($0)) != .notGranted
      }) {
        let profile = stored
        try profile.validate()
        try saveProfile(
          profile, updatedAt: timestamp, expectedRevision: stored.authorizationRevision,
          in: database)
      }
      return .repaired(project)
    case .remove(let id):
      _ = try removeProject(
        id: id, expectedConfiguration: expected,
        now: timestamp, in: database)
      return .removed
    case .deduplicate(let digest, let allowMetadataConflicts):
      return .deduplicated(
        try applyProjectDeduplication(
          expectedPlanDigest: digest, allowMetadataConflicts: allowMetadataConflicts,
          now: timestamp, expectedConfiguration: expected,
          receiptID: receiptID, in: database))
    }
  }

  static func configurationState(in database: Database) throws -> ConfigurationState {
    try ConfigurationState(
      projects: projects(in: database),
      projectAliases: Dictionary(
        uniqueKeysWithValues: ProjectAliasRecord.fetchAll(database).map {
          ($0.aliasProjectID, $0.canonicalProjectID)
        }),
      profiles: profiles(in: database), plugins: pluginStoreSnapshot(in: database),
      profileSource: publishedProfileSource(in: database),
      derivedProjects: SQLiteDerivedProjectStore.records(database))
  }

  package func pluginStoreSnapshot() throws -> PluginStoreSnapshot {
    try writer.read { try Self.pluginStoreSnapshot(in: $0) }
  }

  private static func pluginStoreSnapshot(in database: Database) throws -> PluginStoreSnapshot {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT revision, payloadJSON FROM pluginState WHERE id = 1")
    else {
      return PluginStoreSnapshot()
    }
    let payload: String = row["payloadJSON"]
    guard payload.utf8.count <= 4_194_304 else { throw PluginStoreError.invalidState }
    let state = try JSONDecoder().decode(PluginStoreSnapshot.self, from: Data(payload.utf8))
    let revision: Int64 = row["revision"]
    guard state.revision == revision else { throw PluginStoreError.invalidState }
    try state.validate()
    return state
  }

  @discardableResult
  package func savePluginStoreSnapshot(
    _ state: PluginStoreSnapshot, expectedRevision: Int64,
    expectedConfiguration: ConfigurationState? = nil,
    resolution: GatewayConfigurationResolution = .init(),
    authorization: GatewayManagementAuthorization? = nil
  ) throws -> ConfigurationState {
    try state.validate()
    guard
      expectedConfiguration != nil || resolution.projects.isEmpty
    else { throw PluginStoreError.invalidState }
    guard expectedRevision >= 0, expectedRevision < Int64.max,
      state.revision == expectedRevision + 1
    else {
      throw PluginStoreError.invalidState
    }
    let committed = try permissionTransaction(managementAuthorization: authorization) { database in
      let current =
        try Int64.fetchOne(database, sql: "SELECT revision FROM pluginState WHERE id = 1") ?? 0
      guard current == expectedRevision else {
        throw PluginStoreError.staleRevision(expected: expectedRevision, actual: current)
      }
      if let expectedConfiguration,
        try Self.configurationState(in: database) != expectedConfiguration
      {
        throw GatewayDatabaseError.configurationChanged
      }
      try Self.writePluginSnapshot(state, database: database)
      try Self.applyRuntimeResolution(resolution, in: database)
      return try Self.configurationState(in: database)
    }
    return committed
  }

  static func writePluginSnapshot(_ state: PluginStoreSnapshot, database: Database) throws {
    try state.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    guard data.count <= 4_194_304, let payload = String(data: data, encoding: .utf8) else {
      throw PluginStoreError.invalidState
    }
    try database.execute(
      sql: """
        INSERT INTO pluginState (id, revision, payloadJSON) VALUES (1, ?, ?)
        ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, payloadJSON = excluded.payloadJSON
        """, arguments: [state.revision, payload])
  }

  private static func applyRuntimeResolution(
    _ resolution: GatewayConfigurationResolution, in database: Database
  ) throws {
    if let rules = resolution.configurationPaths {
      try GatewayConfigurationPaths.save(
        rules, key: GatewayConfigurationPaths.configurationKey, database: database)
    }
    for change in resolution.projects {
      guard change.original.id == change.resolved.id,
        try ProjectRecord.fetchOne(database, key: change.original.id)?.value == change.original
      else { throw GatewayDatabaseError.configurationChanged }
      try saveProject(change.resolved, in: database)
    }
  }

  package func saveProject(_ project: ComputerMCPCore.RegisteredProject) throws {
    try permissionTransaction { database in
      try Self.saveProject(project, in: database)
    }
  }

  /// A standalone manifest can initialize a fresh project table. Saved folder
  /// registrations remain authoritative on later starts.
  package func registerManifestProjectsForStartup(
    _ declarations: [ComputerMCPCore.RegisteredProject]
  ) throws {
    guard !declarations.isEmpty else { return }
    guard Set(declarations.map(\.id)).count == declarations.count else {
      throw ConfigurationError.invalid(
        "Standalone project declarations must have distinct identifiers.")
    }
    for project in declarations {
      try ProjectManifestConfig(
        id: project.id, displayName: project.displayName, path: project.rootPath
      ).validate()
    }
    let roots = try Dictionary(
      uniqueKeysWithValues: declarations.map {
        ($0.id, try ProjectPathResolver.canonicalProject(URL(fileURLWithPath: $0.rootPath)).path)
      })
    guard Set(roots.values).count == declarations.count else {
      throw ConfigurationError.invalid("Standalone project declarations must use distinct folders.")
    }
    try permissionTransaction { database in
      let current = try Self.projects(in: database)
      if current.isEmpty {
        for project in declarations { try Self.saveProject(project, in: database) }
      } else {
        for declaration in declarations {
          guard let existing = current.first(where: { $0.id == declaration.id }),
            try ProjectPathResolver.canonicalProject(URL(fileURLWithPath: existing.rootPath)).path
              == roots[declaration.id]
          else {
            throw ConfigurationError.invalid(
              "Standalone project '\(declaration.id)' conflicts with saved folder authority. Use project management to review the registration, or select a fresh standalone database."
            )
          }
        }
      }
    }
  }

  /// Bookmark resolution must not overwrite a concurrent edit or recreate a removed registration.
  @discardableResult
  func saveProject(
    _ project: ComputerMCPCore.RegisteredProject,
    replacing expected: ComputerMCPCore.RegisteredProject
  )
    throws -> Bool
  {
    try permissionTransaction { database in
      guard project.id == expected.id,
        try ProjectRecord.fetchOne(database, key: expected.id)?.value == expected
      else { return false }
      try Self.saveProject(project, in: database)
      return true
    }
  }

  private static func saveProject(
    _ project: ComputerMCPCore.RegisteredProject, in database: Database
  ) throws {
    if let derived = try SQLiteDerivedProjectStore.record(project.id, in: database),
      case .host = derived.provenance
    {
      guard derived.root == project.rootPath,
        let old = try ProjectRecord.fetchOne(database, key: project.id),
        old.createdAt.databaseValue == project.createdAt.databaseValue
      else { throw DerivedProjectStoreError.invalidRecord }
    }
    try ProjectRecord(project).save(database)
    try reconcileDerivedSources(in: database)
    let canonicalRoot = Self.canonicalProjectRoot(project.rootPath)
    try ProjectCanonicalRootRecord
      .filter(Column("projectID") == project.id)
      .filter(Column("canonicalRootPath") != canonicalRoot)
      .deleteAll(database)
    try ProjectCanonicalRootRecord(
      canonicalRootPath: canonicalRoot,
      projectID: project.id,
      createdAt: project.createdAt
    ).insert(database, onConflict: .ignore)
  }

  /// Local recovery ownership is separate from exported plugin settings.
  package func pluginOwnedDirectories() throws -> [PluginOwnedDirectory] {
    try writer.read { database in
      let rows = try Row.fetchAll(
        database, sql: "SELECT id, payloadJSON FROM pluginOwnedDirectories LIMIT 4097")
      guard rows.count <= 4096 else { throw PluginStoreError.invalidState }
      return try rows.map { row in
        let payload: String = row["payloadJSON"]
        guard payload.utf8.count <= 16_384 else { throw PluginStoreError.invalidState }
        let record = try JSONDecoder().decode(PluginOwnedDirectory.self, from: Data(payload.utf8))
        let id: String = row["id"]
        guard id == record.installationID else { throw PluginStoreError.invalidState }
        try record.validate()
        return record
      }
    }
  }

  package func recordPluginDirectory(_ record: PluginOwnedDirectory) throws {
    try record.validate()
    let payload = try JSONEncoder().encode(record)
    guard payload.count <= 16_384 else { throw PluginStoreError.invalidState }
    try writer.write { database in
      let count =
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM pluginOwnedDirectories") ?? 0
      guard count < 4096 else { throw PluginStoreError.invalidState }
      try database.execute(
        sql: "INSERT INTO pluginOwnedDirectories (id, payloadJSON) VALUES (?, ?)",
        arguments: [record.installationID, String(decoding: payload, as: UTF8.self)])
    }
  }

  package func forgetPluginDirectory(_ record: PluginOwnedDirectory) throws {
    try writer.write { database in
      guard
        let payload = try String.fetchOne(
          database, sql: "SELECT payloadJSON FROM pluginOwnedDirectories WHERE id = ?",
          arguments: [record.installationID])
      else { return }
      guard payload.utf8.count <= 16_384,
        try JSONDecoder().decode(PluginOwnedDirectory.self, from: Data(payload.utf8)) == record
      else { throw PluginStoreError.invalidState }
      try database.execute(
        sql: "DELETE FROM pluginOwnedDirectories WHERE id = ?", arguments: [record.installationID])
    }
  }

  /// Ownership migrations do not change selected installations or authorization revisions.
  package func updatePluginDirectoryIdentity(
    _ identity: PluginDirectoryIdentity, replacing expected: PluginOwnedDirectory
  ) throws -> PluginOwnedDirectory {
    guard identity.volumeUUID != nil,
      identity.mayReferToSameDirectory(as: expected.identity)
    else { throw PluginStoreError.invalidState }
    let updated = PluginOwnedDirectory(
      installationID: expected.installationID, pluginID: expected.pluginID, identity: identity)
    try updated.validate()
    let encoded = try JSONEncoder().encode(updated)
    guard encoded.count <= 16_384 else { throw PluginStoreError.invalidState }
    try writer.write { database in
      guard
        let payload = try String.fetchOne(
          database, sql: "SELECT payloadJSON FROM pluginOwnedDirectories WHERE id = ?",
          arguments: [expected.installationID]),
        payload.utf8.count <= 16_384,
        try JSONDecoder().decode(PluginOwnedDirectory.self, from: Data(payload.utf8)) == expected
      else { throw PluginStoreError.invalidState }
      try database.execute(
        sql: "UPDATE pluginOwnedDirectories SET payloadJSON = ? WHERE id = ?",
        arguments: [String(decoding: encoded, as: UTF8.self), expected.installationID])
    }
    return updated
  }

  package func registerProjectIdempotently(
    _ proposed: ComputerMCPCore.RegisteredProject
  ) throws -> (project: ComputerMCPCore.RegisteredProject, created: Bool) {
    try permissionTransaction { try Self.registerProjectIdempotently(proposed, in: $0) }
  }

  static func registerProjectIdempotently(
    _ proposed: ComputerMCPCore.RegisteredProject, in database: Database
  ) throws -> (project: ComputerMCPCore.RegisteredProject, created: Bool) {
    let canonicalRoot = canonicalProjectRoot(proposed.rootPath)
    if let existing = try registeredProject(canonicalRoot: canonicalRoot, in: database) {
      return (existing, false)
    }
    try ProjectRecord(proposed).insert(database)
    try ProjectCanonicalRootRecord(
      canonicalRootPath: canonicalRoot,
      projectID: proposed.id,
      createdAt: proposed.createdAt
    ).insert(database)
    return (proposed, true)
  }

  private static func registeredProject(canonicalRoot: String, in database: Database) throws
    -> ComputerMCPCore.RegisteredProject?
  {
    if let binding = try ProjectCanonicalRootRecord.fetchOne(
      database,
      key: canonicalRoot
    ) {
      let canonicalID =
        try ProjectAliasRecord.fetchOne(database, key: binding.projectID)?
        .canonicalProjectID
        ?? binding.projectID
      if let existing = try ProjectRecord.fetchOne(database, key: canonicalID),
        Self.canonicalProjectRoot(existing.rootPath) == canonicalRoot
      {
        if binding.projectID != canonicalID {
          try ProjectCanonicalRootRecord(
            canonicalRootPath: canonicalRoot, projectID: canonicalID,
            createdAt: existing.createdAt
          ).save(database)
        }
        return existing.value
      }
      _ = try ProjectCanonicalRootRecord.deleteOne(database, key: canonicalRoot)
    }
    if let existing = try Self.projects(in: database).first(where: {
      Self.canonicalProjectRoot($0.rootPath) == canonicalRoot
    }) {
      try ProjectCanonicalRootRecord(
        canonicalRootPath: canonicalRoot,
        projectID: existing.id,
        createdAt: existing.createdAt
      ).insert(database, onConflict: .ignore)
      return existing
    }
    return nil
  }

  package func projects() throws -> [ComputerMCPCore.RegisteredProject] {
    try writer.read { try Self.projects(in: $0) }
  }

  static func projects(in database: Database) throws -> [ComputerMCPCore.RegisteredProject] {
    let aliasIDs = Set(try ProjectAliasRecord.fetchAll(database).map(\.aliasProjectID))
    let derived = try SQLiteDerivedProjectStore.records(database)
    let available = Set(try availableDerivedProjects(in: database).map(\.projectID))
    let unavailable = Set(derived.map(\.projectID)).subtracting(available)
    return
      try ProjectRecord
      .order(Column("displayName").collating(.nocase), Column("id"))
      .fetchAll(database)
      .filter { !aliasIDs.contains($0.id) && !unavailable.contains($0.id) }
      .map(\.value)
  }

  package func project(id: String) throws -> ComputerMCPCore.RegisteredProject? {
    try writer.read { database in
      let resolvedID =
        try ProjectAliasRecord.fetchOne(database, key: id)?.canonicalProjectID ?? id
      return try Self.projects(in: database).first { $0.id == resolvedID }
    }
  }

  package func deleteProject(id: String) throws {
    try permissionTransaction { database in
      try Self.deleteProject(id: id, in: database)
    }
  }

  private static func deleteProject(id: String, in database: Database) throws {
    let canonicalID =
      try ProjectAliasRecord.fetchOne(database, key: id)?.canonicalProjectID ?? id
    guard try SQLiteDerivedProjectStore.record(canonicalID, in: database) == nil else {
      throw GatewayDatabaseError.invalidStoredValue(
        "Derived projects require their lifecycle owner.")
    }
    try invalidateDerivedSources([canonicalID], in: database)
    let aliasIDs =
      try ProjectAliasRecord
      .filter(Column("canonicalProjectID") == canonicalID)
      .fetchAll(database)
      .map(\.aliasProjectID)
    try ProjectAliasRecord
      .filter(Column("canonicalProjectID") == canonicalID)
      .deleteAll(database)
    for removedID in aliasIDs + [canonicalID] {
      try ProjectCanonicalRootRecord.filter(Column("projectID") == removedID).deleteAll(
        database)
      _ = try ProjectRecord.deleteOne(database, key: removedID)
    }
  }

  /// Registration, aliases, affected permissions and revocations share one commit.
  package func removeProject(
    id: String, expectedConfiguration: ConfigurationState, now: Date = Date()
  ) throws {
    let changed = try permissionTransaction { database in
      try Self.removeProject(
        id: id, expectedConfiguration: expectedConfiguration,
        now: now, in: database)
    }
    for id in changed { profileChangeLock.withLock { profileChangeBroadcasters[id] }?.send() }
  }

  private static func removeProject(
    id: String, expectedConfiguration: ConfigurationState,
    now: Date, in database: Database
  ) throws -> [GatewayProfileID] {
    guard try Self.configurationState(in: database) == expectedConfiguration else {
      throw GatewayDatabaseError.configurationChanged
    }
    let canonicalID = expectedConfiguration.projectAliases[id] ?? id
    guard expectedConfiguration.projects.contains(where: { $0.id == canonicalID }) else {
      throw GatewayDatabaseError.invalidStoredValue("Unknown project '\(id)'.")
    }
    let removedIDs = Set(
      expectedConfiguration.projectAliases.filter { $0.value == canonicalID }.map(\.key)
        + [canonicalID])
    var changed: [GatewayProfileID] = []
    for stored in expectedConfiguration.profiles {
      guard
        removedIDs.contains(where: {
          stored.permissions.entries[.project($0)] != nil || stored.projectNetworks[$0] != nil
        })
      else { continue }
      var profile = stored
      for id in removedIDs {
        profile.permissions.removeEntry(for: .project(id))
        profile.projectNetworks[id] = nil
      }
      try profile.validate()
      try Self.saveProfile(
        profile, updatedAt: now, expectedRevision: stored.authorizationRevision, in: database)
      changed.append(profile.id)
    }
    try Self.deleteProject(id: canonicalID, in: database)
    return changed
  }

  package func projectDeduplicationPlan() throws -> ProjectDeduplicationPlan {
    try writer.read { database in
      try Self.projectDeduplicationPlan(database)
    }
  }

  package func applyProjectDeduplication(
    expectedPlanDigest: String,
    allowMetadataConflicts: Bool,
    now: Date = Date(),
    expectedConfiguration: ConfigurationState? = nil
  ) throws -> ProjectDeduplicationResult {
    let result = try permissionTransaction { database in
      try Self.applyProjectDeduplication(
        expectedPlanDigest: expectedPlanDigest, allowMetadataConflicts: allowMetadataConflicts,
        now: now, expectedConfiguration: expectedConfiguration,
        receiptID: UUID().uuidString, in: database)
    }
    for rawID in result.updatedProfileIDs {
      if let id = GatewayProfileID(rawValue: rawID) {
        profileChangeLock.withLock { profileChangeBroadcasters[id] }?.send()
      }
    }
    return result
  }

  private static func applyProjectDeduplication(
    expectedPlanDigest: String, allowMetadataConflicts: Bool, now: Date,
    expectedConfiguration: ConfigurationState?,
    receiptID: String, in database: Database
  ) throws -> ProjectDeduplicationResult {
    if let expectedConfiguration,
      try Self.configurationState(in: database) != expectedConfiguration
    {
      throw GatewayDatabaseError.configurationChanged
    }
    let plan = try Self.projectDeduplicationPlan(database)
    guard plan.planDigest == expectedPlanDigest else {
      throw ProjectDeduplicationError.planChanged(
        expected: expectedPlanDigest,
        actual: plan.planDigest
      )
    }
    let conflictIDs = plan.groups.filter(\.hasMetadataConflict)
      .flatMap(\.duplicateProjectIDs)
      .sorted()
    if !allowMetadataConflicts, !conflictIDs.isEmpty {
      throw ProjectDeduplicationError.metadataConflict(projectIDs: conflictIDs)
    }

    var replacements: [String: String] = [:]
    for group in plan.groups {
      guard
        let canonical = try ProjectRecord.fetchOne(database, key: group.canonicalProjectID)
      else { throw GatewayDatabaseError.configurationChanged }
      try ProjectCanonicalRootRecord(
        canonicalRootPath: group.canonicalRootPath, projectID: canonical.id,
        createdAt: canonical.createdAt
      ).save(database)
      for duplicateID in group.duplicateProjectIDs {
        try ProjectAliasRecord(
          aliasProjectID: duplicateID,
          canonicalProjectID: group.canonicalProjectID,
          canonicalRootPath: group.canonicalRootPath,
          migratedAt: now
        ).save(database)
        replacements[duplicateID] = group.canonicalProjectID
      }
    }
    var updatedProfileIDs: [String] = []
    for stored in try Self.profiles(in: database) {
      guard
        replacements.keys.contains(where: {
          stored.permissions.entries[.project($0)] != nil || stored.projectNetworks[$0] != nil
        })
      else { continue }
      var profile = stored
      for (old, canonical) in replacements.sorted(by: { $0.key < $1.key }) {
        if let state = profile.permissions.entries[.project(old)] {
          if let existing = profile.permissions.entries[.project(canonical)], existing != state {
            throw GatewayDatabaseError.invalidStoredValue(
              "Conflicting project permission entries require an owner edit before deduplication.")
          }
          try profile.permissions.set(state, for: .project(canonical))
          profile.permissions.removeEntry(for: .project(old))
        }
        if let network = profile.projectNetworks[old] {
          if let existing = profile.projectNetworks[canonical],
            existing.configuration != network.configuration
          {
            throw GatewayDatabaseError.invalidStoredValue(
              "Conflicting project networks require an owner edit before deduplication.")
          }
          profile.projectNetworks[canonical] = network
          profile.projectNetworks[old] = nil
        }
      }
      try profile.validate()
      try Self.saveProfile(
        profile, updatedAt: now, expectedRevision: stored.authorizationRevision, in: database)
      updatedProfileIDs.append(profile.id.rawValue)
    }

    let result = ProjectDeduplicationResult(
      receiptID: receiptID,
      planDigest: plan.planDigest,
      canonicalProjectIDs: plan.groups.map(\.canonicalProjectID).sorted(),
      aliasedProjectIDs: plan.groups.flatMap(\.duplicateProjectIDs).sorted(),
      updatedProfileIDs: updatedProfileIDs.sorted(),
      appliedAt: now
    )
    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    try ProjectDeduplicationReceiptRecord(
      id: result.receiptID,
      planDigest: result.planDigest,
      appliedAt: now,
      payloadJSON: String(decoding: try encoder.encode(result), as: UTF8.self)
    ).insert(database)
    return result
  }

  package func saveRuntimeSetting(
    key: String,
    value: String,
    updatedAt: Date = Date()
  ) throws {
    try writer.write { database in
      try RuntimeSettingRecord(
        key: key,
        value: value,
        updatedAt: updatedAt
      ).save(database)
    }
  }

  package func runtimeSetting(key: String) throws -> String? {
    try writer.read { database in
      try RuntimeSettingRecord.fetchOne(database, key: key)?.value
    }
  }

  package static func decodeDesiredOpenAITunnelConfigurationIDs(_ value: String) throws -> [String]
  {
    guard let data = value.data(using: .utf8) else { return [] }
    let identifiers = try JSONDecoder().decode([String].self, from: data)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return Array(Set(identifiers)).sorted()
  }

  package static func decodeDesiredCloudflareProfileIDs(_ value: String) throws -> [String] {
    guard let data = value.data(using: .utf8) else { return [] }
    return try JSONDecoder().decode([String].self, from: data).sorted()
  }

  package static func decodeGatewayTunnelRegistration(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else {
      throw GatewayDatabaseError.invalidStoredValue("The gateway tunnel registration is invalid.")
    }
    return id
  }

  package static func decodeActiveGatewayProfile(_ value: String) throws -> GatewayProfileID {
    guard let profile = GatewayProfileID(rawValue: value) else {
      throw GatewayDatabaseError.invalidStoredValue("The active gateway profile is invalid.")
    }
    return profile
  }

  package func saveProfile(
    _ profile: ProfileGrant, updatedAt: Date = Date(), expectedRevision: Int64? = nil
  ) throws {
    try profile.validate()
    try permissionTransaction { database in
      try Self.saveProfile(
        profile, updatedAt: updatedAt, expectedRevision: expectedRevision, in: database)
    }
    profileChangeLock.withLock { profileChangeBroadcasters[profile.id] }?.send()
  }

  package func saveProfile(
    _ profile: ProfileGrant, expectedRevision: Int64, expectedConfiguration: ConfigurationState,
    authorization: GatewayManagementAuthorization? = nil
  ) throws {
    try profile.validate()
    try permissionTransaction(managementAuthorization: authorization) { database in
      guard try Self.configurationState(in: database) == expectedConfiguration else {
        throw GatewayDatabaseError.configurationChanged
      }
      try Self.saveProfile(
        profile, updatedAt: Date(), expectedRevision: expectedRevision, in: database)
    }
    profileChangeLock.withLock { profileChangeBroadcasters[profile.id] }?.send()
  }

  private static func saveProfile(
    _ profile: ProfileGrant, updatedAt: Date, expectedRevision: Int64?, in database: Database
  ) throws {
    let current = try ProfileRecord.fetchOne(database, key: profile.id.rawValue)
    let revision = current?.authorizationRevision ?? 0
    guard expectedRevision == nil || expectedRevision == revision else {
      throw GatewayDatabaseError.invalidStoredValue(
        "Profile authorization changed; reload before saving.")
    }
    guard revision < Int64.max else {
      throw GatewayDatabaseError.invalidStoredValue("Profile authorization revision exhausted.")
    }
    var saved = profile
    saved.authorizationRevision = revision + 1
    try ProfileRecord(
      saved, authorityEpoch: current?.authorityEpoch.flatMap(UUID.init(uuidString:))
    ).save(database)
  }

  func profileChanges(for profileID: GatewayProfileID) -> AsyncStream<Void> {
    let broadcaster = profileChangeLock.withLock {
      if let existing = profileChangeBroadcasters[profileID] { return existing }
      let new = GatewayToolChangeBroadcaster()
      profileChangeBroadcasters[profileID] = new
      return new
    }
    return broadcaster.stream()
  }

  package func profiles() throws -> [ProfileGrant] {
    try writer.read { try Self.profiles(in: $0) }
  }

  private static func profiles(in database: Database) throws -> [ProfileGrant] {
    try ProfileRecord.order(Column("id")).fetchAll(database).map { try $0.value() }
  }

  package func clientTrusts() throws -> [GatewayClientTrust] {
    try writer.read { database in
      try GatewayClientTrust.order(Column("updatedAt").desc).fetchAll(database)
    }
  }

  package func clientTrust(id: String) throws -> GatewayClientTrust? {
    try writer.read { try GatewayClientTrust.fetchOne($0, key: id) }
  }

  package func clientTrust(
    principalID: String, profileID: GatewayProfileID, caller: GatewayCallerKind
  ) throws -> GatewayClientTrust? {
    try writer.read { database in
      try GatewayClientTrust
        .filter(Column("principalID") == principalID)
        .filter(Column("profileID") == profileID.rawValue)
        .filter(Column("caller") == caller.rawValue).fetchOne(database)
    }
  }

  /// The local consent audit and optional persistent client trust commit together.
  func recordFullAccessConsent(
    sessionID: String, principalID: String, profile authority: GatewayControlProfile,
    caller: GatewayCallerKind, lifetime: GatewayFullAccessLifetime,
    expectedTrustRevision: Int64, approver: GatewayCallerKind = .localApp
  ) throws -> GatewayFullAccessConsent {
    guard approver == .localApp || approver == .localCLI else {
      throw GatewayDatabaseError.invalidStoredValue("Client consent requires a local owner.")
    }
    let profileID = authority.grant.id
    let (consent, trustChanged) = try permissionTransaction { database in
      let storedProfile = try ProfileRecord.fetchOne(database, key: profileID.rawValue)?.value()
      let profile = authority.grant
      guard !principalID.isEmpty, (storedProfile != nil) == authority.persisted,
        storedProfile == nil || storedProfile == profile,
        profile.allowedCallers.contains(caller), !(profileID == .localAdmin && caller.isRemote)
      else {
        throw GatewayDatabaseError.invalidStoredValue(
          "The client is no longer admitted by this profile.")
      }
      let stored =
        try GatewayClientTrust
        .filter(Column("principalID") == principalID)
        .filter(Column("profileID") == profileID.rawValue)
        .filter(Column("caller") == caller.rawValue).fetchOne(database)
      guard (stored?.revision ?? 0) == expectedTrustRevision,
        expectedTrustRevision >= 0, expectedTrustRevision < Int64.max
      else {
        throw GatewayDatabaseError.invalidStoredValue(
          "Client trust changed; reload before granting access.")
      }
      let now = Date()
      let persistent = lifetime == .alwaysAllowClient
      var trust =
        stored
        ?? GatewayClientTrust(
          id: UUID().uuidString, principalID: principalID, profileID: profileID, caller: caller,
          revision: 0, profile: authority,
          fullAccessAllowed: false, updatedAt: now)
      let trustChanged = persistent || stored?.fullAccessAllowed == true
      if trustChanged {
        trust.revision += 1
        trust.profile = authority
        trust.fullAccessAllowed = persistent
        trust.updatedAt = now
        try trust.save(database)
      }
      try AuditEventRecord(
        AuditEvent(
          requestID: UUID().uuidString, invocationID: sessionID, caller: approver,
          principalDigest: AuditEvent.verifiedPrincipalDigest(principalID),
          profileID: profileID,
          capabilityID: persistent
            ? "control.full-access.always-allow" : "control.full-access.this-session",
          decision: .allowed)
      ).insert(database)
      let consent = GatewayFullAccessConsent(
        lifetime: lifetime, grantedAt: now, profile: authority,
        trustID: persistent ? trust.id : nil, trustRevision: persistent ? trust.revision : nil)
      return (consent, trustChanged)
    }
    if trustChanged {
      profileChangeLock.withLock { profileChangeBroadcasters[profileID] }?.send()
    }
    return consent
  }

  /// Refresh managed policy and revalidate the admitted invocation before dispatch.
  package func validateManagementAuthorization(_ authorization: GatewayManagementAuthorization)
    throws
  {
    try permissionTransaction(managementAuthorization: authorization) { _ in }
  }

  /// The caller already owns the permission writer and, for remote changes, the session lock.
  static func requireManagementAuthorization(
    _ authorization: GatewayManagementAuthorization?, in database: Database,
    ledger: inout PermissionLedger
  ) throws {
    guard let authorization else { return }
    try requireManagementTrust(authorization, in: database)
    try authorization.requireInvocationAccess(ledger: &ledger)
  }

  /// Persistent trust can be revoked independently of the in-memory session lock.
  /// Check its captured identity inside the same transaction as the configuration write.
  private static func requireManagementTrust(
    _ authorization: GatewayManagementAuthorization?, in database: Database
  ) throws {
    guard let authorization, authorization.requiresFullAccess else { return }
    guard let consent = authorization.consent else {
      throw GatewayToolError.invalidArguments(
        "[policy.control_session_denied] Full Access consent is unavailable.")
    }
    guard consent.lifetime == .alwaysAllowClient else { return }
    guard let id = consent.trustID, let revision = consent.trustRevision,
      let trust = try GatewayClientTrust.fetchOne(database, key: id),
      trust.fullAccessAllowed, trust.revision == revision,
      trust.principalID == authorization.context.trustedPrincipalID,
      trust.profileID == authorization.context.profileID,
      trust.caller == authorization.context.caller,
      trust.profile.hasSameAuthorization(as: consent.profile)
    else {
      throw GatewayToolError.invalidArguments(
        "[policy.control_session_denied] Client trust changed before publication.")
    }
  }

  package func revokeClientTrust(
    id: String, expectedRevision: Int64, approver: GatewayCallerKind = .localApp
  ) throws {
    guard approver == .localApp || approver == .localCLI else {
      throw GatewayDatabaseError.invalidStoredValue(
        "Client trust revocation requires a local owner.")
    }
    let profileID = try permissionTransaction { database in
      guard var trust = try GatewayClientTrust.fetchOne(database, key: id),
        trust.revision == expectedRevision, trust.revision < Int64.max
      else {
        throw GatewayDatabaseError.invalidStoredValue(
          "Client trust changed; reload before revoking access.")
      }
      trust.fullAccessAllowed = false
      trust.revision += 1
      trust.updatedAt = Date()
      try trust.save(database)
      try AuditEventRecord(
        AuditEvent(
          requestID: UUID().uuidString, caller: approver,
          principalDigest: AuditEvent.verifiedPrincipalDigest(trust.principalID),
          profileID: trust.profileID, capabilityID: "control.client-trust.revoke",
          decision: .allowed)
      ).insert(database)
      return trust.profileID
    }
    profileChangeLock.withLock { profileChangeBroadcasters[profileID] }?.send()
  }

  func reserveMCPExecution(_ proposed: MCPExecutionRecord) throws
    -> (record: MCPExecutionRecord, inserted: Bool)
  {
    try writer.write { database in
      try Self.expireMCPOutput(in: database)
      if let existing = try Self.mcpExecution(key: proposed.key, in: database) {
        guard existing.inputDigest == proposed.inputDigest else {
          throw GatewayToolError.invalidArguments(
            "[request.conflict] This request_id is already bound to different input.")
        }
        return (existing, false)
      }
      // Keep deduplication receipts even after output expires. Evicting identity would
      // silently authorize replay; capacity exhaustion instead fails before dispatch.
      guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM mcpExecutions") ?? 0 < 10_000
      else {
        throw GatewayToolError.executionFailed(
          "MCP execution receipt capacity reached; no request was dispatched.")
      }
      try Self.saveMCPExecution(proposed, in: database)
      return (proposed, true)
    }
  }

  func mcpExecution(scope: String, serverID: String, requestID: String) throws
    -> MCPExecutionRecord?
  {
    let key = MCPExecutionRecord.digest(
      .array([.string(scope), .string(serverID), .string(requestID)]))
    return try writer.write { database in
      try Self.expireMCPOutput(in: database)
      return try Self.mcpExecution(key: key, in: database)
    }
  }

  func updateMCPExecution(
    scope: String, serverID: String, requestID: String, instanceID: String,
    change: (inout MCPExecutionRecord) throws -> Void
  ) throws {
    let key = MCPExecutionRecord.digest(
      .array([.string(scope), .string(serverID), .string(requestID)]))
    try writer.write { database in
      guard var record = try Self.mcpExecution(key: key, in: database),
        record.instanceID == instanceID
      else {
        throw GatewayToolError.invalidArguments(
          "[request.stale_instance] Execution ownership no longer matches.")
      }
      try change(&record)
      try Self.saveMCPExecution(record, in: database)
      try Self.expireMCPOutput(in: database)
      // Output has a global bound independent of individual response sizes. Receipt
      // identity and terminal state survive eviction and remain queryable.
      var retained =
        try Int.fetchOne(
          database,
          sql: "SELECT COALESCE(SUM(length(CAST(outputJSON AS BLOB))), 0) FROM mcpExecutions") ?? 0
      if retained > 16_777_216 {
        let rows = try Row.fetchAll(
          database,
          sql:
            "SELECT id, length(CAST(outputJSON AS BLOB)) AS bytes FROM mcpExecutions WHERE outputJSON IS NOT NULL ORDER BY outputExpiresAt, id"
        )
        for row in rows where retained > 16_777_216 {
          let id: String = row["id"]
          let count: Int = row["bytes"]
          try database.execute(
            sql: "UPDATE mcpExecutions SET outputJSON = NULL WHERE id = ?", arguments: [id])
          retained -= count
        }
      }
    }
  }

  private static func expireMCPOutput(in database: Database) throws {
    try database.execute(
      sql:
        "UPDATE mcpExecutions SET outputJSON = NULL WHERE outputExpiresAt <= ? AND outputJSON IS NOT NULL",
      arguments: [Date().timeIntervalSince1970])
  }

  private static func mcpExecution(key: String, in database: Database) throws -> MCPExecutionRecord?
  {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT metadataJSON, outputJSON FROM mcpExecutions WHERE id = ?",
        arguments: [key])
    else { return nil }
    let metadata: String = row["metadataJSON"]
    var record = try JSONDecoder().decode(MCPExecutionRecord.self, from: Data(metadata.utf8))
    record.outputJSON = row["outputJSON"]
    return record
  }

  private static func saveMCPExecution(_ record: MCPExecutionRecord, in database: Database) throws {
    var metadata = record
    metadata.outputJSON = nil
    let encoded = try JSONEncoder().encode(metadata)
    try database.execute(
      sql: """
        INSERT INTO mcpExecutions (id, metadataJSON, outputJSON, outputExpiresAt) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET metadataJSON = excluded.metadataJSON,
        outputJSON = excluded.outputJSON, outputExpiresAt = excluded.outputExpiresAt
        """,
      arguments: [
        record.key, String(decoding: encoded, as: UTF8.self), record.outputJSON,
        record.outputExpiresAt?.timeIntervalSince1970,
      ])
  }

  package func saveProviderState(_ state: ProviderState) throws {
    try writer.write { database in
      try ProviderStateRecord(state).save(database)
    }
  }

  package func providerStates() throws -> [ProviderState] {
    try writer.read { database in
      try ProviderStateRecord.order(Column("id")).fetchAll(database).map(\.value)
    }
  }

  package func saveConfigurationRevision(_ revision: ConfigurationRevision) throws {
    try writer.write { database in
      try ConfigurationRevisionRecord(revision).save(database)
    }
  }

  /// The caller's recovery journal restores the prepared manifest when the SQL
  /// activation marker does not commit. Publication precedes the authority lock.
  package func activateConfigurationRevision(
    _ revision: ConfigurationRevision, expected: ConfigurationState,
    resolution: GatewayConfigurationResolution, activeTunnelIDs: Set<String>,
    replaceManifest: (ConfigurationState) throws -> Void
  ) throws -> ConfigurationState {
    guard try configurationState() == expected else {
      throw GatewayDatabaseError.configurationChanged
    }
    let resolved = Dictionary(
      uniqueKeysWithValues: resolution.projects.map { ($0.original.id, $0.resolved) })
    let profileSource =
      try resolution.profileDeclarations.map(Self.profileSource) ?? expected.profileSource
    let sourceChanged = profileSource != expected.profileSource
    guard !sourceChanged || permissionRuntimeLock.withLock({ permissionRuntimeCache != nil }) else {
      throw GatewayPermissionError.invalidPolicySnapshot
    }
    let proposed = ConfigurationState(
      projects: expected.projects.map { resolved[$0.id] ?? $0 },
      projectAliases: expected.projectAliases,
      profiles: try Self.profiles(publishing: resolution.profileDeclarations, over: expected),
      plugins: expected.plugins, profileSource: profileSource,
      derivedProjects: expected.derivedProjects)
    try replaceManifest(proposed)
    let committed = try permissionTransaction(requiresProfilePolicy: sourceChanged) { database in
      guard try Self.configurationState(in: database) == expected else {
        throw GatewayDatabaseError.configurationChanged
      }
      try Self.applyRuntimeResolution(resolution, in: database)
      if sourceChanged {
        let proposedIDs = Set(proposed.profiles.map(\.id))
        for profile in expected.profiles where !proposedIDs.contains(profile.id) {
          try ProfileRecord.deleteOne(database, key: profile.id.rawValue)
        }
        for profile in proposed.profiles where !expected.profiles.contains(profile) {
          try Self.saveProfile(
            profile, updatedAt: Date(),
            expectedRevision: expected.profiles.first(where: { $0.id == profile.id })?
              .authorizationRevision,
            in: database)
        }
        try Self.savePublishedProfileDeclarations(resolution.profileDeclarations!, in: database)
      }
      try GatewayOAuthTransaction(database: database).reconcileTunnels(activeIDs: activeTunnelIDs)
      try ConfigurationRevisionRecord(revision).insert(database)
      let state = try Self.configurationState(in: database)
      guard state == proposed else { throw GatewayDatabaseError.configurationChanged }
      return state
    }
    let ids = Set(expected.profiles.map(\.id)).union(committed.profiles.map(\.id))
    for id in ids
    where expected.profiles.first(where: { $0.id == id })
      != committed.profiles.first(where: { $0.id == id })
    {
      profileChangeLock.withLock { profileChangeBroadcasters[id] }?.send()
    }
    return committed
  }

  package func configurationRevision(id: String) throws -> ConfigurationRevision? {
    try writer.read { try ConfigurationRevisionRecord.fetchOne($0, key: id)?.value }
  }

  package func configurationRevisions(limit: Int = 50) throws -> [ConfigurationRevision] {
    try writer.read { database in
      try ConfigurationRevisionRecord
        .order(Column("createdAt").desc, Column("id").desc)
        .limit(max(1, min(limit, 1_000)))
        .fetchAll(database)
        .map(\.value)
    }
  }

  package func recordAudit(_ event: AuditEvent) throws {
    try writer.write { database in
      try AuditEventRecord(event).insertRetained(database)
    }
  }

  package func auditEvents(limit: Int = 200) throws -> [AuditEvent] {
    try writer.read { database in
      try AuditEventRecord
        .order(Column("occurredAt").desc, Column("id").desc)
        .limit(max(1, min(limit, 10_000)))
        .fetchAll(database)
        .map { try $0.value() }
    }
  }

  package func auditEvent(requestID: String) throws -> AuditEvent? {
    try writer.read { database in
      try AuditEventRecord
        .filter(Column("requestID") == requestID)
        .order(Column("occurredAt").desc, Column("id").desc)
        .fetchOne(database)
        .map { try $0.value() }
    }
  }

  package func auditEvents(requestID: String) throws -> [AuditEvent] {
    try writer.read { database in
      try AuditEventRecord
        .filter(Column("requestID") == requestID)
        .order(Column("occurredAt"), Column("id"))
        .fetchAll(database)
        .map { try $0.value() }
    }
  }

  @discardableResult
  package func bindMCPRequestID(
    _ mcpRequestID: String,
    toGatewayRequestID gatewayRequestID: String,
    socketConnectionID: String
  ) throws -> Bool {
    try writer.write { database in
      let records =
        try AuditEventRecord
        .filter(Column("requestID") == gatewayRequestID)
        .filter(Column("socketConnectionID") == socketConnectionID)
        .fetchAll(database)
      let children =
        try AuditEventRecord
        .filter(Column("parentRequestID") == gatewayRequestID)
        .filter(Column("socketConnectionID") == socketConnectionID)
        .fetchAll(database)
      guard let origin = records.first,
        (records + children).allSatisfy({
          ($0.mcpRequestID == nil || $0.mcpRequestID == mcpRequestID)
            && $0.caller == origin.caller && $0.profileID == origin.profileID
            && $0.principalDigest == origin.principalDigest && $0.transport == origin.transport
            && $0.tunnelInstanceID == origin.tunnelInstanceID
            && $0.tunnelProfileID == origin.tunnelProfileID
        })
      else { return false }
      for var record in records + children {
        record.mcpRequestID = mcpRequestID
        try record.update(database)
      }
      return true
    }
  }

  private static func projectDeduplicationPlan(
    _ database: Database
  ) throws -> ProjectDeduplicationPlan {
    let aliasIDs = Set(try ProjectAliasRecord.fetchAll(database).map(\.aliasProjectID))
    let projects = try ProjectRecord.fetchAll(database)
      .filter { !aliasIDs.contains($0.id) }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id < $1.id
      }
    let profiles = try ProfileRecord.fetchAll(database).map { try $0.value() }
    let grouped = Dictionary(grouping: projects) {
      canonicalProjectRoot($0.rootPath)
    }
    let groups = grouped.keys.sorted().compactMap {
      canonicalRoot
        -> ProjectDeduplicationGroup? in
      guard let records = grouped[canonicalRoot], records.count > 1,
        let canonical = records.first
      else { return nil }
      let members = records.map { record in
        ProjectDeduplicationMember(
          projectID: record.id,
          displayName: record.displayName,
          rootPath: record.rootPath,
          createdAt: record.createdAt,
          referencedProfileIDs:
            profiles
            .filter {
              $0.permissions.entries[.project(record.id)] != nil
                || $0.projectNetworks[record.id] != nil
            }
            .map { $0.id.rawValue }
            .sorted()
        )
      }
      return ProjectDeduplicationGroup(
        canonicalRootPath: canonicalRoot,
        canonicalProjectID: canonical.id,
        duplicateProjectIDs: Array(records.dropFirst().map(\.id)).sorted(),
        members: members,
        hasMetadataConflict: Set(records.map(\.displayName)).count > 1
      )
    }
    let digestInput = ProjectDeduplicationDigestInput(groups: groups)
    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    let digest = SHA256.hash(data: try encoder.encode(digestInput))
      .map { String(format: "%02x", $0) }
      .joined()
    return ProjectDeduplicationPlan(
      planDigest: digest,
      groups: groups,
      duplicateCount: groups.reduce(0) { $0 + $1.duplicateProjectIDs.count },
      affectedProfileIDs: Set(
        groups.flatMap(\.members).flatMap(\.referencedProfileIDs)
      ).sorted()
    )
  }

  static func canonicalProjectRoot(_ path: String) -> String {
    URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
  }
}

extension GatewayDatabase {
  func hostDiagnosticAudits(context: ExecutionContext, limit: Int) throws -> [AuditEvent] {
    guard let principal = AuditEvent.verifiedPrincipalDigest(context.trustedPrincipalID) else {
      return []
    }
    return try writer.read { database in
      let request = AuditEventRecord.filter(Column("projectID") == context.projectID)
        .filter(Column("profileID") == context.profileID.rawValue)
        .filter(Column("principalDigest") == principal)
      return try request.order(Column("occurredAt").desc, Column("id").desc)
        .limit(max(1, min(1_000, limit))).fetchAll(database).map { try $0.value() }
    }
  }

  func derivedProjectRegistration(id: String) throws -> MCPDerivedProjectRegistration? {
    try writer.read { try Self.derivedRegistration(id: id, database: $0) }
  }

  /// Registration and inherited source authority are committed together.
  @discardableResult
  func registerDerivedProject(
    _ registration: MCPDerivedProjectRegistration, verifiedPrincipalID: String,
    caller: GatewayCallerKind, authority: HostCallAuthoritySnapshot? = nil
  ) throws -> Bool {
    try Self.requireDerivedPrincipal(registration, verifiedPrincipalID: verifiedPrincipalID)
    let payload = try JSONEncoder().encode(registration)
    guard payload.count <= 32_768 else {
      throw MCPHostServiceError.denied("Registration exceeds its bound.")
    }
    let changed = try permissionTransaction { database in
      if let authority {
        guard authority.context.profileID == registration.profileID,
          authority.context.trustedPrincipalID == verifiedPrincipalID,
          authority.context.caller == caller
        else {
          throw MCPHostServiceError.denied(
            "The call authority differs from the registration owner.")
        }
        try Self.requireHostAuthority(authority, database: database)
      }
      guard
        let source = try ProjectRecord.fetchOne(database, key: registration.sourceProjectID),
        Self.canonicalProjectRoot(source.rootPath) == registration.sourceRoot,
        let profileRow = try ProfileRecord.fetchOne(database, key: registration.profileID.rawValue)
      else {
        throw MCPHostServiceError.denied("Source registration or profile is unavailable.")
      }
      let profile = try profileRow.value()
      try Self.requireDerivedSourceGrant(profile, registration: registration, caller: caller)
      if let old = try Self.derivedRegistration(id: registration.project.id, database: database) {
        guard
          try Self.availableDerivedProjects(in: database).contains(where: {
            $0.projectID == old.project.id
          })
        else {
          throw MCPHostServiceError.denied("The derived source registration is unavailable.")
        }
        try Self.requireDerivedPrincipal(old, verifiedPrincipalID: verifiedPrincipalID)
        guard old.origin == registration.origin, old.receiptDigest == registration.receiptDigest,
          old.receiptID == registration.receiptID, old.profileID == registration.profileID,
          old.sourceProjectID == registration.sourceProjectID,
          old.sourceRoot == registration.sourceRoot,
          Self.sameStoredProject(old.project, registration.project),
          let project = try ProjectRecord.fetchOne(database, key: old.project.id),
          Self.sameStoredProject(project.value, old.project)
        else { throw MCPHostServiceError.denied("Existing derived registration changed.") }
        return false
      }
      guard try ProjectRecord.fetchOne(database, key: registration.project.id) == nil,
        try ProjectAliasRecord.fetchOne(database, key: registration.project.id) == nil
      else {
        throw MCPHostServiceError.denied("Derived identity or source registration is unavailable.")
      }
      guard
        try !ProfileRecord.fetchAll(database).contains(where: {
          try $0.value().permissions.entries[.project(registration.project.id)] != nil
        })
      else {
        throw MCPHostServiceError.denied(
          "The derived identity already has an independently owned grant.")
      }
      let root = Self.canonicalProjectRoot(registration.project.rootPath)
      guard try ProjectCanonicalRootRecord.fetchOne(database, key: root) == nil else {
        throw MCPHostServiceError.denied(
          "The directory already belongs to an independent registration.")
      }
      try ProjectRecord(registration.project).insert(database)
      try ProjectCanonicalRootRecord(
        canonicalRootPath: root, projectID: registration.project.id,
        createdAt: registration.project.createdAt
      ).insert(database)
      let record = try DerivedProjectMigration.pluginRecord(payload: payload, in: database)
      try SQLiteDerivedProjectStore.commit(record, expecting: nil, in: database)
      return true
    }
    if changed {
      profileChangeLock.withLock { profileChangeBroadcasters[registration.profileID] }?.send()
    }
    return changed
  }

  /// Does not remove independently edited registrations, aliases, or grants.
  func unregisterDerivedProject(
    _ registration: MCPDerivedProjectRegistration, verifiedPrincipalID: String,
    caller: GatewayCallerKind, allowRevokedSourceForRollback: Bool = false,
    authority: HostCallAuthoritySnapshot? = nil
  ) throws {
    try Self.requireDerivedPrincipal(registration, verifiedPrincipalID: verifiedPrincipalID)
    let changedProfile = try permissionTransaction { database -> Bool in
      if let authority {
        guard authority.context.profileID == registration.profileID,
          authority.context.trustedPrincipalID == verifiedPrincipalID,
          authority.context.caller == caller
        else {
          throw MCPHostServiceError.denied(
            "The call authority differs from the registration owner.")
        }
        try Self.requireHostAuthority(authority, database: database)
      }
      guard
        let old = try Self.derivedRegistration(id: registration.project.id, database: database)
      else { return false }
      try Self.requireDerivedPrincipal(old, verifiedPrincipalID: verifiedPrincipalID)
      guard try SQLiteDerivedProjectStore.record(old.project.id, in: database)?.state == .active
      else {
        throw MCPHostServiceError.denied("The derived source registration is unavailable.")
      }
      guard old == registration,
        let project = try ProjectRecord.fetchOne(database, key: old.project.id),
        Self.sameStoredProject(project.value, old.project),
        try ProjectAliasRecord.filter(Column("canonicalProjectID") == old.project.id)
          .fetchCount(database) == 0
      else { throw MCPHostServiceError.denied("The derived registration has independent changes.") }
      let profiles = try ProfileRecord.fetchAll(database)
      if !allowRevokedSourceForRollback {
        guard let source = try ProjectRecord.fetchOne(database, key: old.sourceProjectID),
          Self.canonicalProjectRoot(source.rootPath) == old.sourceRoot,
          let profile = try profiles.first(where: { $0.id == old.profileID.rawValue })?.value()
        else {
          throw MCPHostServiceError.denied("The source profile is unavailable.")
        }
        try Self.requireDerivedSourceGrant(profile, registration: old, caller: caller)
      }
      for row in profiles where try row.value().permissions.entries[.project(old.project.id)] != nil
      {
        throw MCPHostServiceError.denied(
          "The derived identity now has an independently owned permission entry.")
      }
      try ProjectCanonicalRootRecord.filter(Column("projectID") == old.project.id).deleteAll(
        database)
      _ = try ProjectRecord.deleteOne(database, key: old.project.id)
      guard let stored = try SQLiteDerivedProjectStore.record(old.project.id, in: database) else {
        throw DerivedProjectStoreError.revisionConflict
      }
      try SQLiteDerivedProjectStore.remove(old.project.id, expecting: stored.revision, in: database)
      return true
    }
    if changedProfile {
      profileChangeLock.withLock { profileChangeBroadcasters[registration.profileID] }?.send()
    }
  }

  private static func requireDerivedPrincipal(
    _ registration: MCPDerivedProjectRegistration, verifiedPrincipalID: String
  ) throws {
    guard let principal = registration.principalID, !principal.isEmpty else {
      throw MCPHostServiceError.denied(
        "This historical registration has no bound principal; its data is preserved for explicit management."
      )
    }
    guard !verifiedPrincipalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      principal == verifiedPrincipalID
    else {
      throw MCPHostServiceError.denied("The derived registration belongs to another principal.")
    }
  }

  private static func requireDerivedSourceGrant(
    _ profile: ProfileGrant, registration: MCPDerivedProjectRegistration,
    caller: GatewayCallerKind
  ) throws {
    guard
      profile.permissions.state(for: .project(registration.sourceProjectID)) == .granted(.write),
      profile.allowedCallers.contains(caller)
    else {
      throw MCPHostServiceError.denied(
        "The persisted source grant no longer permits derived registration changes.")
    }
  }

  static func sameStoredProject(
    _ current: ComputerMCPCore.RegisteredProject, _ expected: ComputerMCPCore.RegisteredProject
  ) -> Bool {
    // Compare timestamps at the database's exact serialization precision, not a time tolerance.
    current.id == expected.id && current.displayName == expected.displayName
      && current.rootPath == expected.rootPath && current.bookmarkData == expected.bookmarkData
      && current.bookmarkIsStale == expected.bookmarkIsStale
      && current.createdAt.databaseValue == expected.createdAt.databaseValue
      && current.updatedAt.databaseValue == expected.updatedAt.databaseValue
  }

  private static func derivedRegistration(id: String, database: Database) throws
    -> MCPDerivedProjectRegistration?
  {
    guard let stored = try SQLiteDerivedProjectStore.record(id, in: database) else { return nil }
    guard case .plugin(let payload) = stored.provenance else {
      throw MCPHostServiceError.denied("This derived project belongs to the host lifecycle.")
    }
    let record = try JSONDecoder().decode(MCPDerivedProjectRegistration.self, from: payload)
    guard record.project.id == id, record.sourceProjectID == stored.source.id,
      record.sourceRoot == stored.source.root, record.project.rootPath == stored.root
    else {
      throw MCPHostServiceError.denied("Stored registration identity differs from its record.")
    }
    return record
  }
}

extension GatewayClientTrust: FetchableRecord, PersistableRecord {
  package static let databaseTableName = "clientControlTrust"
}

/// Isolated in-memory databases have no durable authority to restore. The object
/// lives as long as its GatewayDatabase, so independent runtimes share one epoch.
private final class TransientAuthorizationEpochCounter: AuthorizationEpochCounter,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var watermark: AuthorizationEpochWatermark?

  func withExclusiveAccess<Result>(_ body: (any AuthorizationEpochCounterAccess) throws -> Result)
    throws -> Result
  {
    try lock.withLock { try body(Access(owner: self)) }
  }

  private struct Access: AuthorizationEpochCounterAccess {
    let owner: TransientAuthorizationEpochCounter
    func read() throws -> AuthorizationEpochWatermark? { owner.watermark }
    func advance(to watermark: AuthorizationEpochWatermark) throws {
      guard owner.watermark == nil || watermark.revision > owner.watermark!.revision else {
        throw AuthorizationEpochCounterError.nonMonotonicWrite
      }
      owner.watermark = watermark
    }
  }
}
