import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPToolsWorkspace
import CryptoKit
import Foundation
import GRDB

package final class GatewayDatabase: @unchecked Sendable {
  private let connection: GatewayDatabaseConnection
  private var writer: any DatabaseWriter { connection.writer }
  private let profileChangeLock = NSLock()
  private var profileChangeBroadcasters: [GatewayProfileID: GatewayToolChangeBroadcaster] = [:]
  var fileURL: URL? { connection.fileURL }
  private let transientOwnershipID = UUID()

  var mcpProcessOwnershipRoot: URL? {
    fileURL.map {
      $0.deletingLastPathComponent().appendingPathComponent(
        $0.lastPathComponent + ".mcp-processes", isDirectory: true)
    }
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "computer-mcp-mcp-processes-" + transientOwnershipID.uuidString, isDirectory: true)
  }

  package init(path: String) throws {
    connection = try GatewayDatabaseConnection(path: path)
  }

  package init(inMemory: Void) throws {
    connection = try GatewayDatabaseConnection(inMemory: ())
  }

  package init(connection: GatewayDatabaseConnection) {
    self.connection = connection
  }

  /// Persisted inputs read under one SQLite snapshot. Alias bindings participate in
  /// comparison even though only canonical workspaces appear in the public directory.
  struct ConfigurationState: Equatable, Sendable {
    let workspaces: [RegisteredWorkspace]
    let workspaceAliases: [String: String]
    let profiles: [ProfileGrant]
    let plugins: PluginStoreSnapshot
  }

  func configurationState() throws -> ConfigurationState {
    try writer.read { try Self.configurationState(in: $0) }
  }

  func prepareWorkspaceChange(
    _ mutation: WorkspaceConfigurationMutation, expected: ConfigurationState,
    resolvedProfiles: [ProfileGrant] = []
  ) throws -> PreparedWorkspaceChange<ConfigurationState> {
    let timestamp = Date()
    let receiptID = UUID().uuidString
    return try writer.write { database in
      guard try Self.configurationState(in: database) == expected else {
        throw GatewayDatabaseError.configurationChanged
      }
      var prepared: PreparedWorkspaceChange<ConfigurationState>?
      try database.inSavepoint {
        let result = try Self.applyWorkspaceChange(
          mutation, expected: expected, resolvedProfiles: resolvedProfiles,
          timestamp: timestamp, receiptID: receiptID, in: database)
        prepared = PreparedWorkspaceChange(
          mutation: mutation, expected: expected,
          proposed: try Self.configurationState(in: database),
          resolvedProfiles: resolvedProfiles, result: result, timestamp: timestamp,
          receiptID: receiptID)
        return .rollback
      }
      guard let prepared else { throw GatewayDatabaseError.configurationChanged }
      return prepared
    }
  }

  func saveWorkspaceChange(
    _ prepared: PreparedWorkspaceChange<ConfigurationState>,
    resolution: GatewayConfigurationResolution,
    authorization: GatewayManagementAuthorization? = nil
  ) throws -> ConfigurationState {
    let committed = try writer.write { database in
      try Self.requireManagementTrust(authorization, in: database)
      guard try Self.configurationState(in: database) == prepared.expected else {
        throw GatewayDatabaseError.configurationChanged
      }
      let result = try Self.applyWorkspaceChange(
        prepared.mutation, expected: prepared.expected, resolvedProfiles: prepared.resolvedProfiles,
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

  private static func applyWorkspaceChange(
    _ mutation: WorkspaceConfigurationMutation, expected: ConfigurationState,
    resolvedProfiles: [ProfileGrant], timestamp: Date, receiptID: String, in database: Database
  ) throws -> WorkspaceChangeResult {
    switch mutation {
    case .register(let workspace):
      let result = try registerWorkspaceIdempotently(workspace, in: database)
      return .registered(result.workspace, created: result.created)
    case .repair(let workspace, _):
      guard let original = expected.workspaces.first(where: { $0.id == workspace.id }),
        original.createdAt == workspace.createdAt,
        expected.workspaceAliases[workspace.id] == nil
      else { throw GatewayDatabaseError.configurationChanged }
      if let existing = try registeredWorkspace(
        canonicalRoot: canonicalWorkspaceRoot(workspace.rootPath), in: database),
        existing.id != workspace.id
      {
        throw WorkspaceRepairError.rootAlreadyRegistered(workspaceID: existing.id)
      }
      try saveWorkspace(workspace, in: database)
      let affectedIDs = Set(
        expected.workspaceAliases.filter { $0.value == workspace.id }.map(\.key) + [workspace.id])
      for stored in expected.profiles
      where stored.workspaceIDs.contains("*") || !stored.workspaceIDs.isDisjoint(with: affectedIDs)
      {
        let profile = try resolvedWorkspaceProfile(stored, resolvedProfiles: resolvedProfiles)
        try profile.validate()
        try saveProfile(
          profile, updatedAt: timestamp, expectedRevision: stored.authorizationRevision,
          in: database)
      }
      // Scope-bound tickets can outlive a stored profile. Repair must not reinterpret them.
      for id in affectedIDs {
        try database.execute(
          sql: """
            UPDATE operationTickets SET state = ?, completedAt = ?, failureCode = ?
            WHERE workspaceID = ? AND state IN (?, ?, ?)
            """,
          arguments: [
            OperationTicketState.denied.rawValue, timestamp, "operations.workspace_changed", id,
            OperationTicketState.prepared.rawValue, OperationTicketState.pendingApproval.rawValue,
            OperationTicketState.approved.rawValue,
          ])
      }
      return .repaired(workspace)
    case .remove(let id):
      _ = try removeWorkspace(
        id: id, expectedConfiguration: expected, resolvedProfiles: resolvedProfiles,
        now: timestamp, in: database)
      return .removed
    case .deduplicate(let digest, let allowMetadataConflicts):
      return .deduplicated(
        try applyWorkspaceDeduplication(
          expectedPlanDigest: digest, allowMetadataConflicts: allowMetadataConflicts,
          now: timestamp, expectedConfiguration: expected, resolvedProfiles: resolvedProfiles,
          receiptID: receiptID, in: database))
    }
  }

  private static func configurationState(in database: Database) throws -> ConfigurationState {
    try ConfigurationState(
      workspaces: workspaces(in: database),
      workspaceAliases: Dictionary(
        uniqueKeysWithValues: WorkspaceAliasRecord.fetchAll(database).map {
          ($0.aliasWorkspaceID, $0.canonicalWorkspaceID)
        }),
      profiles: profiles(in: database), plugins: pluginStoreSnapshot(in: database))
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
  func savePluginStoreSnapshot(
    _ state: PluginStoreSnapshot, expectedRevision: Int64,
    expectedConfiguration: ConfigurationState? = nil,
    resolution: GatewayConfigurationResolution = .init(),
    authorization: GatewayManagementAuthorization? = nil
  ) throws -> ConfigurationState {
    try state.validate()
    guard
      expectedConfiguration != nil || (resolution.workspaces.isEmpty && resolution.profiles.isEmpty)
    else { throw PluginStoreError.invalidState }
    guard expectedRevision >= 0, expectedRevision < Int64.max,
      state.revision == expectedRevision + 1
    else {
      throw PluginStoreError.invalidState
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    guard data.count <= 4_194_304, let payload = String(data: data, encoding: .utf8) else {
      throw PluginStoreError.invalidState
    }
    let committed = try writer.write { database in
      try Self.requireManagementTrust(authorization, in: database)
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
      try database.execute(
        sql: """
          INSERT INTO pluginState (id, revision, payloadJSON) VALUES (1, ?, ?)
          ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, payloadJSON = excluded.payloadJSON
          """, arguments: [state.revision, payload])
      try Self.applyRuntimeResolution(resolution, in: database)
      return try Self.configurationState(in: database)
    }
    notifyResolvedProfiles(resolution)
    return committed
  }

  private static func applyRuntimeResolution(
    _ resolution: GatewayConfigurationResolution, in database: Database
  ) throws {
    for change in resolution.workspaces {
      guard change.original.id == change.resolved.id,
        try WorkspaceRecord.fetchOne(database, key: change.original.id)?.value == change.original
      else { throw GatewayDatabaseError.configurationChanged }
      try saveWorkspace(change.resolved, in: database)
    }
    for profile in resolution.profiles {
      guard profile.authorizationRevision == 0,
        try ProfileRecord.fetchOne(database, key: profile.id.rawValue)?.authorizationRevision == 0
      else { throw GatewayDatabaseError.configurationChanged }
      try profile.validate()
      try saveProfile(profile, updatedAt: Date(), expectedRevision: 0, in: database)
    }
  }

  private func notifyResolvedProfiles(_ resolution: GatewayConfigurationResolution) {
    for profile in resolution.profiles {
      profileChangeLock.withLock { profileChangeBroadcasters[profile.id] }?.send()
    }
  }

  package func saveWorkspace(_ workspace: RegisteredWorkspace) throws {
    try writer.write { database in
      try Self.saveWorkspace(workspace, in: database)
    }
  }

  /// Bookmark resolution must not overwrite a concurrent edit or recreate a removed registration.
  @discardableResult
  func saveWorkspace(_ workspace: RegisteredWorkspace, replacing expected: RegisteredWorkspace)
    throws -> Bool
  {
    try writer.write { database in
      guard workspace.id == expected.id,
        try WorkspaceRecord.fetchOne(database, key: expected.id)?.value == expected
      else { return false }
      try Self.saveWorkspace(workspace, in: database)
      return true
    }
  }

  private static func saveWorkspace(_ workspace: RegisteredWorkspace, in database: Database) throws
  {
    try WorkspaceRecord(workspace).save(database)
    let canonicalRoot = Self.canonicalWorkspaceRoot(workspace.rootPath)
    try WorkspaceCanonicalRootRecord
      .filter(Column("workspaceID") == workspace.id)
      .filter(Column("canonicalRootPath") != canonicalRoot)
      .deleteAll(database)
    try WorkspaceCanonicalRootRecord(
      canonicalRootPath: canonicalRoot,
      workspaceID: workspace.id,
      createdAt: workspace.createdAt
    ).insert(database, onConflict: .ignore)
  }

  /// Local recovery ownership is separate from exported plugin settings.
  func pluginOwnedDirectories() throws -> [PluginOwnedDirectory] {
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

  func recordPluginDirectory(_ record: PluginOwnedDirectory) throws {
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

  func forgetPluginDirectory(_ record: PluginOwnedDirectory) throws {
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
  func updatePluginDirectoryIdentity(
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

  package func registerWorkspaceIdempotently(
    _ proposed: RegisteredWorkspace
  ) throws -> (workspace: RegisteredWorkspace, created: Bool) {
    try writer.write { try Self.registerWorkspaceIdempotently(proposed, in: $0) }
  }

  private static func registerWorkspaceIdempotently(
    _ proposed: RegisteredWorkspace, in database: Database
  ) throws -> (workspace: RegisteredWorkspace, created: Bool) {
    let canonicalRoot = canonicalWorkspaceRoot(proposed.rootPath)
    if let existing = try registeredWorkspace(canonicalRoot: canonicalRoot, in: database) {
      return (existing, false)
    }
    try WorkspaceRecord(proposed).insert(database)
    try WorkspaceCanonicalRootRecord(
      canonicalRootPath: canonicalRoot,
      workspaceID: proposed.id,
      createdAt: proposed.createdAt
    ).insert(database)
    return (proposed, true)
  }

  private static func registeredWorkspace(canonicalRoot: String, in database: Database) throws
    -> RegisteredWorkspace?
  {
    if let binding = try WorkspaceCanonicalRootRecord.fetchOne(
      database,
      key: canonicalRoot
    ) {
      let canonicalID =
        try WorkspaceAliasRecord.fetchOne(database, key: binding.workspaceID)?
        .canonicalWorkspaceID
        ?? binding.workspaceID
      if let existing = try WorkspaceRecord.fetchOne(database, key: canonicalID),
        Self.canonicalWorkspaceRoot(existing.rootPath) == canonicalRoot
      {
        if binding.workspaceID != canonicalID {
          try WorkspaceCanonicalRootRecord(
            canonicalRootPath: canonicalRoot, workspaceID: canonicalID,
            createdAt: existing.createdAt
          ).save(database)
        }
        return existing.value
      }
      _ = try WorkspaceCanonicalRootRecord.deleteOne(database, key: canonicalRoot)
    }
    if let existing = try Self.workspaces(in: database).first(where: {
      Self.canonicalWorkspaceRoot($0.rootPath) == canonicalRoot
    }) {
      try WorkspaceCanonicalRootRecord(
        canonicalRootPath: canonicalRoot,
        workspaceID: existing.id,
        createdAt: existing.createdAt
      ).insert(database, onConflict: .ignore)
      return existing
    }
    return nil
  }

  package func workspaces() throws -> [RegisteredWorkspace] {
    try writer.read { try Self.workspaces(in: $0) }
  }

  private static func workspaces(in database: Database) throws -> [RegisteredWorkspace] {
    let aliasIDs = Set(try WorkspaceAliasRecord.fetchAll(database).map(\.aliasWorkspaceID))
    return
      try WorkspaceRecord
      .order(Column("displayName").collating(.nocase), Column("id"))
      .fetchAll(database)
      .filter { !aliasIDs.contains($0.id) }
      .map(\.value)
  }

  package func workspace(id: String) throws -> RegisteredWorkspace? {
    try writer.read { database in
      let resolvedID =
        try WorkspaceAliasRecord.fetchOne(database, key: id)?.canonicalWorkspaceID ?? id
      return try WorkspaceRecord.fetchOne(database, key: resolvedID)?.value
    }
  }

  package func deleteWorkspace(id: String) throws {
    try writer.write { database in
      try Self.deleteWorkspace(id: id, in: database)
    }
  }

  private static func deleteWorkspace(id: String, in database: Database) throws {
    let canonicalID =
      try WorkspaceAliasRecord.fetchOne(database, key: id)?.canonicalWorkspaceID ?? id
    let aliasIDs =
      try WorkspaceAliasRecord
      .filter(Column("canonicalWorkspaceID") == canonicalID)
      .fetchAll(database)
      .map(\.aliasWorkspaceID)
    try WorkspaceAliasRecord
      .filter(Column("canonicalWorkspaceID") == canonicalID)
      .deleteAll(database)
    for removedID in aliasIDs + [canonicalID] {
      try WorkspaceCanonicalRootRecord.filter(Column("workspaceID") == removedID).deleteAll(
        database)
      _ = try WorkspaceRecord.deleteOne(database, key: removedID)
    }
  }

  /// Registration, aliases, affected grants and unused approvals share one commit.
  /// Legacy profiles must be resolved against the admitted manifest before entering SQLite.
  func removeWorkspace(
    id: String, expectedConfiguration: ConfigurationState,
    resolvedProfiles: [ProfileGrant] = [], now: Date = Date()
  ) throws {
    let changed = try writer.write { database in
      try Self.removeWorkspace(
        id: id, expectedConfiguration: expectedConfiguration, resolvedProfiles: resolvedProfiles,
        now: now, in: database)
    }
    for id in changed { profileChangeLock.withLock { profileChangeBroadcasters[id] }?.send() }
  }

  private static func removeWorkspace(
    id: String, expectedConfiguration: ConfigurationState,
    resolvedProfiles: [ProfileGrant], now: Date, in database: Database
  ) throws -> [GatewayProfileID] {
    guard try Self.configurationState(in: database) == expectedConfiguration else {
      throw GatewayDatabaseError.configurationChanged
    }
    let canonicalID = expectedConfiguration.workspaceAliases[id] ?? id
    guard expectedConfiguration.workspaces.contains(where: { $0.id == canonicalID }) else {
      throw GatewayDatabaseError.invalidStoredValue("Unknown workspace '\(id)'.")
    }
    let removedIDs = Set(
      expectedConfiguration.workspaceAliases.filter { $0.value == canonicalID }.map(\.key)
        + [canonicalID])
    var changed: [GatewayProfileID] = []
    for stored in expectedConfiguration.profiles {
      guard !stored.workspaceIDs.isDisjoint(with: removedIDs) else { continue }
      var profile = try Self.resolvedWorkspaceProfile(stored, resolvedProfiles: resolvedProfiles)
      profile.workspaceIDs.subtract(removedIDs)
      try profile.validate()
      try Self.saveProfile(
        profile, updatedAt: now, expectedRevision: stored.authorizationRevision, in: database)
      changed.append(profile.id)
    }
    try Self.deleteWorkspace(id: canonicalID, in: database)
    return changed
  }

  private static func resolvedWorkspaceProfile(
    _ stored: ProfileGrant, resolvedProfiles: [ProfileGrant]
  ) throws -> ProfileGrant {
    guard stored.authorizationRevision == 0 else { return stored }
    let matches = resolvedProfiles.filter { $0.id == stored.id && $0.authorizationRevision == 0 }
    guard matches.count == 1, let profile = matches.first else {
      throw GatewayDatabaseError.invalidStoredValue(
        "Resolve legacy profile '\(stored.id.rawValue)' before changing its workspace grants.")
    }
    return profile
  }

  package func workspaceDeduplicationPlan() throws -> WorkspaceDeduplicationPlan {
    try writer.read { database in
      try Self.workspaceDeduplicationPlan(database)
    }
  }

  func applyWorkspaceDeduplication(
    expectedPlanDigest: String,
    allowMetadataConflicts: Bool,
    now: Date = Date(),
    expectedConfiguration: ConfigurationState? = nil,
    resolvedProfiles: [ProfileGrant] = []
  ) throws -> WorkspaceDeduplicationResult {
    let result = try writer.write { database in
      try Self.applyWorkspaceDeduplication(
        expectedPlanDigest: expectedPlanDigest, allowMetadataConflicts: allowMetadataConflicts,
        now: now, expectedConfiguration: expectedConfiguration, resolvedProfiles: resolvedProfiles,
        receiptID: UUID().uuidString, in: database)
    }
    for rawID in result.updatedProfileIDs {
      if let id = GatewayProfileID(rawValue: rawID) {
        profileChangeLock.withLock { profileChangeBroadcasters[id] }?.send()
      }
    }
    return result
  }

  private static func applyWorkspaceDeduplication(
    expectedPlanDigest: String, allowMetadataConflicts: Bool, now: Date,
    expectedConfiguration: ConfigurationState?, resolvedProfiles: [ProfileGrant],
    receiptID: String, in database: Database
  ) throws -> WorkspaceDeduplicationResult {
    if let expectedConfiguration,
      try Self.configurationState(in: database) != expectedConfiguration
    {
      throw GatewayDatabaseError.configurationChanged
    }
    let plan = try Self.workspaceDeduplicationPlan(database)
    guard plan.planDigest == expectedPlanDigest else {
      throw WorkspaceDeduplicationError.planChanged(
        expected: expectedPlanDigest,
        actual: plan.planDigest
      )
    }
    let conflictIDs = plan.groups.filter(\.hasMetadataConflict)
      .flatMap(\.duplicateWorkspaceIDs)
      .sorted()
    if !allowMetadataConflicts, !conflictIDs.isEmpty {
      throw WorkspaceDeduplicationError.metadataConflict(workspaceIDs: conflictIDs)
    }

    var replacements: [String: String] = [:]
    for group in plan.groups {
      guard
        let canonical = try WorkspaceRecord.fetchOne(database, key: group.canonicalWorkspaceID)
      else { throw GatewayDatabaseError.configurationChanged }
      try WorkspaceCanonicalRootRecord(
        canonicalRootPath: group.canonicalRootPath, workspaceID: canonical.id,
        createdAt: canonical.createdAt
      ).save(database)
      for duplicateID in group.duplicateWorkspaceIDs {
        try WorkspaceAliasRecord(
          aliasWorkspaceID: duplicateID,
          canonicalWorkspaceID: group.canonicalWorkspaceID,
          canonicalRootPath: group.canonicalRootPath,
          migratedAt: now
        ).save(database)
        replacements[duplicateID] = group.canonicalWorkspaceID
      }
    }
    var updatedProfileIDs: [String] = []
    for stored in try Self.profiles(in: database) {
      guard stored.workspaceIDs.contains(where: { replacements[$0] != nil }) else { continue }
      var profile = try Self.resolvedWorkspaceProfile(stored, resolvedProfiles: resolvedProfiles)
      profile.workspaceIDs = Set(profile.workspaceIDs.map { replacements[$0] ?? $0 })
      try profile.validate()
      try Self.saveProfile(
        profile, updatedAt: now, expectedRevision: stored.authorizationRevision, in: database)
      updatedProfileIDs.append(profile.id.rawValue)
    }

    let result = WorkspaceDeduplicationResult(
      receiptID: receiptID,
      planDigest: plan.planDigest,
      canonicalWorkspaceIDs: plan.groups.map(\.canonicalWorkspaceID).sorted(),
      aliasedWorkspaceIDs: plan.groups.flatMap(\.duplicateWorkspaceIDs).sorted(),
      updatedProfileIDs: updatedProfileIDs.sorted(),
      appliedAt: now
    )
    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    try WorkspaceDeduplicationReceiptRecord(
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

  static func decodeDesiredOpenAITunnelConfigurationIDs(_ value: String) throws -> [String] {
    guard let data = value.data(using: .utf8) else { return [] }
    let identifiers = try JSONDecoder().decode([String].self, from: data)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return Array(Set(identifiers)).sorted()
  }

  static func decodeDesiredCloudflareProfileIDs(_ value: String) throws -> [String] {
    guard let data = value.data(using: .utf8) else { return [] }
    return try JSONDecoder().decode([String].self, from: data).sorted()
  }

  static func decodeGatewayTunnelRegistration(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else {
      throw GatewayDatabaseError.invalidStoredValue("The gateway tunnel registration is invalid.")
    }
    return id
  }

  static func decodeActiveGatewayProfile(_ value: String) throws -> GatewayProfileID {
    guard let profile = GatewayProfileID(rawValue: value) else {
      throw GatewayDatabaseError.invalidStoredValue("The active gateway profile is invalid.")
    }
    return profile
  }

  package func saveProfile(
    _ profile: ProfileGrant, updatedAt: Date = Date(), expectedRevision: Int64? = nil
  ) throws {
    try profile.validate()
    try writer.write { database in
      try Self.saveProfile(
        profile, updatedAt: updatedAt, expectedRevision: expectedRevision, in: database)
    }
    profileChangeLock.withLock { profileChangeBroadcasters[profile.id] }?.send()
  }

  func saveProfile(
    _ profile: ProfileGrant, expectedRevision: Int64, expectedConfiguration: ConfigurationState,
    authorization: GatewayManagementAuthorization? = nil
  ) throws {
    try profile.validate()
    try writer.write { database in
      try Self.requireManagementTrust(authorization, in: database)
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
    try ProfileRecord(saved, updatedAt: updatedAt).save(database)
    try database.execute(
      sql: """
        UPDATE operationTickets SET state = ?, completedAt = ?, failureCode = ?
        WHERE profileID = ? AND state IN (?, ?, ?)
        """,
      arguments: [
        OperationTicketState.denied.rawValue, updatedAt,
        "operations.authorization_changed", profile.id.rawValue,
        OperationTicketState.prepared.rawValue, OperationTicketState.pendingApproval.rawValue,
        OperationTicketState.approved.rawValue,
      ])
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

  func clientTrust(id: String) throws -> GatewayClientTrust? {
    try writer.read { try GatewayClientTrust.fetchOne($0, key: id) }
  }

  func clientTrust(
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
    let (consent, trustChanged) = try writer.write { database in
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
    let profileID = try writer.write { database in
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

  /// The manifest replacement and activated revision share a single commit decision.
  /// A recovery journal restores file state if SQLite rolls this transaction back.
  func activateConfigurationRevision(
    _ revision: ConfigurationRevision, expected: ConfigurationState,
    resolution: GatewayConfigurationResolution,
    replaceManifest: (ConfigurationState) throws -> Void
  ) throws -> ConfigurationState {
    let committed = try writer.write { database in
      guard try Self.configurationState(in: database) == expected else {
        throw GatewayDatabaseError.configurationChanged
      }
      try Self.applyRuntimeResolution(resolution, in: database)
      try ConfigurationRevisionRecord(revision).insert(database)
      let state = try Self.configurationState(in: database)
      try replaceManifest(state)
      return state
    }
    notifyResolvedProfiles(resolution)
    return committed
  }

  func configurationRevision(id: String) throws -> ConfigurationRevision? {
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

  /// Checks imported workspaces, canonical roots, aliases, profiles, plugin state and
  /// ownership, derived registrations, client trust and runtime-setting rows with their
  /// decoders. Validates the desired tunnel lists, tunnel registration and active profile
  /// with their readers' rules, and parses the latest activated configuration revision,
  /// resolving relative paths against `configurationDirectory`.
  package func verifyImportedState(configurationDirectory: URL) throws {
    let state = try configurationState()
    _ = try pluginOwnedDirectories()
    _ = try clientTrusts()
    let active = try writer.read { database in
      _ = try WorkspaceCanonicalRootRecord.fetchAll(database)
      for setting in try RuntimeSettingRecord.fetchAll(database) {
        switch setting.key {
        case "desired-running-openai-tunnels":
          _ = try Self.decodeDesiredOpenAITunnelConfigurationIDs(setting.value)
        case "desired-running-cloudflare-tunnels":
          _ = try Self.decodeDesiredCloudflareProfileIDs(setting.value)
        case "gateway-tunnel-registration":
          _ = try Self.decodeGatewayTunnelRegistration(setting.value)
        case "active-gateway-profile":
          _ = try Self.decodeActiveGatewayProfile(setting.value)
        default: break
        }
      }
      for id in try String.fetchAll(
        database, sql: "SELECT workspaceID FROM pluginDerivedWorkspaces")
      {
        _ = try Self.derivedRegistration(id: id, database: database)
      }
      return try ConfigurationRevisionRecord.filter(Column("activatedAt") != nil)
        .order(Column("activatedAt").desc, Column("createdAt").desc, Column("id").desc)
        .fetchOne(database)
    }
    if let active {
      _ = try GatewayConfiguration.load(
        text: active.manifest, baseURL: configurationDirectory,
        knownPluginMCPServerIDs: state.plugins.knownMCPRegistrationIDs)
    }
  }

  package func recordAudit(_ event: AuditEvent) throws {
    try writer.write { database in
      try AuditEventRecord(event).insert(database)
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
      guard
        var record =
          try AuditEventRecord
          .filter(Column("requestID") == gatewayRequestID)
          .filter(Column("socketConnectionID") == socketConnectionID)
          .order(Column("occurredAt").desc, Column("id").desc)
          .fetchOne(database)
      else {
        return false
      }
      guard record.mcpRequestID == nil || record.mcpRequestID == mcpRequestID else {
        return false
      }
      record.mcpRequestID = mcpRequestID
      try record.update(database)
      try AuditEventRecord
        .filter(Column("parentRequestID") == gatewayRequestID)
        .updateAll(database, Column("mcpRequestID").set(to: mcpRequestID))
      return true
    }
  }

  package func saveOperationTicket(_ ticket: OperationTicket) throws {
    try writer.write { database in
      try OperationTicketRecord(ticket).save(database)
    }
  }

  package func operationTicket(id: String) throws -> OperationTicket? {
    try writer.write { database in
      try Self.expireOperationApprovals(in: database, at: Date())
      return try OperationTicketRecord.fetchOne(database, key: id)?.value()
    }
  }

  package func operationApprovals(limit: Int = 100) throws -> [OperationTicket] {
    try writer.write { database in
      try Self.expireOperationApprovals(in: database, at: Date())
      return
        try OperationTicketRecord
        .filter(Column("authorizationRevision") != nil)
        .order(Column("createdAt").desc, Column("id"))
        .limit(max(1, min(limit, 500))).fetchAll(database).map { try $0.value() }
    }
  }

  @discardableResult
  package func resolveOperationApproval(
    id: String, approved: Bool, resolver: GatewayCallerKind, at date: Date = Date()
  ) throws -> OperationTicket {
    guard resolver == .localApp || resolver == .localCLI else {
      throw GatewayDatabaseError.invalidOperationTicketTransition(
        "Only the local management interface may resolve host approvals.")
    }
    return try writer.write { database in
      try Self.expireOperationApprovals(in: database, at: date)
      guard var record = try OperationTicketRecord.fetchOne(database, key: id) else {
        throw GatewayDatabaseError.operationTicketUnknown(id)
      }
      guard record.state == OperationTicketState.pendingApproval.rawValue else {
        throw GatewayDatabaseError.operationTicketUnavailable(id: id, state: record.state)
      }
      if let profile = try ProfileRecord.fetchOne(database, key: record.profileID),
        record.authorizationRevision != profile.authorizationRevision
      {
        throw GatewayDatabaseError.invalidOperationTicketTransition(
          "Authorization changed after approval was requested.")
      }
      record.state =
        approved ? OperationTicketState.approved.rawValue : OperationTicketState.denied.rawValue
      record.completedAt = approved ? nil : date
      record.failureCode = approved ? nil : "operations.user_denied"
      try record.update(database)
      return try record.value()
    }
  }

  private static func expireOperationApprovals(in database: Database, at date: Date) throws {
    try database.execute(
      sql: """
        UPDATE operationTickets SET state = ?, completedAt = ?, failureCode = ?
        WHERE expiresAt <= ? AND state IN (?, ?, ?)
        """,
      arguments: [
        OperationTicketState.expired.rawValue, date, "operations.ticket_expired", date,
        OperationTicketState.prepared.rawValue, OperationTicketState.pendingApproval.rawValue,
        OperationTicketState.approved.rawValue,
      ])
  }

  package func beginOperationTicket(
    id: String,
    principalID: String,
    invocationID: String,
    parentRequestID: String,
    at date: Date = Date()
  ) throws -> OperationTicket {
    let outcome = try writer.write { database -> OperationTicketBeginOutcome in
      guard var record = try OperationTicketRecord.fetchOne(database, key: id) else {
        return .rejected(.operationTicketUnknown(id))
      }
      guard record.principalID == principalID else {
        return .rejected(.operationTicketPrincipalMismatch(id))
      }
      guard
        record.state == OperationTicketState.prepared.rawValue
          || record.state == OperationTicketState.approved.rawValue
      else {
        return .rejected(
          .operationTicketUnavailable(
            id: id,
            state: record.state
          )
        )
      }
      guard record.expiresAt > date else {
        record.state = OperationTicketState.expired.rawValue
        record.completedAt = date
        record.failureCode = "operations.ticket_expired"
        try record.update(database)
        return .rejected(.operationTicketExpired(id))
      }
      if let profile = try ProfileRecord.fetchOne(database, key: record.profileID),
        let revision = record.authorizationRevision, revision != profile.authorizationRevision
      {
        return .rejected(.operationTicketUnavailable(id: id, state: "authorization_changed"))
      }
      record.state = OperationTicketState.executing.rawValue
      record.invocationID = invocationID
      record.parentRequestID = parentRequestID
      record.executingAt = date
      try record.update(database)
      return .began(try record.value())
    }
    switch outcome {
    case .began(let ticket):
      return ticket
    case .rejected(let error):
      throw error
    }
  }

  package func finishOperationTicket(
    id: String,
    invocationID: String,
    state: OperationTicketState,
    failureCode: String? = nil,
    at date: Date = Date()
  ) throws -> OperationTicket {
    guard state == .succeeded || state == .failed else {
      throw GatewayDatabaseError.invalidOperationTicketTransition(
        "Operation ticket completion state must be succeeded or failed."
      )
    }
    return try writer.write { database in
      guard var record = try OperationTicketRecord.fetchOne(database, key: id) else {
        throw GatewayDatabaseError.operationTicketUnknown(id)
      }
      guard record.state == OperationTicketState.executing.rawValue,
        record.invocationID == invocationID
      else {
        throw GatewayDatabaseError.operationTicketUnavailable(
          id: id,
          state: record.state
        )
      }
      record.state = state.rawValue
      record.completedAt = date
      record.failureCode = state == .failed ? failureCode : nil
      try record.update(database)
      return try record.value()
    }
  }

  @discardableResult
  package func failPreparedOperationTicket(
    id: String,
    principalID: String,
    failureCode: String,
    at date: Date = Date()
  ) throws -> OperationTicket {
    try writer.write { database in
      guard var record = try OperationTicketRecord.fetchOne(database, key: id) else {
        throw GatewayDatabaseError.operationTicketUnknown(id)
      }
      guard record.principalID == principalID else {
        throw GatewayDatabaseError.operationTicketPrincipalMismatch(id)
      }
      guard
        [OperationTicketState.prepared, .pendingApproval, .approved].map(\.rawValue).contains(
          record.state)
      else {
        throw GatewayDatabaseError.operationTicketUnavailable(
          id: id,
          state: record.state
        )
      }
      record.state = OperationTicketState.failed.rawValue
      record.completedAt = date
      record.failureCode = failureCode
      try record.update(database)
      return try record.value()
    }
  }

  private static func workspaceDeduplicationPlan(
    _ database: Database
  ) throws -> WorkspaceDeduplicationPlan {
    let aliasIDs = Set(try WorkspaceAliasRecord.fetchAll(database).map(\.aliasWorkspaceID))
    let workspaces = try WorkspaceRecord.fetchAll(database)
      .filter { !aliasIDs.contains($0.id) }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id < $1.id
      }
    let profiles = try ProfileRecord.fetchAll(database).map { try $0.value() }
    let grouped = Dictionary(grouping: workspaces) {
      canonicalWorkspaceRoot($0.rootPath)
    }
    let groups = grouped.keys.sorted().compactMap {
      canonicalRoot
        -> WorkspaceDeduplicationGroup? in
      guard let records = grouped[canonicalRoot], records.count > 1,
        let canonical = records.first
      else { return nil }
      let members = records.map { record in
        WorkspaceDeduplicationMember(
          workspaceID: record.id,
          displayName: record.displayName,
          rootPath: record.rootPath,
          createdAt: record.createdAt,
          referencedProfileIDs:
            profiles
            .filter { $0.workspaceIDs.contains(record.id) }
            .map { $0.id.rawValue }
            .sorted()
        )
      }
      return WorkspaceDeduplicationGroup(
        canonicalRootPath: canonicalRoot,
        canonicalWorkspaceID: canonical.id,
        duplicateWorkspaceIDs: Array(records.dropFirst().map(\.id)).sorted(),
        members: members,
        hasMetadataConflict: Set(records.map(\.displayName)).count > 1
      )
    }
    let digestInput = WorkspaceDeduplicationDigestInput(groups: groups)
    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    let digest = SHA256.hash(data: try encoder.encode(digestInput))
      .map { String(format: "%02x", $0) }
      .joined()
    return WorkspaceDeduplicationPlan(
      planDigest: digest,
      groups: groups,
      duplicateCount: groups.reduce(0) { $0 + $1.duplicateWorkspaceIDs.count },
      affectedProfileIDs: Set(
        groups.flatMap(\.members).flatMap(\.referencedProfileIDs)
      ).sorted()
    )
  }

  private static func canonicalWorkspaceRoot(_ path: String) -> String {
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
      let request = AuditEventRecord.filter(Column("workspaceID") == context.workspaceID)
        .filter(Column("profileID") == context.profileID.rawValue)
        .filter(Column("principalDigest") == principal)
      return try request.order(Column("occurredAt").desc, Column("id").desc)
        .limit(max(1, min(1_000, limit))).fetchAll(database).map { try $0.value() }
    }
  }

  func derivedWorkspaceRegistration(id: String) throws -> MCPDerivedWorkspaceRegistration? {
    try writer.read { try Self.derivedRegistration(id: id, database: $0) }
  }

  /// Registration and the single host-added grant are committed together.
  func registerDerivedWorkspace(
    _ registration: MCPDerivedWorkspaceRegistration, verifiedPrincipalID: String,
    caller: GatewayCallerKind
  ) throws {
    try Self.requireDerivedPrincipal(registration, verifiedPrincipalID: verifiedPrincipalID)
    let payload = try JSONEncoder().encode(registration)
    guard payload.count <= 32_768 else {
      throw MCPHostServiceError.denied("Registration exceeds its bound.")
    }
    let changed = try writer.write { database in
      guard
        let source = try WorkspaceRecord.fetchOne(database, key: registration.sourceWorkspaceID),
        Self.canonicalWorkspaceRoot(source.rootPath) == registration.sourceRoot,
        let profileRow = try ProfileRecord.fetchOne(database, key: registration.profileID.rawValue)
      else {
        throw MCPHostServiceError.denied("Source registration or profile is unavailable.")
      }
      var profile = try profileRow.value()
      try Self.requireDerivedSourceGrant(profile, registration: registration, caller: caller)
      if let old = try Self.derivedRegistration(id: registration.workspace.id, database: database) {
        try Self.requireDerivedPrincipal(old, verifiedPrincipalID: verifiedPrincipalID)
        guard old.origin == registration.origin, old.receiptDigest == registration.receiptDigest,
          old.receiptID == registration.receiptID, old.profileID == registration.profileID,
          old.sourceWorkspaceID == registration.sourceWorkspaceID,
          old.sourceRoot == registration.sourceRoot,
          Self.sameDerivedWorkspace(old.workspace, registration.workspace),
          let workspace = try WorkspaceRecord.fetchOne(database, key: old.workspace.id),
          Self.sameDerivedWorkspace(workspace.value, old.workspace)
        else { throw MCPHostServiceError.denied("Existing derived registration changed.") }
        return false
      }
      guard try WorkspaceRecord.fetchOne(database, key: registration.workspace.id) == nil,
        try WorkspaceAliasRecord.fetchOne(database, key: registration.workspace.id) == nil
      else {
        throw MCPHostServiceError.denied("Derived identity or source registration is unavailable.")
      }
      guard
        try !ProfileRecord.fetchAll(database).contains(where: {
          try $0.value().workspaceIDs.contains(registration.workspace.id)
        })
      else {
        throw MCPHostServiceError.denied(
          "The derived identity already has an independently owned grant.")
      }
      let root = Self.canonicalWorkspaceRoot(registration.workspace.rootPath)
      guard try WorkspaceCanonicalRootRecord.fetchOne(database, key: root) == nil else {
        throw MCPHostServiceError.denied(
          "The directory already belongs to an independent registration.")
      }
      try WorkspaceRecord(registration.workspace).insert(database)
      try WorkspaceCanonicalRootRecord(
        canonicalRootPath: root, workspaceID: registration.workspace.id,
        createdAt: registration.workspace.createdAt
      ).insert(database)
      profile.workspaceIDs.insert(registration.workspace.id)
      try Self.saveDerivedProfileChange(profile, database: database)
      try database.execute(
        sql:
          "INSERT INTO pluginDerivedWorkspaces (workspaceID, origin, sourceWorkspaceID, receiptID, payloadJSON) VALUES (?, ?, ?, ?, ?)",
        arguments: [
          registration.workspace.id, registration.origin, registration.sourceWorkspaceID,
          registration.receiptID, String(decoding: payload, as: UTF8.self),
        ])
      return true
    }
    if changed {
      profileChangeLock.withLock { profileChangeBroadcasters[registration.profileID] }?.send()
    }
  }

  /// Does not remove independently edited registrations, aliases, or grants.
  func unregisterDerivedWorkspace(
    _ registration: MCPDerivedWorkspaceRegistration, verifiedPrincipalID: String,
    caller: GatewayCallerKind, allowRevokedSourceForRollback: Bool = false
  ) throws {
    try Self.requireDerivedPrincipal(registration, verifiedPrincipalID: verifiedPrincipalID)
    let changedProfile = try writer.write { database -> Bool in
      guard
        let old = try Self.derivedRegistration(id: registration.workspace.id, database: database)
      else { return false }
      try Self.requireDerivedPrincipal(old, verifiedPrincipalID: verifiedPrincipalID)
      guard old == registration,
        let workspace = try WorkspaceRecord.fetchOne(database, key: old.workspace.id),
        Self.sameDerivedWorkspace(workspace.value, old.workspace),
        try WorkspaceAliasRecord.filter(Column("canonicalWorkspaceID") == old.workspace.id)
          .fetchCount(database) == 0
      else { throw MCPHostServiceError.denied("The derived registration has independent changes.") }
      let profiles = try ProfileRecord.fetchAll(database)
      if !allowRevokedSourceForRollback {
        guard let source = try WorkspaceRecord.fetchOne(database, key: old.sourceWorkspaceID),
          Self.canonicalWorkspaceRoot(source.rootPath) == old.sourceRoot,
          let profile = try profiles.first(where: { $0.id == old.profileID.rawValue })?.value()
        else {
          throw MCPHostServiceError.denied("The source profile is unavailable.")
        }
        try Self.requireDerivedSourceGrant(profile, registration: old, caller: caller)
      }
      var changed = false
      for row in profiles {
        var profile = try row.value()
        guard profile.workspaceIDs.contains(old.workspace.id) else { continue }
        guard profile.id == old.profileID else {
          throw MCPHostServiceError.denied(
            "Another profile now holds an independent workspace grant.")
        }
        profile.workspaceIDs.remove(old.workspace.id)
        try Self.saveDerivedProfileChange(profile, database: database)
        changed = true
      }
      try WorkspaceCanonicalRootRecord.filter(Column("workspaceID") == old.workspace.id).deleteAll(
        database)
      _ = try WorkspaceRecord.deleteOne(database, key: old.workspace.id)
      try database.execute(
        sql: "DELETE FROM pluginDerivedWorkspaces WHERE workspaceID = ?",
        arguments: [old.workspace.id])
      return changed
    }
    if changedProfile {
      profileChangeLock.withLock { profileChangeBroadcasters[registration.profileID] }?.send()
    }
  }

  private static func requireDerivedPrincipal(
    _ registration: MCPDerivedWorkspaceRegistration, verifiedPrincipalID: String
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
    _ profile: ProfileGrant, registration: MCPDerivedWorkspaceRegistration,
    caller: GatewayCallerKind
  ) throws {
    guard
      profile.workspaceIDs.contains(registration.sourceWorkspaceID)
        || profile.workspaceIDs.contains("*"),
      profile.allowedCallers.contains(caller), profile.permitsRisk(.workspaceWrite)
    else {
      throw MCPHostServiceError.denied(
        "The persisted source grant no longer permits derived registration changes.")
    }
  }

  private static func saveDerivedProfileChange(_ profile: ProfileGrant, database: Database) throws {
    guard profile.authorizationRevision < Int64.max else {
      throw GatewayDatabaseError.invalidStoredValue("Profile authorization revision exhausted.")
    }
    var saved = profile
    saved.authorizationRevision += 1
    let date = Date()
    try ProfileRecord(saved, updatedAt: date).update(database)
    try database.execute(
      sql: """
        UPDATE operationTickets SET state = ?, completedAt = ?, failureCode = ?
        WHERE profileID = ? AND state IN (?, ?, ?)
        """,
      arguments: [
        OperationTicketState.denied.rawValue, date, "operations.authorization_changed",
        profile.id.rawValue,
        OperationTicketState.prepared.rawValue, OperationTicketState.pendingApproval.rawValue,
        OperationTicketState.approved.rawValue,
      ])
  }

  private static func sameDerivedWorkspace(
    _ current: RegisteredWorkspace, _ expected: RegisteredWorkspace
  ) -> Bool {
    // Compare timestamps at the database's exact serialization precision, not a time tolerance.
    current.id == expected.id && current.displayName == expected.displayName
      && current.rootPath == expected.rootPath && current.bookmarkData == expected.bookmarkData
      && current.bookmarkIsStale == expected.bookmarkIsStale
      && current.createdAt.databaseValue == expected.createdAt.databaseValue
      && current.updatedAt.databaseValue == expected.updatedAt.databaseValue
  }

  private static func derivedRegistration(id: String, database: Database) throws
    -> MCPDerivedWorkspaceRegistration?
  {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT * FROM pluginDerivedWorkspaces WHERE workspaceID = ?",
        arguments: [id])
    else { return nil }
    let payload: String = row["payloadJSON"]
    guard payload.utf8.count <= 32_768 else {
      throw MCPHostServiceError.denied("Invalid stored derived registration.")
    }
    let record = try JSONDecoder().decode(
      MCPDerivedWorkspaceRegistration.self, from: Data(payload.utf8))
    guard record.workspace.id == id, record.origin == row["origin"],
      record.sourceWorkspaceID == row["sourceWorkspaceID"], record.receiptID == row["receiptID"]
    else {
      throw MCPHostServiceError.denied("Stored registration identity differs from its record.")
    }
    return record
  }
}

extension GatewayClientTrust: FetchableRecord, PersistableRecord {
  package static let databaseTableName = "clientControlTrust"
}

private enum OperationTicketBeginOutcome {
  case began(OperationTicket)
  case rejected(GatewayDatabaseError)
}
