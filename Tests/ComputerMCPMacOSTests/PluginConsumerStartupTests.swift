import ComputerMCPCore
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

enum PluginConsumerTiming {
  static let startupSeconds: TimeInterval = 45
  static let protocolSeconds: TimeInterval = 45
  // The enclosing invocation also covers fixture setup and result propagation.
  static let invocationSeconds = startupSeconds + protocolSeconds + 10
}

/// SwiftPM may plan the package before launching the already-built consumer.
/// This budget ends at connection; protocol execution has its own deadline.
func acceptPluginConsumer(
  listener: Int32, process: Process, log: URL,
  timeout: Duration = .seconds(PluginConsumerTiming.startupSeconds)
) throws -> Int32 {
  let deadline = ContinuousClock.now + timeout
  while process.isRunning, ContinuousClock.now < deadline {
    var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    let result = poll(&item, 1, 100)
    if result < 0 {
      if errno == EINTR { continue }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if result > 0 {
      guard item.revents & Int16(POLLIN) != 0 else { throw POSIXError(.EIO) }
      let descriptor = accept(listener, nil, nil)
      guard descriptor >= 0 else {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return descriptor
    }
  }
  let status =
    process.isRunning
    ? "Consumer did not connect within the startup budget."
    : "Consumer exited before connecting (status \(process.terminationStatus))."
  let output = (try? String(contentsOf: log, encoding: .utf8)) ?? "Consumer log unavailable."
  throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: status + "\n" + output])
}

func pluginConsumerListener(at path: String) throws -> Int32 {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  do {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) {
      $0.initializeMemory(as: UInt8.self, repeating: 0)
      $0.copyBytes(from: bytes)
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(descriptor, 1) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
  } catch {
    Darwin.close(descriptor)
    throw error
  }
}

@Suite(.nativeIntegration, .serialized)
struct PluginConsumerStartupTests {
  @Test func delayedConsumerConnectsWithinBootstrapBudget() async throws {
    let temporary = try ScopedTemporaryDirectory()
    let path = temporary.url.appendingPathComponent("consumer.sock").path
    let listener = try pluginConsumerListener(at: path)
    defer {
      Darwin.close(listener)
      unlink(path)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    let connection = Task {
      // A real socket arriving after package planning must still be admitted.
      try await Task.sleep(for: .seconds(9))
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &address.sun_path) {
        $0.initializeMemory(as: UInt8.self, repeating: 0)
        $0.copyBytes(from: Array(path.utf8))
      }
      let client = socket(AF_UNIX, SOCK_STREAM, 0)
      try #require(client >= 0)
      defer { Darwin.close(client) }
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      try #require(result == 0)
    }
    defer { connection.cancel() }
    let log = temporary.url.appendingPathComponent("consumer.log")
    let accepted = try await BlockingOperationExecutor(label: "consumer-startup-test").perform {
      try acceptPluginConsumer(listener: listener, process: process, log: log)
    }
    Darwin.close(accepted)
    try await connection.value
  }

  enum ChildState: CaseIterable, Sendable { case running, exited, stopped }

  @Test(arguments: ChildState.allCases)
  func missingConnectionReportsStartupFailure(state: ChildState) throws {
    let temporary = try ScopedTemporaryDirectory()
    let log = temporary.url.appendingPathComponent("consumer.log")
    try Data("fixture startup diagnostic".utf8).write(to: log)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: state == .exited ? "/bin/sh" : "/bin/sleep")
    process.arguments = state == .exited ? ["-c", "exit 7"] : ["60"]
    try process.run()
    defer {
      if process.isRunning {
        if state == .stopped { _ = process.resume() }
        process.terminate()
      }
      process.waitUntilExit()
    }
    if state == .exited { process.waitUntilExit() }
    if state == .stopped { try #require(process.suspend()) }
    let start = ContinuousClock.now
    do {
      _ = try acceptPluginConsumer(
        listener: -1, process: process, log: log, timeout: .milliseconds(100))
      Issue.record("A consumer without a connection was accepted.")
    } catch {
      let message = (error as NSError).localizedDescription
      #expect(message.contains(state == .exited ? "status 7" : "startup budget"))
      #expect(message.contains("fixture startup diagnostic"))
    }
    #expect(start.duration(to: .now) < .seconds(5))
  }
}
