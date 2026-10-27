import ComputerMCPSandbox
import Foundation
import NIOConcurrencyHelpers

extension ExecutionLauncher {
  /// Captures bounded streams while retaining borrowed descriptors through confirmed termination.
  package func capture(
    executable: SandboxPath, arguments: [String], directory: SandboxPath,
    environment: ExecutionEnvironment, mode: ExecutionMode,
    input: Int32, inheritedDescriptors: [Int32: Int32] = [:],
    maxOutputBytes: Int, maxErrorBytes: Int
  ) async throws -> (exit: ExecutionExit, stdout: Data, stderr: Data) {
    guard maxOutputBytes >= 0, maxErrorBytes >= 0 else {
      throw ExecutionEnvironmentError.invalidConfiguration("Invalid capture limits")
    }
    let stdout = Pipe()
    let stderr = Pipe()
    let captured = NIOLockedValueBox(CapturedOutput())
    let owner = NIOLockedValueBox<(any ExecutionOwnership)?>(nil)
    let fail: @Sendable (any Error) async -> Void = { error in
      captured.withLockedValue { $0.error = error }
      if let owner = owner.withLockedValue({ $0 }) { await owner.cancelAndWait() }
    }
    let output = try ProcessOutputReader(
      handle: stdout.fileHandleForReading,
      consume: { data in
        try captured.withLockedValue {
          guard data.count <= maxOutputBytes - $0.stdout.count else {
            throw ExecutionEnvironmentError.launchFailed("Execution output exceeded capture limit")
          }
          $0.stdout.append(data)
        }
      }, onError: fail)
    let diagnostics = try ProcessOutputReader(
      handle: stderr.fileHandleForReading,
      consume: { data in
        try captured.withLockedValue {
          guard data.count <= maxErrorBytes - $0.stderr.count else {
            throw ExecutionEnvironmentError.launchFailed(
              "Execution error output exceeded capture limit")
          }
          $0.stderr.append(data)
        }
      }, onError: fail)
    output.start()
    diagnostics.start()
    do {
      let handle = try await start(
        executable: executable, arguments: arguments, directory: directory,
        environment: environment, mode: mode,
        input: input, output: stdout.fileHandleForWriting.fileDescriptor,
        error: stderr.fileHandleForWriting.fileDescriptor,
        inheritedDescriptors: inheritedDescriptors,
        bindOwnership: { handle in owner.withLockedValue { $0 = handle } })
      try stdout.fileHandleForWriting.close()
      try stderr.fileHandleForWriting.close()
      let exit = try await handle.wait()
      await output.stop(drainRemainingOutput: true)
      await diagnostics.stop(drainRemainingOutput: true)
      try Task.checkCancellation()
      let result = captured.withLockedValue { $0 }
      if let error = result.error { throw error }
      return (exit, result.stdout, result.stderr)
    } catch {
      if let owner = owner.withLockedValue({ $0 }) { await owner.cancelAndWait() }
      try? stdout.fileHandleForWriting.close()
      try? stderr.fileHandleForWriting.close()
      await output.stop(drainRemainingOutput: false)
      await diagnostics.stop(drainRemainingOutput: false)
      throw error
    }
  }
}

extension ExecutionOwnership {
  /// Services have no finite run deadline; ownership uncertainty retains their resources.
  package func waitForExit() async throws -> ExecutionExit {
    while true {
      do { return try await wait() } catch is ExecutionCompletionFailure { continue }
    }
  }

  /// Resource owners cannot retire borrowed files or descriptors while cleanup is unconfirmed.
  package func cancelAndWait() async {
    while true {
      do {
        _ = try await cancel()
        return
      } catch is ExecutionCompletionFailure {
        continue
      } catch is ExecutionWaitExpired {
        continue
      } catch {
        return
      }
    }
  }
}

private struct CapturedOutput: Sendable {
  var stdout = Data()
  var stderr = Data()
  var error: (any Error)?
}
