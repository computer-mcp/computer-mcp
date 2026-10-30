import ComputerMCPConfiguration
import ComputerMCPCore
import Foundation

extension GatewayConfiguration {
  package func mcpRisk(for reference: MCPToolReference, declaredBy tool: MCPTool) throws
    -> CapabilityRisk
  {
    try mcpRisk(for: reference).raised(to: tool.declaredRiskFloor)
  }
}

extension InvocationAdmission {
  package func validate(
    reference: MCPToolReference, risk: CapabilityRisk,
    hostServiceAction: MCPHostServiceAction?
  ) throws {
    guard self.reference == reference, self.risk.raised(to: risk) == self.risk else {
      throw GatewayToolError.invalidArguments(
        "[mcp.risk_changed] The downstream tool risk changed after host authorization. Retry through the current host permission policy."
      )
    }
    guard self.hostServiceAction == hostServiceAction else {
      throw GatewayToolError.invalidArguments(
        "[mcp.host_action_changed] The downstream host action changed after authorization. Retry through the current permission policy."
      )
    }
  }

  package func hostDispatch(for server: MCPServerConfig, tool: String) -> HostServiceDispatch? {
    guard server.hostServices, reference == MCPToolReference(serverID: server.id, toolName: tool),
      let hostInvocationID
    else { return nil }
    return .init(
      invocationID: hostInvocationID, operationID: hostOperationID, action: hostServiceAction)
  }
}
