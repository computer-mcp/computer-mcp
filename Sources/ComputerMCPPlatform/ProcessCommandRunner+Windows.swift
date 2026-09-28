#if os(Windows)
  import Dispatch
  import Foundation
  import Subprocess
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
      // Windows overlapped IO must finish before its buffers and handles are released.
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

    private struct Captured: Sendable {
      var data = Data()
      var truncated = false
    }

    private struct Outcome: Sendable {
      let exitCode: Int32
      let stdout: Captured
      let stderr: Captured
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
        var options = PlatformOptions()
        options.windowStyle = .hidden
        options.preSpawnProcessConfigurator = { flags, _ in flags |= DWORD(CREATE_SUSPENDED) }
        let childEnvironment = Dictionary(
          uniqueKeysWithValues: environment.map {
            (Subprocess.Environment.Key(stringLiteral: $0.key), $0.value)
          })
        do {
          let outcome = try await Subprocess.run(
            .path(.init(path)), arguments: Arguments(arguments),
            environment: .custom(childEnvironment),
            workingDirectory: .init(cwd), platformOptions: options,
            preferredBufferSize: 16_384
          ) { execution, input, output, error in
            job.start(execution.processIdentifier)
            var inputFailure: (any Error)?
            do { try await input.finish() } catch {
              inputFailure = error
              job.stop(.failed)
            }
            async let stdout = Self.capture(output, limit: limit, job: job)
            async let stderr = Self.capture(error, limit: limit, job: job)
            async let root: Void = job.monitorRoot(execution.processIdentifier)
            let values = await (stdout, stderr, root)
            if let inputFailure { throw inputFailure }
            return try (values.0.get(), values.1.get())
          }
          try await job.confirmCleanup()
          switch outcome.terminationStatus {
          case .exited(let code):
            return Outcome(
              exitCode: Int32(bitPattern: code), stdout: outcome.value.0, stderr: outcome.value.1)
          }
        } catch {
          job.stop(.failed)
          try await job.confirmCleanup()
          throw error
        }
      }
    }

    private static func capture(
      _ sequence: AsyncBufferSequence, limit: Int, job: WindowsProcessJob
    ) async -> Result<Captured, any Error> {
      var capture = Captured()
      do {
        for try await buffer in sequence {
          buffer.withUnsafeBytes { bytes in
            let count = min(bytes.count, limit - capture.data.count)
            capture.data.append(contentsOf: bytes.prefix(count))
            capture.truncated = capture.truncated || count < bytes.count
          }
        }
        return .success(capture)
      } catch {
        job.stop(.failed)
        return .failure(error)
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
      // Subprocess otherwise fills a missing PATH from the parent even with a custom environment.
      if merged["path"] == nil { merged["path"] = ("PATH", "") }
      return Dictionary(uniqueKeysWithValues: merged.values.map { ($0.key, $0.value) })
    }
  }
#endif
