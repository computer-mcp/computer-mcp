import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct MCPProcessOwnershipTests {
  @Test(arguments: [false, true])
  func recoveryRequiresHostCleanupConfirmationAndReviewedReceipt(hostConfirmed: Bool) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    let owner = try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    let live = try #require(
      try MCPProcessOwnership.inspect(root: storage, workspace: root, registration: "mcp").first)
    #expect(live.state == "running" && !live.recoverable && !live.blocksLaunch)
    try owner.finish(confirmed: false, hostServicesConfirmed: hostConfirmed)
    let status = try #require(
      try MCPProcessOwnership.inspect(root: storage, workspace: root, registration: "mcp").first)
    #expect(status.recoverable == hostConfirmed && status.blocksLaunch)
    #expect(status.state == (hostConfirmed ? "cleanup_failed" : "host_cleanup_unconfirmed"))
    #expect(throws: GatewayToolError.self) {
      try MCPProcessOwnership.recover(
        root: storage, workspace: root, registration: "mcp", id: status.id,
        expectedDigest: live.digest)
    }
    if hostConfirmed {
      try MCPProcessOwnership.recover(
        root: storage, workspace: root, registration: "mcp", id: status.id,
        expectedDigest: status.digest)
      #expect(try receipts(storage).isEmpty)
      let next = try MCPProcessOwnership.acquire(
        root: storage, workspace: root, registration: "mcp")
      try next.finish(confirmed: true)
    } else {
      #expect(throws: GatewayToolError.self) {
        try MCPProcessOwnership.recover(
          root: storage, workspace: root, registration: "mcp", id: status.id,
          expectedDigest: status.digest)
      }
      #expect(try receipts(storage).count == 1)
    }
  }

  @Test
  func recoveryCannotClearAnInheritedLockOrAnotherScope() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    let owner = try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    let inherited = try fcntl(owner.supervisorHandle().fileDescriptor, F_DUPFD_CLOEXEC, 10)
    try #require(inherited >= 0)
    let handle = FileHandle(fileDescriptor: inherited, closeOnDealloc: true)
    try owner.finish(confirmed: false, hostServicesConfirmed: true)
    let locked = try #require(
      try MCPProcessOwnership.inspect(root: storage, workspace: root, registration: "mcp").first)
    #expect(!locked.recoverable)
    #expect(throws: GatewayToolError.self) {
      try MCPProcessOwnership.recover(
        root: storage, workspace: root, registration: "mcp", id: locked.id,
        expectedDigest: locked.digest)
    }
    try handle.close()
    var ready = try #require(
      try MCPProcessOwnership.inspect(root: storage, workspace: root, registration: "mcp").first)
    let deadline = ContinuousClock.now + .seconds(1)
    while !ready.recoverable, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
      ready = try #require(
        try MCPProcessOwnership.inspect(root: storage, workspace: root, registration: "mcp").first)
    }
    try #require(ready.recoverable)
    #expect(throws: GatewayToolError.self) {
      try MCPProcessOwnership.recover(
        root: storage, workspace: root, registration: "other", id: ready.id,
        expectedDigest: ready.digest)
    }
    try MCPProcessOwnership.recover(
      root: storage, workspace: root, registration: "mcp", id: ready.id,
      expectedDigest: ready.digest)
  }

  @Test(arguments: [
    "partial", #"{"owner":{"pid":1,"seconds":0,"microseconds":0},"cleanupFailed":true}"#,
  ])
  func damagedAndUnspecifiedHostCleanupRemainBlocked(contents: String) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    let owner = try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    try owner.finish(confirmed: false)
    let file = try #require(try receipts(storage).first)
    try Data(contents.utf8).write(to: file)
    let status = try #require(
      try MCPProcessOwnership.inspect(root: storage, workspace: root, registration: "mcp").first)
    #expect(status.blocksLaunch && !status.recoverable)
    #expect(throws: GatewayToolError.self) {
      try MCPProcessOwnership.recover(
        root: storage, workspace: root, registration: "mcp", id: status.id,
        expectedDigest: status.digest)
    }
    #expect(try Data(contentsOf: file) == Data(contents.utf8))
  }

  @Test(arguments: [2, 8, 16, 32])
  func simultaneousLiveClientsShareScopeWithoutBecomingSingleInstance(clientCount: Int) async throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    let executor = BlockingOperationExecutor(label: "ownership-concurrency-test", serial: false)
    let owners = try await withThrowingTaskGroup(of: MCPProcessOwnership.self) { group in
      for _ in 0..<clientCount {
        group.addTask {
          try await executor.perform {
            try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
          }
        }
      }
      var owners: [MCPProcessOwnership] = []
      for try await owner in group { owners.append(owner) }
      return owners
    }
    #expect(try receipts(storage).count == clientCount)
    try await withThrowingTaskGroup(of: Void.self) { group in
      for owner in owners {
        group.addTask { try await executor.perform { try owner.finish(confirmed: true) } }
      }
      try await group.waitForAll()
    }
    #expect(try receipts(storage).isEmpty)
  }

  @Test
  func liveSessionsRemainIndependentAndConfirmedExitRemovesItsOwnReceipt() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    let first = try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    let second = try MCPProcessOwnership.acquire(
      root: storage, workspace: root, registration: "mcp")
    #expect(try receipts(storage).count == 2)
    try first.finish(confirmed: true)
    #expect(try receipts(storage).count == 1)
    try second.finish(confirmed: true)
    #expect(try receipts(storage).isEmpty)
  }

  @Test
  func failedCleanupPersistsAcrossNewStoreInstancesAndDoesNotBlockOtherScopes() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    let first = try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    try first.finish(confirmed: false)
    #expect(throws: GatewayToolError.self) {
      try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    }
    let otherRegistration = try MCPProcessOwnership.acquire(
      root: storage, workspace: root, registration: "other")
    let otherWorkspace = try MCPProcessOwnership.acquire(
      root: storage, workspace: root.appendingPathComponent("other"), registration: "mcp")
    try otherRegistration.finish(confirmed: true)
    try otherWorkspace.finish(confirmed: true)
    #expect(try receipts(storage).count == 1)
  }

  @Test
  func abandonedLaunchWithoutInheritedLockIsReconciled() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    do {
      let first = try MCPProcessOwnership.acquire(
        root: storage, workspace: root, registration: "mcp")
      #expect(try first.supervisorHandle().fileDescriptor >= 0)
    }
    #expect(try receipts(storage).count == 1)
    let next = try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    #expect(try receipts(storage).count == 1)
    try next.finish(confirmed: true)
  }

  @Test
  func aReportedExitCannotDiscardAnInheritedProcessLock() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    let first = try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    let descriptor = try first.supervisorHandle().fileDescriptor
    let inherited = fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
    try #require(inherited >= 0)
    defer { Darwin.close(inherited) }
    #expect(throws: GatewayToolError.self) { try first.finish(confirmed: true) }
    #expect(try receipts(storage).count == 1)
    #expect(throws: GatewayToolError.self) {
      try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    }
  }

  @Test
  func reusedOwnerProcessIDDoesNotAuthorizeAnOrphanedLock() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    let first = try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    let receipt = try #require(try receipts(storage).first)
    let staleIdentity: [String: Any] = [
      "owner": ["pid": getpid(), "seconds": 0, "microseconds": 0], "cleanupFailed": false,
    ]
    try JSONSerialization.data(withJSONObject: staleIdentity).write(to: receipt)
    #expect(throws: GatewayToolError.self) {
      try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    }
    try first.finish(confirmed: true)
  }

  @Test
  func corruptReceiptCannotEraseUnknownCleanupState() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    do {
      let first = try MCPProcessOwnership.acquire(
        root: storage, workspace: root, registration: "mcp")
      try first.finish(confirmed: false)
    }
    let receipt = try #require(try receipts(storage).first)
    try Data("partial".utf8).write(to: receipt)
    #expect(throws: (any Error).self) {
      try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    }
    #expect(try Data(contentsOf: receipt) == Data("partial".utf8))
  }

  @Test
  func linkedStorageCannotAdoptOutsideFiles() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let sentinel = outside.appendingPathComponent("sentinel")
    try Data("user content".utf8).write(to: sentinel)
    let storage = root.appendingPathComponent("ownership")
    try FileManager.default.createSymbolicLink(at: storage, withDestinationURL: outside)
    #expect(throws: GatewayToolError.self) {
      try MCPProcessOwnership.acquire(root: storage, workspace: root, registration: "mcp")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["sentinel"])
    #expect(try Data(contentsOf: sentinel) == Data("user content".utf8))
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }

  private func receipts(_ root: URL) throws -> [URL] {
    let scopes = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    return try scopes.flatMap {
      try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent != "scope.lock" }
    }
  }
}
