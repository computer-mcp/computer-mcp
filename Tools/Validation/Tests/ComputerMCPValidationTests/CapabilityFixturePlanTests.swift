import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite

final class CapabilityFixturePlanTests {
  @Test
  func testObserveProfileHasBoundedFixtureArgumentsForEveryTool() throws {
    let manifestURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("computer-mcp-observe-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: manifestURL) }
    try ValidationDefaultManifest.write(to: manifestURL)
    let observeCapabilities = try ValidationToolInventoryContract.load(
      configurationURL: manifestURL,
      caller: .secureTunnel,
      profileID: .chatGPTObserve
    ).tools.map(\.name)
    let plan = CapabilityFixturePlan(
      workspaceID: "fixture",
      repositoryWorkspaceID: "repository",
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
    #expect((unsupported) == ([]))
    #expect(
      plan.invocation(for: "workspace.executable_files")?.arguments["include_hidden"]
        == .bool(true)
    )
    #expect(
      plan.invocation(for: "workspace.symlinks")?.arguments["include_hidden"] == .bool(true)
    )
  }

  @Test
  func testExternalFixtureBindingsFailClosedWhenUnavailable() {
    let plan = CapabilityFixturePlan(
      workspaceID: "fixture",
      accessibilityProcessID: 123
    )

    #expect((plan.invocation(for: "git.status")) == nil)
    #expect((plan.invocation(for: "network.http_check")) == nil)
    #expect((plan.invocation(for: "network.tcp_check")) == nil)
    #expect((plan.invocation(for: "file.read")) != nil)
    #expect((plan.invocation(for: "file.write")?.execution) == (.committed))
    #expect((plan.invocation(for: "archive.create")?.execution) == (.committed))

    let repositoryPlan = CapabilityFixturePlan(
      workspaceID: "fixture",
      repositoryWorkspaceID: "repository",
      accessibilityProcessID: 123
    )
    #expect((repositoryPlan.invocation(for: "git.add")?.execution) == (.committed))
    #expect((repositoryPlan.invocation(for: "git.branch_create")?.execution) == (.direct))
  }

  @Test
  func testOperateProviderReadsAndProcessListHaveBoundedFixtures() {
    let plan = CapabilityFixturePlan(
      workspaceID: "fixture",
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

  @Test
  func testCodexReadOnlyLifecycleSurfacesHaveBoundedFixtures() {
    let plan = CapabilityFixturePlan(
      workspaceID: "fixture",
      accessibilityProcessID: 123
    )
    let supported = [
      "codex.app.apps.list",
      "codex.app.events.read",
      "codex.app.methods.describe",
      "codex.app.methods.list",
      "codex.app.models.list",
      "codex.app.requests.list",
      "codex.app.skills.list",
      "codex.app.status",
      "codex.app.thread.list",
      "codex.exec.list",
      "codex.mcp.calls.list",
      "codex.mcp.status",
      "codex.mcp.tools.list",
    ]

    #expect((supported.filter { plan.invocation(for: $0) == nil }) == ([]))
  }

  @Test
  func testCodexThreadCleanupIsBoundToTheFixtureWorkspace() {
    let plan = CapabilityFixturePlan(
      workspaceID: "fixture",
      repositoryWorkspaceID: "repository",
      accessibilityProcessID: 123
    )

    let invocation = plan.codexThreadArchiveInvocation(threadID: "thread-123")

    #expect(invocation.arguments["workspace_id"] == .string("fixture"))
    #expect(invocation.arguments["method"] == .string("thread/archive"))
    #expect(
      invocation.arguments["params"]
        == .object(["threadId": .string("thread-123")])
    )
  }
}
