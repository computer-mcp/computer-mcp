import Foundation
import MCP

/// Runs the gateway through the official MCP Swift SDK.
package enum MCPRuntimeAdapter: Sendable {
  package static func makeGatewayServer(
    configuration: GatewayConfiguration,
    registry: any GatewayToolServing
  ) async -> MCP.Server {
    let instructions = serverInstructions(for: configuration)
    let server = MCP.Server(
      name: configuration.server.name,
      version: ComputerMCPCLI.version,
      title: "Computer MCP Gateway",
      instructions: instructions,
      capabilities: .init(tools: .init(listChanged: false))
    )

    await registerGatewayHandlers(
      server: server,
      configuration: configuration,
      registry: registry
    )
    return server
  }

  package static func runStdioGateway(
    configuration: GatewayConfiguration,
    registry: any GatewayToolServing
  ) async throws {
    let server = await makeGatewayServer(configuration: configuration, registry: registry)
    let transport = MCPInitializeNormalizationTransport(wrapping: StdioTransport())
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
  }

  package static func runHTTPGateway(
    configuration: GatewayConfiguration,
    registry: any GatewayToolServing,
    host: String?,
    port: Int?,
    publicBaseURL: String?
  ) async throws {
    let http = configuration.server.http
    let runtime = GatewayHTTPRuntime(
      configuration: configuration,
      registry: registry,
      host: host ?? http.host,
      port: port ?? http.port,
      publicBaseURL: publicBaseURL ?? http.publicBaseURL
    )
    try await runtime.start()
  }

  private static func registerGatewayHandlers(
    server: MCP.Server,
    configuration: GatewayConfiguration,
    registry: any GatewayToolServing
  ) async {
    let surface = GatewayMCPToolSurface(registry: registry)

    await server.withMethodHandler(MCP.ListTools.self) { _ in
      MCP.ListTools.Result(tools: try surface.listTools().map(\.sdkTool))
    }

    await server.withMethodHandler(MCP.CallTool.self) { params in
      let arguments: JSONValue?
      if let sdkArguments = params.arguments {
        arguments = .object(sdkArguments.mapValues(JSONValue.init(sdkValue:)))
      } else {
        arguments = .object([:])
      }

      do {
        return try await registry.callToolForMCPAsync(
          name: params.name,
          arguments: arguments
        )
        .sdkCallToolResult()
      } catch GatewayToolError.invalidArguments(let message) {
        throw MCPError.invalidParams(message)
      }
    }
  }

  private static func serverInstructions(for configuration: GatewayConfiguration) -> String {
    var sections = [
      "Use only tools exposed by this MCP server for local computer access."
    ]
    if !configuration.cli.commands.isEmpty {
      sections.append(
        "For registered CLIs, inspect cli.status, cli.describe, and cli.help, then execute argv through cli.exec; never translate returned help into an out-of-gateway local command."
      )
    }
    if !configuration.mcp.servers.isEmpty {
      sections.append(
        "Discover downstream MCP capabilities through mcp.tools.list or mcp.tools.describe and invoke them through mcp.tools.call."
      )
    }
    sections.append("The gateway is deterministic and does not select tools or plan.")
    return sections.joined(separator: " ")
  }
}
