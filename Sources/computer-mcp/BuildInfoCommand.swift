import ArgumentParser
import ComputerMCP
import CryptoKit
import Foundation

struct BuildInfo: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "build-info",
    abstract: "Print the signed release identity for this CLI executable."
  )

  func run() throws {
    let executableURL = try Self.executableURL()
    let identityURL = executableURL.deletingLastPathComponent()
      .appendingPathComponent("ComputerMCPBuildIdentity.plist")
    let identity = try Self.identity(at: identityURL)
    let actualDigest = try Self.sha256(of: executableURL)
    let expectedDigest = identity?["embedded_cli_sha256"] as? String

    printJSON(
      .object([
        "schema_version": .number(1),
        "version": .string(identity?["version"] as? String ?? ComputerMCPCLI.version),
        "build": .string(identity?["build"] as? String ?? ComputerMCPCLI.build),
        "source_commit": optionalString(identity?["source_commit"] as? String),
        "team_identifier": optionalString(identity?["team_identifier"] as? String),
        "architectures": .array(
          (identity?["architectures"] as? [String] ?? []).sorted().map(JSONValue.string)
        ),
        "embedded_cli_sha256": .string(actualDigest),
        "embedded_cli_digest_matches": .bool(
          expectedDigest.map { $0 == actualDigest } ?? false
        ),
        "identity_resource": .string(
          identity == nil ? "unavailable" : "signed-app-resource"
        ),
      ])
    )
  }

  private static func executableURL() throws -> URL {
    guard let argument = ProcessInfo.processInfo.arguments.first, !argument.isEmpty else {
      throw ValidationError("Unable to locate the running computer-mcp executable.")
    }
    let url: URL
    if argument.hasPrefix("/") {
      url = URL(fileURLWithPath: argument)
    } else {
      url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(argument)
    }
    return url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func identity(at url: URL) throws -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let object = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: url),
      options: [],
      format: nil
    )
    guard let identity = object as? [String: Any],
      identity["schema_version"] as? Int == 1
    else {
      throw ValidationError("The signed build identity resource is malformed.")
    }
    return identity
  }

  private static func sha256(of url: URL) throws -> String {
    let digest = SHA256.hash(data: try Data(contentsOf: url))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

private func optionalString(_ value: String?) -> JSONValue {
  value.map(JSONValue.string) ?? .null
}
