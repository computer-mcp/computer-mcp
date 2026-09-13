import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct BundledPluginDistributionTests {
  @Test
  func actualDistributionArchiveLoadsWithoutGrantsOrExternalExecution() async throws {
    let files = try ArchiveFixture()
    defer { files.remove() }
    let output = files.root.appendingPathComponent("Plugins")
    let artifacts = try await BundledPluginDistribution.prepare(
      index: Self.repository.appendingPathComponent("Resources/PluginArchives/index.json"),
      destination: output, workerExecutable: Self.worker,
      hostVersion: PluginVersion(ComputerMCPCLI.version), architectures: ["arm64", "x86_64"])
    #expect(artifacts.map(\.id) == ["computer-use"])
    let inventory = BundledPlugins.load(directory: output)
    #expect(inventory.issues.isEmpty)
    let package = try #require(inventory.packages.first)
    #expect(package.manifest.mcp.first?.executable?.dependency == "computer-use-client")
    #expect(package.manifest.mcp.first?.args == ["mcp"])
    #expect(package.manifest.skills.first?.path == "skills")
    let snapshot = try PluginHostSnapshot(state: PluginStoreSnapshot(), bundled: inventory)
    #expect(snapshot.state == PluginStoreSnapshot())
    #expect(!snapshot.settings(for: "computer-use").enabled)
    #expect(snapshot.contributions.isEmpty)
    let guidance = try String(
      contentsOf: package.root.appendingPathComponent("skills/observe-act-verify/SKILL.md"),
      encoding: .utf8)
    #expect(guidance.contains("# Observe, Act, Verify"))
    #expect(!guidance.contains("[TODO"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["computer-use"])
    #expect(
      try Set(FileManager.default.contentsOfDirectory(atPath: package.root.path))
        == [
          "README.md", "CONTRIBUTING.md", "Documentation", "computer-mcp-plugin.toml", "skills",
          "LICENSE", "THIRD_PARTY_NOTICES.md", "ThirdPartyNotices.txt",
        ])
    #expect(
      try Data(contentsOf: package.root.appendingPathComponent("LICENSE"))
        == Data(contentsOf: Self.repository.appendingPathComponent("LICENSE")))
    for name in ["THIRD_PARTY_NOTICES.md", "ThirdPartyNotices.txt"] {
      #expect(try !Data(contentsOf: package.root.appendingPathComponent(name)).isEmpty)
    }
    #expect(
      package.manifest.dependencies.first?.applications.first?.bundleIdentifier
        == "com.openai.sky.CUAService")
    #expect(try Self.mode(output) == 0o755)
    #expect(try Self.mode(package.root.appendingPathComponent(PluginManifest.filename)) == 0o644)
  }

  @Test
  func combinedPackagePreservesExecutableBitsWithoutRunningHelpers() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let index = try Self.index(fixture)
    let output = fixture.files.root.appendingPathComponent("Plugins")
    _ = try await Self.prepare(index: index, output: output, architectures: ["arm64"])
    let package = try #require(BundledPlugins.load(directory: output).packages.first)
    #expect(package.manifest.mcp.count == 1)
    #expect(package.manifest.cli.count == 1)
    #expect(package.manifest.skills.count == 1)
    #expect(try Self.mode(package.root.appendingPathComponent("helper")) == 0o755)
    #expect(
      !FileManager.default.fileExists(atPath: package.root.appendingPathComponent("executed").path))
    #expect(FileManager.default.fileExists(atPath: fixture.archive.path))
  }

  @Test(arguments: [
    "checksum", "identity", "version", "architectures", "unknown-field", "duplicate", "path",
    "linked-archive", "empty", "too-many",
  ])
  func invalidInputNeverLeavesAPartialDistribution(failure: String) async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let output = fixture.files.root.appendingPathComponent("Plugins")
    let sentinel = fixture.files.root.appendingPathComponent("keep")
    try Data("user-owned".utf8).write(to: sentinel)
    var artifact: [String: Any] = [
      "id": "combined", "version": "1.2.3", "archive": fixture.archive.lastPathComponent,
      "sha256": fixture.digest,
    ]
    switch failure {
    case "checksum": artifact["sha256"] = String(repeating: "0", count: 64)
    case "identity": artifact["id"] = "other"
    case "version": artifact["version"] = "2.0.0"
    case "unknown-field": artifact["official"] = true
    case "path": artifact["archive"] = "../outside.zip"
    case "linked-archive":
      let link = fixture.files.root.appendingPathComponent("link.zip")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.archive)
      artifact["archive"] = "link.zip"
    default: break
    }
    let entries = Array(
      repeating: artifact,
      count: failure == "empty" ? 0 : failure == "duplicate" ? 2 : failure == "too-many" ? 129 : 1)
    let index = fixture.files.root.appendingPathComponent("index.json")
    try JSONSerialization.data(withJSONObject: entries).write(to: index)
    await #expect(throws: (any Error).self) {
      _ = try await Self.prepare(
        index: index, output: output,
        architectures: failure == "architectures" ? ["arm64", "x86_64"] : ["arm64"])
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "user-owned")
    #expect(FileManager.default.fileExists(atPath: fixture.archive.path))
  }

  @Test(arguments: [false, true])
  func existingOutputAndLinksAreNeverOverwritten(link: Bool) async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let index = try Self.index(fixture)
    let output = fixture.files.root.appendingPathComponent("Plugins")
    if link {
      try FileManager.default.createSymbolicLink(at: output, withDestinationURL: fixture.staging)
    } else {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    }
    let sentinel = output.appendingPathComponent("keep")
    try Data("keep".utf8).write(to: sentinel)
    await #expect(throws: PluginArchiveError.conflictingPath) {
      _ = try await Self.prepare(index: index, output: output, architectures: ["arm64"])
    }
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
  }

  @Test
  func laterFailureReclaimsEarlierPackagesWithoutTouchingSourceArchives() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let index = try Self.index(fixture)
    var entries = try JSONDecoder().decode(
      [BundledPluginArtifact].self, from: Data(contentsOf: index))
    entries.append(
      BundledPluginArtifact(
        id: "missing", version: try PluginVersion("1.0.0"), archive: "missing.zip",
        sha256: fixture.digest))
    try JSONEncoder().encode(entries).write(to: index)
    let output = fixture.files.root.appendingPathComponent("Plugins")
    await #expect(throws: PluginArchiveError.invalidInput) {
      _ = try await Self.prepare(index: index, output: output, architectures: ["arm64"])
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(FileManager.default.fileExists(atPath: fixture.archive.path))
  }

  private static var repository: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  private static var worker: URL {
    repository.appendingPathComponent(".build/out/Products/Debug/computer-mcp")
  }

  private static func prepare(index: URL, output: URL, architectures: [String]) async throws
    -> [BundledPluginArtifact]
  {
    try await BundledPluginDistribution.prepare(
      index: index, destination: output, workerExecutable: worker,
      hostVersion: PluginVersion("1.0.0"), architectures: architectures)
  }

  private static func index(_ fixture: PreparationFixture) throws -> URL {
    let index = fixture.files.root.appendingPathComponent("index.json")
    let entry = BundledPluginArtifact(
      id: "combined", version: try PluginVersion("1.2.3"),
      archive: fixture.archive.lastPathComponent, sha256: fixture.digest)
    try JSONEncoder().encode([entry]).write(to: index)
    return index
  }

  private static func mode(_ file: URL) throws -> mode_t {
    var status = stat()
    try #require(lstat(file.path, &status) == 0)
    return status.st_mode & 0o777
  }
}
