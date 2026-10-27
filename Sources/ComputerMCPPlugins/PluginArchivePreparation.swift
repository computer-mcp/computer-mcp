import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPSandbox
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif
/// Prepares an artifact without activating it or changing configuration.
/// `workerExecutable` must be the host's own CLI, never a package contribution.
package struct PluginArchivePreparation: Sendable {
  private let launcher: ExecutionLauncher
  package let workerExecutable: URL
  package let stagingParent: URL
  let directoryFactory: any PluginArchiveDirectoryFactory
  package var timeout: Duration = .seconds(60)
  /// Borrowed until this preparation finishes, including cancellation/reaping.
  package var inheritedLockDescriptor: Int32?

  package init(
    launcher: ExecutionLauncher, workerExecutable: URL, stagingParent: URL,
    timeout: Duration = .seconds(60), inheritedLockDescriptor: Int32? = nil,
    directoryFactory: any PluginArchiveDirectoryFactory
  ) {
    self.launcher = launcher
    self.workerExecutable = workerExecutable
    self.stagingParent = stagingParent
    self.directoryFactory = directoryFactory
    self.timeout = timeout
    self.inheritedLockDescriptor = inheritedLockDescriptor
  }

  /// The package is valid only within `operation`. An installation transaction
  /// may move its payload to an owned final location before committing the DB.
  /// On return or failure only the newly created job root is reclaimed.
  package func withPreparedPackage<Result: Sendable>(
    archive: URL, expectedSHA256: String, pluginID: String, version: PluginVersion,
    hostVersion: PluginVersion, architecture: String, artifactName: String? = nil,
    operation: @Sendable (PluginPackage, PluginArchiveReceipt) async throws -> Result
  ) async throws -> Result {
    try Task.checkCancellation()
    try PluginArchiveSnapshot.validateDigest(expectedSHA256)
    try validatePluginID(pluginID)
    guard timeout > .zero, timeout <= .seconds(60),
      ["arm64", "x86_64"].contains(architecture),
      archive.isFileURL, archive.path.hasPrefix("/"), !archive.path.contains("\0"),
      workerExecutable.isFileURL, workerExecutable.path.hasPrefix("/"),
      !workerExecutable.path.contains("\0")
    else { throw PluginArchiveError.invalidInput }
    let input = open(archive.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard input >= 0 else { throw PluginArchiveError.invalidInput }
    defer { close(input) }
    var status = stat()
    guard fstat(input, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size > 0 else {
      throw PluginArchiveError.invalidInput
    }
    guard status.st_size <= PluginArchiveLimits().archiveBytes else {
      throw PluginArchiveError.limitExceeded
    }
    let job = try directoryFactory.create(
      at: stagingParent.appendingPathComponent(UUID().uuidString, isDirectory: true))
    let result: Result
    do {
      let receipt = try await runWorker(input: input, directory: job.url, sha256: expectedSHA256)
      try Task.checkCancellation()
      let package: PluginPackage
      do {
        package = try PluginPackage.load(at: job.url.appendingPathComponent("payload"))
      } catch let refusal as PluginCompatibilityRefusal {
        throw refusal
      } catch let invalid as PluginManifestError {
        throw invalid
      } catch {
        throw PluginArchiveError.invalidPackage
      }
      guard package.manifest.id == pluginID, package.manifest.version == version else {
        throw PluginArchiveError.identityMismatch
      }
      if let refusal = package.manifest.refusal(
        host: hostVersion, architecture: architecture,
        artifactName: artifactName ?? archive.lastPathComponent)
      {
        throw refusal
      }
      try job.finish()
      try Task.checkCancellation()
      result = try await operation(package, receipt)
    } catch {
      try job.discard()
      throw error
    }
    try job.discard()
    return result
  }

  private func runWorker(input: Int32, directory: URL, sha256: String) async throws
    -> PluginArchiveReceipt
  {
    try await withThrowingTaskGroup(of: PluginArchiveReceipt.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        do {
          let environment = try ExecutionEnvironment(fullAccessVariables: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            "TMPDIR": directory.path,
          ])
          if let inheritedLockDescriptor, inheritedLockDescriptor <= STDERR_FILENO {
            throw PluginArchiveError.invalidInput
          }
          // The fixed worker owns host staging, independently of a principal's
          // program context. It joins before staging or the installation lock is released.
          let administration = ExecutionAdministration(mode: .fullAccess, environment: environment)
          let execution = try await InvocationExecution.$current.withValue(nil) {
            try await ExecutionAdministration.$current.withValue(administration) {
              try await launcher.capture(
                executable: SandboxPath(workerExecutable.path),
                arguments: ["_plugin-archive", "--sha256", sha256],
                directory: SandboxPath(directory.path), environment: environment, mode: .fullAccess,
                input: input,
                inheritedDescriptors: inheritedLockDescriptor.map { [$0: $0] } ?? [:],
                maxOutputBytes: 16_384, maxErrorBytes: 4_096)
            }
          }
          try Task.checkCancellation()
          let output = execution.stdout
          if execution.exit != ExecutionExit(status: 0) {
            if execution.exit == ExecutionExit(status: 1),
              let failure = try? JSONDecoder().decode(PluginArchiveError.self, from: output)
            {
              throw failure
            }
            throw PluginArchiveError.workerFailed
          }
          guard
            let object = try? JSONSerialization.jsonObject(with: output)
              as? [String: Any],
            Set(object.keys) == ["sha256", "archive_bytes", "extracted_bytes", "entries"],
            let receipt = try? JSONDecoder().decode(
              PluginArchiveReceipt.self, from: output),
            receipt.sha256 == sha256, receipt.archiveBytes > 0,
            receipt.archiveBytes <= PluginArchiveLimits().archiveBytes,
            receipt.extractedBytes >= 0,
            receipt.extractedBytes <= PluginArchiveLimits().expandedBytes,
            receipt.entries > 0, receipt.entries <= PluginArchiveLimits().entries
          else { throw PluginArchiveError.workerFailed }
          return receipt
        } catch {
          if Task.isCancelled { throw CancellationError() }
          throw error as? PluginArchiveError ?? .workerFailed
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw PluginArchiveError.timedOut
      }
      guard let receipt = try await group.next() else { throw CancellationError() }
      // Group scope waits for execution ownership to confirm termination before callers
      // can remove files the worker might still be writing.
      return receipt
    }
  }
}
