import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class GatewayMCPToolSurfaceTests {
  @Test
  func testSurfacePreservesAndRoutesCanonicalDottedToolNames() throws {
    let configuration = GatewayConfiguration.fixture(
      cli: CLISectionConfig(),
      mcp: MCPSectionConfig(),
      builtin: BuiltinConfig(enabled: ["system.time"])
    )
    let surface = GatewayMCPToolSurface(
      registry: GatewayToolRegistry(configuration: configuration)
    )

    #expect((try surface.listTools().map(\.name)) == (["system.time"]))
    let result = try surface.callTool(name: "system.time", arguments: .object([:]))
    #expect((result.objectValue?["structuredContent"]) != nil)
    expectThrows(
      try surface.callTool(name: "system_time", arguments: .object([:]))
    )
  }
}
