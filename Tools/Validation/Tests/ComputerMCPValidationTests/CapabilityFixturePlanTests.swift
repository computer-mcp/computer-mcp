import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite

final class CapabilityFixturePlanTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["COMPUTER_MCP_EXECUTABLE"] != nil,
      "Set COMPUTER_MCP_EXECUTABLE to the native host CLI for catalog acceptance."),
    arguments: [GatewayProfileID.chatGPTObserve, .cloudflareObserve])
  func testPublicCatalogHasRequirementsAndBoundedIndependentReadFixtures(profile: GatewayProfileID)
    throws
  {
    let manifestURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("computer-mcp-observe-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: manifestURL) }
    try ValidationDefaultManifest.write(to: manifestURL)
    let tools = try ValidationToolInventoryContract.load(
      configurationURL: manifestURL,
      caller: profile == .chatGPTObserve ? .secureTunnel : .cloudflareTunnel,
      profileID: profile
    ).tools
    let readCapabilities = tools.filter(\.isIndependentReadProbe).map(\.name)
    let plan = CapabilityFixturePlan(
      projectID: "fixture",
      repositoryProjectID: "repository",
      fixturePrefix: ".",
      skillRootID: "codex-user",
      skillName: "github-swift-package-issue-workflow",
      accessibilityProcessID: 123,
      loopbackHTTPURL: URL(string: "http://127.0.0.1:64884/health")!
    )

    let unsupported = readCapabilities.filter {
      plan.invocation(for: $0, pointerPosition: (x: 100, y: 100)) == nil
    }

    #expect(!readCapabilities.isEmpty)
    #expect(!tools.contains { $0.name.hasPrefix("delivery.") })
    #expect(tools.contains { $0.name == "project.request" })
    #expect(!readCapabilities.contains("project.request"))
    #expect(!readCapabilities.contains("process.read"))
    #expect(readCapabilities.contains("runtime.owners.list"))
    for tool in tools {
      #expect(
        tool.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil,
        "Missing requirements: \(tool.name)")
    }
    #expect((unsupported) == ([]))
    #expect(
      plan.invocation(for: "project.executable_files")?.arguments["include_hidden"]
        == .bool(true)
    )
    #expect(
      plan.invocation(for: "project.symlinks")?.arguments["include_hidden"] == .bool(true)
    )
  }

  @Test
  func testExternalFixtureBindingsFailClosedWhenUnavailable() {
    let plan = CapabilityFixturePlan(
      projectID: "fixture",
      accessibilityProcessID: 123
    )

    #expect((plan.invocation(for: "git.status")) == nil)
    #expect((plan.invocation(for: "network.http_check")) == nil)
    #expect((plan.invocation(for: "network.tcp_check")) == nil)
    #expect((plan.invocation(for: "file.read")) != nil)

  }

  @Test
  func testOperateProviderReadsAndProcessListHaveBoundedFixtures() {
    let plan = CapabilityFixturePlan(
      projectID: "fixture",
      accessibilityProcessID: 123
    )
    let supported = [
      "process.list",
      "mcp.events.read",
      "mcp.prompts.get",
      "mcp.prompts.list",
      "mcp.requests.list",
      "mcp.resources.list",
      "mcp.resources.read",
      "mcp.resources.templates.list",
      "mcp.servers.list",
      "mcp.servers.status",
      "mcp.tools.describe",
      "mcp.tools.find",
      "mcp.tools.list",
    ]

    #expect((supported.filter { plan.invocation(for: $0) == nil }) == ([]))
    #expect((plan.invocation(for: "mcp.requests.cancel")) == nil)
  }

}
