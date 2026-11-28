import ComputerMCPCore

extension MCPServerConfig {
  /// Host classification and registration transport determine the downstream
  /// boundary. Project access is conditional on the call naming a project.
  package func requirement(for policy: MCPToolAdmissionPolicy) -> ToolRequirement {
    .downstream(
      serverID: id, readOnly: policy.risk == .readOnly,
      remoteExecution: transport != .stdio && policy.risk == .fullShell,
      hostAction: policy.hostServiceAction)
  }
}
