import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite
struct ValidationAuditClientTests {
  @Test
  func projectListDecodesCurrentResultContract() throws {
    let project = RegisteredProject(
      id: "fixture",
      displayName: "Fixture",
      rootPath: "/tmp/fixture"
    )
    let data = try responseData(key: "result", project: project)

    #expect(try GatewayDatabase.decodeProjectListResponse(data) == [project])
  }

  @Test
  func projectListDecodesLegacyProjectsContract() throws {
    let project = RegisteredProject(
      id: "fixture",
      displayName: "Fixture",
      rootPath: "/tmp/fixture"
    )
    let data = try responseData(key: "projects", project: project)

    #expect(try GatewayDatabase.decodeProjectListResponse(data) == [project])
  }

  @Test
  func projectListRejectsUnknownContract() throws {
    let data = try ValidationCanonicalJSONCoding.encoder().encode(
      JSONValue.object(["result_count": .number(0)])
    )

    #expect(throws: ValidationProcessError.self) {
      _ = try GatewayDatabase.decodeProjectListResponse(data)
    }
  }

  private func responseData(key: String, project: RegisteredProject) throws -> Data {
    let projectData = try ValidationCanonicalJSONCoding.encoder().encode(project)
    let projectValue = try ValidationCanonicalJSONCoding.decoder().decode(
      JSONValue.self,
      from: projectData
    )
    return try ValidationCanonicalJSONCoding.encoder().encode(
      JSONValue.object([key: .array([projectValue])])
    )
  }
}
