import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class GatewayMCPCallTests {
  @Test
  func testExtractsGatewayRequestIDFromStructuredExecutionMetadata() {
    let report = GatewayCallReport(
      generatedAt: "2026-07-31T00:00:00Z",
      transport: "gateway_socket",
      endpoint: "/tmp/computer-mcp.sock",
      protocolVersion: "2025-06-18",
      serverName: "computer-mcp",
      serverVersion: "1",
      requestID: "sdk-request-1",
      toolName: "codex.app.status",
      result: .object([
        "structuredContent": .object([
          "result": .object(["state": .string("ready")]),
          "gateway_execution": .object([
            "request_id": .string("gateway-request-1")
          ]),
        ])
      ])
    )

    #expect((report.gatewayRequestID) == ("gateway-request-1"))
  }

  @Test
  func testMissingGatewayExecutionMetadataReturnsNil() {
    let report = GatewayCallReport(
      generatedAt: "2026-07-31T00:00:00Z",
      transport: "streamable_http",
      endpoint: "http://127.0.0.1:8877/mcp",
      protocolVersion: "2025-06-18",
      serverName: "computer-mcp",
      serverVersion: "1",
      requestID: "sdk-request-1",
      toolName: "codex.app.status",
      result: .object([
        "structuredContent": .object([
          "result": .object(["state": .string("ready")])
        ])
      ])
    )

    #expect((report.gatewayRequestID) == nil)
  }

  @Test
  func testReportJSONUsesCurrentSnakeCaseKeys() throws {
    let report = GatewayCallReport(
      generatedAt: "2026-08-02T00:00:00Z",
      transport: "gateway_socket",
      endpoint: "/tmp/computer-mcp.sock",
      protocolVersion: "2025-06-18",
      serverName: "computer-mcp",
      serverVersion: "1",
      requestID: "request-1",
      toolName: "system.time",
      result: .object([:])
    )
    let json = try #require(String(data: report.encodedJSON(), encoding: .utf8))

    #expect(json.contains("\"schema_version\""))
    #expect(json.contains("\"request_id\""))
    #expect(json.contains("\"tool_name\""))
    #expect(!json.contains("\"schemaVersion\""))
  }
}
