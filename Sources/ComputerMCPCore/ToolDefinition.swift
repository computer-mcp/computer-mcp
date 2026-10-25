package struct ToolDefinition: Sendable {
  package let tool: MCPTool
  package var requirement: ToolRequirement { capability.requirement }
  package let capability: CapabilityDescriptor

  package init(tool: MCPTool, capability: CapabilityDescriptor) {
    self.tool = tool
    self.capability = capability
  }
}
