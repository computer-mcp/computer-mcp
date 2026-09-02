import CryptoKit
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
final class ArtifactProvenanceTests {
  @Test
  func testDevelopmentArtifactCannotUseFinalReleaseIdentity() throws {
    let fixture = try ArtifactProvenanceFixture()
    defer { fixture.remove() }
    let finalLooking = fixture.directory.appendingPathComponent(
      "Computer-MCP-1.0.28-universal.dmg"
    )
    try Data("development-bytes".utf8).write(to: finalLooking)
    let rejectedReceipt = fixture.directory.appendingPathComponent("rejected.json")
    let rejected = try fixture.writeReceipt(
      artifact: finalLooking,
      receipt: rejectedReceipt,
      artifactClass: "development",
      environment: fixture.developmentEnvironment
    )
    #expect(rejected.exitCode != 0)
    #expect(rejected.stderr.contains("development artifact names"))
    #expect(!FileManager.default.fileExists(atPath: rejectedReceipt.path))

    let development = fixture.directory.appendingPathComponent(
      "Computer-MCP-1.0.28-development-local-001-universal.dmg"
    )
    try Data("development-bytes".utf8).write(to: development)
    let receipt = fixture.directory.appendingPathComponent(
      "Computer-MCP-1.0.28-development-local-001-ArtifactProvenance.json"
    )
    let written = try fixture.writeReceipt(
      artifact: development,
      receipt: receipt,
      artifactClass: "development",
      environment: fixture.developmentEnvironment
    )
    #expect(written.exitCode == 0)
    let verified = try fixture.verifyReceipt(
      receipt: receipt,
      artifact: development,
      artifactClass: "development"
    )
    #expect(verified.exitCode == 0)
    let json = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(contentsOf: receipt)
    )
    #expect(json.objectValue?["artifact"]?.objectValue?["class"] == .string("development"))
    #expect(json.objectValue?["release"]?.objectValue?["tag"] == .null)
    #expect(
      json.objectValue?["published_asset"]?.objectValue?["byte_identical"] == .bool(false)
    )
  }

  @Test
  func testPublishedReceiptBindsCommitTagChecksumNotarizationAndStapling() throws {
    let fixture = try ArtifactProvenanceFixture()
    defer { fixture.remove() }
    let artifact = fixture.directory.appendingPathComponent(
      "Computer-MCP-1.0.28-universal.dmg"
    )
    let bytes = Data("exact-published-release-bytes".utf8)
    try bytes.write(to: artifact)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let receipt = fixture.directory.appendingPathComponent(
      "Computer-MCP-1.0.28-PublishedArtifactProvenance.json"
    )
    let sourceCommit = String(repeating: "a", count: 40)
    let environment: [String: String] = [
      "SOURCE_COMMIT": sourceCommit,
      "RELEASE_COMMIT": sourceCommit,
      "RELEASE_TAG": "v1.0.28",
      "BUILD_IDENTITY": "1.0.28-28-aaaaaaaaaaaa",
      "CREATION_PHASE": "published_asset_verification",
      "APP_NOTARIZATION_STATE": "accepted",
      "DMG_NOTARIZATION_STATE": "accepted",
      "APP_NOTARIZATION_ID": "11111111-1111-1111-1111-111111111111",
      "DMG_NOTARIZATION_ID": "22222222-2222-2222-2222-222222222222",
      "APP_STAPLE_STATE": "validated",
      "DMG_STAPLE_STATE": "validated",
      "PUBLISHED_ASSET_SHA256": digest,
      "BYTE_IDENTICAL_TO_PUBLISHED_ASSET": "true",
    ]
    let written = try fixture.writeReceipt(
      artifact: artifact,
      receipt: receipt,
      artifactClass: "exact_published_release",
      environment: environment
    )
    #expect(written.exitCode == 0)
    let verified = try fixture.verifyReceipt(
      receipt: receipt,
      artifact: artifact,
      artifactClass: "exact_published_release"
    )
    #expect(verified.exitCode == 0)

    let json = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(contentsOf: receipt)
    )
    #expect(json.objectValue?["source"]?.objectValue?["commit"] == .string(sourceCommit))
    #expect(json.objectValue?["release"]?.objectValue?["tag"] == .string("v1.0.28"))
    #expect(json.objectValue?["artifact"]?.objectValue?["sha256"] == .string(digest))
    #expect(
      json.objectValue?["notarization"]?.objectValue?["dmg"]?.objectValue?["state"]
        == .string("accepted")
    )
    #expect(json.objectValue?["stapling"]?.objectValue?["dmg"] == .string("validated"))
    #expect(
      json.objectValue?["published_asset"]?.objectValue?["byte_identical"] == .bool(true)
    )

    let originalBuildIdentity = try Data(contentsOf: fixture.buildIdentity)
    try Data("tampered-identity".utf8).append(to: fixture.buildIdentity)
    let tamperedIdentity = try fixture.verifyReceipt(
      receipt: receipt,
      artifact: artifact,
      artifactClass: "exact_published_release"
    )
    #expect(tamperedIdentity.exitCode != 0)
    #expect(tamperedIdentity.stderr.contains("build identity checksum differs"))
    try originalBuildIdentity.write(to: fixture.buildIdentity)

    try Data("tampered".utf8).append(to: artifact)
    let tampered = try fixture.verifyReceipt(
      receipt: receipt,
      artifact: artifact,
      artifactClass: "exact_published_release"
    )
    #expect(tampered.exitCode != 0)
    #expect(tampered.stderr.contains("checksum differs"))
  }
}

private struct ArtifactProvenanceFixture {
  let directory: URL
  let root: URL
  let writer: URL
  let verifier: URL
  let buildIdentity: URL
  let runner = ProcessCommandRunner()

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cm-artifact-provenance-\(UUID().uuidString)",
      isDirectory: true
    )
    root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    writer = root.appendingPathComponent("Scripts/write-artifact-provenance.sh")
    verifier = root.appendingPathComponent("Scripts/verify-artifact-provenance.sh")
    buildIdentity = directory.appendingPathComponent("ComputerMCPBuildIdentity.plist")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>source_commit</key><string>\(String(repeating: "d", count: 40))</string></dict></plist>
    """.write(to: buildIdentity, atomically: true, encoding: .utf8)
  }

  var developmentEnvironment: [String: String] {
    [
      "SOURCE_COMMIT": String(repeating: "d", count: 40),
      "BUILD_IDENTITY": "1.0.28-28-dddddddddddd",
      "BUILD_IDENTITY_PATH": buildIdentity.path,
      "CREATION_PHASE": "development",
    ]
  }

  func writeReceipt(
    artifact: URL,
    receipt: URL,
    artifactClass: String,
    environment: [String: String]
  ) throws -> CommandResult {
    let sourceCommit = environment["SOURCE_COMMIT"] ?? String(repeating: "d", count: 40)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>source_commit</key><string>\(sourceCommit)</string></dict></plist>
    """.write(to: buildIdentity, atomically: true, encoding: .utf8)
    return try runner.run(
      executable: writer.path,
      arguments: [artifact.path, receipt.path, artifactClass],
      workingDirectory: root,
      environment: environment.merging(["BUILD_IDENTITY_PATH": buildIdentity.path]) { current, _ in
        current
      },
      timeoutMilliseconds: 5_000,
      maxOutputBytes: 64 * 1_024
    )
  }

  func verifyReceipt(
    receipt: URL,
    artifact: URL,
    artifactClass: String
  ) throws -> CommandResult {
    try runner.run(
      executable: verifier.path,
      arguments: [receipt.path, artifact.path, artifactClass],
      workingDirectory: root,
      environment: ["BUILD_IDENTITY_PATH": buildIdentity.path],
      timeoutMilliseconds: 5_000,
      maxOutputBytes: 64 * 1_024
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

extension Data {
  fileprivate func append(to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: self)
  }
}
