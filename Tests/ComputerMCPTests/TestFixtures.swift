import ComputerMCP

extension GatewayConfiguration {
  static func fixture(
    server: ServerConfig = ServerConfig(),
    cli: CLISectionConfig = CLISectionConfig(commands: [
      CLICommandConfig(id: "echo", executable: "/bin/echo")
    ]),
    mcp: MCPSectionConfig = MCPSectionConfig(servers: [
      MCPServerConfig(
        id: "fake",
        transport: .stdio,
        command: "/bin/cat",
        allowAnyTool: true
      )
    ]),
    tools: [ToolConfig] = [],
    policy: PolicyConfig = PolicyConfig(),
    builtin: BuiltinConfig = BuiltinConfig(),
    skills: SkillsConfig = SkillsConfig()
  ) -> GatewayConfiguration {
    GatewayConfiguration(
      server: server,
      policy: policy,
      cli: cli,
      mcp: mcp,
      tools: tools,
      builtin: builtin,
      skills: skills
    )
  }
}
