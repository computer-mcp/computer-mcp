import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPPermissions

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

/// Native unit fixtures own their sandbox, child handles and private scratch.
func withCLIProcessScope<Value>(
  directory: URL, readOnly: Bool = false, variables: [String: String] = [:],
  operation: () async throws -> Value
) async throws -> Value {
  #if os(Linux)
    // These adapter fixtures exercise arguments, output and owned cancellation.
    // Linux has no sandbox backend; principal admission is tested separately.
    let scratch = try ScopedTemporaryDirectory()
    var environment = [
      "PATH": "/usr/bin:/bin", "HOME": scratch.url.path, "TMPDIR": scratch.url.path + "/",
    ]
    environment.merge(variables) { _, value in value }
    let administration = ExecutionAdministration(
      mode: .fullAccess,
      environment: try .init(fullAccessVariables: environment))
    return try await ExecutionAdministration.$current.withValue(administration) {
      try await operation()
    }
  #else
    let scope = try CLIProcessScope(directory: directory, readOnly: readOnly, variables: variables)
    do {
      let result = try await InvocationExecution.$current.withValue(scope.prepared) {
        try await operation()
      }
      try await Task.detached { try await scope.finish(cancel: false) }.value
      return result
    } catch {
      do { try await Task.detached { try await scope.finish(cancel: true) }.value } catch let
        cleanup
      {
        Issue.record("CLI fixture cleanup did not confirm completion: \(cleanup)")
      }
      throw error
    }
  #endif
}

private final class CLIProcessScope: @unchecked Sendable {
  let prepared: PreparedExecutionContext
  private let scratch: ScopedTemporaryDirectory
  private let authority: CLIProcessAuthority
  private let launcher: ExecutionLauncher

  init(directory: URL, readOnly: Bool, variables: [String: String]) throws {
    let launcher = testExecutionLauncher()
    self.launcher = launcher
    let scratch = try ScopedTemporaryDirectory()
    self.scratch = scratch
    let root = try SandboxPath(ProjectPathResolver.canonicalProject(directory).path)
    let home = try SandboxPath(ProjectPathResolver.canonicalProject(scratch.url).path)
    let reads = [root] + launcher.hostSystemReadPaths
    var ancestors: Set<String> = ["/"]
    for path in reads + [home] {
      var parent = (path.value as NSString).deletingLastPathComponent
      while parent != "/" {
        ancestors.insert(parent)
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
    let sandbox = try SandboxConfiguration(
      readOnly: readOnly, worktree: root, temporaryDirectory: home,
      homeDirectory: home, cacheDirectory: home, readableRoots: reads,
      listableAncestors: ancestors.sorted().map(SandboxPath.init))
    let authority = CLIProcessAuthority()
    self.authority = authority
    prepared = try PreparedExecutionContext(
      authority: authority, mode: .sandbox(sandbox),
      environment: .init(
        searchPath: [SandboxPath("/usr/bin"), SandboxPath("/bin")],
        home: home, temporary: home, cache: home, hostVariables: variables),
      limits: CLIProcessAuthority.limits)
  }

  func finish(cancel: Bool) async throws {
    try prepared.finishAdmission()
    try await authority.joinChildren(cancel: cancel, launcher: launcher)
    withExtendedLifetime(scratch) {}
  }
}

/// Scope-local authority for reviewed native fixture processes; it never admits Gateway calls.
private final class CLIProcessAuthority: ExecutionAuthorizing, @unchecked Sendable {
  static let limits = EffectiveExecutionLimits(
    timeMilliseconds: 60_000, outputBytes: 8 * 1024 * 1024,
    memoryBytes: nil, retentionSeconds: 60, retainedOutputBytes: 8 * 1024 * 1024,
    sources: [:])

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
  private var children: [UUID: Child] = [:]

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
    }
  }

  func launchFailed(_ id: UUID) {
    lock.withLock { children[id]?.failed = true }
  }

  func finishAdmission() {
    lock.withLock { closed = true }
  }

  func access(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits {
    try lock.withLock {
      guard id == executionID, !closed else { throw PermissionModelError.invalidAuthorization }
      return Self.limits
    }
  }

  func joinChildren(cancel: Bool, launcher: ExecutionLauncher) async throws {
    let snapshot = lock.withLock { children }
    var failure: (any Error)?
    for (id, child) in snapshot where !child.released {
      guard let ownership = child.ownership else {
        #expect(child.failed)
        continue
      }
      do {
        if cancel {
          _ = try await ownership.cancel()
        } else {
          _ = try await ownership.wait(until: .now.advanced(by: .seconds(5)))
        }
        #expect(try await ownership.members().isEmpty)
        if let member = child.member {
          let recovery = try ownership.recoveryState()
          #expect(recovery.root == member && recovery.sandboxed)
          try launcher.releaseRecovery(recovery)
        }
        lock.withLock { children[id]?.released = true }
      } catch {
        failure = failure ?? error
        _ = try? await ownership.cancel()
      }
    }
    if let failure { throw failure }
  }
}

/// Records adapter inputs while preserving the real native process path.
final class CLIContextCommandRunner: CommandRunning, @unchecked Sendable {
  struct Call: Sendable {
    let executable: String
    let arguments: [String]
    let directory: URL?
    let environment: [String: String]
  }
  private let base: ProcessCommandRunner
  private let lock = NSLock()
  private var recorded: [Call] = []
  var calls: [Call] { lock.withLock { recorded } }

  init(environment: [String: String]) {
    base = ProcessCommandRunner(launcher: testExecutionLauncher(), environment: environment)
  }

  func run(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    lock.withLock {
      recorded.append(
        Call(
          executable: executable, arguments: arguments,
          directory: workingDirectory, environment: environment))
    }
    return try base.run(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
  }

  func runData(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    lock.withLock {
      recorded.append(
        Call(
          executable: executable, arguments: arguments,
          directory: workingDirectory, environment: environment))
    }
    return try base.runData(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
  }

}
