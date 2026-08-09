import CryptoKit
import Darwin
import Foundation
import Security

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
}

package struct CloudflareOnboardingResult: Codable, Equatable, Sendable {
  package var profile: CloudflareTunnelConfiguration
  package var generatedAccessToken: String?

  private enum CodingKeys: String, CodingKey {
    case profile
    case generatedAccessToken = "generated_access_token"
  }
}

package struct CloudflareCredentialState: Codable, Equatable, Sendable {
  package var tunnelTokenPresent: Bool
  package var accessTokenPresent: Bool

  private enum CodingKeys: String, CodingKey {
    case tunnelTokenPresent = "tunnel_token_present"
    case accessTokenPresent = "access_token_present"
  }
}

struct CloudflareRuntimeState {
  var profile: CloudflareTunnelConfiguration
  var state: CloudflareTunnelLifecycleState
  var process: Process?
  var origin: GatewayHTTPRuntime?
  var tokenFile: URL?
  var stdoutHandle: FileHandle?
  var stderrHandle: FileHandle?
  var startedAt: Date?
  var lastError: String?
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

extension AppControlPlaneService {
  package func cloudflareTunnelConfigurations() throws -> [CloudflareTunnelConfiguration] {
    let configured = try manifestStore.activeConfiguration().transports.cloudflare
    return try configured.map { definition in
      let tunnelTokenReference =
        try SecretReference(account: "cloudflare.\(definition.id).tunnel-token")
      let accessTokenReference =
        try SecretReference(account: "cloudflare.\(definition.id).access-token")
      return CloudflareTunnelConfiguration(
        id: definition.id,
        tunnelName: definition.tunnelName,
        publicHostname: definition.publicHostname,
        gatewayProfile: definition.gatewayProfile,
        localPort: definition.localPort,
        metricsPort: definition.metricsPort,
        cloudflaredPath: definition.cloudflaredPath,
        tunnelTokenReference: tunnelTokenReference,
        accessTokenReference: accessTokenReference
      )
    }.sorted { $0.id < $1.id }
  }

  package func cloudflareCredentialState(
    for profile: CloudflareTunnelConfiguration
  ) async throws -> CloudflareCredentialState {
    CloudflareCredentialState(
      tunnelTokenPresent: try await keychainContainsSecret(profile.tunnelTokenReference),
      accessTokenPresent: try await keychainContainsSecret(profile.accessTokenReference)
    )
  }

  package func saveCloudflareTunnelConfiguration(
    _ profile: CloudflareTunnelConfiguration,
    tunnelToken: String?,
    regenerateAccessToken: Bool = false
  ) async throws -> CloudflareOnboardingResult {
    try profile.validate()
    var configuration = try manifestStore.activeConfiguration()
    configuration.transports.cloudflare.removeAll { $0.id == profile.id }
    configuration.transports.cloudflare.append(
      CloudflareTunnelTransportConfig(
        id: profile.id,
        tunnelName: profile.tunnelName,
        publicHostname: profile.publicHostname,
        gatewayProfile: profile.gatewayProfile,
        localPort: profile.localPort,
        metricsPort: profile.metricsPort,
        cloudflaredPath: profile.cloudflaredPath
      )
    )
    configuration.transports.cloudflare.sort { $0.id < $1.id }
    try configuration.validate()

    let existingTunnelToken = try await keychainSecretValue(for: profile.tunnelTokenReference)
    let existingAccessToken = try await keychainSecretValue(for: profile.accessTokenReference)
    guard tunnelToken != nil || existingTunnelToken != nil else {
      throw CloudflareTunnelError.missingTunnelToken
    }
    let generatedAccessToken =
      regenerateAccessToken || existingAccessToken == nil
      ? try Self.secureRandomToken() : nil
    do {
      if let tunnelToken {
        try await setKeychainSecret(tunnelToken, for: profile.tunnelTokenReference)
      }
      if let generatedAccessToken {
        try await setKeychainSecret(generatedAccessToken, for: profile.accessTokenReference)
      }
      try activateTransportConfiguration(configuration)
    } catch {
      await restoreCloudflareSecret(
        existingTunnelToken,
        reference: profile.tunnelTokenReference
      )
      await restoreCloudflareSecret(
        existingAccessToken,
        reference: profile.accessTokenReference
      )
      throw error
    }
    return CloudflareOnboardingResult(
      profile: profile,
      generatedAccessToken: generatedAccessToken
    )
  }

  package func deleteCloudflareTunnelConfiguration(id: String) async throws {
    let profile = try requireCloudflareProfile(id)
    _ = try await stopCloudflareTunnel(profileID: id)
    var configuration = try manifestStore.activeConfiguration()
    configuration.transports.cloudflare.removeAll { $0.id == id }
    try activateTransportConfiguration(configuration)
    try await deleteKeychainSecret(profile.tunnelTokenReference)
    try await deleteKeychainSecret(profile.accessTokenReference)
  }

  package func cloudflareTunnelStatuses() -> [CloudflareTunnelStatus] {
    let profiles = (try? cloudflareTunnelConfigurations()) ?? []
    return profiles.map { profile in
      if let runtime = cloudflareRuntimes[profile.id] {
        let running = runtime.process?.isRunning == true
        let exitedBeforeCleanupStarted = runtime.state == .running && !running
        return CloudflareTunnelStatus(
          profileID: profile.id,
          state: exitedBeforeCleanupStarted ? .stopping : runtime.state,
          processID: running ? runtime.process?.processIdentifier : nil,
          originURL: "http://127.0.0.1:\(profile.localPort)/mcp",
          publicURL: profile.mcpURL?.absoluteString,
          metricsURL: "http://127.0.0.1:\(profile.metricsPort)/metrics",
          startedAt: runtime.startedAt,
          lastError: runtime.lastError
        )
      }
      return CloudflareTunnelStatus(
        profileID: profile.id,
        state: .stopped,
        processID: nil,
        originURL: "http://127.0.0.1:\(profile.localPort)/mcp",
        publicURL: profile.mcpURL?.absoluteString,
        metricsURL: "http://127.0.0.1:\(profile.metricsPort)/metrics",
        startedAt: nil,
        lastError: nil
      )
    }.sorted { $0.profileID < $1.profileID }
  }

  package func doctorCloudflareTunnel(profileID: String) async throws
    -> CloudflareTunnelDoctorReport
  {
    let profile = try requireCloudflareProfile(profileID)
    let executable = resolveCloudflared(profile.cloudflaredPath)
    let tunnelTokenPresent = try await keychainSecretValue(for: profile.tunnelTokenReference) != nil
    let accessTokenPresent = try await keychainSecretValue(for: profile.accessTokenReference) != nil
    let configuration = try manifestStore.activeConfiguration()
    let callerAllowed = configuration.profileGrant(for: profile.gatewayProfile)
      .allowedCallers.contains(.cloudflareTunnel)
    var diagnostics: [String] = []
    var version: String?
    var tokenFileSupported: Bool?
    if let executable {
      let result = try? ProcessCommandRunner().run(
        executable: executable,
        arguments: ["version"],
        workingDirectory: nil,
        environment: [:],
        timeoutMilliseconds: 5_000,
        maxOutputBytes: 16_384
      )
      version = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      if result?.exitCode != 0 {
        diagnostics.append("cloudflared version failed")
      } else if let version {
        tokenFileSupported = Self.cloudflaredVersionSupportsTokenFile(version)
        if tokenFileSupported != true {
          diagnostics.append("cloudflared 2025.4.0 or newer is required for token-file")
        }
      } else {
        diagnostics.append("cloudflared version could not be determined")
      }
    } else {
      diagnostics.append("cloudflared executable unavailable")
    }
    if !tunnelTokenPresent { diagnostics.append("named tunnel token missing") }
    if !accessTokenPresent { diagnostics.append("Computer MCP Access Token missing") }
    if !callerAllowed { diagnostics.append("profile does not allow cloudflare-tunnel") }
    let running = cloudflareRuntimes[profileID]?.process?.isRunning == true
    let metricsHealthy = running ? await Self.metricsHealthy(port: profile.metricsPort) : nil
    if metricsHealthy == false {
      diagnostics.append("local cloudflared metrics endpoint unhealthy")
    }
    return CloudflareTunnelDoctorReport(
      profileID: profileID,
      passed: diagnostics.isEmpty,
      cloudflaredPath: executable,
      version: version,
      tokenFileSupported: tokenFileSupported,
      tunnelTokenPresent: tunnelTokenPresent,
      accessTokenPresent: accessTokenPresent,
      namedTunnelOnly: true,
      metricsHealthy: metricsHealthy,
      diagnostics: diagnostics
    )
  }

  package func startCloudflareTunnel(profileID: String) async throws -> CloudflareTunnelStatus {
    if let existingRuntime = cloudflareRuntimes[profileID] {
      if existingRuntime.process?.isRunning == true {
        throw CloudflareTunnelError.alreadyRunning(profileID)
      }
      cloudflareRuntimes.removeValue(forKey: profileID)
      await Self.releaseCloudflareRuntimeResources(existingRuntime, terminateProcess: true)
    }
    let profile = try requireCloudflareProfile(profileID)
    let configuration = try manifestStore.activeConfiguration()
    let grant = configuration.profileGrant(for: profile.gatewayProfile)
    guard grant.allowedCallers.contains(.cloudflareTunnel) else {
      throw CloudflareTunnelError.profileCallerMismatch(profile.gatewayProfile.rawValue)
    }
    guard let tunnelToken = try await keychainSecretValue(for: profile.tunnelTokenReference) else {
      throw CloudflareTunnelError.missingTunnelToken
    }
    guard let accessToken = try await keychainSecretValue(for: profile.accessTokenReference) else {
      throw CloudflareTunnelError.missingAccessToken
    }
    guard let cloudflared = resolveCloudflared(profile.cloudflaredPath) else {
      throw CloudflareTunnelError.cloudflaredUnavailable
    }
    let versionResult = try ProcessCommandRunner().run(
      executable: cloudflared,
      arguments: ["version"],
      workingDirectory: nil,
      environment: [:],
      timeoutMilliseconds: 5_000,
      maxOutputBytes: 16_384
    )
    let version =
      versionResult.exitCode == 0
      ? versionResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    guard let version, Self.cloudflaredVersionSupportsTokenFile(version) else {
      throw CloudflareTunnelError.unsupportedCloudflaredVersion(version)
    }
    let desiredBeforeStart = try desiredCloudflareProfileIDs().contains(profileID)

    let tokenFile = directories.runtime.appendingPathComponent(
      "cloudflare-\(Self.safeFileComponent(profile.id))-token"
    )
    var runtime = CloudflareRuntimeState(
      profile: profile,
      state: .starting,
      process: nil,
      origin: nil,
      tokenFile: tokenFile,
      stdoutHandle: nil,
      stderrHandle: nil,
      startedAt: nil,
      lastError: nil
    )
    do {
      try Data((tunnelToken + "\n").utf8).write(to: tokenFile, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: tokenFile.path
      )

      var httpConfiguration = configuration
      httpConfiguration.server.http = HTTPServerConfig(
        host: "127.0.0.1",
        port: profile.localPort,
        path: "/mcp",
        healthPath: "/health",
        publicBaseURL: profile.publicBaseURL?.absoluteString,
        accessTokenEnv: nil,
        allowedOrigins: profile.publicBaseURL.map { [$0.absoluteString] } ?? []
      )
      httpConfiguration.runtime = RuntimeBindingConfig(
        caller: .cloudflareTunnel,
        profileID: profile.gatewayProfile
      )
      try httpConfiguration.validate()
      let gateway = try GatewayRuntime(
        configuration: httpConfiguration,
        context: httpConfiguration.executionContext(
          caller: .cloudflareTunnel,
          profileID: profile.gatewayProfile,
          transportTrace: GatewayTransportTrace(
            transport: "cloudflare_tunnel",
            tunnelInstanceID: profile.id,
            tunnelProfileID: profile.tunnelName
          )
        ),
        database: database,
        registeredWorkspaces: try database.workspaces(),
        bookmarkService: bookmarkService
      )
      let origin = GatewayHTTPRuntime(
        configuration: httpConfiguration,
        registry: gateway,
        host: "127.0.0.1",
        port: profile.localPort,
        publicBaseURL: profile.publicBaseURL?.absoluteString,
        accessToken: accessToken
      )
      runtime.origin = origin
      try await origin.startListening()

      let stdoutURL = directories.logs.appendingPathComponent(
        "cloudflare-\(profile.id).stdout.log"
      )
      let stderrURL = directories.logs.appendingPathComponent(
        "cloudflare-\(profile.id).stderr.log"
      )
      FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
      FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
      let stdout = try FileHandle(forWritingTo: stdoutURL)
      runtime.stdoutHandle = stdout
      let stderr = try FileHandle(forWritingTo: stderrURL)
      runtime.stderrHandle = stderr
      try stdout.seekToEnd()
      try stderr.seekToEnd()

      let process = Process()
      process.executableURL = URL(fileURLWithPath: cloudflared)
      process.arguments = [
        "tunnel", "--no-autoupdate", "--metrics", "127.0.0.1:\(profile.metricsPort)",
        "run", "--token-file", tokenFile.path,
      ]
      process.standardOutput = stdout
      process.standardError = stderr
      process.terminationHandler = { [weak self] terminatedProcess in
        let processID = terminatedProcess.processIdentifier
        let terminationStatus = terminatedProcess.terminationStatus
        Task {
          await self?.handleCloudflareProcessExit(
            profileID: profileID,
            processID: processID,
            terminationStatus: terminationStatus
          )
        }
      }
      runtime.process = process
      try process.run()
      try await Task.sleep(for: .milliseconds(250))
      guard process.isRunning else {
        throw CloudflareTunnelError.processLaunchFailed(
          "cloudflared exited during startup with status \(process.terminationStatus)"
        )
      }
      runtime.state = .running
      runtime.startedAt = Date()
      cloudflareRuntimes[profileID] = runtime
      try setCloudflareDesiredRunning(true, profileID: profileID)
      try recordCloudflareLifecycle(profile: profile, action: "start", decision: .allowed)
      return cloudflareTunnelStatuses().first { $0.profileID == profileID }!
    } catch {
      cloudflareRuntimes.removeValue(forKey: profileID)
      await Self.releaseCloudflareRuntimeResources(runtime, terminateProcess: true)
      try? setCloudflareDesiredRunning(desiredBeforeStart, profileID: profileID)
      throw error
    }
  }

  package func stopCloudflareTunnel(profileID: String) async throws -> CloudflareTunnelStatus {
    let profile = try requireCloudflareProfile(profileID)
    guard var runtime = cloudflareRuntimes[profileID] else {
      try setCloudflareDesiredRunning(false, profileID: profileID)
      return cloudflareTunnelStatuses().first { $0.profileID == profileID }!
    }
    runtime.state = .stopping
    cloudflareRuntimes[profileID] = runtime
    await Self.releaseCloudflareRuntimeResources(runtime, terminateProcess: true)
    cloudflareRuntimes.removeValue(forKey: profileID)
    try setCloudflareDesiredRunning(false, profileID: profileID)
    try recordCloudflareLifecycle(profile: profile, action: "stop", decision: .allowed)
    return cloudflareTunnelStatuses().first { $0.profileID == profileID }!
  }

  package func cloudflareTunnelLogs(profileID: String, maxBytes: Int = 65_536) throws
    -> CloudflareTunnelLogs
  {
    _ = try requireCloudflareProfile(profileID)
    let stdoutURL = directories.logs.appendingPathComponent("cloudflare-\(profileID).stdout.log")
    let stderrURL = directories.logs.appendingPathComponent("cloudflare-\(profileID).stderr.log")
    let stdout = Self.boundedLog(stdoutURL, maxBytes: maxBytes)
    let stderr = Self.boundedLog(stderrURL, maxBytes: maxBytes)
    return CloudflareTunnelLogs(
      profileID: profileID,
      stdout: stdout.text,
      stderr: stderr.text,
      truncated: stdout.truncated || stderr.truncated
    )
  }

  private func requireCloudflareProfile(_ id: String) throws -> CloudflareTunnelConfiguration {
    guard let profile = try cloudflareTunnelConfigurations().first(where: { $0.id == id }) else {
      throw CloudflareTunnelError.profileNotFound(id)
    }
    return profile
  }

  private func restoreCloudflareSecret(
    _ value: String?,
    reference: SecretReference
  ) async {
    if let value {
      try? await setKeychainSecret(value, for: reference)
    } else {
      try? await deleteKeychainSecret(reference)
    }
  }

  private func resolveCloudflared(_ requested: String?) -> String? {
    let candidates = [requested, "/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
      .compactMap { $0 }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private func setCloudflareDesiredRunning(_ running: Bool, profileID: String) throws {
    var identifiers = Set(try desiredCloudflareProfileIDs())
    if running { identifiers.insert(profileID) } else { identifiers.remove(profileID) }
    let data = try JSONEncoder().encode(identifiers.sorted())
    try database.saveRuntimeSetting(
      key: "desired-running-cloudflare-tunnels",
      value: String(decoding: data, as: UTF8.self)
    )
  }

  package func desiredCloudflareProfileIDs() throws -> [String] {
    guard let value = try database.runtimeSetting(key: "desired-running-cloudflare-tunnels"),
      let data = value.data(using: .utf8)
    else { return [] }
    return try JSONDecoder().decode([String].self, from: data).sorted()
  }

  private func recordCloudflareLifecycle(
    profile: CloudflareTunnelConfiguration,
    action: String,
    decision: AuditDecision,
    errorCode: String? = nil
  ) throws {
    try database.recordAudit(
      AuditEvent(
        requestID: UUID().uuidString,
        caller: .localApp,
        transport: "control_socket",
        tunnelInstanceID: profile.id,
        tunnelProfileID: profile.tunnelName,
        profileID: profile.gatewayProfile,
        capabilityID: "tunnel.cloudflare.\(action)",
        decision: decision,
        errorCode: errorCode
      )
    )
  }

  private func handleCloudflareProcessExit(
    profileID: String,
    processID: Int32,
    terminationStatus: Int32
  ) async {
    guard var runtime = cloudflareRuntimes[profileID],
      runtime.process?.processIdentifier == processID,
      runtime.state == .running
    else {
      return
    }
    // Keep the externally visible state transitional until sensitive files and
    // runtime resources have been released. Observers must not see `.failed`
    // before cleanup is complete.
    runtime.state = .stopping
    cloudflareRuntimes[profileID] = runtime
    await Self.releaseCloudflareRuntimeResources(runtime, terminateProcess: false)
    guard var current = cloudflareRuntimes[profileID],
      current.process?.processIdentifier == processID,
      current.state == .stopping
    else {
      return
    }
    current.process = nil
    current.origin = nil
    current.tokenFile = nil
    current.stdoutHandle = nil
    current.stderrHandle = nil
    try? recordCloudflareLifecycle(
      profile: current.profile,
      action: "exit",
      decision: .failed,
      errorCode: "tunnel.cloudflare.process_exited"
    )
    current.state = .failed
    current.lastError = "cloudflared exited unexpectedly with status \(terminationStatus)"
    cloudflareRuntimes[profileID] = current
  }

  private static func secureRandomToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw CloudflareTunnelError.processLaunchFailed("secure random generation failed")
    }
    return Data(bytes).base64EncodedString()
  }

  private static func safeFileComponent(_ value: String) -> String {
    value.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
      .reduce(into: "") { $0.append($1) }
  }

  private static func cloudflaredVersionSupportsTokenFile(_ output: String) -> Bool {
    for token in output.split(whereSeparator: { !$0.isNumber && $0 != "." }) {
      let components = token.split(separator: ".", omittingEmptySubsequences: false)
      guard components.count >= 2,
        let year = Int(components[0]),
        let month = Int(components[1])
      else {
        continue
      }
      let patch = components.count > 2 ? Int(components[2]) ?? 0 : 0
      return (year, month, patch) >= (2025, 4, 0)
    }
    return false
  }

  private static func releaseCloudflareRuntimeResources(
    _ runtime: CloudflareRuntimeState,
    terminateProcess: Bool
  ) async {
    runtime.process?.terminationHandler = nil
    if terminateProcess, let process = runtime.process, process.isRunning {
      process.terminate()
      for _ in 0..<20 where process.isRunning {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
    await runtime.origin?.stop()
    try? runtime.stdoutHandle?.close()
    try? runtime.stderrHandle?.close()
    if let tokenFile = runtime.tokenFile {
      try? FileManager.default.removeItem(at: tokenFile)
    }
  }

  private static func boundedLog(_ url: URL, maxBytes: Int) -> (text: String, truncated: Bool) {
    guard let data = try? Data(contentsOf: url) else { return ("", false) }
    let truncated = data.count > maxBytes
    let bounded = truncated ? data.suffix(maxBytes) : data[...]
    return (String(decoding: bounded, as: UTF8.self), truncated)
  }

  private static func metricsHealthy(port: Int) async -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/metrics") else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }
}
