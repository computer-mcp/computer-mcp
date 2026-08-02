import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite

final class CapabilityInventoryTests {
  @Test
  func testGatewaySocketCatalogReportEncodesSortedToolEvidence() throws {
    let report = GatewaySocketCatalogReport(
      generatedAt: "2026-07-31T02:00:00Z",
      socketPath: "/tmp/computer-mcp.sock",
      protocolVersion: "2025-11-25",
      serverName: "computer-mcp",
      serverVersion: "1",
      tools: []
    )

    #expect((report.schemaVersion) == (1))
    #expect((report.toolCount) == (0))
    #expect((report.toolNames) == ([]))
    let encoded = try #require(String(data: report.encodedJSON(), encoding: .utf8))
    #expect(encoded.contains("\"protocol_version\" : \"2025-11-25\""))
    #expect(encoded.contains("\"socket_path\" : \"/tmp/computer-mcp.sock\""))
    #expect(!encoded.contains("\"protocolVersion\""))
  }

  @Test
  func testBuildsSortedDeterministicInventory() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    try profile(serverName: "Zulu", builtins: ["system.uptime"]).write(
      to: directory.appendingPathComponent("computer-mcp-z.toml"),
      atomically: true,
      encoding: .utf8
    )
    try profile(serverName: "Alpha", builtins: ["system.time", "system.uptime"]).write(
      to: directory.appendingPathComponent("computer-mcp-a.toml"),
      atomically: true,
      encoding: .utf8
    )
    try "not a gateway profile".write(
      to: directory.appendingPathComponent("sample.toml"),
      atomically: true,
      encoding: .utf8
    )

    let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let builder = CapabilityInventoryBuilder()
    let first = try builder.build(
      examplesDirectory: directory,
      generatedAt: generatedAt
    )
    let second = try builder.build(
      examplesDirectory: directory,
      generatedAt: generatedAt
    )

    #expect((first) == (second))
    #expect((first.schemaVersion) == (1))
    #expect((first.generatedAt) == ("2023-11-14T22:13:20Z"))
    #expect(
      (first.profiles.map(\.configuration)) == (["computer-mcp-a.toml", "computer-mcp-z.toml"]))
    #expect((first.summary.profileCount) == (2))
    #expect((first.summary.issueCount) == (0))
    #expect(first.isValid)

    for profile in first.profiles {
      #expect((profile.toolNames) == (profile.toolNames.sorted()))
      #expect((profile.toolCount) == (profile.tools.count))
      #expect((profile.toolNames) == (profile.tools.map(\.name)))
      #expect(profile.duplicateToolNames.isEmpty)
      #expect(!(profile.domains.isEmpty))
      let hasInputSchemas = profile.tools.allSatisfy(\.hasInputSchema)
      let hasOutputSchemas = profile.tools.allSatisfy(\.hasOutputSchema)
      let hasAnnotations = profile.tools.allSatisfy(\.hasAnnotations)
      #expect(hasInputSchemas)
      #expect(hasOutputSchemas)
      #expect(hasAnnotations)
    }

    let alpha = try #require(first.profiles.first)
    #expect((alpha.serverName) == ("Alpha"))
    #expect((alpha.caller) == ("local-mcp"))
    #expect((alpha.profile) == ("local-admin"))
    #expect(alpha.toolNames.contains("system.time"))
    #expect(alpha.domains.contains(where: { $0.name == "system" }))
  }

  @Test("Encoded inventory is accepted by the report input decoder")
  func inventoryJSONRoundTrip() throws {
    let original = CapabilityInventoryReport(
      generatedAt: "2026-08-03T00:00:00Z",
      summary: CapabilityInventorySummary(
        profileCount: 0,
        profileToolCount: 0,
        uniqueToolCount: 0,
        issueCount: 0
      ),
      profiles: [],
      issues: []
    )

    let encoded = try original.encodedJSON()
    let decoded = try CapabilityInventoryReport.decodeJSON(encoded)

    #expect(decoded == original)
    #expect(String(decoding: encoded, as: UTF8.self).contains("\"schema_version\""))
  }

  @Test("Inventory decoder rejects a noncurrent schema")
  func inventoryRejectsNoncurrentSchema() throws {
    let data = Data(
      """
      {"schema_version":2,"generated_at":"2026-08-03T00:00:00Z","summary":{"profile_count":0,"profile_tool_count":0,"unique_tool_count":0,"issue_count":0},"profiles":[],"issues":[]}
      """.utf8
    )

    expectThrows(try CapabilityInventoryReport.decodeJSON(data)) { error in
      #expect(
        error as? ValidationArtifactError
          == .unsupportedSchema(artifact: "Capability Inventory", expected: 1, actual: 2)
      )
    }
  }

  @Test("Inventory decoder rejects fields outside the current schema")
  func inventoryRejectsUnknownField() throws {
    let data = Data(
      """
      {"schema_version":1,"generated_at":"2026-08-03T00:00:00Z","summary":{"profile_count":0,"profile_tool_count":0,"unique_tool_count":0,"issue_count":0},"profiles":[],"issues":[],"unexpected":true}
      """.utf8
    )

    expectThrows(try CapabilityInventoryReport.decodeJSON(data)) { error in
      #expect(
        error as? ValidationArtifactError
          == .noncanonicalShape(artifact: "Capability Inventory")
      )
    }
  }

  @Test
  func testReportsNoProfilesWithoutReadingUnrelatedFiles() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let secret = "never-include-this-value"
    try secret.write(
      to: directory.appendingPathComponent("sample.toml"),
      atomically: true,
      encoding: .utf8
    )

    let report = try CapabilityInventoryBuilder().build(
      examplesDirectory: directory,
      generatedAt: Date(timeIntervalSince1970: 0)
    )
    let json = try #require(String(data: report.encodedJSON(), encoding: .utf8))
    let markdown = report.markdown()

    #expect((report.profiles) == ([]))
    #expect((report.issues.map(\.code)) == (["inventory.no_profiles"]))
    #expect(!(report.isValid))
    #expect(!(json.contains(secret)))
    #expect(!(markdown.contains(secret)))
  }

  @Test
  func testIncludesGeneratedRuntimeConfigurationsWithoutWritingFixtures() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("runtime-default.toml")
    try ValidationDefaultManifest.write(to: manifestURL)

    let report = try CapabilityInventoryBuilder().build(
      examplesDirectory: directory,
      additionalConfigurations: [
        CapabilityInventoryConfiguration(
          name: "runtime-default.chatgpt-operate.toml",
          configurationURL: manifestURL,
          caller: .secureTunnel,
          profileID: .chatGPTOperate,
          requiresRuntimeEvidence: true
        ),
        CapabilityInventoryConfiguration(
          name: "runtime-default.chatgpt-observe.toml",
          configurationURL: manifestURL,
          caller: .secureTunnel,
          profileID: .chatGPTObserve,
          requiresRuntimeEvidence: true
        ),
      ],
      generatedAt: Date(timeIntervalSince1970: 0)
    )

    #expect(
      (report.profiles.map(\.configuration))
        == ([
          "runtime-default.chatgpt-observe.toml",
          "runtime-default.chatgpt-operate.toml",
        ]))
    #expect((report.summary.profileCount) == (2))
    #expect((report.summary.issueCount) == (0))
    #expect(report.isValid)
    let observeInventory = try ValidationToolInventoryContract.load(
      configurationURL: manifestURL,
      caller: .secureTunnel,
      profileID: .chatGPTObserve
    )
    #expect((Set(report.profiles[0].toolNames)) == (Set(observeInventory.tools.map(\.name))))
    #expect(report.profiles[1].toolNames.contains("file.write"))
    #expect(!(report.profiles[1].toolNames.contains("cli.exec")))
    #expect(report.profiles.allSatisfy { $0.requiresRuntimeEvidence })
    #expect(report.profiles.allSatisfy { $0.acceptanceDigest.count == 64 })
  }

  @Test
  func testManifestFixtureGenerateConfigurationsPreserveProviderAndVersionNames() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("acceptance-candidate.toml")
    let manifest =
      String(decoding: try ValidationDefaultManifest.data(), as: UTF8.self)
        + """


        [[mcp.servers]]
        id = "fixture"
        transport = "stdio"
        command = "/usr/bin/true"
        exposure = "gateway"
        capabilities = ["tools", "resources", "prompts"]
        allowed_tools = ["fixture_echo"]
        """
    try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

    let configurations = try CapabilityInventoryConfiguration.runtimeManifest(
      at: manifestURL
    )
    let report = try CapabilityInventoryBuilder().build(
      examplesDirectory: directory,
      additionalConfigurations: configurations,
      generatedAt: Date(timeIntervalSince1970: 0)
    )

    #expect(
      (report.profiles.map(\.configuration))
        == ([
          "acceptance-candidate.chatgpt-observe.toml",
          "acceptance-candidate.chatgpt-operate.toml",
          "acceptance-candidate.cloudflare-observe.toml",
          "acceptance-candidate.cloudflare-operate.toml",
          "acceptance-candidate.local-admin.toml",
        ]))
    #expect(
      (Set(report.profiles.map(\.profile))) == (Set(GatewayProfileID.builtIns.map(\.rawValue))))
    #expect(
      (report.profiles.first { $0.profile == GatewayProfileID.chatGPTOperate.rawValue }?
        .toolNames.contains("mcp.resources.read")) == (true))
    #expect(
      report.profiles.filter { $0.profile != GatewayProfileID.localAdmin.rawValue }
        .allSatisfy { $0.requiresRuntimeEvidence }
    )
    #expect(
      report.profiles.first { $0.profile == GatewayProfileID.localAdmin.rawValue }?
        .requiresRuntimeEvidence == false
    )
    #expect(report.isValid)
  }

  @Test
  func testReportsFailedProfileWithoutLeakingFileContents() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let secret = """
      schema_version = 999
      # do-not-report-this
      """
    try secret.write(
      to: directory.appendingPathComponent("computer-mcp-invalid.toml"),
      atomically: true,
      encoding: .utf8
    )

    let report = try CapabilityInventoryBuilder().build(
      examplesDirectory: directory,
      generatedAt: Date(timeIntervalSince1970: 0)
    )
    let encoded = try #require(String(data: report.encodedJSON(), encoding: .utf8))

    #expect((report.profiles) == ([]))
    #expect((report.issues.count) == (1))
    #expect((report.issues.first?.code) == ("profile.inventory_failed"))
    #expect((report.issues.first?.configuration) == ("computer-mcp-invalid.toml"))
    #expect(!(encoded.contains("do-not-report-this")))
    #expect(!(encoded.contains(directory.path)))
  }

  @Test
  func testMarkdownIncludesProfileAndToolMetadata() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try profile(serverName: "Inventory", builtins: ["system.time"]).write(
      to: directory.appendingPathComponent("computer-mcp.toml"),
      atomically: true,
      encoding: .utf8
    )

    let report = try CapabilityInventoryBuilder().build(
      examplesDirectory: directory,
      generatedAt: Date(timeIntervalSince1970: 0)
    )
    let markdown = report.markdown()

    #expect(markdown.contains("# Computer MCP Capability Inventory"))
    #expect(markdown.contains("## computer-mcp.toml"))
    #expect(markdown.contains("`system.time`"))
    #expect(
      markdown.contains("| Tool | Domain | Input schema | Output schema | Annotations | Risk |"))
    #expect(markdown.hasSuffix("\n"))
  }

  @Test
  func testDynamicReexportIsReportedWithoutContactingDownstream() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = """
      schema_version = 1

      [[mcp.servers]]
      id = "must-not-run"
      transport = "stdio"
      command = "/path/that/does/not/exist"
      exposure = "reexport"
      prefix = "downstream"
      allow_any_tool = true
      """
    try configuration.write(
      to: directory.appendingPathComponent("computer-mcp-reexport.toml"),
      atomically: true,
      encoding: .utf8
    )

    let report = try CapabilityInventoryBuilder().build(
      examplesDirectory: directory,
      generatedAt: Date(timeIntervalSince1970: 0)
    )

    #expect((report.profiles.count) == (1))
    #expect((report.profiles.first?.configuration) == ("computer-mcp-reexport.toml"))
    #expect(report.profiles.first?.toolNames.contains("downstream.fixture") == false)
    #expect((report.issues.count) == (1))
    #expect((report.issues.first?.code) == ("profile.dynamic_reexport_unsupported"))
  }

  @Test
  func testMissingExamplesDirectoryThrowsStableError() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    expectThrows(
      try CapabilityInventoryBuilder().build(examplesDirectory: missing)
    ) { error in
      #expect((error as? CapabilityInventoryError) == (.examplesDirectoryUnavailable))
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func profile(serverName: String, builtins: [String]) -> String {
    let values = builtins.map { "\"\($0)\"" }.joined(separator: ", ")
    return """
      schema_version = 1

      [server]
      name = "\(serverName)"

      [builtin]
      enabled = [\(values)]
      """
  }
}
