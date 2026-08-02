import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class CodexAppServerRuntimeTests {
  @Test
  func testBoundedRequestClosesTimedOutOperation() async {
    let probe = CodexAppServerTimeoutProbe()

    do {
      _ = try await LiveCodexAppServerRuntime.boundedRequest(
        timeoutSeconds: 1,
        onTimeout: {
          await probe.recordTimeout()
        },
        operation: {
          try await Task.sleep(for: .seconds(60))
          return "late"
        }
      )
      Issue.record("Expected the App Server request to time out.")
    } catch {
      #expect(error.localizedDescription.contains("1-second deadline"))
    }
    #expect(await probe.didTimeOut)
  }

  @Test
  func testNormalizePinsThreadListAndSkillsToBoundWorkspace() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-workspace")
    let runtime = LiveCodexAppServerRuntime(
      configuration: CodexConfig(enabled: true),
      workspaceURL: workspace
    )

    let threadList = try await runtime.normalize(
      params: .object([
        "cwd": .string(workspace.path),
        "searchTerm": .string("gateway"),
      ]),
      for: try method("thread/list")
    )
    #expect((threadList?.objectValue?["cwd"]) == (.string(workspace.path)))
    #expect((threadList?.objectValue?["searchTerm"]) == (.string("gateway")))

    let skillsList = try await runtime.normalize(
      params: .object([
        "perCwdExtraUserRoots": .object([workspace.path: .array([.string("/tmp/escape")])])
      ]),
      for: try method("skills/list")
    )
    #expect((skillsList?.objectValue?["cwds"]) == (.array([.string(workspace.path)])))
    #expect((skillsList?.objectValue?["perCwdExtraUserRoots"]) == nil)
  }

  @Test
  func testNormalizePinsSandboxAndRejectsAuthorityOverrides() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-workspace")
    let runtime = LiveCodexAppServerRuntime(
      configuration: CodexConfig(
        enabled: true,
        sandbox: .workspaceWrite,
        approvalPolicy: .never
      ),
      workspaceURL: workspace
    )

    let normalized = try await runtime.normalize(
      params: .object([
        "threadId": .string("thread-1"),
        "input": .array([]),
      ]),
      for: try method("turn/start")
    )
    #expect((normalized?.objectValue?["cwd"]) == (.string(workspace.path)))
    #expect((normalized?.objectValue?["approvalPolicy"]) == (.string("never")))
    #expect(
      (normalized?.objectValue?["sandboxPolicy"]?.objectValue?["type"])
        == (.string("workspaceWrite")))

    await assertThrowsErrorAsync(
      try await runtime.normalize(
        params: .object(["config": .object([:])]),
        for: try method("thread/start")
      ),
      expectedCode: "codex.app.override_denied"
    )
    await assertThrowsErrorAsync(
      try await runtime.normalize(
        params: .object(["sandbox": .string("danger-full-access")]),
        for: try method("thread/start")
      ),
      expectedCode: "codex.app.danger_full_access_denied"
    )
  }

  @Test
  func testWorkspaceScopedThreadIDRequiresThreadForScopedMethods() throws {
    #expect(
      (try LiveCodexAppServerRuntime.workspaceScopedThreadID(
        method: "thread/list",
        params: .object([:])
      )) == nil)
    #expect(
      (try LiveCodexAppServerRuntime.workspaceScopedThreadID(
        method: "turn/start",
        params: .object(["threadId": .string("thread-1")])
      )) == ("thread-1"))
    expectThrows(
      try LiveCodexAppServerRuntime.workspaceScopedThreadID(
        method: "thread/read",
        params: .object([:])
      )
    )
  }

  @Test
  func testThreadWorkspaceValidationAllowsDescendantsAndRejectsOtherRoots() throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-workspace")

    expectNoThrow(
      try LiveCodexAppServerRuntime.validateThreadWorkspace(
        threadID: "thread-1",
        response: threadResponse(cwd: workspace.appendingPathComponent("nested").path),
        workspaceURL: workspace
      )
    )
    expectThrows(
      try LiveCodexAppServerRuntime.validateThreadWorkspace(
        threadID: "thread-2",
        response: threadResponse(cwd: "/tmp/other-workspace"),
        workspaceURL: workspace
      )
    )
    expectThrows(
      try LiveCodexAppServerRuntime.validateThreadWorkspace(
        threadID: "thread-3",
        response: .object(["thread": .object([:])]),
        workspaceURL: workspace
      )
    )
  }

  @Test
  func testCreatedThreadWorkspaceValidationAcceptsBoundThreadAndRejectsEscapes() throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-workspace")

    #expect(
      (try LiveCodexAppServerRuntime.createdWorkspaceScopedThreadID(
        response: createdThreadResponse(id: "thread-created", cwd: workspace.path),
        workspaceURL: workspace
      )) == ("thread-created"))
    expectThrows(
      try LiveCodexAppServerRuntime.createdWorkspaceScopedThreadID(
        response: createdThreadResponse(
          id: "thread-created-outside",
          cwd: "/tmp/outside-workspace"
        ),
        workspaceURL: workspace
      )
    )
    expectThrows(
      try LiveCodexAppServerRuntime.createdWorkspaceScopedThreadID(
        response: threadResponse(cwd: workspace.path),
        workspaceURL: workspace
      )
    )
  }

  private func method(_ name: String) throws -> CodexAppServerMethod {
    try #require(CodexAppServerMethodCatalog.method(named: name))
  }

  private func threadResponse(cwd: String) -> JSONValue {
    .object([
      "thread": .object([
        "cwd": .string(cwd)
      ])
    ])
  }

  private func createdThreadResponse(id: String, cwd: String) -> JSONValue {
    .object([
      "thread": .object([
        "id": .string(id),
        "cwd": .string(cwd),
      ])
    ])
  }
}

private actor CodexAppServerTimeoutProbe {
  private(set) var didTimeOut = false

  func recordTimeout() {
    didTimeOut = true
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  expectedCode: String? = nil,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    Issue.record("Expected expression to throw.")
  } catch {
    if let expectedCode {
      #expect(String(describing: error).contains("[\(expectedCode)]"))
    }
  }
}
