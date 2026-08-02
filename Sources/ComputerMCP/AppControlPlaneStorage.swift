import Darwin
import Foundation

package struct AppControlPlaneServiceDirectories: Codable, Equatable, Sendable {
  package var applicationSupport: URL
  package var logs: URL
  package var configuration: URL
  package var tunnelClientProfiles: URL
  package var runtime: URL
  package var database: URL
  package var manifest: URL

  package init(applicationSupport: URL, logs: URL) {
    let support = applicationSupport.standardizedFileURL
    let logDirectory = logs.standardizedFileURL
    self.applicationSupport = support
    self.logs = logDirectory
    self.configuration = support.appendingPathComponent("Configuration", isDirectory: true)
    self.tunnelClientProfiles = support.appendingPathComponent(
      "Tunnel Client",
      isDirectory: true
    )
    self.runtime = support.appendingPathComponent("Runtime", isDirectory: true)
    self.database = support.appendingPathComponent("gateway.sqlite")
    self.manifest = configuration.appendingPathComponent("computer-mcp.toml")
  }

  package static func standard(fileManager: FileManager = .default) throws
    -> AppControlPlaneServiceDirectories
  {
    let supportRoot = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let library = try fileManager.url(
      for: .libraryDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return AppControlPlaneServiceDirectories(
      applicationSupport: supportRoot.appendingPathComponent("Computer MCP", isDirectory: true),
      logs:
        library
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("Computer MCP", isDirectory: true)
    )
  }

  package func prepare(fileManager: FileManager = .default) throws {
    for directory in [
      applicationSupport,
      logs,
      configuration,
      tunnelClientProfiles,
      runtime,
    ] {
      try Self.prepareDirectory(directory, fileManager: fileManager)
    }
  }

  package var gatewaySocket: URL {
    runtime.appendingPathComponent("gateway.sock")
  }

  package var controlSocket: URL {
    runtime.appendingPathComponent("control.sock")
  }

  package var openAITunnelGatewayCredential: URL {
    runtime.appendingPathComponent("gateway.sock.openai-tunnel-auth")
  }

  package func secureDatabaseFiles(fileManager: FileManager = .default) throws {
    for suffix in ["", "-wal", "-shm"] {
      let path = database.path + suffix
      if fileManager.fileExists(atPath: path) {
        try fileManager.setAttributes(
          [.posixPermissions: NSNumber(value: Int16(0o600))],
          ofItemAtPath: path
        )
      }
    }
  }

  private static func prepareDirectory(_ url: URL, fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw AppControlPlaneServiceError.invalidDirectory(url.path)
      }
      let resourceValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard resourceValues.isSymbolicLink != true else {
        throw AppControlPlaneServiceError.symbolicLinkDirectory(url.path)
      }
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      if let owner = attributes[.ownerAccountID] as? NSNumber,
        owner.uint32Value != getuid()
      {
        throw AppControlPlaneServiceError.directoryOwnedByAnotherUser(url.path)
      }
    } else {
      try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
    }
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: url.path
    )
  }
}
