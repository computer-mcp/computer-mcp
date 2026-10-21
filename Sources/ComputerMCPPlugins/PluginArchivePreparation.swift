import ComputerMCPPlatform
import Foundation
import Subprocess

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif
#if canImport(System)
  import System
#else
  import SystemPackage
#endif

/// Prepares an artifact without activating it or changing configuration.
/// `workerExecutable` must be the host's own CLI, never a package contribution.
package struct PluginArchivePreparation: Sendable {
  package let workerExecutable: URL
  package let stagingParent: URL
  let directoryFactory: any PluginArchiveDirectoryFactory
  package var timeout: Duration = .seconds(60)
  /// Borrowed until this preparation finishes, including cancellation/reaping.
  package var inheritedLockDescriptor: Int32?

  package init(
    workerExecutable: URL, stagingParent: URL,
    timeout: Duration = .seconds(60), inheritedLockDescriptor: Int32? = nil,
    directoryFactory: any PluginArchiveDirectoryFactory
  ) {
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
      } catch {
        throw PluginArchiveError.invalidPackage
      }
      guard package.manifest.id == pluginID, package.manifest.version == version else {
        throw PluginArchiveError.identityMismatch
      }
      guard
        package.manifest.compatibility?.permits(host: hostVersion, architecture: architecture)
          ?? true
      else { throw PluginArchiveError.incompatiblePackage }
      let target =
        package.manifest.compatibility?.artifactTarget(
          named: artifactName ?? archive.lastPathComponent)
        ?? (package.manifest.compatibility == nil ? .macOS : nil)
      guard
        target?.permits(
          platform: PluginPlatformCompatibility.currentPlatform, architecture: architecture) == true
      else { throw PluginArchiveError.incompatiblePackage }
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
          // No inherited credentials, HOME, dynamic-loader overrides or host config.
          let environment: [Environment.Key: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
            "TMPDIR": directory.path,
          ]
          var options = PlatformOptions()
          if let inheritedLockDescriptor {
            guard inheritedLockDescriptor > STDERR_FILENO else {
              throw PluginArchiveError.invalidInput
            }
            #if canImport(Darwin)
              options.preSpawnProcessConfigurator = { _, actions in
                guard posix_spawn_file_actions_addinherit_np(&actions, inheritedLockDescriptor) == 0
                else { throw PluginArchiveError.workerFailed }
              }
            #elseif canImport(Glibc) || canImport(Musl)
              throw PluginArchiveError.workerFailed
            #endif
          }
          let execution = try await Subprocess.run(
            .path(FilePath(workerExecutable.path)),
            arguments: ["_plugin-archive", "--sha256", sha256],
            environment: .custom(environment), workingDirectory: FilePath(directory.path),
            platformOptions: options,
            input: .fileDescriptor(
              FileDescriptor(rawValue: input), closeAfterSpawningProcess: false),
            output: .bytes(limit: 16_384), error: .bytes(limit: 4_096))
          try Task.checkCancellation()
          if execution.terminationStatus != .exited(0) {
            if execution.terminationStatus == .exited(1),
              let failure = try? JSONDecoder().decode(
                PluginArchiveError.self, from: Data(execution.standardOutput))
            {
              throw failure
            }
            throw PluginArchiveError.workerFailed
          }
          guard
            let object = try? JSONSerialization.jsonObject(with: Data(execution.standardOutput))
              as? [String: Any],
            Set(object.keys) == ["sha256", "archive_bytes", "extracted_bytes", "entries"],
            let receipt = try? JSONDecoder().decode(
              PluginArchiveReceipt.self, from: Data(execution.standardOutput)),
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
      // Group scope waits for Subprocess cancellation/kill/reap before callers
      // can remove files the worker might still be writing.
      return receipt
    }
  }
}
