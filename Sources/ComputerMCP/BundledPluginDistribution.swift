import Darwin
import Foundation

/// Build-time inputs pinned by the App repository, not a runtime registry or a publisher claim.
package struct BundledPluginArtifact: Codable, Equatable, Sendable {
  package let id: String
  package let version: PluginVersion
  package let archive: String
  package let sha256: String
}

package enum BundledPluginDistribution {
  /// Creates a new unsigned resource directory. Existing output is never modified.
  /// Only verified package bytes are moved; no contribution or install script is executed.
  package static func prepare(
    index: URL, destination: URL, workerExecutable: URL,
    hostVersion: PluginVersion, architectures: [String]
  ) async throws -> [BundledPluginArtifact] {
    guard !architectures.isEmpty, Set(architectures).count == architectures.count,
      architectures.allSatisfy({ ["arm64", "x86_64"].contains($0) })
    else { throw PluginArchiveError.invalidInput }
    let inputs = try PluginPackageFiles(root: index.deletingLastPathComponent())
    let artifacts = try readIndex(inputs.read(index.lastPathComponent, maximumBytes: 1_048_576))
    try Task.checkCancellation()
    let output = try PluginArchiveDirectory(at: destination)
    let outputDescriptor = output.descriptor
    do {
      for artifact in artifacts {
        let preparation = PluginArchivePreparation(
          workerExecutable: workerExecutable, stagingParent: output.url)
        try output.finish()
        try await preparation.withPreparedPackage(
          archive: inputs.root.appendingPathComponent(artifact.archive),
          expectedSHA256: artifact.sha256, pluginID: artifact.id, version: artifact.version,
          hostVersion: hostVersion, architecture: architectures[0]
        ) { package, _ in
          guard
            architectures.allSatisfy({
              package.manifest.compatibility?.permits(host: hostVersion, architecture: $0) ?? true
            })
          else { throw PluginArchiveError.incompatiblePackage }
          try adopt(package: package, name: artifact.id, destination: outputDescriptor)
        }
        try output.finish()
      }
      try Task.checkCancellation()
      let inventory = BundledPlugins.load(directory: output.url)
      guard inventory.issues.isEmpty,
        Set(inventory.packages.map(\.manifest.id)) == Set(artifacts.map(\.id))
      else { throw PluginArchiveError.invalidPackage }
      // Installation staging is owner-only; distributed App resources must be
      // readable by other users. Normalize only our validated, newly owned tree.
      try makeDistributable(output.descriptor)
      try output.finish()
      return artifacts
    } catch {
      try output.discard()
      throw error
    }
  }

  private static func readIndex(_ data: Data) throws -> [BundledPluginArtifact] {
    guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      !entries.isEmpty, entries.count <= 128,
      entries.allSatisfy({ Set($0.keys) == ["id", "version", "archive", "sha256"] }),
      let artifacts = try? JSONDecoder().decode([BundledPluginArtifact].self, from: data),
      Set(artifacts.map(\.id)).count == artifacts.count,
      Set(artifacts.map(\.archive)).count == artifacts.count
    else { throw PluginArchiveError.invalidInput }
    for artifact in artifacts {
      try validatePluginID(artifact.id)
      try PluginArchiveSnapshot.validateDigest(artifact.sha256)
      try validatePluginRelativePath(artifact.archive)
      guard !artifact.archive.contains("/"), artifact.archive.utf8.count <= 255 else {
        throw PluginArchiveError.invalidInput
      }
    }
    return artifacts
  }

  private static func adopt(package: PluginPackage, name: String, destination: Int32) throws {
    let parent = Darwin.open(
      package.root.deletingLastPathComponent().path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw PluginArchiveError.fileSystemFailure }
    defer { Darwin.close(parent) }
    var status = stat()
    guard fstatat(parent, package.root.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) == 0,
      status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0,
      renameatx_np(parent, package.root.lastPathComponent, destination, name, UInt32(RENAME_EXCL))
        == 0
    else { throw PluginArchiveError.fileSystemFailure }
  }

  private static func makeDistributable(_ directory: Int32) throws {
    // A separate open file description leaves the owner's cleanup cursor untouched.
    let duplicate = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard duplicate >= 0 else { throw PluginArchiveError.fileSystemFailure }
    guard let stream = fdopendir(duplicate) else {
      Darwin.close(duplicate)
      throw PluginArchiveError.fileSystemFailure
    }
    defer { closedir(stream) }
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw PluginArchiveError.fileSystemFailure }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1_024) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      let child = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard child >= 0 else { throw PluginArchiveError.fileSystemFailure }
      defer { Darwin.close(child) }
      var status = stat()
      guard fstat(child, &status) == 0, status.st_uid == geteuid() else {
        throw PluginArchiveError.fileSystemFailure
      }
      switch status.st_mode & S_IFMT {
      case S_IFDIR: try makeDistributable(child)
      case S_IFREG:
        guard status.st_nlink == 1,
          fchmod(child, status.st_mode & 0o100 == 0 ? 0o644 : 0o755) == 0
        else { throw PluginArchiveError.fileSystemFailure }
      default: throw PluginArchiveError.unsupportedEntry
      }
    }
    guard fchmod(directory, 0o755) == 0 else { throw PluginArchiveError.fileSystemFailure }
  }
}
