import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import Foundation

package struct CloudflareTunnelConfiguration: Codable, Equatable, Sendable, Identifiable {
  package var id: String
  package var tunnelName: String
  package var publicHostname: String
  package var gatewayProfile: GatewayProfileID
  package var localPort: Int
  package var metricsPort: Int
  package var cloudflaredPath: String?
  package var tunnelTokenReference: SecretReference
  package var accessTokenReference: SecretReference

  private enum CodingKeys: String, CodingKey {
    case id
    case tunnelName = "tunnel_name"
    case publicHostname = "public_hostname"
    case gatewayProfile = "gateway_profile"
    case localPort = "local_port"
    case metricsPort = "metrics_port"
    case cloudflaredPath = "cloudflared_path"
    case tunnelTokenReference = "tunnel_token_reference"
    case accessTokenReference = "access_token_reference"
  }

  package init(
    id: String,
    tunnelName: String,
    publicHostname: String,
    gatewayProfile: GatewayProfileID = .cloudflareObserve,
    localPort: Int = 8_765,
    metricsPort: Int = 20_241,
    cloudflaredPath: String? = nil,
    tunnelTokenReference: SecretReference,
    accessTokenReference: SecretReference
  ) {
    self.id = id
    self.tunnelName = tunnelName
    self.publicHostname = publicHostname
    self.gatewayProfile = gatewayProfile
    self.localPort = localPort
    self.metricsPort = metricsPort
    self.cloudflaredPath = cloudflaredPath
    self.tunnelTokenReference = tunnelTokenReference
    self.accessTokenReference = accessTokenReference
  }

  package var publicBaseURL: URL? {
    URL(string: "https://\(publicHostname)")
  }

  package var mcpURL: URL? {
    publicBaseURL?.appendingPathComponent("mcp")
  }

  package func validate() throws {
    try validateConfigIdentifier(id, label: "transports.cloudflare.id")
    for (label, value) in [("tunnel name", tunnelName)] {
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !value.contains("\0")
      else { throw CloudflareTunnelError.invalidProfile("\(label) is invalid") }
    }
    guard let url = publicBaseURL, url.host == publicHostname,
      !publicHostname.contains("/"), !publicHostname.contains(":"),
      publicHostname.contains(".")
    else { throw CloudflareTunnelError.invalidProfile("public hostname is invalid") }
    guard gatewayProfile != .localAdmin else {
      throw CloudflareTunnelError.invalidProfile("local-admin cannot be remotely exposed")
    }
    guard (1...65_535).contains(localPort), (1...65_535).contains(metricsPort),
      localPort != metricsPort
    else { throw CloudflareTunnelError.invalidProfile("origin and metrics ports are invalid") }
    if let cloudflaredPath, !cloudflaredPath.hasPrefix("/") {
      throw CloudflareTunnelError.invalidProfile("cloudflared path must be absolute")
    }
    guard tunnelTokenReference.account == "cloudflare.\(id).tunnel-token" else {
      throw CloudflareTunnelError.invalidProfile("tunnel token reference is not canonical")
    }
    guard accessTokenReference.account == "cloudflare.\(id).access-token" else {
      throw CloudflareTunnelError.invalidProfile("access token reference is not canonical")
    }
  }
}

package enum CloudflareTunnelLifecycleState: String, Codable, Equatable, Sendable {
  case stopped
  case starting
  case running
  case stopping
  case failed
}

package struct CloudflareTunnelStatus: Codable, Equatable, Sendable {
  package var profileID: String
  package var state: CloudflareTunnelLifecycleState
  package var processID: Int32?
  package var originURL: String?
  package var publicURL: String?
  package var metricsURL: String?
  package var startedAt: Date?
  package var lastError: String?

  private enum CodingKeys: String, CodingKey {
    case profileID = "profile_id"
    case state
    case processID = "process_id"
    case originURL = "origin_url"
    case publicURL = "public_url"
    case metricsURL = "metrics_url"
    case startedAt = "started_at"
    case lastError = "last_error"
  }

  package init(
    profileID: String,
    state: CloudflareTunnelLifecycleState,
    processID: Int32?,
    originURL: String?,
    publicURL: String?,
    metricsURL: String?,
    startedAt: Date?,
    lastError: String?
  ) {
    self.profileID = profileID
    self.state = state
    self.processID = processID
    self.originURL = originURL
    self.publicURL = publicURL
    self.metricsURL = metricsURL
    self.startedAt = startedAt
    self.lastError = lastError
  }
}

package struct CloudflareTunnelDoctorReport: Codable, Equatable, Sendable {
  package var profileID: String
  package var passed: Bool
  package var cloudflaredPath: String?
  package var version: String?
  package var tokenFileSupported: Bool?
  package var tunnelTokenPresent: Bool
  package var accessTokenPresent: Bool
  package var namedTunnelOnly: Bool
  package var metricsHealthy: Bool?
  package var diagnostics: [String]

  private enum CodingKeys: String, CodingKey {
    case profileID = "profile_id"
    case passed
    case cloudflaredPath = "cloudflared_path"
    case version
    case tokenFileSupported = "token_file_supported"
    case tunnelTokenPresent = "tunnel_token_present"
    case accessTokenPresent = "access_token_present"
    case namedTunnelOnly = "named_tunnel_only"
    case metricsHealthy = "metrics_healthy"
    case diagnostics
  }

  package init(
    profileID: String,
    passed: Bool,
    cloudflaredPath: String?,
    version: String?,
    tokenFileSupported: Bool?,
    tunnelTokenPresent: Bool,
    accessTokenPresent: Bool,
    namedTunnelOnly: Bool,
    metricsHealthy: Bool?,
    diagnostics: [String]
  ) {
    self.profileID = profileID
    self.passed = passed
    self.cloudflaredPath = cloudflaredPath
    self.version = version
    self.tokenFileSupported = tokenFileSupported
    self.tunnelTokenPresent = tunnelTokenPresent
    self.accessTokenPresent = accessTokenPresent
    self.namedTunnelOnly = namedTunnelOnly
    self.metricsHealthy = metricsHealthy
    self.diagnostics = diagnostics
  }
}

package struct CloudflareTunnelLogs: Codable, Equatable, Sendable {
  package var profileID: String
  package var stdout: String
  package var stderr: String
  package var truncated: Bool

  private enum CodingKeys: String, CodingKey {
    case profileID = "profile_id"
    case stdout
    case stderr
    case truncated
  }

  package init(
    profileID: String,
    stdout: String,
    stderr: String,
    truncated: Bool
  ) {
    self.profileID = profileID
    self.stdout = stdout
    self.stderr = stderr
    self.truncated = truncated
  }
}

package struct CloudflareOnboardingResult: Codable, Equatable, Sendable {
  package var profile: CloudflareTunnelConfiguration
  package var generatedAccessToken: String?

  private enum CodingKeys: String, CodingKey {
    case profile
    case generatedAccessToken = "generated_access_token"
  }

  package init(
    profile: CloudflareTunnelConfiguration,
    generatedAccessToken: String?
  ) {
    self.profile = profile
    self.generatedAccessToken = generatedAccessToken
  }
}

package struct CloudflareCredentialState: Codable, Equatable, Sendable {
  package var tunnelTokenPresent: Bool
  package var accessTokenPresent: Bool

  private enum CodingKeys: String, CodingKey {
    case tunnelTokenPresent = "tunnel_token_present"
    case accessTokenPresent = "access_token_present"
  }

  package init(
    tunnelTokenPresent: Bool,
    accessTokenPresent: Bool
  ) {
    self.tunnelTokenPresent = tunnelTokenPresent
    self.accessTokenPresent = accessTokenPresent
  }
}

package struct CloudflareRuntimeState {
  package var profile: CloudflareTunnelConfiguration
  package var state: CloudflareTunnelLifecycleState
  package var process: Process?
  package var origin: (any HTTPOriginLifecycle)?
  package var tokenFile: URL?
  package var stdoutHandle: FileHandle?
  package var stderrHandle: FileHandle?
  package var startedAt: Date?
  package var lastError: String?

  package init(
    profile: CloudflareTunnelConfiguration,
    state: CloudflareTunnelLifecycleState,
    process: Process?,
    origin: (any HTTPOriginLifecycle)?,
    tokenFile: URL?,
    stdoutHandle: FileHandle?,
    stderrHandle: FileHandle?,
    startedAt: Date?,
    lastError: String?
  ) {
    self.profile = profile
    self.state = state
    self.process = process
    self.origin = origin
    self.tokenFile = tokenFile
    self.stdoutHandle = stdoutHandle
    self.stderrHandle = stderrHandle
    self.startedAt = startedAt
    self.lastError = lastError
  }
}

package enum CloudflareTunnelError: Error, LocalizedError, Equatable {
  case alreadyRunning(String)
  case cloudflaredUnavailable
  case invalidProfile(String)
  case missingAccessToken
  case missingTunnelToken
  case profileNotFound(String)
  case processLaunchFailed(String)
  case profileCallerMismatch(String)
  case unsupportedCloudflaredVersion(String?)

  package var errorDescription: String? {
    switch self {
    case .alreadyRunning(let id): "Cloudflare tunnel '\(id)' is already running."
    case .cloudflaredUnavailable: "cloudflared is not installed or executable."
    case .invalidProfile(let message): "Invalid Cloudflare profile: \(message)."
    case .missingAccessToken: "The Computer MCP Access Token is missing from Keychain."
    case .missingTunnelToken: "The named tunnel token is missing from Keychain."
    case .profileNotFound(let id): "Unknown Cloudflare tunnel profile '\(id)'."
    case .processLaunchFailed(let message): "cloudflared failed to launch: \(message)"
    case .profileCallerMismatch(let id):
      "Gateway profile '\(id)' does not allow the cloudflare-tunnel caller."
    case .unsupportedCloudflaredVersion(let version):
      "cloudflared 2025.4.0 or newer is required for token-file"
        + (version.map { "; found \($0)" } ?? "; the installed version could not be determined")
        + "."
    }
  }
}
