import Foundation

package enum GatewayToolCounts {
  package static let skills = GatewayToolRegistry.gatewayDefinitions(
    shellEnabled: false,
    builtins: [],
    skillsEnabled: true,
    hasCLIProviders: false,
    hasMCPProviders: false,
    toolMeta: nil
  ).filter { $0.tool.name.hasPrefix("skills.") }.count

  package static let computerUse = ComputerUseGatewayProvider.toolCount
}
