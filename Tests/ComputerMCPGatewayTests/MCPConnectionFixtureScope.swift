import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPPermissions

#if os(macOS)
  import ComputerMCPDarwinTestSupport

  @testable import ComputerMCPPlatformDarwin
#endif

/// Native protocol fixtures own one sandbox tree independently of Gateway admission.
final class MCPConnectionFixtureScope: @unchecked Sendable {
  private let authority = MCPConnectionFixtureAuthority()
  private let launcher: ExecutionLauncher
  private let sandbox: SandboxConfiguration
  private let home: SandboxPath

  init(directory: URL) throws {
    let launcher = testExecutionLauncher()
    self.launcher = launcher
    let root = try SandboxPath(ProjectPathResolver.canonicalProject(directory).path)
    let storage = directory.appendingPathComponent("private-home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: storage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let home = try SandboxPath(ProjectPathResolver.canonicalProject(storage).path)
    self.home = home
    let reads = [root] + launcher.hostSystemReadPaths
    var ancestors: Set<String> = ["/"]
    for path in reads + [home] {
      var parent = (path.value as NSString).deletingLastPathComponent
      while parent != "/" {
        ancestors.insert(parent)
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
    sandbox = try SandboxConfiguration(
      worktree: root, temporaryDirectory: home, homeDirectory: home, cacheDirectory: home,
      readableRoots: reads, listableAncestors: ancestors.sorted().map(SandboxPath.init))
  }

  var joined: Bool { authority.joined }

  func prepared(variables: [String: String]) throws -> PreparedExecutionContext {
    try PreparedExecutionContext(
      authority: authority, mode: .sandbox(sandbox),
      environment: .init(
        searchPath: [SandboxPath("/usr/bin"), SandboxPath("/bin")],
        home: home, temporary: home, cache: home, hostVariables: variables),
      limits: MCPConnectionFixtureAuthority.limits)
  }

  func finish() async throws {
    authority.finishAdmission()
    try await Task.detached { [authority, launcher] in
      try await authority.joinResources(launcher: launcher)
    }.value
  }
}

private final class MCPConnectionFixtureAuthority: ExecutionAuthorizing, @unchecked Sendable {
  static let limits = EffectiveExecutionLimits(
    timeMilliseconds: 60_000, outputBytes: 8 * 1024 * 1024, memoryBytes: nil,
    retentionSeconds: 60, retainedOutputBytes: 8 * 1024 * 1024, sources: [:])

  let executionID = UUID()
  let authorizationIDs: Set<UUID> = [UUID()]
  private struct Child {
    var ownership: (any ExecutionOwnership)?
    var member: ExecutionMember?
    var failed = false
    var released = false
  }
  private let lock = NSLock()
  private var closed = false
  private var didJoin = false
  private var children: [UUID: Child] = [:]
  private var work: [UUID: @Sendable () async -> Void] = [:]
  private var rootObservers: [UUID: Task<Void, Never>] = [:]

  var joined: Bool { lock.withLock { didJoin } }

  func reserveChild(_ id: UUID) throws {
    try lock.withLock {
      guard !closed, children[id] == nil else { throw PermissionModelError.invalidAuthorization }
      children[id] = Child()
    }
  }

  func bindChild(_ id: UUID, ownership: any ExecutionOwnership) {
    lock.withLock { children[id]?.ownership = ownership }
    ownership.beforeStart { [weak self] member in
      guard let self else { throw PermissionModelError.invalidAuthorization }
      try self.lock.withLock {
        guard !self.closed, self.children[id]?.ownership != nil,
          self.children[id]?.member == nil
        else { throw PermissionModelError.invalidAuthorization }
        self.children[id]?.member = member
      }
      #if os(macOS)
        let root = DarwinProcessIdentity(pid: member.processID, uniqueID: member.identity)
        let observer = Task.detached { [weak self] in
          guard let self else { return }
          await self.observeRoot(id, identity: root, ownership: ownership)
        }
        self.lock.withLock {
          self.rootObservers[id] = observer
          if self.closed { observer.cancel() }
        }
      #endif
    }
  }

  #if os(macOS)
    /// A wrapper's pinned kernel identity survives exec and remains observable until reaped.
    /// Its departure closes only the original ownership tree, including descendants.
    private func observeRoot(
      _ id: UUID, identity: DarwinProcessIdentity, ownership: any ExecutionOwnership
    ) async {
      while !Task.isCancelled, lock.withLock({ !closed && children[id]?.released == false }) {
        do {
          let current = DarwinProcessIdentity.current(pid: identity.pid, includingZombies: true)
          if current?.identity != identity {
            _ = try await ownership.cancel()
            return
          }
        } catch {
          if Task.isCancelled { return }
        }
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
      }
    }
  #endif

  func launchFailed(_ id: UUID) {
    lock.withLock { children[id]?.failed = true }
  }

  func finishAdmission() { lock.withLock { closed = true } }

  func retainWork(cancellation: @escaping @Sendable () async -> Void) throws -> ExecutionWorkLease {
    let id = UUID()
    try lock.withLock {
      guard !closed else { throw PermissionModelError.invalidAuthorization }
      work[id] = cancellation
    }
    return ExecutionWorkLease { [self] in _ = lock.withLock { work.removeValue(forKey: id) } }
  }

  func access(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits {
    try lock.withLock {
      guard id == executionID, !closed || operation == .readResult else {
        throw PermissionModelError.invalidAuthorization
      }
      return Self.limits
    }
  }

  func joinResources(launcher: ExecutionLauncher) async throws {
    if joined { return }
    let rootObservers = lock.withLock { Array(self.rootObservers.values) }
    for observer in rootObservers { observer.cancel() }
    let cancellations = lock.withLock { Array(work.values) }
    let cancelling = cancellations.map { cancellation in Task { await cancellation() } }
    let deadline = ContinuousClock.now + .seconds(10)
    var firstError: (any Error)?
    while true {
      let pending = lock.withLock { children.filter { !$0.value.released } }
      for (id, child) in pending {
        guard let ownership = child.ownership else {
          if child.failed { lock.withLock { children[id]?.released = true } }
          continue
        }
        do {
          _ = try await ownership.cancel(until: deadline)
          try #require(try await ownership.members().isEmpty)
          if let member = child.member {
            let recovery = try ownership.recoveryState()
            try #require(recovery.root == member && recovery.sandboxed)
            try launcher.releaseRecovery(recovery)
          }
          lock.withLock { children[id]?.released = true }
        } catch { firstError = firstError ?? error }
      }
      if let firstError {
        for task in cancelling { await task.value }
        for observer in rootObservers { await observer.value }
        throw firstError
      }
      let complete = lock.withLock { children.values.allSatisfy(\.released) && work.isEmpty }
      if complete {
        for task in cancelling { await task.value }
        let observers = lock.withLock { Array(self.rootObservers.values) }
        for observer in observers {
          observer.cancel()
          await observer.value
        }
        lock.withLock { didJoin = true }
        return
      }
      guard ContinuousClock.now < deadline else {
        throw ExecutionEnvironmentError.unavailable(
          "The native protocol fixture has unjoined child reservations or logical work")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
