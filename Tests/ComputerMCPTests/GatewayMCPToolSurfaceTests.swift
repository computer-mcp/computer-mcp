import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsSystem
import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPConfiguration

@Suite

final class GatewayMCPToolSurfaceTests {
  @Test
  func testSurfacePreservesAndRoutesCanonicalDottedToolNames() throws {
    let configuration = GatewayConfiguration.fixture(
      cli: CLISectionConfig(),
      mcp: MCPSectionConfig(),
      builtin: BuiltinConfig(enabled: ["system.time"])
    )
    let surface = try GatewayMCPToolSurface(
      registry: GatewayProviderRouter(providers: [
        SystemToolProvider(environment: ToolEnvironment(configuration: configuration))
      ])
    )

    #expect((try surface.listTools(context: .empty).map(\.name)) == (["system.time"]))
    let result = try surface.callTool(name: "system.time", arguments: .object([:]), context: .empty)
    #expect((result.objectValue?["structuredContent"]) != nil)
    expectThrows(
      try surface.callTool(name: "system_time", arguments: .object([:]), context: .empty)
    )
  }
}
