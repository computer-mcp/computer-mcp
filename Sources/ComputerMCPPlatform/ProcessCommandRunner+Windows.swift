#if os(Windows)
  import Dispatch
  import Foundation
  import Synchronization
  import WinSDK

  package final class ProcessCommandRunner: CommandRunning, Sendable {
    private let baseEnvironment: [String: String]

    package init(environment: [String: String] = ProcessInfo.processInfo.environment) {
      baseEnvironment = environment
    }

    /// Synchronous compatibility entry point. Call from a blocking executor, not the main actor.
    package func runData(
      executable: String, arguments: [String], workingDirectory: URL?,
      environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
    ) throws -> CommandDataResult {
      let result = Mutex<Result<CommandDataResult, any Error>?>(nil)
      let completed = DispatchSemaphore(value: 0)
      // The synchronous protocol has no task cancellation channel. Its deadline owns termination.
      Task.detached {
        let value: Result<CommandDataResult, any Error>
        do {
          value = .success(
            try await self.runDataAsync(
              executable: executable, arguments: arguments, workingDirectory: workingDirectory,
              environment: environment, timeoutMilliseconds: timeoutMilliseconds,
              maxOutputBytes: maxOutputBytes))
        } catch { value = .failure(error) }
        result.withLock { $0 = value }
        completed.signal()
      }
      completed.wait()
      return try result.withLock { try $0!.get() }
    }

    package func run(
      executable: String, arguments: [String], workingDirectory: URL?,
      environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
    ) throws -> CommandResult {
      let value = try runData(
        executable: executable, arguments: arguments, workingDirectory: workingDirectory,
        environment: environment, timeoutMilliseconds: timeoutMilliseconds,
        maxOutputBytes: maxOutputBytes)
      return CommandResult(
        executable: value.executable, arguments: value.arguments, exitCode: value.exitCode,
        timedOut: value.timedOut, stdout: value.stdoutString, stderr: value.stderrString,
        stdoutTruncated: value.stdoutTruncated, stderrTruncated: value.stderrTruncated)
    }

    package func runDataAsync(
      executable: String, arguments: [String], workingDirectory: URL?,
      environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
    ) async throws -> CommandDataResult {
      try Task.checkCancellation()
      guard (1...3_600_000).contains(timeoutMilliseconds),
        (1...32_000_000).contains(maxOutputBytes),
        arguments.allSatisfy({ !$0.contains("\0") })
      else {
        throw CommandRunnerError.launchFailed("Invalid command arguments or execution limits.")
      }
      let cwd = workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      guard let nativeCwd = WindowsFilePath.native(cwd), WindowsFilePath.isValid(nativeCwd),
        WindowsFilePath.isAbsolute(nativeCwd)
      else { throw CommandRunnerError.launchFailed("Invalid command working directory.") }
      let childEnvironment = try mergedEnvironment(environment)
      let inspection = ExecutableInspection.inspect(
        executable, workingDirectory: cwd, environment: childEnvironment)
      guard !inspection.hasKnownFailure, let path = inspection.path else {
        throw CommandRunnerError.launchFailed(inspection.message)
      }
      let job = try WindowsProcessJob()
      // Native IO must finish before its buffers and handles are released.
      // Cancellation stops the job, while this owner drains and joins without task cancellation.
      let owner = Task.detached {
        try await self.execute(
          path: path, arguments: arguments, cwd: nativeCwd, environment: childEnvironment,
          timeoutMilliseconds: timeoutMilliseconds, limit: maxOutputBytes, job: job)
      }
      return try await withTaskCancellationHandler {
        let value = try await owner.value
        try Task.checkCancellation()
        return CommandDataResult(
          executable: executable, arguments: arguments, exitCode: value.exitCode,
          timedOut: job.timedOut, stdout: value.stdout.data, stderr: value.stderr.data,
          stdoutTruncated: value.stdout.truncated, stderrTruncated: value.stderr.truncated)
      } onCancel: {
        job.stop(.cancelled)
      }
    }

    private struct Outcome: Sendable {
      let exitCode: Int32
      let stdout: WindowsCommandProcess.Capture
      let stderr: WindowsCommandProcess.Capture
    }

    private func execute(
      path: String, arguments: [String], cwd: String, environment: [String: String],
      timeoutMilliseconds: Int, limit: Int, job: WindowsProcessJob
    ) async throws -> Outcome {
      try await withThrowingTaskGroup(of: Void.self) { timers in
        timers.addTask {
          do { try await Task.sleep(for: .milliseconds(timeoutMilliseconds)) } catch { return }
          job.stop(.timedOut)
        }
        defer { timers.cancelAll() }
        do {
          let process = try WindowsCommandProcess(
            path: path, arguments: arguments, cwd: cwd, environment: environment, job: job)
          async let stdout = process.stdout.capture(limit: limit, job: job)
          async let stderr = process.stderr.capture(limit: limit, job: job)
          async let root = process.wait(job: job)
          let values = await (stdout, stderr, root)
          try await job.confirmCleanup()
          return try Outcome(
            exitCode: values.2.get(), stdout: values.0.get(), stderr: values.1.get())
        } catch {
          job.stop(.failed)
          try await job.confirmCleanup()
          throw error
        }
      }
    }

    private func mergedEnvironment(_ overrides: [String: String]) throws -> [String: String] {
      var merged: [String: (key: String, value: String)] = [:]
      for environment in [baseEnvironment, overrides] {
        var keys = Set<String>()
        for (key, value) in environment {
          let folded = key.lowercased()
          guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0"),
            keys.insert(folded).inserted
          else { throw CommandRunnerError.launchFailed("Invalid or ambiguous child environment.") }
          merged[folded] = (key, value)
        }
      }
      if merged["path"] == nil { merged["path"] = ("PATH", "") }
      return Dictionary(uniqueKeysWithValues: merged.values.map { ($0.key, $0.value) })
    }
  }
#endif
