import Foundation

package enum GatewayToolCounts {
  package static let skills = GatewayToolRegistry.gatewayTools(
    shellEnabled: false,
    builtins: [],
    skillsEnabled: true,
    hasCLIProviders: false,
    hasMCPProviders: false,
    toolMeta: nil
  ).filter { $0.name.hasPrefix("skills.") }.count

  package static let computerUse = ComputerUseGatewayProvider.toolCount
}
