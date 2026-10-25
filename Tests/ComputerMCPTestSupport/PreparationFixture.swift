import ComputerMCPPlatform
import ComputerMCPPlugins
import Crypto
import Foundation
import Testing

package struct PreparationFixture: Sendable {
  package let files: ArchiveFixture
  package let archive: URL
  package let digest: String
  package let staging: URL
  private let directoryFactory: any PluginArchiveDirectoryFactory

  package static let manifest = """
    id = 'combined'
    name = 'Combined'
    version = '1.2.3'
    plugin_api = 1
    [compatibility]
    minimum_host = '0.1.0'
    architectures = ['arm64']
    [[mcp]]
    id = 'native'
    transport = 'stdio'
    executable = { path = 'helper' }
    [[cli]]
    id = 'commands'
    executable = { path = 'helper' }
    [[skills]]
    id = 'guide'
    path = 'skills'
    """

  package static let platformManifest =
    manifest
    .replacingOccurrences(of: "architectures = ['arm64']", with: "platforms = ['macos']")
    .replacingOccurrences(
      of: "[[mcp]]",
      with: """
        [[compatibility.artifacts]]
        name = 'mac.zip'
        platforms = ['macos']
        architectures = ['arm64']
        [[compatibility.artifacts]]
        name = 'intel.zip'
        platforms = ['macos']
        architectures = ['x86_64']
        [[mcp]]
        """)

  package static func make(
    directoryFactory: any PluginArchiveDirectoryFactory,
    manifest: String = Self.manifest, format: String = "tar"
  ) async throws -> Self {
    try await blockingFixtureIO {
      try Self(directoryFactory: directoryFactory, manifest: manifest, format: format)
    }
  }

  private init(
    directoryFactory: any PluginArchiveDirectoryFactory, manifest: String, format: String
  ) throws {
    self.directoryFactory = directoryFactory
    files = try ArchiveFixture()
    archive = try files.archive(
      [
        .init(name: PluginManifest.filename, content: manifest),
        .init(name: "helper", content: "#!/bin/sh\ntouch executed\n", mode: 0o755),
        .init(name: "skills/SKILL.md", content: "# Fixture"),
      ], format: format)
    digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }
      .joined()
    staging = files.root.appendingPathComponent("jobs")
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }

  package var preparation: PluginArchivePreparation {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    return PluginArchivePreparation(
      workerExecutable: repository.appendingPathComponent(".build/debug/computer-mcp"),
      stagingParent: staging, directoryFactory: directoryFactory)
  }

  package func prepare<Result: Sendable>(
    worker: URL? = nil, timeout: Duration = .seconds(60),
    operation: @Sendable (PluginPackage, PluginArchiveReceipt) async throws -> Result
  ) async throws -> Result {
    var preparation = preparation
    if let worker {
      preparation = PluginArchivePreparation(
        workerExecutable: worker, stagingParent: staging, directoryFactory: directoryFactory)
    }
    preparation.timeout = timeout
    return try await preparation.withPreparedPackage(
      archive: archive, expectedSHA256: digest, pluginID: "combined",
      version: PluginVersion("1.2.3"),
      hostVersion: PluginVersion("1.0.0"), architecture: "arm64", operation: operation)
  }

  package func currentDigest() throws -> String {
    SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
  }

  package func stagingContents() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
  }

  package func literal(_ value: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  package func stub(_ script: String) async throws -> URL {
    try await blockingFixtureIO { try writeStub(script) }
  }

  private func writeStub(_ script: String) throws -> URL {
    let executable = files.root.appendingPathComponent("worker")
    try writePythonTestExecutable(script, to: executable)
    return executable
  }
}

/// Foundation Process waits used to manufacture fixtures must not occupy Swift
/// cooperative executor threads while unrelated cancellation timers need them.
private func blockingFixtureIO<Result: Sendable>(
  _ operation: @escaping @Sendable () throws -> Result
) async throws -> Result {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(with: Swift.Result { try operation() })
    }
  }
}
