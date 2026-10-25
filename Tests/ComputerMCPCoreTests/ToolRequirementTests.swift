import ComputerMCPPermissions
import Foundation
import Testing

@testable import ComputerMCPCore

struct ToolRequirementTests {
  @Test(arguments: [true, false])
  func hostActionsAndPluginOriginsPreserveRequirements(remote: Bool) throws {
    let declaration = ToolRequirement.downstream(
      serverID: "server", readOnly: false, remoteExecution: remote, hostAction: .projectRemoval)
    let composed = try declaration.requiringPlugin("plugin")
    #expect(composed.paths.isEmpty)
    #expect(composed.namedProjectAccess == .write)
    #expect(composed.access == .sourceProjectWrite)
    #expect(composed.requiresFullAccess == remote)
    #expect(composed.target == .mcp(server: .registered(id: "server"), access: .all))
    #expect(composed.contribution == .mcp(server: .registered(id: "server")))
    #expect(composed.permissions == [try .init(.plugin("plugin"), .use)])
    #expect(try composed.requiringPlugin("plugin") == composed)
    #expect(
      try JSONDecoder().decode(ToolRequirement.self, from: JSONEncoder().encode(composed))
        == composed)
  }

  @Test
  func descriptorRequiresAnExplicitDeclarationWhenDecoded() throws {
    let data = Data(
      #"{"id":"unknown","risk":"read-only","projectRequirement":"none","localOnly":false,"usesNetwork":false,"tccServices":[]}"#
        .utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(CapabilityDescriptor.self, from: data)
    }
  }
}
