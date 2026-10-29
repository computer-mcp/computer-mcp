import ComputerMCPPermissions
import ComputerMCPPlatformPOSIX
import ComputerMCPPlugins
import Foundation

package struct GatewayReadExceptionReview: Sendable {
  package let declaredPath: String
  package let purpose: String
  package let approval: ApprovedReadException?
}

extension GatewayProviderReview {
  /// Missing or unverifiable locations remain individually visible and unselected.
  package func readExceptions(
    replacements: [String: CanonicalPath] = [:],
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> [GatewayReadExceptionReview] {
    let requested = declarations?.sandbox?.readExceptions ?? []
    guard Set(replacements.keys).isSubset(of: Set(requested.map(\.path))) else {
      throw GatewayPermissionError.invalidBinding
    }
    var targets: Set<CanonicalPath> = []
    return try requested.map { declaration in
      let approval = try? GatewayProviderReadExceptions.resolve(
        declaredPath: declaration.path, purpose: declaration.purpose,
        replacement: replacements[declaration.path], userHome: userHome)
      if let approval, !targets.insert(approval.path).inserted {
        throw GatewayPermissionError.invalidBinding
      }
      return .init(declaredPath: declaration.path, purpose: declaration.purpose, approval: approval)
    }
  }
}

package enum GatewayProviderReadExceptions {
  package static func resolve(
    declaredPath: String, purpose: String, replacement: CanonicalPath? = nil,
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> ApprovedReadException {
    try ApprovedReadException.validate(declaredPath: declaredPath)
    let input = location(declaredPath: declaredPath, replacement: replacement, userHome: userHome)
    let identity = try VerifiedFileIdentity.capture(input)
    return try .init(
      declaredPath: declaredPath, ownerSelectedPath: replacement, path: .init(identity.path),
      filesystemIdentity: identity.evidence, isDirectory: identity.isDirectory, purpose: purpose)
  }

  package static func verify(
    _ exceptions: Set<ApprovedReadException>,
    userHome: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws {
    guard Set(exceptions.map(\.path)).count == exceptions.count,
      Set(exceptions.map(\.declaredPath)).count == exceptions.count
    else { throw GatewayPermissionError.invalidBinding }
    for approved in exceptions {
      let current = try resolve(
        declaredPath: approved.declaredPath, purpose: approved.purpose,
        replacement: approved.ownerSelectedPath, userHome: userHome)
      guard current.path == approved.path, current.isDirectory == approved.isDirectory,
        current.filesystemIdentity == approved.filesystemIdentity
      else { throw FileIdentityError.changed }
    }
  }

  private static func location(
    declaredPath: String, replacement: CanonicalPath?, userHome: URL
  ) -> URL {
    replacement.map { URL(fileURLWithPath: $0.string) }
      ?? userHome.appendingPathComponent(String(declaredPath.dropFirst(2)))
  }
}
