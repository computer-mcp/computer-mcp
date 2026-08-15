import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite
struct ValidationAuditClientTests {
  @Test
  func workspaceListDecodesCurrentResultContract() throws {
    let workspace = RegisteredWorkspace(
      id: "fixture",
      displayName: "Fixture",
      rootPath: "/tmp/fixture"
    )
    let data = try responseData(key: "result", workspace: workspace)

    #expect(try GatewayDatabase.decodeWorkspaceListResponse(data) == [workspace])
  }

  @Test
  func workspaceListDecodesLegacyWorkspacesContract() throws {
    let workspace = RegisteredWorkspace(
      id: "fixture",
      displayName: "Fixture",
      rootPath: "/tmp/fixture"
    )
    let data = try responseData(key: "workspaces", workspace: workspace)

    #expect(try GatewayDatabase.decodeWorkspaceListResponse(data) == [workspace])
  }

  @Test
  func workspaceListRejectsUnknownContract() throws {
    let data = try ValidationCanonicalJSONCoding.encoder().encode(
      JSONValue.object(["result_count": .number(0)])
    )

    #expect(throws: ValidationProcessError.self) {
      _ = try GatewayDatabase.decodeWorkspaceListResponse(data)
    }
  }

  private func responseData(key: String, workspace: RegisteredWorkspace) throws -> Data {
    let workspaceData = try ValidationCanonicalJSONCoding.encoder().encode(workspace)
    let workspaceValue = try ValidationCanonicalJSONCoding.decoder().decode(
      JSONValue.self,
      from: workspaceData
    )
    return try ValidationCanonicalJSONCoding.encoder().encode(
      JSONValue.object([key: .array([workspaceValue])])
    )
  }
}
