import ComputerMCPPlatform
import Foundation

/// Consecutive manifest schemas and runtime contracts understood by a host.
package struct PluginAPIVersions: Codable, Equatable, Sendable {
  package static let supported = Self(1...1)
  package let minimum: Int
  package let maximum: Int

  init(_ range: ClosedRange<Int>) {
    minimum = range.lowerBound
    maximum = range.upperBound
  }

  func refusal(pluginID: String, version: PluginVersion, declared: Int)
    -> PluginCompatibilityRefusal?
  {
    guard !(minimum...maximum).contains(declared) else { return nil }
    return PluginCompatibilityRefusal(
      pluginID: pluginID, version: version,
      reason: declared > maximum ? .hostUpdateRequired : .pluginUpdateRequired,
      requirement: .pluginAPI(declared: declared, supported: self))
  }
}

/// The first failed compatibility check, retained across loading, management and diagnostics.
package struct PluginCompatibilityRefusal: Error, Codable, Equatable, LocalizedError, Sendable {
  package enum Reason: String, Codable, Sendable {
    case hostUpdateRequired = "host_update_required"
    case pluginUpdateRequired = "plugin_update_required"
    case platformUnsupported = "platform_unsupported"
  }

  package enum Requirement: Codable, Equatable, Sendable {
    case pluginAPI(declared: Int, supported: PluginAPIVersions)
    /// Artifact targets are the candidates for this source; an empty list has no matching artifact.
    case platform(
      declared: PluginPlatformCompatibility, artifacts: [PluginPlatformCompatibility],
      platform: String, architecture: String)
    case hostVersion(minimum: PluginVersion?, maximum: PluginVersion?, current: PluginVersion)
  }

  package let pluginID: String
  package let version: PluginVersion
  package let reason: Reason
  package let requirement: Requirement
  package var code: String { "plugin.\(reason.rawValue)" }
  package var message: String {
    let identity = "Plugin '\(pluginID)' \(version)"
    switch requirement {
    case .pluginAPI(let declared, let supported):
      let action = reason == .hostUpdateRequired ? "Update Computer MCP." : "Update the plugin."
      return
        "\(action) \(identity) declares plugin_api \(declared); this host supports \(supported.minimum)...\(supported.maximum)."
    case .platform(_, _, let platform, let architecture):
      return
        "Use a package built for this Mac. \(identity) has no package artifact for \(platform)/\(architecture)."
    case .hostVersion(let minimum, let maximum, let current):
      if reason == .hostUpdateRequired {
        return
          "Update Computer MCP. \(identity) requires Computer MCP \(minimum?.description ?? "unknown") or later; this host is \(current)."
      }
      return
        "Update the plugin. \(identity) requires Computer MCP below \(maximum?.description ?? "unknown"); this host is \(current)."
    }
  }
  package var errorDescription: String? { message }

  /// API support precedes platform/artifact support, which precedes host release constraints.
  static func evaluate(
    pluginID: String, version: PluginVersion, pluginAPI: Int,
    target: PluginPlatformCompatibility, artifacts: [PluginPlatformCompatibility],
    minimumHost: PluginVersion?, maximumHost: PluginVersion?, host: PluginVersion,
    architecture: String, platform: String,
    supportedAPIs: PluginAPIVersions = .supported
  ) -> Self? {
    if let refusal = supportedAPIs.refusal(
      pluginID: pluginID, version: version, declared: pluginAPI)
    {
      return refusal
    }
    if !target.permits(platform: platform, architecture: architecture)
      || !artifacts.contains(where: { $0.permits(platform: platform, architecture: architecture) })
    {
      return Self(
        pluginID: pluginID, version: version, reason: .platformUnsupported,
        requirement: .platform(
          declared: target, artifacts: artifacts, platform: platform, architecture: architecture))
    }
    let reason: Reason
    if let minimumHost, host.precedes(minimumHost) {
      reason = .hostUpdateRequired
    } else if let maximumHost, !host.precedes(maximumHost) {
      reason = .pluginUpdateRequired
    } else {
      return nil
    }
    return Self(
      pluginID: pluginID, version: version, reason: reason,
      requirement: .hostVersion(minimum: minimumHost, maximum: maximumHost, current: host))
  }
}
