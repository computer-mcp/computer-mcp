import Darwin
import Foundation

package enum EmbeddedCLIInstallationState: String, Codable, Equatable, Sendable {
  case notInstalled = "not-installed"
  case installed
  case brokenLink = "broken-link"
  case wrongTarget = "wrong-target"
  case occupied
}

package struct EmbeddedCLIInstallationStatus: Codable, Equatable, Sendable {
  package let state: EmbeddedCLIInstallationState
  package let destination: String
  package let target: String?
  package let destinationDirectoryIsOnPath: Bool

  private enum CodingKeys: String, CodingKey {
    case state
    case destination
    case target
    case destinationDirectoryIsOnPath = "destination_directory_is_on_path"
  }
}

package struct EmbeddedCLIInstaller {
  private let fileManager: FileManager
  private let environment: [String: String]

  package init(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.fileManager = fileManager
    self.environment = environment
  }

  package func defaultDestination() -> URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/bin", isDirectory: true)
      .appendingPathComponent("computer-mcp")
  }

  package func embeddedExecutable(bundle: Bundle = .main) -> URL {
    bundle.resourceURL?
      .appendingPathComponent("computer-mcp")
      .standardizedFileURL
      ?? bundle.bundleURL
      .appendingPathComponent("Contents/Resources", isDirectory: true)
      .appendingPathComponent("computer-mcp")
      .standardizedFileURL
  }

  package func status(destination: URL? = nil) throws -> EmbeddedCLIInstallationStatus {
    let destination = (destination ?? defaultDestination()).standardizedFileURL
    let directoryOnPath = pathEntries().contains(destination.deletingLastPathComponent().path)
    var status = stat()
    guard lstat(destination.path, &status) == 0 else {
      if errno == ENOENT {
        return EmbeddedCLIInstallationStatus(
          state: .notInstalled,
          destination: destination.path,
          target: nil,
          destinationDirectoryIsOnPath: directoryOnPath
        )
      }
      throw EmbeddedCLIInstallerError.posix("lstat", errno)
    }
    guard status.st_uid == getuid() else {
      throw EmbeddedCLIInstallerError.notOwned(destination.path)
    }
    guard status.st_mode & S_IFMT == S_IFLNK else {
      return EmbeddedCLIInstallationStatus(
        state: .occupied,
        destination: destination.path,
        target: nil,
        destinationDirectoryIsOnPath: directoryOnPath
      )
    }
    let target = try fileManager.destinationOfSymbolicLink(atPath: destination.path)
    let targetURL = URL(
      fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent()
    )
    .standardizedFileURL
    let exists = fileManager.isExecutableFile(atPath: targetURL.path)
    let isComputerMCP =
      targetURL.lastPathComponent == "computer-mcp"
      && Self.isEmbeddedAppExecutable(targetURL)
    return EmbeddedCLIInstallationStatus(
      state: !exists ? .brokenLink : (isComputerMCP ? .installed : .wrongTarget),
      destination: destination.path,
      target: targetURL.path,
      destinationDirectoryIsOnPath: directoryOnPath
    )
  }

  @discardableResult
  package func install(
    source: URL,
    destination: URL? = nil,
    replaceInvalidLink: Bool = false
  ) throws -> EmbeddedCLIInstallationStatus {
    let source = source.standardizedFileURL
    let destination = (destination ?? defaultDestination()).standardizedFileURL
    guard source.lastPathComponent == "computer-mcp",
      Self.isEmbeddedAppExecutable(source),
      fileManager.isExecutableFile(atPath: source.path)
    else {
      throw EmbeddedCLIInstallerError.notEmbeddedExecutable(source.path)
    }
    let directory = destination.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: directory.path
    )

    let current = try status(destination: destination)
    switch current.state {
    case .installed where current.target == source.path:
      return current
    case .notInstalled:
      break
    case .brokenLink, .wrongTarget:
      guard replaceInvalidLink else {
        throw EmbeddedCLIInstallerError.destinationConflict(destination.path)
      }
      try fileManager.removeItem(at: destination)
    case .installed:
      // A user-owned link to another Computer MCP app bundle is the normal
      // state during an app update. Replace that app-owned link without
      // requiring the broader invalid-link override.
      try fileManager.removeItem(at: destination)
    case .occupied:
      throw EmbeddedCLIInstallerError.destinationOccupied(destination.path)
    }
    try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
    return try status(destination: destination)
  }

  package func uninstall(destination: URL? = nil) throws {
    let destination = (destination ?? defaultDestination()).standardizedFileURL
    let current = try status(destination: destination)
    switch current.state {
    case .notInstalled:
      return
    case .installed, .brokenLink, .wrongTarget:
      try fileManager.removeItem(at: destination)
    case .occupied:
      throw EmbeddedCLIInstallerError.destinationOccupied(destination.path)
    }
  }

  private func pathEntries() -> Set<String> {
    Set((environment["PATH"] ?? "").split(separator: ":").map(String.init))
  }

  private static func isEmbeddedAppExecutable(_ url: URL) -> Bool {
    url.path.contains(".app/Contents/Resources/")
      || url.path.contains(".app/Contents/MacOS/")
  }
}

package enum EmbeddedCLIInstallerError: Error, LocalizedError, Equatable {
  case destinationConflict(String)
  case destinationOccupied(String)
  case notEmbeddedExecutable(String)
  case notOwned(String)
  case posix(String, Int32)

  package var errorDescription: String? {
    switch self {
    case .destinationConflict(let path):
      "A different or invalid CLI link exists at \(path); pass --replace-invalid-link after inspecting it."
    case .destinationOccupied(let path):
      "Refusing to replace the non-symlink item at \(path)."
    case .notEmbeddedExecutable(let path):
      "The CLI source is not the signed executable embedded in Computer MCP.app: \(path)"
    case .notOwned(let path):
      "The CLI link is not owned by the current user: \(path)"
    case .posix(let operation, let code):
      "\(operation) failed with POSIX error \(code): \(String(cString: strerror(code)))."
    }
  }
}
