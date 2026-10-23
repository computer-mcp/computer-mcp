import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite

final class CapabilityFixturePlanTests {
  @Test(arguments: [GatewayProfileID.chatGPTObserve, .cloudflareObserve])
  func testObserveProfileHasBoundedFixtureArgumentsForEveryTool(profile: GatewayProfileID) throws {
    let manifestURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("computer-mcp-observe-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: manifestURL) }
    try ValidationDefaultManifest.write(to: manifestURL)
    let observeCapabilities = try ValidationToolInventoryContract.load(
      configurationURL: manifestURL,
      caller: profile == .chatGPTObserve ? .secureTunnel : .cloudflareTunnel,
      profileID: profile
    ).tools.map(\.name)
    let plan = CapabilityFixturePlan(
      projectID: "fixture",
      repositoryProjectID: "repository",
      fixturePrefix: ".",
      skillRootID: "codex-user",
      skillName: "github-swift-package-issue-workflow",
      accessibilityProcessID: 123,
      loopbackHTTPURL: URL(string: "http://127.0.0.1:64884/health")!
    )

    let unsupported = observeCapabilities.filter {
      plan.invocation(for: $0, pointerPosition: (x: 100, y: 100)) == nil
    }

    #expect(!observeCapabilities.isEmpty)
    #expect(observeCapabilities.contains("delivery.scopes.list"))
    #expect(!observeCapabilities.contains("delivery.apply"))
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
    #expect((plan.invocation(for: "file.write")?.execution) == (.committed))
    #expect((plan.invocation(for: "archive.create")?.execution) == (.committed))

    let repositoryPlan = CapabilityFixturePlan(
      projectID: "fixture",
      repositoryProjectID: "repository",
      accessibilityProcessID: 123
    )
    #expect((repositoryPlan.invocation(for: "git.add")?.execution) == (.committed))
    #expect((repositoryPlan.invocation(for: "git.branch_create")?.execution) == (.direct))
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
    #expect((plan.invocation(for: "mcp.tools.call")?.execution) == (.committed))
    #expect((plan.invocation(for: "mcp.requests.cancel")) == nil)
  }

}
