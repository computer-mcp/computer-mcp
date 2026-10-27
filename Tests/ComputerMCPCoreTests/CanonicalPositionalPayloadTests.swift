import Foundation
import Testing

@testable import ComputerMCPCore

@Suite struct CanonicalPositionalPayloadTests {
  private enum ObjectPermission: Codable, Equatable {
    case project(String)
    case plugin(String)
    case mcpServer(String)
  }

  @Test func synthesizedObjectPayloadsPreserveTheirPositionalKeys() throws {
    for value in [
      ObjectPermission.project("*"), .plugin("saved-plugin"), .mcpServer("saved-server"),
    ] {
      let bytes = try CanonicalJSONCoding.encoder().encode(value)
      let text = String(decoding: bytes, as: UTF8.self)
      #expect(text.contains("\"_0\""))
      #expect(try CanonicalJSONCoding.decoder().decode(ObjectPermission.self, from: bytes) == value)
    }
    #expect(CanonicalJSONCoding.snakeCase("authorizationRevision") == "authorization_revision")
    #expect(CanonicalJSONCoding.swiftPropertyName("profile_ids") == "profileIDs")
  }
}
