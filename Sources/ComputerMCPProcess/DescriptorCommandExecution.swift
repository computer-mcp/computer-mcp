import ComputerMCPPlatform
import ComputerMCPSandbox
import Foundation
import NIOConcurrencyHelpers

/// Host file operations retain their descriptors until execution and output consumption finish.
internal enum DescriptorCommandExecution {
  static func run(
    launcher: ExecutionLauncher, policy: HostExecutionPolicy, executable: String,
    arguments: [String],
    workingDirectory: URL?, directoryDescriptor: Int32?, inputDescriptor: Int32,
    outputDescriptor: Int32, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    guard timeoutMilliseconds > 0, maxOutputBytes > 0, outputDescriptor >= 0 else {
      throw CommandRunnerError.launchFailed("Invalid descriptor command limits or output.")
    }
    let directory =
      workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let inspection = ExecutableInspection.inspect(
      executable, workingDirectory: directory, environment: environment)
    guard !inspection.hasKnownFailure, let path = inspection.path else {
      throw CommandRunnerError.launchFailed(inspection.message)
    }
    let setup = try policy.prepare(
      directory: directory, environment: environment, systemReadPaths: launcher.hostSystemReadPaths)
    defer { setup.removeTemporaryDirectory() }
    let launchDirectory: SandboxPath
    if case .sandbox(let configuration) = setup.mode {
      launchDirectory = configuration.worktree
    } else {
      launchDirectory = try SandboxPath(directory.standardizedFileURL.path)
    }
    return try blockingAsync {
      // Pipes force sparse producers to emit holes as bytes and make host write errors observable.
      let stdout = Pipe()
      let stderr = Pipe()
      let state = NIOLockedValueBox(Output())
      let destination = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false)
      let output = try ProcessOutputReader(
        handle: stdout.fileHandleForReading,
        consume: { try destination.write(contentsOf: $0) },
        onError: { error in state.withLockedValue { $0.error = $0.error ?? error } })
      let diagnostics = try ProcessOutputReader(
        handle: stderr.fileHandleForReading,
        consume: { data in
          state.withLockedValue {
            let remaining = maxOutputBytes - $0.stderr.count
            $0.stderr.append(data.prefix(remaining))
            $0.truncated = $0.truncated || data.count > remaining
          }
        }, onError: { error in state.withLockedValue { $0.error = $0.error ?? error } })
      output.start()
      diagnostics.start()
      let owner = NIOLockedValueBox<(any ExecutionOwnership)?>(nil)
      do {
        let handle = try await launcher.start(
          executable: SandboxPath(path), arguments: arguments,
          directory: launchDirectory,
          environment: setup.environment, mode: setup.mode,
          input: inputDescriptor, output: stdout.fileHandleForWriting.fileDescriptor,
          error: stderr.fileHandleForWriting.fileDescriptor,
          directoryDescriptor: directoryDescriptor,
          bindOwnership: { handle in owner.withLockedValue { $0 = handle } })
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        let exit: ExecutionExit
        var timedOut = false
        do {
          exit = try await handle.wait(until: deadline)
        } catch is ExecutionCompletionFailure where ContinuousClock.now >= deadline {
          timedOut = true
          exit = try await cancelAndConfirm(handle)
        }
        await output.stop(drainRemainingOutput: true)
        await diagnostics.stop(drainRemainingOutput: true)
        let collected = state.withLockedValue { $0 }
        if let error = collected.error { throw error }
        return CommandResult(
          executable: executable, arguments: arguments, exitCode: exit.signal ?? exit.status,
          timedOut: timedOut, stdout: "", stderr: String(decoding: collected.stderr, as: UTF8.self),
          stdoutTruncated: false, stderrTruncated: collected.truncated)
      } catch {
        if let owner = owner.withLockedValue({ $0 }) { _ = try? await cancelAndConfirm(owner) }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        await output.stop(drainRemainingOutput: false)
        await diagnostics.stop(drainRemainingOutput: false)
        throw error
      }
    }
  }

  private static func cancelAndConfirm(_ owner: any ExecutionOwnership) async throws
    -> ExecutionExit
  {
    while true {
      do { return try await owner.cancel() } catch is ExecutionCompletionFailure {
        // Borrowed descriptors and sandbox paths remain live until termination is confirmed.
      }
    }
  }

  private struct Output: Sendable {
    var stderr = Data()
    var truncated = false
    var error: (any Error)?
  }
}
