import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation
import GRDB
import Testing

@testable import ComputerMCPPersistence

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private let storeClient = Principal.client("store-test")
private let storeNow = Date(timeIntervalSince1970: 1_700_000_000)
private let storeCall = InvocationIdentity(
  principal: storeClient, tool: "fixture.run",
  projectID: nil, argumentsDigest: "arguments")
private func storeRequirements() throws -> InvocationRequirements {
  InvocationRequirements(actions: [
    PermissionAction(requirement: try PermissionRequirement(.screen, .access))
  ])
}
private enum StoreTestError: Error { case injected }

/// An isolated durable counter double shared by child processes. Production never
/// substitutes a file or an in-memory counter for the platform counter service.
private struct FileEpochCounter: AuthorizationEpochCounter {
  let directory: URL
  var failWrites = false
  var url: URL { directory.appendingPathComponent("watermark.json") }
  func withExclusiveAccess<Result>(_ body: (any AuthorizationEpochCounterAccess) throws -> Result)
    throws -> Result
  {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let lock: FileLock
    while true {
      do {
        lock = try FileLock(
          path: directory.appendingPathComponent("counter.lock").path, mode: .exclusive)
        break
      } catch FileLockError.held where ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.005)
      }
    }
    defer { lock.release() }
    return try body(Access(url: url, failWrites: failWrites))
  }
  private struct Access: AuthorizationEpochCounterAccess {
    let url: URL
    let failWrites: Bool
    func read() throws -> AuthorizationEpochWatermark? {
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try JSONDecoder().decode(AuthorizationEpochWatermark.self, from: Data(contentsOf: url))
    }
    func advance(to watermark: AuthorizationEpochWatermark) throws {
      if failWrites { throw StoreTestError.injected }
      guard watermark.revision > (try read()?.revision ?? 0) else {
        throw AuthorizationEpochCounterError.nonMonotonicWrite
      }
      try JSONEncoder().encode(watermark).write(to: url, options: .atomic)
    }
  }
}

private final class StoreFixture: @unchecked Sendable {
  let directory: URL
  var path: String { directory.appendingPathComponent("ledger.sqlite").path }
  var counter: FileEpochCounter { FileEpochCounter(directory: directory) }
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "permission-store-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  deinit { try? FileManager.default.removeItem(at: directory) }
  func connection() throws -> GatewayDatabaseConnection {
    try GatewayDatabaseConnection(path: path)
  }
  func sql<Result>(_ body: (Database) throws -> Result) throws -> Result {
    try connection().writer.write(body)
  }
  func open() throws -> SQLitePermissionStore {
    try SQLitePermissionStore(connection: connection(), counter: counter)
  }
  func activate() async throws -> SQLitePermissionStore {
    let store = try open()
    _ = try await store.read()
    try await store.transaction { ledger in
      let epoch = try #require(ledger.authorizationEpochID)
      try ledger.acknowledgeEpochRecovery(epoch)
      try ledger.confirmSuspendedAuthority(epochID: epoch, expectedRevision: ledger.revision)
    }
    return store
  }
  func pending(_ store: SQLitePermissionStore, answer: Bool = true) async throws -> UUID {
    try await store.transaction { ledger in
      guard
        case .requests(let requests) = try ledger.authorize(
          invocation: storeCall, requirements: storeRequirements(), now: storeNow),
        let request = requests.first
      else {
        throw PermissionModelError.invalidAuthorization
      }
      if answer { try ledger.answer(request.id, with: .onlyThisTime, now: storeNow) }
      return request.id
    }
  }
  func consume(_ store: SQLitePermissionStore, id: UUID) async throws -> Bool {
    try await consumeRetry(store, id: id)
  }
}

private func consumeRetry(_ store: SQLitePermissionStore, id: UUID) async throws -> Bool {
  try await store.transaction { ledger in
    do {
      guard
        case .allowed = try ledger.authorize(
          invocation: storeCall,
          requirements: storeRequirements(), retryIDs: [id], now: storeNow)
      else { return false }
      return true
    } catch PermissionModelError.requestConsumed { return false }
  }
}

@Suite(.timeLimit(.minutes(2)))
struct PermissionStoreTests {
  @Test func independentConnectionsConsumeExactlyOnceAndRejectStaleImport() async throws {
    let fixture = try StoreFixture()
    let setup = try await fixture.activate()
    let id = try await fixture.pending(setup)
    let stale = try await setup.read()
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let attempted = DispatchSemaphore(value: 0)
    let first = try SQLitePermissionStore(
      connection: fixture.connection(), counter: fixture.counter
    ) { stage in
      if stage == .beforeWrite {
        held.signal()
        guard release.wait(timeout: .now() + 30) == .success else { throw StoreTestError.injected }
      }
    }
    let second = try SQLitePermissionStore(
      connection: fixture.connection(), counter: fixture.counter
    ) { stage in
      if stage == .beforeLock { attempted.signal() }
    }
    defer { release.signal() }
    let a = Task { try await fixture.consume(first, id: id) }
    try await waitForSemaphore(held)
    let b = Task { try await fixture.consume(second, id: id) }
    try await waitForSemaphore(attempted)
    try await Task.sleep(for: .milliseconds(50))
    release.signal()
    let results = try await [a.value, b.value]
    #expect(results == [true, false])
    await #expect(throws: PermissionModelError.revisionConflict) {
      try await second.transaction { $0 = stale }
    }
    #expect(try await second.read().authorizations.count == 1)
  }

  @Test func retryRetirementCommitsWhenErrorIsReturnedAsValue() async throws {
    let fixture = try StoreFixture()
    let store = try await fixture.activate()
    let id = try await fixture.pending(store)
    let error = try await store.transaction { ledger -> PermissionModelError? in
      do {
        _ = try ledger.authorize(
          invocation: storeCall, requirements: storeRequirements(),
          retryIDs: [id], now: storeNow.addingTimeInterval(86_401))
        return nil
      } catch let error as PermissionModelError { return error }
    }
    #expect(error == .expiredRequest)
    #expect(try await fixture.open().read().requests[id]?.status == .revoked)
  }

  @Test(arguments: ["missing-counter", "missing-ledger", "behind", "ahead", "identity"])
  func counterMismatchSuspendsAndClearsTransientAuthority(kind: String) async throws {
    let fixture = try StoreFixture()
    let store = try await fixture.activate()
    let id = try await fixture.pending(store)
    let execution = try await store.transaction { ledger in
      guard
        case .allowed(let proof) = try ledger.authorize(
          invocation: storeCall,
          requirements: storeRequirements(), retryIDs: [id], now: storeNow)
      else {
        throw PermissionModelError.invalidAuthorization
      }
      _ = try ledger.setPermission(
        .granted(.access), for: .unifiedLogs,
        principal: storeClient, expectedRevision: ledger.revision)
      let consent = ledger.consent(for: storeClient, mode: .fullAccess(.standing))
      var environment = ledger.environment
      environment.modes[storeClient] = consent
      environment.limits[storeClient] = ManagedLimits(
        owner: .available(ManagedPolicy(network: .none)))
      try ledger.reconcile(
        environment: environment, expectedRevision: ledger.revision, now: storeNow)
      return try ledger.startExecution(
        owner: storeClient, authorizationIDs: [proof.id], now: storeNow)
    }
    let old = try await store.read()
    if kind == "missing-counter" {
      try FileManager.default.removeItem(at: fixture.counter.url)
    } else {
      try fixture.sql { database in
        switch kind {
        case "missing-ledger": try database.execute(sql: "DELETE FROM permissionLedger")
        case "behind":
          try database.execute(sql: "UPDATE permissionLedger SET counter = counter - 1")
        case "ahead": try database.execute(sql: "UPDATE permissionLedger SET counter = counter + 1")
        default:
          try database.execute(
            sql: "UPDATE permissionLedger SET databaseID = ?", arguments: [UUID().uuidString])
        }
      }
    }
    var recovered = try await fixture.open().read()
    #expect(recovered.authorizationEpochID != old.authorizationEpochID)
    #expect(recovered.suspendedAuthority != nil)
    #expect(
      recovered.requests.isEmpty && recovered.authorizations.isEmpty && recovered.executions.isEmpty
    )
    #expect(recovered.environment.modes.isEmpty && recovered.environment.connections.isEmpty)
    #expect(recovered.permissions(for: storeClient).state(for: .unifiedLogs) == .notGranted)
    #expect(
      recovered.executionAccess(
        execution.id, principal: storeClient,
        operation: .readResult, now: storeNow) == .denied(.authoritySuspended))
    #expect(
      try recovered.authorize(invocation: storeCall, requirements: .init(), now: storeNow)
        == .denied(.authoritySuspended))
    let epoch = try #require(recovered.authorizationEpochID)
    try await store.transaction { ledger in
      var environment = ledger.environment
      environment.limits = [:]
      try ledger.reconcile(
        environment: environment, expectedRevision: ledger.revision, now: storeNow)
      ledger.register(.client("new"))
      #expect(
        ledger.permissions(for: .client("new")).state(for: .machineInformation) == .notGranted)
      #expect(throws: PermissionModelError.authoritySuspended) {
        try ledger.setPermission(
          .granted(.access), for: .screen,
          principal: storeClient, expectedRevision: ledger.revision)
      }
      #expect(
        try ledger.authorize(invocation: storeCall, requirements: .init(), now: storeNow)
          == .denied(.authoritySuspended))
      try ledger.confirmSuspendedAuthority(epochID: epoch, expectedRevision: ledger.revision)
      #expect(
        try ledger.authorize(invocation: storeCall, requirements: .init(), now: storeNow)
          == .denied(.authoritySuspended))
      try ledger.acknowledgeEpochRecovery(epoch)
    }
    let confirmed = try await store.read()
    #expect(confirmed.suspendedAuthority == nil && confirmed.pendingEpochRecovery == nil)
    #expect(confirmed.authorizations.isEmpty && confirmed.executions.isEmpty)
    #expect(
      confirmed.permissions(for: storeClient).state(for: .unifiedLogs)
        == (kind == "missing-ledger" ? .notGranted : .granted(.access)))
    if kind != "missing-ledger" {
      #expect(confirmed.suspendedAuthority == nil)
      #expect(confirmed.environment.limits[storeClient]?.sources[.owner] != .absent)
      #expect(recovered.pendingEpochRecovery?.executionsToTerminate == [execution.id])
    }
  }

  @Test func failedBodyRollsBackItsSQLButCommitsEpochRecovery() async throws {
    let fixture = try StoreFixture()
    let store = try await fixture.activate()
    _ = try await fixture.pending(store)
    try FileManager.default.removeItem(at: fixture.counter.url)
    #expect(throws: StoreTestError.self) {
      try store.transactionWithDatabase { database, ledger in
        try database.execute(
          sql: "INSERT INTO runtimeSettings VALUES ('partial', 'value', 'today')")
        ledger.register(.client("partial"))
        throw StoreTestError.injected
      }
    }
    let recovered = try await store.read()
    #expect(recovered.suspendedAuthority != nil && recovered.requests.isEmpty)
    #expect(
      try fixture.sql {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM runtimeSettings WHERE key = 'partial'")
      } == 0)
  }

  @Test func failedCounterAndDiskWritesNeverCommitCandidate() async throws {
    let fixture = try StoreFixture()
    let store = try await fixture.activate()
    let before = try await store.read()
    let failing = try SQLitePermissionStore(
      connection: fixture.connection(),
      counter: FileEpochCounter(directory: fixture.directory, failWrites: true))
    await #expect(throws: StoreTestError.self) {
      try await failing.transaction { ledger in
        try ledger.setPermission(
          .granted(.access), for: .screen,
          principal: storeClient, expectedRevision: ledger.revision)
      }
    }
    #expect(try await store.read().revision == before.revision)
    try fixture.sql {
      try $0.execute(
        sql:
          "CREATE TRIGGER failLedger BEFORE UPDATE ON permissionLedger BEGIN SELECT RAISE(ABORT, 'disk failure'); END"
      )
    }
    await #expect(throws: DatabaseError.self) {
      try await store.transaction { $0.register(storeClient) }
    }
    try fixture.sql { try $0.execute(sql: "DROP TRIGGER failLedger") }
    #expect(try await store.read().authorizationEpochID == before.authorizationEpochID)
    let interrupted = try SQLitePermissionStore(
      connection: fixture.connection(), counter: fixture.counter
    ) { stage in
      if stage == .afterCounterAdvance { throw StoreTestError.injected }
    }
    await #expect(throws: StoreTestError.self) {
      try await interrupted.transaction { $0.register(storeClient) }
    }
    let recovered = try await store.read()
    #expect(recovered.authorizationEpochID != before.authorizationEpochID)
    #expect(recovered.suspendedAuthority != nil)
    #expect(recovered.permissions(for: storeClient).state(for: .screen) == .notGranted)
  }

  @Test(arguments: ["codec", "json", "references", "row-shape"])
  func corruptCurrentStateHasNoFallback(kind: String) async throws {
    let fixture = try StoreFixture()
    let store = try await fixture.activate()
    let id = try await fixture.pending(store)
    _ = try await fixture.consume(store, id: id)
    try fixture.sql { database in
      if kind == "codec" {
        try database.execute(sql: "UPDATE permissionLedger SET codecVersion = 999")
      } else if kind == "row-shape" {
        try database.execute(sql: "UPDATE permissionLedger SET counter = 'invalid'")
      } else if kind == "json" {
        try database.execute(sql: "UPDATE permissionLedger SET payload = X'00'")
      } else {
        let data = try #require(
          try Data.fetchOne(database, sql: "SELECT payload FROM permissionLedger"))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["authorizations"] = []
        try database.execute(
          sql: "UPDATE permissionLedger SET payload = ?",
          arguments: [try JSONSerialization.data(withJSONObject: object)])
      }
    }
    await #expect(throws: PermissionPersistenceError.self) { try await fixture.open().read() }
  }

  @Test func unavailableCounterNeverFallsBack() async throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let store = SQLitePermissionStore(
      connection: connection, counter: UnavailableAuthorizationEpochCounter())
    await #expect(throws: AuthorizationEpochCounterError.unavailable) { try await store.read() }
    #expect(
      try await connection.writer.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM permissionLedger")
      } == 0)
  }

  @Test func twoProcessesRaceOneRetry() async throws {
    let fixture = try StoreFixture()
    let store = try await fixture.activate()
    let id = try await fixture.pending(store)
    let first = try child(fixture, mode: "held-retry", requestID: id, name: "first")
    defer { if first.isRunning { first.terminate() } }
    try await waitForFiles(fixture, names: ["first.held"])
    let second = try child(fixture, mode: "following-retry", requestID: id, name: "second")
    defer {
      if first.isRunning { first.terminate() }
      if second.isRunning { second.terminate() }
    }
    try await waitForFiles(fixture, names: ["second.attempted"])
    try await Task.sleep(for: .milliseconds(50))
    #expect(second.isRunning)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.directory.appendingPathComponent("second.result").path))
    try Data().write(to: fixture.directory.appendingPathComponent("release"))
    try await waitForProcesses([first, second])
    #expect(first.terminationStatus == 0 && second.terminationStatus == 0)
    let results = try ["first", "second"].map {
      try String(
        contentsOf: fixture.directory.appendingPathComponent($0 + ".result"), encoding: .utf8)
    }
    #expect(results == ["true", "false"])
    #expect(try await store.read().authorizations.count == 1)
  }

  @Test(arguments: ["beforeWrite", "afterCounterAdvance", "beforeCommit", "afterCommit"])
  func processCrashBoundariesPreserveConsumptionOrSuspend(stage: String) async throws {
    let fixture = try StoreFixture()
    let store = try await fixture.activate()
    let id = try await fixture.pending(store)
    let originalEpoch = try await store.read().authorizationEpochID
    let process = try child(fixture, mode: stage, requestID: id, name: "crash")
    defer { if process.isRunning { process.terminate() } }
    try await waitForProcesses([process])
    #expect(process.terminationStatus == 71)
    let ledger = try await fixture.open().read()
    if stage == "beforeWrite" {
      #expect(ledger.authorizationEpochID == originalEpoch)
      #expect(try await fixture.consume(store, id: id))
    } else if stage == "afterCommit" {
      #expect(ledger.authorizationEpochID == originalEpoch)
      #expect(!(try await fixture.consume(store, id: id)))
    } else {
      #expect(ledger.authorizationEpochID != originalEpoch)
      #expect(ledger.suspendedAuthority != nil && ledger.requests.isEmpty)
    }
  }

  @Test func permissionStoreChildProcess() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["PERMISSION_STORE_CHILD_DIRECTORY"],
      let mode = environment["PERMISSION_STORE_CHILD_MODE"],
      let name = environment["PERMISSION_STORE_CHILD_NAME"],
      let id = environment["PERMISSION_STORE_CHILD_REQUEST"].flatMap(UUID.init(uuidString:))
    else { return }
    let root = URL(fileURLWithPath: directory)
    let connection = try GatewayDatabaseConnection(
      path: root.appendingPathComponent("ledger.sqlite").path)
    let counter = FileEpochCounter(directory: root)
    let store = SQLitePermissionStore(connection: connection, counter: counter) { stage in
      if String(describing: stage) == mode { _exit(71) }
      if mode == "held-retry", stage == .beforeWrite {
        try Data().write(to: root.appendingPathComponent(name + ".held"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("release").path) {
          guard ContinuousClock.now < deadline else { throw StoreTestError.injected }
          Thread.sleep(forTimeInterval: 0.005)
        }
      }
      if mode == "following-retry", stage == .beforeLock {
        try Data().write(to: root.appendingPathComponent(name + ".attempted"))
      }
    }
    if ["retry", "recover", "confirm"].contains(mode) {
      try Data().write(to: root.appendingPathComponent(name + ".ready"))
      let deadline = Date().addingTimeInterval(30)
      while !FileManager.default.fileExists(atPath: root.appendingPathComponent("go").path) {
        guard Date() < deadline else { throw StoreTestError.injected }
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    let result: Bool
    if mode == "recover" {
      result = try await store.read().suspendedAuthority != nil
    } else if mode == "confirm" {
      let epoch = try #require(
        environment["PERMISSION_STORE_CHILD_EPOCH"].flatMap(UUID.init(uuidString:)))
      let revision = try #require(
        environment["PERMISSION_STORE_CHILD_REVISION"].flatMap(UInt64.init))
      result = try await store.transaction { ledger in
        do {
          try ledger.confirmSuspendedAuthority(epochID: epoch, expectedRevision: revision)
          return true
        } catch PermissionModelError.revisionConflict { return false }
      }
    } else {
      result = try await consumeRetry(store, id: id)
    }
    try Data(String(result).utf8).write(to: root.appendingPathComponent(name + ".result"))
  }

  private func child(
    _ fixture: StoreFixture, mode: String, requestID: UUID, name: String, epochID: UUID? = nil,
    revision: UInt64? = nil
  ) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var arguments = [
      "--testing-library", "swift-testing", "--filter", "permissionStoreChildProcess",
    ]
    if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
      CommandLine.arguments.indices.contains(index + 1)
    {
      let bundle = CommandLine.arguments[index + 1]
      arguments = ["--test-bundle-path", bundle, bundle] + arguments
    }
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["PERMISSION_STORE_CHILD_DIRECTORY"] = fixture.directory.path
    environment["PERMISSION_STORE_CHILD_MODE"] = mode
    environment["PERMISSION_STORE_CHILD_NAME"] = name
    environment["PERMISSION_STORE_CHILD_REQUEST"] = requestID.uuidString
    environment["PERMISSION_STORE_CHILD_EPOCH"] = epochID?.uuidString
    environment["PERMISSION_STORE_CHILD_REVISION"] = revision.map(String.init)
    process.environment = environment
    let log = fixture.directory.appendingPathComponent(name + ".log")
    try Data().write(to: log)
    let output = try FileHandle(forWritingTo: log)
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try output.close()
    return process
  }

  private func waitForSemaphore(_ semaphore: DispatchSemaphore) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !pollSignal(semaphore) {
      guard ContinuousClock.now < deadline else { throw StoreTestError.injected }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func waitForFiles(_ fixture: StoreFixture, names: [String]) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !names.allSatisfy({
      FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent($0).path)
    }) {
      guard Date() < deadline else { throw StoreTestError.injected }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func waitForProcesses(_ processes: [Process]) async throws {
    let deadline = Date().addingTimeInterval(30)
    while processes.contains(where: \.isRunning) {
      guard Date() < deadline else { throw StoreTestError.injected }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

extension PermissionStoreTests {
  @Test func competingAnswersAndRevokeSerializeWithoutLostUpdates() async throws {
    let fixture = try StoreFixture()
    let a = try await fixture.activate()
    let b = try fixture.open()
    let id = try await fixture.pending(a, answer: false)
    func answer(_ store: SQLitePermissionStore) async throws -> Bool {
      try await store.transaction { ledger in
        do {
          try ledger.answer(id, with: .always, now: storeNow)
          return true
        } catch is PermissionModelError { return false }
      }
    }
    async let first = answer(a)
    async let second = answer(b)
    #expect(try await [first, second].filter { $0 }.count == 1)
    let next = try await a.transaction { ledger -> UUID in
      _ = try ledger.setPermission(
        .notGranted, for: .screen,
        principal: storeClient, expectedRevision: ledger.revision)
      guard
        case .requests(let requests) = try ledger.authorize(
          invocation: storeCall,
          requirements: storeRequirements(), now: storeNow), let request = requests.first
      else {
        throw PermissionModelError.invalidAuthorization
      }
      return request.id
    }
    async let grant: Void = a.transaction { ledger in
      do { try ledger.answer(next, with: .always, now: storeNow) } catch is PermissionModelError {}
    }
    async let revoke: Void = b.transaction { ledger in
      _ = try ledger.revoke(
        principal: storeClient, permission: .screen, expectedRevision: ledger.revision)
    }
    _ = try await (grant, revoke)
    #expect(try await a.read().permissions(for: storeClient).state(for: .screen) == .denied)
  }

  @Test func acknowledgementCannotLoseAnotherWritersTermination() async throws {
    let fixture = try StoreFixture()
    let a = try await fixture.activate()
    let b = try fixture.open()
    let ids = try await a.transaction { ledger -> [UUID] in
      try [.screen, .unifiedLogs].map { (permission: Permission) in
        try ledger.setPermission(
          .granted(.access), for: permission,
          principal: storeClient, expectedRevision: ledger.revision)
        guard
          case .allowed(let proof) = try ledger.authorize(
            invocation: storeCall,
            actions: [
              PermissionAction(requirement: try PermissionRequirement(permission, .access))
            ], now: storeNow)
        else {
          throw PermissionModelError.invalidAuthorization
        }
        return try ledger.startExecution(
          owner: storeClient, authorizationIDs: [proof.id], now: storeNow
        ).id
      }
    }
    try await a.transaction { ledger in
      _ = try ledger.revoke(
        principal: storeClient, permission: .screen, expectedRevision: ledger.revision)
    }
    async let ack: Void = a.transaction { $0.acknowledgeExecutionTerminations([ids[0]]) }
    async let revoke: Void = b.transaction { ledger in
      _ = try ledger.revoke(
        principal: storeClient, permission: .unifiedLogs, expectedRevision: ledger.revision)
    }
    _ = try await (ack, revoke)
    #expect(try await a.read().pendingExecutionTerminations == [ids[1]])
  }

  @Test func projectRegistrationAndSQLRowsShareOneCommitAcrossConnections() async throws {
    let fixture = try StoreFixture()
    let a = try await fixture.activate()
    let b = try fixture.open()
    let project = RegisteredProject(id: "new", root: try CanonicalPath("/projects/new"))
    let id = try await a.transaction { ledger -> UUID in
      var environment = ledger.environment
      environment.paths = try PathEnvironmentSnapshot(rules: [
        PathRule(root: CanonicalPath("/projects"), kind: .developer)
      ])
      try ledger.reconcile(
        environment: environment, expectedRevision: ledger.revision, now: storeNow)
      let content = try ProjectRegistrationRequest(
        principal: storeClient, projectID: project.id,
        path: project.root, access: .read)
      guard
        case .request(let request) = try ledger.requestProjectRegistration(
          content,
          invocation: storeCall, now: storeNow)
      else { throw PermissionModelError.invalidAuthorization }
      return request.id
    }
    func register(_ store: SQLitePermissionStore) throws -> Bool {
      do {
        return try store.transactionWithDatabase { database, ledger in
          try ledger.answerProjectRegistration(id, registeredProject: project, now: storeNow)
          try database.execute(
            sql: "INSERT INTO projects VALUES (?, ?, ?, NULL, 0, 'today', 'today')",
            arguments: [project.id, project.id, project.root.string])
          var environment = ledger.environment
          try environment.paths?.setProjects([project])
          try ledger.reconcile(
            environment: environment, expectedRevision: ledger.revision, now: storeNow)
          return true
        }
      } catch PermissionModelError.alreadyAnswered { return false }
    }
    let first = Task.detached { try register(a) }
    let second = Task.detached { try register(b) }
    #expect(try await [first.value, second.value].filter { $0 }.count == 1)
    let ledger = try await a.read()
    #expect(ledger.requests[id]?.status == .registered("new"))
    #expect(ledger.permissions(for: storeClient).state(for: .project("new")) == .granted(.read))
    #expect(
      try fixture.sql {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM projects WHERE id = 'new'")
      } == 1)
  }

  @Test func counterLockCoversActualCommitAndBusyErrorsDoNotFallback() async throws {
    let fixture = try StoreFixture()
    _ = try await fixture.activate()
    let store = try SQLitePermissionStore(
      connection: fixture.connection(), counter: fixture.counter
    ) { stage in
      if stage == .beforeCommit || stage == .afterCommit {
        #expect(throws: FileLockError.self) {
          try FileLock(
            path: fixture.directory.appendingPathComponent("counter.lock").path, mode: .exclusive)
        }
      }
    }
    try await store.transaction { $0.register(storeClient) }
    try fixture.counter.withExclusiveAccess { _ in () }
    let connection = try fixture.connection()
    let contender = try fixture.open()
    try await connection.writer.writeWithoutTransaction { database in
      try database.execute(sql: "BEGIN IMMEDIATE")
      defer { try? database.execute(sql: "ROLLBACK") }
      #expect(throws: DatabaseError.self) { try contender.transactionWithDatabase { _, _ in () } }
    }
    #expect(try await store.read().suspendedAuthority == nil)
  }
}

extension PermissionStoreTests {
  @Test func lateNeedChainAndConsumedAnswersSurviveIndependentReopening() async throws {
    let fixture = try StoreFixture()
    let store = try await fixture.activate()
    let requirements = InvocationRequirements(
      actions: try storeRequirements().actions,
      sandboxProjectID: "project", execution: .background)
    let next = try await store.transaction { ledger -> UUID in
      guard
        case .requests(let pending) = try ledger.authorize(
          invocation: storeCall,
          requirements: requirements, now: storeNow), let request = pending.first
      else {
        throw PermissionModelError.invalidAuthorization
      }
      try ledger.answer(request.id, with: .onlyThisTime, now: storeNow)
      guard
        case .allowed(let proof) = try ledger.authorize(
          invocation: storeCall,
          requirements: requirements, retryIDs: [request.id], now: storeNow)
      else {
        throw PermissionModelError.invalidAuthorization
      }
      let execution = try ledger.startExecution(
        owner: storeClient, authorizationIDs: [proof.id], now: storeNow)
      guard
        case .requests(let discovered) = try ledger.recordDiscoveredNeeds(
          executionID: execution.id,
          principal: storeClient,
          needs: [
            .network(.init(host: "new.example", projectID: "project", isLocalNetwork: false))
          ],
          now: storeNow), let next = discovered.first
      else { throw PermissionModelError.invalidAuthorization }
      try ledger.answer(next.id, with: .onlyThisTime, now: storeNow)
      return next.id
    }
    try await fixture.open().transaction { ledger in
      guard
        case .allowed(let proof) = try ledger.authorize(
          invocation: storeCall,
          requirements: requirements, retryIDs: [next], now: storeNow)
      else {
        throw PermissionModelError.invalidAuthorization
      }
      #expect(proof.requirements.networks.count == 1 && proof.requestIDs.count == 2)
      _ = try ledger.startExecution(owner: storeClient, authorizationIDs: [proof.id], now: storeNow)
    }
    #expect(try await store.read().executions.count == 2)
  }
}

extension PermissionStoreTests {
  @Test func recoveryAndStaleConfirmationRaceAcrossProcesses() async throws {
    let fixture = try StoreFixture()
    let store = try await fixture.activate()
    try FileManager.default.removeItem(at: fixture.counter.url)
    let displayed = try await store.read()
    try FileManager.default.removeItem(at: fixture.counter.url)
    let recover = try child(fixture, mode: "recover", requestID: UUID(), name: "recover")
    let confirm = try child(
      fixture, mode: "confirm", requestID: UUID(), name: "confirm",
      epochID: displayed.authorizationEpochID, revision: displayed.revision)
    defer {
      if recover.isRunning { recover.terminate() }
      if confirm.isRunning { confirm.terminate() }
    }
    try await waitForFiles(fixture, names: ["recover.ready", "confirm.ready"])
    try Data().write(to: fixture.directory.appendingPathComponent("go"))
    try await waitForProcesses([recover, confirm])
    #expect(recover.terminationStatus == 0 && confirm.terminationStatus == 0)
    #expect(
      try String(
        contentsOf: fixture.directory.appendingPathComponent("confirm.result"), encoding: .utf8)
        == "false")
    let current = try await store.read()
    #expect(current.authorizationEpochID != displayed.authorizationEpochID)
    #expect(current.suspendedAuthority != nil && current.pendingEpochRecovery != nil)
  }
}

extension PermissionStoreTests {
  @Test func versionOneFixtureRetainsConsumedAuthorityAndLateRetryProvenance() async throws {
    let fixture = try StoreFixture()
    let url = try #require(
      Bundle.module.url(
        forResource: "permission-ledger-v1", withExtension: "json", subdirectory: "Fixtures"))
    let payload = try Data(contentsOf: url)
    let decoded = try JSONDecoder().decode(PermissionLedger.self, from: payload)
    let epoch = try #require(decoded.authorizationEpochID)
    let databaseID = UUID()
    try fixture.sql { database in
      try database.execute(
        sql: "INSERT INTO permissionLedger VALUES (1, 1, ?, ?, 1, ?)",
        arguments: [databaseID.uuidString, epoch.uuidString, payload])
    }
    try fixture.counter.withExclusiveAccess {
      try $0.advance(to: .init(databaseID: databaseID, revision: 1))
    }
    let store = try fixture.open()
    let ledger = try await store.read()
    #expect(
      ledger.executions.count == 1 && ledger.authorizations.count == 1 && ledger.requests.count == 4
    )
    let next = try #require(
      ledger.requests.values.first {
        if case .network = $0.content { return true }
        return false
      })
    let original = try #require(ledger.authorizations.values.first)
    #expect(ledger.requests.values.contains { $0.status == .consumed(original.id) })
    try await store.transaction { current in
      guard
        case .allowed(let retried) = try current.authorize(
          invocation: original.invocation,
          requirements: original.requirements, retryIDs: [next.id], now: storeNow)
      else {
        throw PermissionModelError.invalidAuthorization
      }
      #expect(retried.requestIDs.count == 2)
      #expect(retried.requirements.networks.first?.host == "api.example.test")
    }
  }

  @Test func ownerCanNarrowConfirmedSnapshotInTheSameCommit() async throws {
    let fixture = try StoreFixture()
    let store = try await fixture.activate()
    try await store.transaction { ledger in
      _ = try ledger.setPermission(
        .granted(.access), for: .screen,
        principal: storeClient, expectedRevision: ledger.revision)
    }
    try FileManager.default.removeItem(at: fixture.counter.url)
    let displayed = try await store.read()
    let epoch = try #require(displayed.authorizationEpochID)
    try await store.transaction { ledger in
      try ledger.confirmSuspendedAuthority(epochID: epoch, expectedRevision: displayed.revision)
      // The runtime handoff still blocks admission, but owner edits can narrow
      // the reviewed snapshot before it becomes visible in the durable store.
      try ledger.setPermission(
        .denied, for: .screen,
        principal: storeClient, expectedRevision: ledger.revision)
      #expect(
        try ledger.authorize(invocation: storeCall, requirements: .init(), now: storeNow)
          == .denied(.authoritySuspended))
      try ledger.acknowledgeEpochRecovery(epoch)
    }
    try await fixture.open().transaction { ledger in
      let decision = try ledger.authorize(
        invocation: storeCall, requirements: storeRequirements(), now: storeNow)
      #expect(decision == .denied(.permissionDenied(.screen)))
    }
  }
}

private func pollSignal(_ semaphore: DispatchSemaphore) -> Bool {
  semaphore.wait(timeout: .now()) == .success
}
