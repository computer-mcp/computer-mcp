import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence
@testable import ComputerMCPPlugins

@Suite struct PermissionProfileMigrationTests {
  let project = ComputerMCPCore.RegisteredProject(
    id: "project", displayName: "Fixture", rootPath: "/fixture/project",
    createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
  func profile(
    _ capabilities: Set<String> = [], mode: LegacyPermissionMode = .projectOperations,
    shell: Bool = false, projects: Set<String> = ["project"], servers: Set<String> = []
  ) -> LegacyProfileGrant {
    LegacyProfileGrant(
      id: .chatGPTOperate, capabilityIDs: capabilities, projectIDs: projects,
      allowedCallers: [.secureTunnel], fullShellEnabled: shell, mcpServerIDs: servers,
      mode: mode, authorizationRevision: 7)
  }
  func catalog(
    _ profile: LegacyProfileGrant, tools: [PermissionMigrationTool] = [],
    available: Set<String>? = nil
  ) throws -> PermissionMigrationCatalog {
    try PermissionMigrationCatalog(
      configurationDigest: "config",
      availableBuiltinIDs: available ?? Set(PermissionMigrationCatalog.builtinV1.map(\.id)),
      dynamicTools: tools, serverIDs: ["server"], manifestProfiles: [profile])
  }
  func convert(
    _ profile: LegacyProfileGrant, tools: [PermissionMigrationTool] = [],
    available: Set<String>? = nil
  ) throws -> PermissionMigrationPlan {
    try PermissionProfileMigration.plan(
      profiles: [profile], catalog: catalog(profile, tools: tools, available: available),
      projects: .init(registered: [project]))
  }

  @Test(
    arguments: [LegacyPermissionMode.localFullAccess, .projectOperations, .readOnly],
    [false, true])
  func modesAndRiskFiltering(mode: LegacyPermissionMode, write: Bool) throws {
    let old = profile(write ? ["file.write"] : ["file.read"], mode: mode)
    let new = try #require(convert(old).profiles.first)
    #expect(new.fullAccess == false)
    #expect(
      new.permissions.state(for: .project("project"))
        == .granted(write && mode != .readOnly ? .write : .read))
    #expect(new.authorizationRevision == 8)
    #expect(new.projectNetworks["project"] == NetworkAccess.none)
    #expect(new.permissions.state(for: .machineInformation) == .notGranted)
  }

  @Test func fullAccessAndFutureProjectWildcard() throws {
    let new = try #require(
      convert(profile(mode: .localFullAccess, shell: true, projects: ["*", "project"])).profiles
        .first)
    #expect(new.fullAccess)
    #expect(new.permissions.state(for: .project("future")) == .granted(.write))
    #expect(new.permissions.entries[.project("project")] == .granted(.write))
  }

  @Test func effectivePrivacyAndNetworkClassification() throws {
    let old = profile(
      [
        "computer.screenshot", "computer.keyboard.text", "system.info", "logs.query", "skills.read",
        "file.download", "network.interfaces",
      ], mode: .readOnly)
    let readonly = try #require(convert(old).profiles.first)
    #expect(readonly.permissions.state(for: .screen) == .granted(.access))
    #expect(readonly.permissions.state(for: .desktopControl) == .notGranted)
    #expect(readonly.permissions.state(for: .unifiedLogs) == .granted(.access))
    #expect(readonly.permissions.state(for: .skills) == .granted(.access))
    #expect(readonly.permissions.state(for: .localNetwork) == .notGranted)
    #expect(readonly.projectNetworks["project"] == NetworkAccess.none)
    #expect(
      try convert(profile(["file.download"])).profiles[0].projectNetworks["project"]
        == NetworkAccess.none)
    #expect(
      try convert(profile(["network.interfaces"])).profiles[0].projectNetworks["project"]
        == NetworkAccess.none)
  }

  @Test(arguments: [LegacyPermissionMode.localFullAccess, .projectOperations, .readOnly])
  func networkUsingProjectToolsStartWithNoNetworkAccess(mode: LegacyPermissionMode) throws {
    let converted = try convert(
      profile(["file.download"], mode: mode, shell: true, projects: ["*", "project"]))
    let migrated = try #require(converted.profiles.first)
    #expect(migrated.projectNetworks == ["*": NetworkAccess.none, "project": NetworkAccess.none])
    #expect(
      migrated.permissions.state(for: .project("project"))
        == .granted(mode == .readOnly ? .read : .write))
  }

  @Test(arguments: [LegacyPermissionMode.readOnly, .projectOperations])
  func downstreamWrappersServersAndAliases(mode: LegacyPermissionMode) throws {
    let value: PermissionState = .granted(mode == .readOnly ? .read : .all)
    #expect(
      try convert(profile(["mcp.tools.call"], mode: mode)).profiles[0].permissions.state(
        for: .mcpServer("future")) == value)
    #expect(
      try convert(profile(mode: mode, servers: ["server"])).profiles[0].permissions.state(
        for: .mcpServer("server")) == value)
    #expect(
      try convert(profile(mode: mode, servers: ["server"])).profiles[0].permissions.state(
        for: .mcpServer("unregistered")) == .notGranted)
    let tool = PermissionMigrationTool(
      id: "server.read", risk: .readOnly, aliases: ["old.read"], serverID: "server",
      pluginID: "package")
    let plan = try convert(profile(["old.read"], mode: mode), tools: [tool])
    #expect(plan.profiles[0].permissions.state(for: .mcpServer("server")) == .granted(.read))
    #expect(plan.profiles[0].permissions.state(for: .plugin("package")) == .granted(.use))
    #expect(plan.report.dropped.isEmpty)
    #expect(
      try convert(profile(["old.read"], mode: mode)).profiles[0].permissions.state(
        for: .mcpServer("server")) == .notGranted)
  }

  @Test func readSurfacesCancelOnlyDisabledAndAbsentTools() throws {
    #expect(
      try convert(profile(["mcp.resources.read"])).profiles[0].permissions.state(
        for: .mcpServer("future")) == .granted(.read))
    let controls = try convert(profile(["mcp.requests.cancel", "mcp.connections.close"]))
    #expect(controls.profiles[0].permissions.state(for: .mcpServer("future")) == .notGranted)
    #expect(controls.report.dropped.count == 2)
    let absent = try convert(profile(["logs.query"]), available: [])
    #expect(absent.profiles[0].permissions.state(for: .unifiedLogs) == .notGranted)
  }

  @Test func revisionZeroUsesManifestAndNewDefaultsStaySeparate() throws {
    var old = profile(["computer.keyboard.text"])
    old.authorizationRevision = 0
    let defaults = profile(["logs.query"])
    let plan = try PermissionProfileMigration.plan(
      profiles: [old], catalog: catalog(defaults), projects: .init(registered: [project]))
    #expect(plan.profiles[0].permissions.state(for: .desktopControl) == .notGranted)
    #expect(plan.profiles[0].permissions.state(for: .unifiedLogs) == .granted(.access))
    #expect(plan.profiles[0].authorizationRevision == 1)
    #expect(try convert(profile()).profiles[0].permissions.state(for: .skills) == .notGranted)
    #expect(
      ProfileGrant.newPrincipal(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
        .permissions.state(for: .skills) == .granted(.access))
    let missing = try PermissionMigrationCatalog(
      configurationDigest: "config", availableBuiltinIDs: [], serverIDs: [], manifestProfiles: [])
    #expect(throws: PermissionMigrationError.missingManifestProfile(old.id.rawValue)) {
      try PermissionProfileMigration.plan(
        profiles: [old], catalog: missing, projects: .init(registered: [project]))
    }
  }

  @Test func deterministicOrderingAndBoundedUnresolvedReport() throws {
    let old = profile(Set((0..<300).map { "missing-\($0)" }))
    let first = try convert(old)
    let second = try convert(old)
    #expect(first.profiles == second.profiles)
    #expect(first.inputDigest == second.inputDigest)
    #expect(first.report == second.report)
    #expect(first.report.dropped.count == 256)
    #expect(first.report.omittedCount == 44)
    let a = PermissionMigrationTool(
      id: "a", risk: .readOnly, aliases: ["z", "y"], serverID: "server")
    let b = PermissionMigrationTool(id: "b", risk: .readOnly, serverID: "server")
    #expect(try catalog(old, tools: [a, b]).digest == catalog(old, tools: [b, a]).digest)
    #expect(try catalog(old, tools: [a]).digest != catalog(old, tools: [b]).digest)
  }

  @Test func derivedInheritancePreservesReceiptAndRejectsIndependentGrant() throws {
    let child = ComputerMCPCore.RegisteredProject(
      id: "derived", displayName: "Derived", rootPath: "/fixture/derived",
      createdAt: project.createdAt, updatedAt: project.updatedAt)
    let row = MCPDerivedProjectRegistration(
      origin: "plugin:fixture", receiptID: "receipt", sourceProjectID: project.id,
      sourceRoot: project.rootPath, receiptDigest: "digest", profileID: .chatGPTOperate,
      caller: .secureTunnel, project: child)
    let old = profile(["file.write"], projects: [project.id, child.id])
    let projects = PermissionMigrationProjects(registered: [project, child], derived: [row])
    let result = try PermissionProfileMigration.plan(
      profiles: [old], catalog: catalog(old), projects: projects)
    #expect(result.derived == [row])
    #expect(result.derived[0].principalID == nil)
    #expect(result.profiles[0].permissions.entries[.project(child.id)] == nil)
    #expect(result.profiles[0].permissions.state(for: .project(project.id)) == .granted(.write))
    var independent = old
    independent.id = .localAdmin
    #expect(
      throws: PermissionMigrationError.ownershipConflict(
        child.id, reason: "Receipt ownership, source grant, or independent derived grant conflicts."
      )
    ) {
      try PermissionProfileMigration.plan(
        profiles: [old, independent], catalog: catalog(old), projects: projects)
    }
  }

  @Test(arguments: [false, true])
  func historicalWorkspaceAndCurrentSchema(historical: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "migration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state.sqlite").path
    if historical {
      let queue = try DatabaseQueue(path: path)
      try GatewayDatabaseConnection.migrator.migrate(queue, upTo: "audit-error-details")
      try queue.write { database in
        try database.execute(
          sql:
            "INSERT INTO workspaces (id, displayName, rootPath, bookmarkIsStale, createdAt, updatedAt) VALUES ('project', 'Fixture', '/fixture/project', 0, ?, ?)",
          arguments: [project.createdAt, project.updatedAt])
        try database.execute(
          sql:
            "INSERT INTO profiles (id, capabilityIDsJSON, workspaceIDsJSON, allowedCallersJSON, fullShellEnabled, mode, authorizationRevision, updatedAt) VALUES ('chatgpt-operate', '[\"file.write\"]', '[\"project\"]', '[\"secure-tunnel\"]', 0, 'workspace-operations', 7, ?)",
          arguments: [project.updatedAt])
      }
      try queue.close()
    }
    let connection = try GatewayDatabaseConnection(path: path)
    let old = profile(["file.write"])
    if !historical {
      try connection.writer.write { database in
        try LegacyProfileRecord(old, updatedAt: project.updatedAt).insert(database)
        try ProjectRecord(project).insert(database)
      }
    }
    let store = PermissionMigrationStore(connection: connection, counter: MigrationCounter())
    let catalog = try catalog(old)
    let (plan, state) = try store.prepare(catalog: catalog)
    #expect(plan.profiles[0].permissions.state(for: .project("project")) == .granted(.write))
    try store.apply(plan, expectedState: state, currentCatalog: catalog)
    #expect(try store.profiles() == plan.profiles)
  }

  @Test func persistedInputChangeInvalidatesPlan() throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let old = profile(["file.read"])
    try connection.writer.write {
      try LegacyProfileRecord(old, updatedAt: project.updatedAt).insert($0)
      try ProjectRecord(project).insert($0)
    }
    let store = PermissionMigrationStore(connection: connection, counter: MigrationCounter())
    let catalog = try catalog(old)
    let (plan, state) = try store.prepare(catalog: catalog)
    try connection.writer.write {
      try $0.execute(sql: "UPDATE profiles SET authorizationRevision = 8")
    }
    #expect(throws: PermissionMigrationError.stateChanged) {
      try store.apply(plan, expectedState: state, currentCatalog: catalog)
    }
    #expect(try store.profiles().isEmpty)
  }

  @Test func transactionRollbackIdempotenceAndSnapshotChanges() throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let old = profile(["file.write"])
    try connection.writer.write {
      try LegacyProfileRecord(old, updatedAt: project.updatedAt).insert($0)
      try ProjectRecord(project).insert($0)
    }
    try connection.writer.write {
      try $0.execute(
        sql:
          "INSERT INTO clientControlTrust (id, principalID, profileID, caller, revision, profile, fullAccessAllowed, updatedAt) VALUES ('trust', 'client', 'chatgpt-operate', 'secure-tunnel', 7, ?, 1, ?)",
        arguments: ["historical-profile", project.updatedAt])
    }
    let counter = MigrationCounter()
    let store = PermissionMigrationStore(connection: connection, counter: counter)
    let catalog = try catalog(old)
    let (plan, state) = try store.prepare(catalog: catalog)
    #expect(try store.profiles().isEmpty)
    #expect(
      try connection.writer.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM clientControlTrust")
      } == 1)
    let changed = try PermissionMigrationCatalog(
      configurationDigest: "changed",
      availableBuiltinIDs: Set(PermissionMigrationCatalog.builtinV1.map(\.id)),
      serverIDs: ["server"], manifestProfiles: [old])
    #expect(throws: PermissionMigrationError.stateChanged) {
      try store.apply(plan, expectedState: state, currentCatalog: changed)
    }
    try connection.writer.write {
      try $0.execute(
        sql:
          "CREATE TRIGGER fail_migration BEFORE INSERT ON permissionMigration BEGIN SELECT RAISE(ABORT, 'injected'); END"
      )
    }
    #expect(throws: (any Error).self) {
      try store.apply(plan, expectedState: state, currentCatalog: catalog)
    }
    #expect(try store.profiles().isEmpty)
    #expect(
      try connection.writer.read {
        try String.fetchOne($0, sql: "SELECT profile FROM clientControlTrust WHERE id = 'trust'")
      } == "historical-profile")
    try connection.writer.write { try $0.execute(sql: "DROP TRIGGER fail_migration") }
    #expect(try store.apply(plan, expectedState: state, currentCatalog: catalog))
    let watermark = try counter.withExclusiveAccess { try $0.read() }
    #expect(try !store.apply(plan, expectedState: state, currentCatalog: catalog))
    #expect(try counter.withExclusiveAccess { try $0.read() } == watermark)
    #expect(try store.profiles() == plan.profiles)
    #expect(try store.isActivated())
    try connection.writer.write {
      try $0.execute(sql: "UPDATE profiles SET authorizationRevision = 999")
    }
    #expect(try !store.apply(plan, expectedState: state, currentCatalog: changed))
    #expect(
      try connection.writer.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM clientControlTrust")
      } == 0)
    #expect(
      try connection.writer.read {
        try LegacyProfileRecord.fetchOne($0, key: old.id.rawValue)?.authorizationRevision
      }
        == 999)
  }

  @Test func currentStandaloneManifestActivatesLegacyDatabaseWithoutChangingSourceBytes() throws {
    let database = try GatewayDatabase(inMemory: ())
    _ = database.permissionStore(counter: TestAuthorizationEpochCounter())
    let old = profile(["system.info"])
    try database.connection.writer.write {
      try LegacyProfileRecord(old, updatedAt: Date()).insert($0)
    }
    let manifest = try GatewayConfiguration(
      profiles: [.init(grant: .operate)], builtin: .init(enabled: ["system.info"])
    ).exportedTOML()
    let original = manifest
    let report = try database.activatePermissionMigration(
      manifest: manifest,
      baseURL: URL(fileURLWithPath: "/fixture"), applications: TestApplicationBundleLocator(),
      bundledPlugins: .init(packages: [], issues: []))
    #expect(report != nil)
    let converted = try #require(database.profiles().first)
    #expect(converted.permissions.state(for: .machineInformation) == .granted(.access))
    #expect(converted.permissions.state(for: .skills) == .notGranted)
    #expect(manifest == original)
    #expect(
      try database.activatePermissionMigration(
        manifest: manifest,
        baseURL: URL(fileURLWithPath: "/fixture"), applications: TestApplicationBundleLocator(),
        bundledPlugins: .init(packages: [], issues: [])) == nil)
  }

  @Test func productionActivationConvertsManifestFallbackAndPinsOriginalBytes() throws {
    let database = try GatewayDatabase(inMemory: ())
    _ = database.permissionStore(counter: TestAuthorizationEpochCounter())
    let manifest = """
      schema_version = 1
      [builtin]
      enabled = ["system.info", "file.write"]
      [[workspaces]]
      id = "project"
      path = "/fixture/project"
      [[profiles]]
      id = "chatgpt-operate"
      mode = "workspace-operations"
      capabilities = ["system.info", "file.write"]
      workspaces = ["project"]
      allowed_callers = ["secure-tunnel"]
      """
    let applications = TestApplicationBundleLocator()
    let bundled = BundledPlugins(packages: [], issues: [])
    let report = try database.activatePermissionMigration(
      manifest: manifest, baseURL: URL(fileURLWithPath: "/fixture"),
      applications: applications, bundledPlugins: bundled)
    #expect(report?.dropped.isEmpty == true)
    #expect(try database.projects().map(\.id) == ["project"])
    var profile = try #require(database.profiles().first)
    #expect(profile.permissions.state(for: .project("project")) == .granted(.write))
    #expect(profile.permissions.state(for: .machineInformation) == .granted(.access))
    #expect(profile.permissions.state(for: .skills) == .notGranted)
    let source = try #require(database.configurationState().profileSource)
    let convertedSource = try PermissionProfileManifest.encode(database.profiles())
    #expect(String(data: source, encoding: .utf8) == convertedSource)
    try database.validatePermissionMigrationManifest(manifest)
    try profile.permissions.set(.denied, for: .screen)
    try database.saveProfile(profile, expectedRevision: profile.authorizationRevision)
    let edited = try database.profiles()
    #expect(
      try database.activatePermissionMigration(
        manifest: manifest, baseURL: URL(fileURLWithPath: "/fixture"),
        applications: applications, bundledPlugins: bundled) == nil)
    #expect(try database.profiles() == edited)
    #expect(try database.configurationState().profileSource == source)
    #expect(throws: PermissionMigrationError.stateChanged) {
      try database.activatePermissionMigration(
        manifest: manifest + "\n# external edit\n", baseURL: URL(fileURLWithPath: "/fixture"),
        applications: applications, bundledPlugins: bundled)
    }
  }

  @Test func activationPublishesEpochAndRecoveryRequiresOwnerConfirmation() throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let old = profile(["system.info"])
    try connection.writer.write {
      try LegacyProfileRecord(old, updatedAt: project.updatedAt).insert($0)
    }
    let counter = MigrationCounter()
    let permissions = SQLitePermissionStore(connection: connection, counter: counter)
    let migration = PermissionMigrationStore(connection: connection, store: permissions)
    let catalog = try catalog(old)
    let (plan, state) = try migration.prepare(catalog: catalog)
    #expect(try migration.apply(plan, expectedState: state, currentCatalog: catalog))
    let initial = try permissions.readWithDatabase { database, ledger in
      #expect(ledger.suspendedAuthority == nil)
      #expect(ledger.pendingEpochRecovery == nil)
      return (
        try ProfileRecord.fetchOne(database, key: old.id.rawValue), ledger.authorizationEpochID
      )
    }
    #expect(initial.0?.authorityEpoch == initial.1?.uuidString)
    counter.forget()
    let recovered = try permissions.readWithDatabase { _, ledger in ledger }
    #expect(recovered.authorizationEpochID != initial.1)
    #expect(recovered.suspendedAuthority != nil)
    #expect(try !migration.apply(plan, expectedState: state, currentCatalog: catalog))
    let preservedEpoch = try connection.writer.read {
      try String.fetchOne($0, sql: "SELECT authorityEpoch FROM permissionProfiles")
    }
    #expect(preservedEpoch == initial.1?.uuidString)
  }

  @Test func requiredProjectMustResolveBeforeInferringPrivacy() throws {
    let old = profile(["project.open"], projects: ["missing"])
    let converted = try convert(old)
    #expect(converted.profiles[0].permissions.state(for: .desktopControl) == .notGranted)
    #expect(converted.report.dropped.contains { $0.grant == "missing" })
    let aliased = profile(["project.open"], projects: ["alias"])
    let resolved = try PermissionProfileMigration.plan(
      profiles: [aliased], catalog: catalog(aliased),
      projects: .init(registered: [project], aliases: ["alias": project.id]))
    #expect(resolved.profiles[0].permissions.state(for: .desktopControl) == .granted(.access))
  }

  @Test func revisionZeroCapabilityWildcardExpandsProjectAuthority() throws {
    var old = profile(projects: [])
    old.authorizationRevision = 0
    let defaults = profile(["*"])
    let converted = try PermissionProfileMigration.plan(
      profiles: [old], catalog: catalog(defaults), projects: .init(registered: [project]))
    #expect(converted.profiles[0].permissions.state(for: .project(project.id)) == .granted(.write))
    #expect(converted.profiles[0].permissions.state(for: .project("future")) == .notGranted)
    old.projectIDs = ["*"]
    let explicit = try PermissionProfileMigration.plan(
      profiles: [old], catalog: catalog(defaults), projects: .init(registered: [project]))
    #expect(explicit.profiles[0].permissions.state(for: .project("future")) == .granted(.write))
  }

  @Test func downstreamTransportDoesNotGrantProjectNetworkOrMaterializeWildcard() throws {
    let old = profile(["mcp.tools.call", "mcp.requests.cancel"])
    let tool = PermissionMigrationTool(
      id: "server.read", risk: .readOnly, projectRequirement: .optional, usesNetwork: true,
      serverID: "server")
    let converted = try convert(old, tools: [tool])
    #expect(converted.profiles[0].projectNetworks[project.id] == NetworkAccess.none)
    #expect(converted.profiles[0].permissions.entries[.mcpServer("server")] == nil)
    #expect(converted.report.dropped.isEmpty)
  }

  @Test func catalogCaptureSeparatesDirectPluginDisabledAndInvalidRegistrations() throws {
    let cli = IntegrationRegistration(kind: .cli, id: "command")
    let server = IntegrationRegistration(kind: .mcp, id: "server")
    let origin = PluginContributionOrigin(
      pluginID: "package", componentID: "component", version: try PluginVersion("1.0.0"),
      source: .init(
        kind: .development, root: URL(fileURLWithPath: "/fixture/package"), revision: "fixture"))
    let projected = CapabilityDescriptor(
      id: "cli.command.read", risk: .readOnly, requirement: .init(access: .none))
    let downstream = CapabilityDescriptor(
      id: "server.read", risk: .readOnly, requirement: .init(access: .none),
      projectRequirement: .optional, usesNetwork: true,
      mcpReference: .init(serverID: "server", toolName: "read"))
    let old = profile([projected.id, downstream.id], shell: true)
    func capture(
      _ enabled: Set<IntegrationRegistration>, plugin: Bool = false,
      registered: Set<IntegrationRegistration> = [cli, server]
    ) throws -> PermissionMigrationCatalog {
      try .capture(
        configurationDigest: "fixture", builtinIDs: [], downstream: [downstream],
        serverIDs: ["server"], registrations: registered, enabledRegistrations: enabled,
        origins: plugin ? [cli: origin, server: origin] : [:], manifestProfiles: [old],
        projectedCLI: [cli.id: [projected]])
    }
    let direct = try capture([cli, server])
    #expect(direct.tools.allSatisfy { $0.pluginID == nil })
    #expect(direct.tools.first { $0.id == projected.id }?.risk == .fullShell)
    let plugin = try capture([cli, server], plugin: true)
    #expect(plugin.tools.allSatisfy { $0.pluginID == "package" })
    let disabled = try capture([], plugin: true)
    #expect(disabled.tools.isEmpty)
    let explicitServer = profile(servers: ["server"])
    let keptServer = try PermissionProfileMigration.plan(
      profiles: [explicitServer], catalog: disabled, projects: .init(registered: [project]))
    #expect(keptServer.profiles[0].permissions.state(for: .mcpServer("server")) == .granted(.all))
    #expect(keptServer.report.dropped.isEmpty)
    #expect(keptServer.profiles[0].permissions.state(for: .plugin("package")) == .notGranted)
    let converted = try PermissionProfileMigration.plan(
      profiles: [old], catalog: disabled, projects: .init(registered: [project]))
    #expect(converted.profiles[0].permissions.state(for: .plugin("package")) == .notGranted)
    #expect(throws: PermissionMigrationError.invalidCatalog) {
      try capture([server], registered: [server])
    }
  }

  @Test func persistedDerivedReceiptUsesStoredPrecisionAndCanonicalRoot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "migration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("source")
    let alias = directory.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    var source = project
    source.rootPath = alias.path
    let date = Date(timeIntervalSince1970: 1_750_000_000.123456)
    let child = ComputerMCPCore.RegisteredProject(
      id: "derived", displayName: "Derived",
      rootPath: directory.appendingPathComponent("derived").path, createdAt: date, updatedAt: date)
    let row = MCPDerivedProjectRegistration(
      origin: "plugin:fixture", receiptID: "receipt", sourceProjectID: source.id,
      sourceRoot: root.resolvingSymlinksInPath().path, receiptDigest: "digest",
      profileID: .chatGPTOperate, principalID: "client", caller: .secureTunnel, project: child)
    let connection = try GatewayDatabaseConnection(inMemory: ())
    var old = profile(["file.write"])
    old.projectIDs.insert(child.id)
    try connection.writer.write { database in
      try ProjectRecord(source).insert(database)
      try ProjectRecord(child).insert(database)
      try LegacyProfileRecord(old, updatedAt: date).insert(database)
      try ProjectCanonicalRootRecord(
        canonicalRootPath: root.resolvingSymlinksInPath().path, projectID: source.id,
        createdAt: date
      ).insert(database)
      try ProjectCanonicalRootRecord(
        canonicalRootPath: "/fixture/previous-root", projectID: source.id, createdAt: date
      ).insert(database)
      try database.execute(
        sql:
          "INSERT INTO pluginDerivedProjects (projectID, origin, sourceProjectID, receiptID, payloadJSON) VALUES (?, ?, ?, ?, ?)",
        arguments: [
          child.id, row.origin, source.id, row.receiptID,
          String(decoding: try JSONEncoder().encode(row), as: UTF8.self),
        ])
    }
    let store = PermissionMigrationStore(connection: connection, counter: MigrationCounter())
    let catalog = try catalog(old)
    let (plan, state) = try store.prepare(catalog: catalog)
    #expect(plan.derived == [row])
    #expect(plan.profiles[0].permissions.entries[.project(child.id)] == nil)
    let controlRevision = try connection.writer.read {
      try Int.fetchOne($0, sql: "SELECT revision FROM permissionControlRevision WHERE id = 1")
    }
    try store.apply(plan, expectedState: state, currentCatalog: catalog)
    #expect(
      try connection.writer.read {
        try Int.fetchOne($0, sql: "SELECT revision FROM permissionControlRevision WHERE id = 1")
      } == controlRevision.map { $0 + 1 })
    let saved = try connection.writer.read {
      try Data.fetchOne($0, sql: "SELECT payload FROM permissionDerivedProjects")
    }
    #expect(
      try JSONDecoder().decode(MCPDerivedProjectRegistration.self, from: #require(saved)) == row)
    try connection.writer.write {
      try $0.execute(sql: "UPDATE projects SET displayName = 'Changed' WHERE id = 'derived'")
    }
    #expect(
      throws: PermissionMigrationError.ownershipConflict(
        child.id, reason: "Derived registration metadata changed.")
    ) { try store.prepare(catalog: catalog) }
  }

  @Test(arguments: ["alias", "plugin"])
  func persistedConfigurationChangeRejectsPreparedMigration(kind: String) throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let old = profile(["file.read"])
    try connection.writer.write {
      try LegacyProfileRecord(old, updatedAt: project.updatedAt).insert($0)
      try ProjectRecord(project).insert($0)
    }
    let store = PermissionMigrationStore(connection: connection, counter: MigrationCounter())
    let catalog = try catalog(old)
    let (plan, state) = try store.prepare(catalog: catalog)
    try connection.writer.write { database in
      if kind == "alias" {
        try ProjectAliasRecord(
          aliasProjectID: "alias", canonicalProjectID: project.id,
          canonicalRootPath: project.rootPath, migratedAt: project.updatedAt
        ).insert(database)
      } else {
        try database.execute(
          sql: "INSERT INTO pluginState (id, revision, payloadJSON) VALUES (1, 1, '{}')")
      }
    }
    #expect(throws: PermissionMigrationError.stateChanged) {
      try store.apply(plan, expectedState: state, currentCatalog: catalog)
    }
    #expect(try store.profiles().isEmpty)
  }
}

private final class MigrationCounter: AuthorizationEpochCounter, @unchecked Sendable {
  private let lock = NSLock()
  private let access = Access()
  func withExclusiveAccess<Result>(_ body: (any AuthorizationEpochCounterAccess) throws -> Result)
    throws -> Result
  {
    lock.lock()
    defer { lock.unlock() }
    return try body(access)
  }
  func forget() { lock.withLock { access.watermark = nil } }
  private final class Access: AuthorizationEpochCounterAccess {
    var watermark: AuthorizationEpochWatermark?
    func read() throws -> AuthorizationEpochWatermark? { watermark }
    func advance(to watermark: AuthorizationEpochWatermark) throws { self.watermark = watermark }
  }
}
