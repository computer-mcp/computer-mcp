import ComputerMCPPermissions
import Foundation
import Testing

@testable import ComputerMCPCore

struct ToolRequirementTests {
  @Test func callerConditionsPreserveHostOwnedInputs() throws {
    let original = ToolRequirement(
      access: .sourceProjectWrite, permissions: [try .init(.screen, .access)],
      namedProjectAccess: .write, requiresFullAccess: true, paths: [.project(.write)],
      execution: .start, target: .forwarded(tool: "tool", arguments: "arguments", server: "server"),
      networkURL: "url", contribution: .cli(registration: .registered(id: "formatter")))
    let composed = original.adding(
      access: .read,
      permissions: [
        try .init(.screen, .access), try .init(.filesAndFolders(.downloads), .read),
      ])
    #expect(composed.access == original.access && composed.namedProjectAccess == .write)
    #expect(composed.requiresFullAccess && composed.paths == original.paths)
    #expect(composed.execution == original.execution && composed.target == original.target)
    #expect(
      composed.networkURL == original.networkURL && composed.contribution == original.contribution)
    #expect(composed.permissions.count == 2)
    #expect(
      ToolRequirement.none.adding(access: .projectWrite, permissions: []).access == .projectWrite)
  }

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
