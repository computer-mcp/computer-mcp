import Foundation

/// Errors thrown while validating or executing registered gateway tools.
package enum GatewayToolError: Error, LocalizedError, Equatable {
  case unknownTool(String)
  case unknownCLI(String)
  case unknownMCPServer(String)
  case invalidArguments(String)
  case disabled(String)
  case executionFailed(String)

  package var errorDescription: String? {
    switch self {
    case .unknownTool(let name):
      return "Unknown tool: \(name)"
    case .unknownCLI(let id):
      return "Unknown CLI command id: \(id)"
    case .unknownMCPServer(let id):
      return "Unknown MCP server id: \(id)"
    case .invalidArguments(let message), .disabled(let message), .executionFailed(let message):
      return message
    }
  }
}
