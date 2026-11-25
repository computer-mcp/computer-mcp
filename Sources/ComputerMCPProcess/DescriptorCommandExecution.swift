import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import Foundation
import NIOConcurrencyHelpers

/// Host file operations retain their descriptors until execution and output consumption finish.
internal enum DescriptorCommandExecution {
  static func runBounded(
    launcher: ExecutionLauncher, executable: String, invocation: CLIInvocation,
    directory: URL, environment: [String: String], timeoutMilliseconds: Int,
    maxOutputBytes: Int, fileOutput: (descriptor: Int32, bytes: Int)?,
    fileSizeLimit: ExecutionFileSizeLimit?
  ) throws -> CommandDataResult {
    guard timeoutMilliseconds > 0, maxOutputBytes > 0,
      fileOutput.map({ $0.descriptor >= 0 && $0.bytes > 0 }) ?? true
    else { throw CommandRunnerError.launchFailed("Invalid bounded command limits.") }
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    let inspection = ExecutableInspection.inspect(
      executable, workingDirectory: directory, environment: environment)
    guard !inspection.hasKnownFailure, let path = inspection.path,
      try PreparedExecutionContext.current() == nil
    else { throw CommandRunnerError.launchFailed("Bounded host command is unavailable.") }
    let setup = try HostExecutionSetup.prepare()
    let launchDirectory = try SandboxPath(directory.standardizedFileURL.path)
    installBrokenPipeHandler()
    return try blockingAsync {
      let input = Pipe()
      let writer = try DescriptorInputWriter(handle: input.fileHandleForWriting)
      let stdout = Pipe()
      let stderr = Pipe()
      let owner = NIOLockedValueBox<(any ExecutionOwnership)?>(nil)
      let state = NIOLockedValueBox(BoundedOutput())
      let destination = fileOutput.map {
        FileHandle(fileDescriptor: $0.descriptor, closeOnDealloc: false)
      }
      let fail: @Sendable (any Error) async -> Void = { error in
        state.withLockedValue { $0.error = $0.error ?? error }
        writer.cancel()
        if let ownership = owner.withLockedValue({ $0 }) {
          _ = try? await ownership.cancel()
        }
      }
      let output = try ProcessOutputReader(
        handle: stdout.fileHandleForReading,
        consume: { chunk in
          try state.withLockedValue { state in
            if let error = state.error { throw error }
            guard ContinuousClock.now < deadline else {
              throw CommandRunnerError.launchFailed("Bounded command output deadline exceeded.")
            }
            if let fileOutput, let destination {
              guard chunk.count <= fileOutput.bytes - state.written else {
                throw CommandRunnerError.launchFailed(
                  "Bounded command file output exceeded its limit.")
              }
              try destination.write(contentsOf: chunk)
              state.written += chunk.count
            } else {
              guard chunk.count <= maxOutputBytes - state.stdout.count else {
                throw CommandRunnerError.launchFailed("Bounded command stdout exceeded its limit.")
              }
              state.stdout.append(chunk)
            }
          }
        }, onError: fail)
      let diagnostics = try ProcessOutputReader(
        handle: stderr.fileHandleForReading,
        consume: { chunk in
          try state.withLockedValue {
            guard chunk.count <= maxOutputBytes - $0.stderr.count else {
              throw CommandRunnerError.launchFailed("Bounded command stderr exceeded its limit.")
            }
            $0.stderr.append(chunk)
          }
        }, onError: fail)
      output.start()
      diagnostics.start()
      var feeding: Task<Void, any Error>?
      do {
        guard ContinuousClock.now < deadline else {
          throw CommandRunnerError.launchFailed("Bounded command deadline exceeded before launch.")
        }
        let handle = try await launcher.start(
          executable: SandboxPath(path), arguments: invocation.arguments,
          directory: launchDirectory, environment: setup.environment, mode: setup.mode,
          input: input.fileHandleForReading.fileDescriptor,
          output: stdout.fileHandleForWriting.fileDescriptor,
          error: stderr.fileHandleForWriting.fileDescriptor,
          fileSizeLimit: fileSizeLimit,
          bindOwnership: { handle in owner.withLockedValue { $0 = handle } })
        try input.fileHandleForReading.close()
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        feeding = ExecutionTasks.startThrowing {
          do {
            let bytes = Array(invocation.standardInput)
            let written = try await writer.write(bytes)
            guard written == bytes.count else {
              throw CommandRunnerError.launchFailed("Bounded command did not consume its input.")
            }
            try await writer.finish()
          } catch {
            try? await writer.finish()
            await fail(error)
            throw error
          }
        }
        let exit = try await handle.wait(until: deadline)
        await output.stop(drainRemainingOutput: true)
        await diagnostics.stop(drainRemainingOutput: true)
        let fed = await feeding?.result
        let collected = state.withLockedValue { $0 }
        if let error = collected.error { throw error }
        try fed?.get()
        guard ContinuousClock.now < deadline else {
          throw CommandRunnerError.launchFailed("Bounded command deadline exceeded.")
        }
        return CommandDataResult(
          executable: executable, arguments: invocation.arguments,
          exitCode: exit.signal ?? exit.status, timedOut: false, stdout: collected.stdout,
          stderr: collected.stderr, stdoutTruncated: false, stderrTruncated: false)
      } catch {
        writer.cancel()
        if let ownership = owner.withLockedValue({ $0 }) {
          await confirmBoundedTermination(ownership)
        }
        try? input.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        await output.stop(drainRemainingOutput: false)
        await diagnostics.stop(drainRemainingOutput: false)
        _ = await feeding?.result
        try? await writer.finish()
        throw error
      }
    }
  }

  private static func confirmBoundedTermination(_ owner: any ExecutionOwnership) async {
    while true {
      do {
        _ = try await owner.cancel()
        return
      } catch {
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private struct BoundedOutput: Sendable {
    var written = 0
    var stdout = Data()
    var stderr = Data()
    var error: (any Error)?
  }

  static func run(
    launcher: ExecutionLauncher, executable: String,
    arguments: [String],
    workingDirectory: URL?, directoryDescriptor: Int32?, inputDescriptor: Int32,
    outputDescriptor: Int32, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    guard timeoutMilliseconds > 0, maxOutputBytes > 0, outputDescriptor >= 0 else {
      throw CommandRunnerError.launchFailed("Invalid descriptor command limits or output.")
    }
    let prepared = try PreparedExecutionContext.current()
    let directory =
      workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let inspection = ExecutableInspection.inspect(
      executable, workingDirectory: directory, environment: environment)
    guard !inspection.hasKnownFailure, let path = inspection.path else {
      throw CommandRunnerError.launchFailed(inspection.message)
    }
    let setup = try HostExecutionSetup.prepare()
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
      let state = NIOLockedValueBox(Output(limit: maxOutputBytes))
      prepared?.observeLimits { limits in
        state.withLockedValue {
          $0.limit = min($0.limit, Int(clamping: limits.outputBytes))
          if $0.stderr.count > $0.limit {
            $0.stderr.removeFirst($0.stderr.count - $0.limit)
            $0.truncated = true
          }
        }
      }
      let destination = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false)
      let output = try ProcessOutputReader(
        handle: stdout.fileHandleForReading,
        consume: { try destination.write(contentsOf: $0) },
        onError: { error in state.withLockedValue { $0.error = $0.error ?? error } })
      let diagnostics = try ProcessOutputReader(
        handle: stderr.fileHandleForReading,
        consume: { data in
          state.withLockedValue {
            guard prepared != nil else {
              let remaining = max(0, $0.limit - $0.stderr.count)
              $0.stderr.append(data.prefix(remaining))
              $0.truncated = $0.truncated || data.count > remaining
              return
            }
            $0.stderr.append(data)
            if $0.stderr.count > $0.limit {
              $0.stderr.removeFirst($0.stderr.count - $0.limit)
              $0.truncated = true
            }
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
        } catch is ExecutionWaitExpired {
          timedOut = true
          exit = try await cancelAndConfirm(handle)
        }
        await output.stop(drainRemainingOutput: true)
        await diagnostics.stop(drainRemainingOutput: true)
        if let prepared {
          let limits = try prepared.accessExecution(prepared.executionID, operation: .readResult)
          state.withLockedValue {
            $0.limit = min($0.limit, Int(clamping: limits.outputBytes))
            if $0.stderr.count > $0.limit {
              $0.stderr.removeFirst($0.stderr.count - $0.limit)
              $0.truncated = true
            }
          }
        }
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
      } catch is ExecutionWaitExpired {
        continue
      }
    }
  }

  private struct Output: Sendable {
    var limit: Int
    var stderr = Data()
    var truncated = false
    var error: (any Error)?
  }
}
