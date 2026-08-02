import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite

final class CapabilityFixtureTests {
  @Test
  func testGeneratorCreatesCrossDomainFixturesThatRealToolsCanRead() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let report = try CapabilityFixtureGenerator().generate(
      at: root,
      generatedAt: Date(timeIntervalSince1970: 0)
    )

    #expect((report.schemaVersion) == (1))
    #expect((report.generatedAt) == ("1970-01-01T00:00:00.000Z"))
    #expect((report.rootPath) == (root.standardizedFileURL.resolvingSymlinksInPath().path))
    #expect(report.entries.contains { $0.path == "Artifacts/pixel.png" })
    #expect(report.entries.contains { $0.path == "Artifacts/report.pdf" })
    #expect(report.entries.contains { $0.path == "Artifacts/silence.wav" })
    #expect(report.entries.contains { $0.path == "Artifacts/sample.zip" })
    #expect(report.entries.contains { $0.path == "build/fixture-output.txt" })
    #expect(report.entries.contains { $0.path == ".swift-format" })
    #expect(report.entries.contains { $0.path == ".github/CODEOWNERS" })
    #expect(
      (report.entries.first { $0.path == "Xattrs/tagged.txt" }?.fixtureMetadata?[
        "com.showxu.computer-mcp.fixture"
      ]?.count) == (64))
    #expect(report.entries.contains { $0.path == "Data/sample.sqlite" })
    #expect(report.entries.contains { $0.path == "Links/readme.md" && $0.kind == "symlink" })
    #expect(report.entries.contains { $0.path == "Repository/staged.txt" })
    #expect(report.entries.contains { $0.path == "Repository/.fixture-ignored" })
    #expect(!(report.entries.contains { $0.path.hasPrefix("Repository/.git/") }))
    #expect((report.contentDigest.count) == (64))
    #expect(
      report.entries
        .filter { $0.kind == "file" || $0.kind == "symlink" }
        .allSatisfy { $0.contentDigest?.count == 64 })

    let decodedReport = try CapabilityFixtureReport.decodeJSON(report.encodedJSON())
    #expect(decodedReport == report)

    let configURL = try writeManifest(
      workspace: root,
      builtins: [
        "archive.list",
        "image.info",
        "json.read",
        "media.info",
        "pdf.text",
        "sqlite.schema",
      ]
    )
    defer { try? FileManager.default.removeItem(at: configURL) }

    #expect(
      (try payload(
        productCall(
          name: "json.read",
          arguments: .object(["path": .string("Data/sample.json")]),
          configURL: configURL
        )
      ).objectValue?["operation"]) == (.string("json.read")))
    #expect(
      (try payload(
        productCall(
          name: "image.info",
          arguments: .object(["path": .string("Artifacts/pixel.png")]),
          configURL: configURL
        )
      ).objectValue?["pixel_width"]) == (.number(1)))
    let pdfPayload = try payload(
      productCall(
        name: "pdf.text",
        arguments: .object(["path": .string("Artifacts/report.pdf")]),
        configURL: configURL
      )
    )
    #expect(
      String(decoding: try JSONEncoder().encode(pdfPayload), as: UTF8.self)
        .contains("Computer MCP fixture PDF page one"))
    #expect(
      (try payload(
        productCall(
          name: "media.info",
          arguments: .object(["path": .string("Artifacts/silence.wav")]),
          configURL: configURL
        )
      ).objectValue?["operation"]) == (.string("media.info")))
    #expect(
      (try payload(
        productCall(
          name: "sqlite.schema",
          arguments: .object(["path": .string("Data/sample.sqlite")]),
          configURL: configURL
        )
      ).objectValue?["operation"]) == (.string("sqlite.schema")))
    #expect(
      (try payload(
        productCall(
          name: "archive.list",
          arguments: .object(["path": .string("Artifacts/sample.zip")]),
          configURL: configURL
        )
      ).objectValue?["operation"]) == (.string("archive.list")))
  }

  @Test
  func testGitFixtureIncludesReusableReadOnlyStates() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try CapabilityFixtureGenerator().generate(at: root)

    let configURL = try writeManifest(
      workspace: root.appendingPathComponent("Repository"),
      builtins: [
        "git.branch",
        "git.remotes",
        "git.stashes",
        "git.status",
        "git.tags",
        "git.tracking_status",
      ],
      includeGit: true
    )
    defer { try? FileManager.default.removeItem(at: configURL) }

    let encoded = try [
      "git.branch",
      "git.remotes",
      "git.stashes",
      "git.status",
      "git.tags",
      "git.tracking_status",
    ]
    .map { name in
      try JSONEncoder().encode(
        payload(productCall(name: name, arguments: .object([:]), configURL: configURL))
      )
    }
    .reduce(into: Data()) { $0.append($1) }
    let text = String(decoding: encoded, as: UTF8.self)

    #expect(text.contains("fixture-base"))
    #expect(text.contains("origin"))
    #expect(text.contains("Fixture stash"))
    #expect(text.contains("staged.txt"))
    #expect(text.contains("untracked.txt"))
    #expect(text.contains("v0.1.0"))
    #expect(text.contains("upstream"))
  }

  @Test
  func testForceOnlyReplacesOwnedFixtureDirectory() throws {
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let owned = parent.appendingPathComponent("owned", isDirectory: true)
    let unowned = parent.appendingPathComponent("unowned", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let initial = try CapabilityFixtureGenerator().generate(
      at: owned,
      generatedAt: Date(timeIntervalSince1970: 0)
    )
    let regenerated = try CapabilityFixtureGenerator().generate(at: owned, force: true)
    #expect(!(regenerated.entries.isEmpty))
    #expect((regenerated.contentDigest) == (initial.contentDigest))

    try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
    try "user data".write(
      to: unowned.appendingPathComponent("keep.txt"),
      atomically: true,
      encoding: .utf8
    )
    expectThrows(
      try CapabilityFixtureGenerator().generate(at: unowned, force: true)
    ) { error in
      #expect(
        (error as? CapabilityFixtureError)
          == (.destinationNotOwned(
            unowned.standardizedFileURL.resolvingSymlinksInPath().path
          )))
    }
    #expect(
      FileManager.default.fileExists(
        atPath: unowned.appendingPathComponent("keep.txt").path
      ))
  }

  private func writeManifest(
    workspace: URL,
    builtins: [String],
    includeGit: Bool = false
  ) throws -> URL {
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("computer-mcp-fixture-\(UUID().uuidString).toml")
    let builtinValues = builtins.sorted().map { "  \(tomlString($0))," }.joined(separator: "\n")
    let git =
      includeGit
      ? """

      [[cli.commands]]
      id = "git"
      executable = "/usr/bin/git"
      cwd = "workspace"
      allow_any_args = true
      risk = "workspace-write-capable"
      discovery = ["help"]
      """
      : ""
    let manifest = """
      schema_version = 1

      [runtime]
      caller = "local-mcp"
      profile = "local-admin"

      [policy]
      shell_enabled = false

      [[workspaces]]
      id = "default"
      display_name = "Validation Fixture"
      path = \(tomlString(workspace.standardizedFileURL.path))

      [[profiles]]
      id = "local-admin"
      capabilities = ["*"]
      workspaces = ["default"]
      allowed_callers = ["local-mcp"]
      full_shell_enabled = false
      \(git)

      [builtin]
      enabled = [
      \(builtinValues)
      ]
      """
    try Data(manifest.utf8).write(to: destination, options: .atomic)
    _ = try ValidationProductCommand().run([
      "config", "validate", "--config", destination.path,
    ])
    return destination
  }

  private func productCall(
    name: String,
    arguments: JSONValue,
    configURL: URL
  ) throws -> JSONValue {
    let argumentData = try ValidationCanonicalJSONCoding.encoder().encode(arguments)
    let data = try ValidationProductCommand().run([
      "tools", "call", name,
      "--arguments-json", String(decoding: argumentData, as: UTF8.self),
      "--config", configURL.path,
      "--caller", "local-mcp",
      "--profile", "local-admin",
      "--workspace-id", "default",
    ])
    return try ValidationCanonicalJSONCoding.decoder().decode(JSONValue.self, from: data)
  }

  private func tomlString(_ value: String) -> String {
    "\""
      + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      + "\""
  }

  private func payload(_ result: JSONValue) throws -> JSONValue {
    try #require(
      result.objectValue?["structuredContent"]?.objectValue?["result"]
    )
  }
}
