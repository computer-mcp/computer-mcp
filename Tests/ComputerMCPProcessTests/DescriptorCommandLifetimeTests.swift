import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct DescriptorCommandLifetimeTests {
  @Test(arguments: [false, true])
  func failedConfirmationRetainsResources(startFails: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let output = open("/dev/null", O_WRONLY | O_CLOEXEC)
    defer { close(output) }
    let platform = RetryingDescriptorPlatform(startFails: startFails)
    let runner = ManagedCommandRunner(
      launcher: ExecutionLauncher(platform: platform))
    try withCommandAdministration(readOnly: true, workingDirectory: temporary.url) {
      #expect(throws: ExecutionEnvironmentError.self) {
        try runner.runToFile(
          executable: testExecutable("echo"), arguments: [], workingDirectory: temporary.url,
          environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 1024,
          outputDescriptor: output)
      }
      let owner = try #require(platform.owner)
      #expect(FileManager.default.fileExists(atPath: owner.home))
    }
    let owner = try #require(platform.owner)
    #expect(owner.cancellations == 2)
    #expect(!FileManager.default.fileExists(atPath: owner.home))
  }
}

private final class RetryingDescriptorPlatform: ExecutionPlatform, @unchecked Sendable {
  private let lock = NSLock()
  private var value: RetryingDescriptorOwnership?
  let startFails: Bool
  var owner: RetryingDescriptorOwnership? { lock.withLock { value } }

  init(startFails: Bool) { self.startFails = startFails }

  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    let owner = RetryingDescriptorOwnership(
      home: try #require(command.environment["HOME"]), output: output, error: error)
    lock.withLock { value = owner }
    bindOwnership(owner)
    if startFails { throw ExecutionEnvironmentError.launchFailed("fixture") }
    return owner
  }
}

private final class RetryingDescriptorOwnership: ExecutionOwnership, @unchecked Sendable {
  private let lock = NSLock()
  private var attempts = 0
  let home: String
  private let output: Int32
  private let error: Int32
  var cancellations: Int { lock.withLock { attempts } }

  init(home: String, output: Int32, error: Int32) {
    self.home = home
    // Model the platform's ownership of duplicated child stream descriptors.
    self.output = dup(output)
    self.error = dup(error)
  }

  deinit {
    close(output)
    close(error)
  }

  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {}
  func onCancellation(_ handler: @escaping @Sendable () -> Void) {}
  func members() async throws -> [ExecutionMember] { [] }

  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    throw ExecutionEnvironmentError.launchFailed("fixture")
  }

  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    #expect(FileManager.default.fileExists(atPath: home))
    // A live reader is still present while completion is unconfirmed.
    let byte: [UInt8] = [65]
    #expect(write(output, byte, byte.count) == byte.count)
    #expect(write(error, byte, byte.count) == byte.count)
    let attempt = lock.withLock {
      attempts += 1
      return attempts
    }
    if attempt == 1 {
      throw ExecutionCompletionFailure(
        ownership: self, members: [], reasons: ["fixture"], bestEffort: false)
    }
    return .init(status: 0)
  }
}
