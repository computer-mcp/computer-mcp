import ComputerMCPConfiguration
import ComputerMCPTunnels

internal struct ChatGPTProfileAuditor: Sendable {
  internal func audit(
    configuration: GatewayConfiguration,
    registry: any GatewayToolServing,
    allowWriteTools: Bool
  ) throws -> ChatGPTProfileAudit {
    // Profile auditing inventories the host catalog outside any caller invocation.
    let tools = try GatewayMCPToolSurface(registry: registry).listTools(context: .empty)
    guard !tools.isEmpty else {
      throw ChatGPTProfileAuditError.noTools
    }

    let missingAnnotations =
      tools
      .filter { $0.annotations?.readOnlyHint == nil }
      .map(\.name)
      .sorted()
    guard missingAnnotations.isEmpty else {
      throw ChatGPTProfileAuditError.missingReadOnlyAnnotations(missingAnnotations)
    }

    let writeCapable =
      tools
      .filter { $0.annotations?.readOnlyHint != true }
      .map(\.name)
      .sorted()
    if !allowWriteTools, !writeCapable.isEmpty {
      throw ChatGPTProfileAuditError.writeToolsRequireExplicitOptIn(writeCapable)
    }

    return ChatGPTProfileAudit(
      toolCount: tools.count,
      readOnlyToolCount: tools.count - writeCapable.count,
      writeCapableToolNames: writeCapable
    )
  }
}
