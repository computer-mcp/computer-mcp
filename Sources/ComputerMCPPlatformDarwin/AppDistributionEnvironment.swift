import Foundation

package enum AppDistributionEnvironment: String, Codable, CaseIterable, Sendable {
  case development
  case production

  package static let infoPlistKey = "ComputerMCPEnvironment"

  package var bundleIdentifier: String {
    switch self {
    case .development:
      "com.showxu.computer-mcp.development"
    case .production:
      "com.showxu.computer-mcp"
    }
  }

  package var applicationSupportDirectoryName: String {
    switch self {
    case .development:
      "Computer MCP Development"
    case .production:
      "Computer MCP"
    }
  }

  package var keychainService: String {
    "\(bundleIdentifier).secrets"
  }
}

package struct AppDistributionIdentity: Equatable, Sendable {
  package static let teamIdentifierInfoPlistKey = "ComputerMCPTeamIdentifier"

  package var environment: AppDistributionEnvironment
  package var bundleIdentifier: String
  package var teamIdentifier: String
  package var keychainAccessGroup: String

  package init(
    environment: AppDistributionEnvironment,
    bundleIdentifier: String,
    teamIdentifier: String
  ) throws {
    let normalizedBundleIdentifier = bundleIdentifier.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard normalizedBundleIdentifier == environment.bundleIdentifier else {
      throw AppDistributionIdentityError.bundleIdentifierMismatch(
        expected: environment.bundleIdentifier,
        actual: normalizedBundleIdentifier
      )
    }
    let normalizedTeamIdentifier = teamIdentifier.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      normalizedTeamIdentifier.utf8.count == 10,
      normalizedTeamIdentifier.unicodeScalars.allSatisfy({ scalar in
        CharacterSet.alphanumerics.contains(scalar)
      })
    else {
      throw AppDistributionIdentityError.invalidTeamIdentifier
    }
    self.environment = environment
    self.bundleIdentifier = normalizedBundleIdentifier
    self.teamIdentifier = normalizedTeamIdentifier
    self.keychainAccessGroup = "\(normalizedTeamIdentifier).\(normalizedBundleIdentifier)"
  }

  package static func bundled(
    infoDictionary: [String: Any]? = Bundle.main.infoDictionary
  ) throws -> AppDistributionIdentity {
    guard let infoDictionary else {
      throw AppDistributionIdentityError.missingInfoDictionary
    }
    guard
      let environmentValue = infoDictionary[AppDistributionEnvironment.infoPlistKey]
        as? String,
      let environment = AppDistributionEnvironment(rawValue: environmentValue)
    else {
      throw AppDistributionIdentityError.invalidEnvironment
    }
    guard let bundleIdentifier = infoDictionary[kCFBundleIdentifierKey as String] as? String else {
      throw AppDistributionIdentityError.missingBundleIdentifier
    }
    guard
      let teamIdentifier = infoDictionary[teamIdentifierInfoPlistKey] as? String,
      teamIdentifier != "adhoc"
    else {
      throw AppDistributionIdentityError.invalidTeamIdentifier
    }
    return try AppDistributionIdentity(
      environment: environment,
      bundleIdentifier: bundleIdentifier,
      teamIdentifier: teamIdentifier
    )
  }
}

package enum AppDistributionIdentityError: Error, LocalizedError, Equatable {
  case missingInfoDictionary
  case invalidEnvironment
  case missingBundleIdentifier
  case bundleIdentifierMismatch(expected: String, actual: String)
  case invalidTeamIdentifier

  package var errorDescription: String? {
    switch self {
    case .missingInfoDictionary:
      "The signed App Info.plist is unavailable."
    case .invalidEnvironment:
      "The signed App environment is missing or invalid."
    case .missingBundleIdentifier:
      "The signed App bundle identifier is missing."
    case .bundleIdentifierMismatch(let expected, let actual):
      "The signed App bundle identifier does not match its environment: expected \(expected), found \(actual)."
    case .invalidTeamIdentifier:
      "The signed App Team ID is missing or invalid; Data Protection Keychain requires a provisioned signing identity."
    }
  }
}
