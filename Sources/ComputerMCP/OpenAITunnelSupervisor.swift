import Foundation

package struct OpenAITunnelConfiguration: Codable, Equatable, Sendable, Identifiable {
  package var id: String
  package var tunnelClientProfile: String
  package var tunnelID: String
  package var gatewayProfile: GatewayProfileID
  package var manifestPath: String
  package var gatewayExecutablePath: String
  package var gatewaySocketPath: String?
  package var profileDirectory: String?
  package var tunnelClientPath: String?
  package var httpProxy: String?
  package var apiKeyReference: SecretReference?

  private enum CodingKeys: String, CodingKey {
    case id
    case tunnelClientProfile = "tunnel_client_profile"
    case tunnelID = "tunnel_id"
    case gatewayProfile = "gateway_profile"
    case manifestPath = "manifest_path"
    case gatewayExecutablePath = "gateway_executable_path"
    case gatewaySocketPath = "gateway_socket_path"
    case profileDirectory = "profile_directory"
    case tunnelClientPath = "tunnel_client_path"
    case httpProxy = "http_proxy"
    case apiKeyReference = "api_key_reference"
  }

  package init(
    id: String,
    tunnelClientProfile: String,
    tunnelID: String,
    gatewayProfile: GatewayProfileID = .chatGPTObserve,
    manifestPath: String,
    gatewayExecutablePath: String,
    gatewaySocketPath: String? = nil,
    profileDirectory: String? = nil,
    tunnelClientPath: String? = nil,
    httpProxy: String? = nil,
    apiKeyReference: SecretReference? = nil
  ) {
    self.id = id
    self.tunnelClientProfile = tunnelClientProfile
    self.tunnelID = tunnelID
    self.gatewayProfile = gatewayProfile
    self.manifestPath = manifestPath
    self.gatewayExecutablePath = gatewayExecutablePath
    self.gatewaySocketPath = gatewaySocketPath
    self.profileDirectory = profileDirectory
    self.tunnelClientPath = tunnelClientPath
    self.httpProxy = httpProxy
    self.apiKeyReference = apiKeyReference
  }

  package func validate() throws {
    try validateConfigIdentifier(id, label: "transports.openai.id")
    for (label, value) in [
      ("tunnel-client profile", tunnelClientProfile),
      ("Tunnel ID", tunnelID),
      ("manifest path", manifestPath),
      ("gateway executable path", gatewayExecutablePath),
    ] {
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !value.contains("\0")
      else {
        throw OpenAITunnelSupervisorError.invalidProfile("\(label) is invalid.")
      }
    }
    guard gatewayProfile != .localAdmin else {
      throw OpenAITunnelSupervisorError.invalidProfile(
        "local-admin must never be exposed through a tunnel."
      )
    }
    if let gatewaySocketPath {
      let normalized = gatewaySocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.isEmpty, !normalized.contains("\0"), normalized.hasPrefix("/") else {
        throw OpenAITunnelSupervisorError.invalidProfile(
          "gateway socket path must be an absolute path."
        )
      }
    }
    if let apiKeyReference,
      apiKeyReference.account != "tunnel.\(id).openai-api-key"
    {
      throw OpenAITunnelSupervisorError.invalidProfile("API key reference is not canonical.")
    }
    if let httpProxy,
      let failure = openAITunnelHTTPProxyValidationFailure(httpProxy)
    {
      throw OpenAITunnelSupervisorError.invalidProfile(failure)
    }
  }
}

package enum OpenAITunnelLifecycleState: String, Codable, Equatable, Sendable {
  case stopped
  case starting
  case running
  case stopping
  case failed
}

package struct OpenAITunnelStatus: Codable, Equatable, Sendable {
  package var profileID: String
  package var state: OpenAITunnelLifecycleState
  package var sessionID: String?
  package var processID: Int32?
  package var startedAt: Date?
  package var lastError: String?

  private enum CodingKeys: String, CodingKey {
    case profileID = "profile_id"
    case state
    case sessionID = "session_id"
    case processID = "process_id"
    case startedAt = "started_at"
    case lastError = "last_error"
  }

  package init(
    profileID: String,
    state: OpenAITunnelLifecycleState,
    sessionID: String? = nil,
    processID: Int32? = nil,
    startedAt: Date? = nil,
    lastError: String? = nil
  ) {
    self.profileID = profileID
    self.state = state
    self.sessionID = sessionID
    self.processID = processID
    self.startedAt = startedAt
    self.lastError = lastError
  }
}

package struct OpenAITunnelDoctorReport: Codable, Equatable, Sendable {
  package var profileID: String
  package var passed: Bool
  package var exitCode: Int32?
  package var timedOut: Bool
  package var stdout: String
  package var stderr: String

  private enum CodingKeys: String, CodingKey {
    case profileID = "profile_id"
    case passed
    case exitCode = "exit_code"
    case timedOut = "timed_out"
    case stdout
    case stderr
  }

  package init(
    profileID: String,
    passed: Bool,
    exitCode: Int32?,
    timedOut: Bool,
    stdout: String,
    stderr: String
  ) {
    self.profileID = profileID
    self.passed = passed
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.stdout = stdout
    self.stderr = stderr
  }
}

package struct OpenAITunnelLogPage: Codable, Equatable, Sendable {
  package var profileID: String
  package var status: OpenAITunnelStatus
  package var stdout: ShellStreamRead
  package var stderr: ShellStreamRead

  private enum CodingKeys: String, CodingKey {
    case profileID = "profile_id"
    case status
    case stdout
    case stderr
  }

  package init(
    profileID: String,
    status: OpenAITunnelStatus,
    stdout: ShellStreamRead,
    stderr: ShellStreamRead
  ) {
    self.profileID = profileID
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }
}

internal protocol OpenAITunnelClientResolving: Sendable {
  func resolve(
    requestedPath: String?,
    configuration: GatewayConfiguration
  ) throws -> String
}

internal struct OpenAITunnelClientResolver: OpenAITunnelClientResolving {
  private let commandRunner: any CommandRunning
  private let environment: [String: String]

  internal init(
    commandRunner: any CommandRunning = ProcessCommandRunner(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.commandRunner = commandRunner
    self.environment = environment
  }

  internal func resolve(
    requestedPath: String?,
    configuration: GatewayConfiguration
  ) throws -> String {
    if let requestedPath {
      let path = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
      guard FileManager.default.isExecutableFile(atPath: path) else {
        throw OpenAITunnelSupervisorError.tunnelClientUnavailable
      }
      return path
    }

    let discovery = ExternalProviderDiscovery(
      configuration: configuration,
      definitions: ExternalProviderDefinition.defaults.filter { $0.kind == .tunnelClient },
      commandRunner: commandRunner,
      environment: environment
    )
    guard let result = try discovery.discover().first,
      let path = result.resolvedPath,
      result.doctorStatus.state != .unavailable
    else {
      throw OpenAITunnelSupervisorError.tunnelClientUnavailable
    }
    return path
  }
}

internal protocol OpenAITunnelPlanBuilding: Sendable {
  func plan(profile: OpenAITunnelConfiguration, tunnelClientPath: String, force: Bool) throws
    -> OpenAITunnelPlan
}

internal struct OpenAITunnelPlanBuilder: OpenAITunnelPlanBuilding {
  internal func plan(
    profile: OpenAITunnelConfiguration,
    tunnelClientPath: String,
    force: Bool
  ) throws -> OpenAITunnelPlan {
    try OpenAITunnelLauncher().plan(
      tunnelClient: tunnelClientPath,
      profile: profile.tunnelClientProfile,
      configPath: profile.manifestPath,
      executablePath: profile.gatewayExecutablePath,
      gatewaySocketPath: profile.gatewaySocketPath,
      gatewayProfile: profile.gatewayProfile,
      tunnelID: profile.tunnelID,
      profileDirectory: profile.profileDirectory,
      httpProxy: profile.httpProxy,
      forceInit: force
    )
  }
}

internal protocol OpenAITunnelProcessManaging: Sendable {
  func spawn(
    executable: String,
    arguments: [String],
    environment: [String: String],
    maxOutputBytes: Int
  ) throws -> String
  func read(
    sessionID: String,
    stdoutCursor: Int64,
    stderrCursor: Int64,
    maxReadBytes: Int
  ) throws -> ShellSessionSnapshot
  func cancel(sessionID: String) throws
}

internal final class SubprocessOpenAITunnelProcessManager: OpenAITunnelProcessManaging,
  @unchecked Sendable
{
  private let shellManager: any ShellManaging

  internal init(shellManager: any ShellManaging = SubprocessShellRuntime()) {
    self.shellManager = shellManager
  }

  internal func spawn(
    executable: String,
    arguments: [String],
    environment: [String: String],
    maxOutputBytes: Int
  ) throws -> String {
    try shellManager.spawn(
      request: ShellLaunchRequest(
        mode: .argv,
        executable: executable,
        argv: arguments,
        environment: environment
      ),
      defaultShell: "/bin/zsh",
      defaultWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser,
      timeoutMilliseconds: nil,
      maxOutputBytes: maxOutputBytes,
      maxSessions: 8,
      terminationGraceMilliseconds: 2_000
    )
  }

  internal func read(
    sessionID: String,
    stdoutCursor: Int64,
    stderrCursor: Int64,
    maxReadBytes: Int
  ) throws -> ShellSessionSnapshot {
    try shellManager.read(
      sessionID: sessionID,
      stdoutCursor: stdoutCursor,
      stderrCursor: stderrCursor,
      maxReadBytes: maxReadBytes,
      encoding: .utf8
    )
  }

  internal func cancel(sessionID: String) throws {
    _ = try shellManager.cancel(sessionID: sessionID)
  }
}

internal actor OpenAITunnelSupervisor {
  private let secretStore: KeychainSecretStore
  private let resolver: any OpenAITunnelClientResolving
  private let planBuilder: any OpenAITunnelPlanBuilding
  private let proxyResolver: any OpenAITunnelHTTPProxyResolving
  private let commandRunner: any CommandRunning
  private let processManager: any OpenAITunnelProcessManaging
  private let maxOutputBytes: Int
  private let startupStabilityMilliseconds: Int
  private var statuses: [String: OpenAITunnelStatus] = [:]
  private var startupTokens: [String: UUID] = [:]

  internal init(
    secretStore: KeychainSecretStore,
    resolver: any OpenAITunnelClientResolving = OpenAITunnelClientResolver(),
    planBuilder: any OpenAITunnelPlanBuilding = OpenAITunnelPlanBuilder(),
    proxyResolver: any OpenAITunnelHTTPProxyResolving = SystemOpenAITunnelHTTPProxyResolver(),
    commandRunner: any CommandRunning = ProcessCommandRunner(),
    processManager: any OpenAITunnelProcessManaging = SubprocessOpenAITunnelProcessManager(),
    maxOutputBytes: Int = 1_048_576,
    startupStabilityMilliseconds: Int = 500
  ) {
    self.secretStore = secretStore
    self.resolver = resolver
    self.planBuilder = planBuilder
    self.proxyResolver = proxyResolver
    self.commandRunner = commandRunner
    self.processManager = processManager
    self.maxOutputBytes = max(4_096, maxOutputBytes)
    self.startupStabilityMilliseconds = max(0, startupStabilityMilliseconds)
  }

  internal func status(profileID: String) -> OpenAITunnelStatus {
    refreshStatus(profileID: profileID)
  }

  internal func statusesSnapshot() -> [OpenAITunnelStatus] {
    statuses.keys.map(refreshStatus(profileID:)).sorted { $0.profileID < $1.profileID }
  }

  @discardableResult
  internal func provision(
    _ profile: OpenAITunnelConfiguration,
    configuration: GatewayConfiguration,
    force: Bool = false
  ) async throws -> OpenAITunnelDoctorReport {
    try profile.validate()
    let context = try await executionContext(
      profile: profile,
      configuration: configuration,
      force: force
    )
    guard let invocation = context.plan.initInvocation else {
      throw OpenAITunnelSupervisorError.profileProvisioningUnavailable
    }
    let result: CommandResult
    do {
      result = try runControl(invocation, environment: context.environment)
    } catch {
      throw OpenAITunnelSupervisorError.provisionFailed(
        redact(stableErrorDescription(error), secret: context.secret)
      )
    }
    guard result.exitCode == 0, !result.timedOut else {
      throw OpenAITunnelSupervisorError.provisionFailed(
        stableProcessFailure(result, secret: context.secret)
      )
    }
    return report(
      profileID: profile.id,
      result: result,
      secret: context.secret
    )
  }

  internal func doctor(
    _ profile: OpenAITunnelConfiguration,
    configuration: GatewayConfiguration
  ) async throws -> OpenAITunnelDoctorReport {
    try profile.validate()
    let context = try await executionContext(
      profile: profile,
      configuration: configuration,
      force: false
    )
    let result: CommandResult
    do {
      result = try runControl(
        doctorInvocation(
          context.plan.doctorInvocation,
          profileID: profile.id
        ),
        environment: context.environment
      )
    } catch {
      throw OpenAITunnelSupervisorError.doctorFailed(
        redact(stableErrorDescription(error), secret: context.secret)
      )
    }
    return report(profileID: profile.id, result: result, secret: context.secret)
  }

  @discardableResult
  internal func start(
    _ profile: OpenAITunnelConfiguration,
    configuration: GatewayConfiguration,
    authenticationUI: KeychainAuthenticationUI = .allow
  ) async throws -> OpenAITunnelStatus {
    try profile.validate()
    if let current = statuses[profile.id], current.state == .running || current.state == .starting {
      throw OpenAITunnelSupervisorError.alreadyRunning(profile.id)
    }
    let startupToken = UUID()
    startupTokens[profile.id] = startupToken
    statuses[profile.id] = OpenAITunnelStatus(profileID: profile.id, state: .starting)

    var secretForRedaction: String?
    var spawnedSessionID: String?
    do {
      let context = try await executionContext(
        profile: profile,
        configuration: configuration,
        force: false,
        authenticationUI: authenticationUI
      )
      try requireActiveStartup(profileID: profile.id, token: startupToken)
      secretForRedaction = context.secret
      let doctorResult = try runControl(
        context.plan.doctorInvocation,
        environment: context.environment
      )
      guard doctorResult.exitCode == 0, !doctorResult.timedOut else {
        throw OpenAITunnelSupervisorError.doctorFailed(
          stableProcessFailure(doctorResult, secret: context.secret)
        )
      }
      let sessionID = try processManager.spawn(
        executable: context.plan.runInvocation.tunnelClient,
        arguments: context.plan.runInvocation.arguments,
        environment: context.environment,
        maxOutputBytes: maxOutputBytes
      )
      spawnedSessionID = sessionID
      var snapshot = try processManager.read(
        sessionID: sessionID,
        stdoutCursor: 0,
        stderrCursor: 0,
        maxReadBytes: 0
      )
      statuses[profile.id] = OpenAITunnelStatus(
        profileID: profile.id,
        state: .starting,
        sessionID: sessionID,
        processID: snapshot.processID,
        startedAt: snapshot.startedAt,
        lastError: snapshot.isRunning ? nil : processExitDescription(snapshot)
      )
      if snapshot.isRunning, startupStabilityMilliseconds > 0 {
        try await Task.sleep(for: .milliseconds(startupStabilityMilliseconds))
        try requireActiveStartup(profileID: profile.id, token: startupToken)
        snapshot = try processManager.read(
          sessionID: sessionID,
          stdoutCursor: 0,
          stderrCursor: 0,
          maxReadBytes: 0
        )
      }
      let state = snapshot.isRunning ? OpenAITunnelLifecycleState.running : .failed
      let result = OpenAITunnelStatus(
        profileID: profile.id,
        state: state,
        sessionID: sessionID,
        processID: snapshot.processID,
        startedAt: snapshot.startedAt,
        lastError: processExitDescription(snapshot).map { redact($0, secret: context.secret) }
      )
      statuses[profile.id] = result
      guard state == .running else {
        throw OpenAITunnelSupervisorError.startFailed(
          result.lastError ?? "Tunnel exited during startup.")
      }
      startupTokens[profile.id] = nil
      return result
    } catch {
      if let spawnedSessionID {
        try? processManager.cancel(sessionID: spawnedSessionID)
      }
      let detail = redact(stableErrorDescription(error), secret: secretForRedaction)
      if startupTokens[profile.id] == startupToken {
        startupTokens[profile.id] = nil
        let current = statuses[profile.id]
        statuses[profile.id] = OpenAITunnelStatus(
          profileID: profile.id,
          state: .failed,
          sessionID: current?.sessionID,
          processID: current?.processID,
          startedAt: current?.startedAt,
          lastError: detail
        )
      }
      if let supervisorError = error as? OpenAITunnelSupervisorError {
        switch supervisorError {
        case .invalidProfile(_), .tunnelClientUnavailable, .secretMissing, .alreadyRunning(_):
          throw supervisorError
        default:
          break
        }
      }
      throw OpenAITunnelSupervisorError.startFailed(detail)
    }
  }

  @discardableResult
  internal func reconnect(
    _ profile: OpenAITunnelConfiguration,
    configuration: GatewayConfiguration,
    authenticationUI: KeychainAuthenticationUI = .allow
  ) async throws -> OpenAITunnelStatus {
    try stop(profileID: profile.id)
    return try await start(
      profile,
      configuration: configuration,
      authenticationUI: authenticationUI
    )
  }

  @discardableResult
  internal func stop(profileID: String) throws -> OpenAITunnelStatus {
    startupTokens[profileID] = nil
    guard let current = statuses[profileID], let sessionID = current.sessionID else {
      let stopped = OpenAITunnelStatus(profileID: profileID, state: .stopped)
      statuses[profileID] = stopped
      return stopped
    }
    statuses[profileID] = OpenAITunnelStatus(
      profileID: profileID,
      state: .stopping,
      sessionID: sessionID,
      processID: current.processID,
      startedAt: current.startedAt
    )
    try processManager.cancel(sessionID: sessionID)
    let stopped = OpenAITunnelStatus(profileID: profileID, state: .stopped)
    statuses[profileID] = stopped
    return stopped
  }

  internal func logs(
    profileID: String,
    stdoutCursor: Int64 = 0,
    stderrCursor: Int64 = 0,
    maxReadBytes: Int = 65_536,
    secretReference: SecretReference? = nil
  ) async throws -> OpenAITunnelLogPage {
    guard stdoutCursor >= 0, stderrCursor >= 0, maxReadBytes >= 0 else {
      throw OpenAITunnelSupervisorError.invalidCursor
    }
    guard let current = statuses[profileID], let sessionID = current.sessionID else {
      throw OpenAITunnelSupervisorError.notRunning(profileID)
    }
    let snapshot = try processManager.read(
      sessionID: sessionID,
      stdoutCursor: stdoutCursor,
      stderrCursor: stderrCursor,
      maxReadBytes: min(maxReadBytes, maxOutputBytes)
    )
    let secret = try await secretValue(for: secretReference)
    var refreshed = current
    refreshed.state =
      snapshot.isRunning
      ? .running
      : (snapshot.exitCode == 0 && !snapshot.timedOut ? .stopped : .failed)
    refreshed.processID = snapshot.processID
    refreshed.lastError = processExitDescription(snapshot).map { redact($0, secret: secret) }
    statuses[profileID] = refreshed
    return OpenAITunnelLogPage(
      profileID: profileID,
      status: refreshed,
      stdout: redacted(snapshot.stdout, secret: secret),
      stderr: redacted(snapshot.stderr, secret: secret)
    )
  }

  private func refreshStatus(profileID: String) -> OpenAITunnelStatus {
    guard var current = statuses[profileID], let sessionID = current.sessionID else {
      return statuses[profileID] ?? OpenAITunnelStatus(profileID: profileID, state: .stopped)
    }
    guard current.state == .running || current.state == .starting else {
      return current
    }
    do {
      let snapshot = try processManager.read(
        sessionID: sessionID,
        stdoutCursor: 0,
        stderrCursor: 0,
        maxReadBytes: 0
      )
      current.processID = snapshot.processID
      current.startedAt = snapshot.startedAt
      if snapshot.isRunning {
        current.state = current.state == .starting ? .starting : .running
      } else {
        current.state = snapshot.exitCode == 0 && !snapshot.timedOut ? .stopped : .failed
        current.lastError = processExitDescription(snapshot)
      }
    } catch {
      current.state = .failed
      current.lastError = stableErrorDescription(error)
    }
    statuses[profileID] = current
    return current
  }

  private func requireActiveStartup(profileID: String, token: UUID) throws {
    guard startupTokens[profileID] == token else {
      throw OpenAITunnelSupervisorError.startFailed("Tunnel startup was cancelled.")
    }
  }

  private func processExitDescription(_ snapshot: ShellSessionSnapshot) -> String? {
    if let launchError = snapshot.launchError {
      return launchError
    }
    if snapshot.timedOut {
      return "Tunnel process timed out."
    }
    if snapshot.cancelled {
      return "Tunnel process was cancelled."
    }
    if let signal = snapshot.signal {
      return "Tunnel process exited after signal \(signal)."
    }
    if let exitCode = snapshot.exitCode, exitCode != 0 {
      return "Tunnel process exited with code \(exitCode)."
    }
    if let streamError = snapshot.streamErrors.first {
      return streamError
    }
    return nil
  }

  private func executionContext(
    profile: OpenAITunnelConfiguration,
    configuration: GatewayConfiguration,
    force: Bool,
    authenticationUI: KeychainAuthenticationUI = .allow
  ) async throws -> TunnelExecutionContext {
    let tunnelClientPath = try resolver.resolve(
      requestedPath: profile.tunnelClientPath,
      configuration: configuration
    )
    let secret = try await secretValue(
      for: profile.apiKeyReference,
      authenticationUI: authenticationUI
    )
    if profile.apiKeyReference != nil, secret == nil {
      throw OpenAITunnelSupervisorError.secretMissing
    }
    let environment =
      secret.map {
        [
          "CONTROL_PLANE_API_KEY": $0,
          "OPENAI_API_KEY": $0,
        ]
      } ?? [:]
    var effectiveProfile = profile
    if effectiveProfile.httpProxy == nil {
      effectiveProfile.httpProxy = proxyResolver.systemHTTPProxy()
    }
    try effectiveProfile.validate()
    let plan = try planBuilder.plan(
      profile: effectiveProfile,
      tunnelClientPath: tunnelClientPath,
      force: force
    )
    return TunnelExecutionContext(plan: plan, environment: environment, secret: secret)
  }

  private func secretValue(
    for reference: SecretReference?,
    authenticationUI: KeychainAuthenticationUI = .allow
  ) async throws -> String? {
    guard let reference else {
      return nil
    }
    return try await secretStore.valueAsynchronously(
      for: reference,
      authenticationUI: authenticationUI
    )
  }

  private func runControl(
    _ invocation: OpenAITunnelInvocation,
    environment: [String: String]
  ) throws -> CommandResult {
    try commandRunner.run(
      executable: invocation.tunnelClient,
      arguments: invocation.arguments,
      workingDirectory: nil,
      environment: environment,
      timeoutMilliseconds: 30_000,
      maxOutputBytes: maxOutputBytes
    )
  }

  private func doctorInvocation(
    _ invocation: OpenAITunnelInvocation,
    profileID: String
  ) -> OpenAITunnelInvocation {
    guard refreshStatus(profileID: profileID).state == .running else {
      return invocation
    }

    var runningInvocation = invocation
    runningInvocation.arguments += [
      "--health.listen-addr",
      "127.0.0.1:0",
    ]
    return runningInvocation
  }

  private func report(
    profileID: String,
    result: CommandResult,
    secret: String?
  ) -> OpenAITunnelDoctorReport {
    OpenAITunnelDoctorReport(
      profileID: profileID,
      passed: result.exitCode == 0 && !result.timedOut,
      exitCode: result.exitCode,
      timedOut: result.timedOut,
      stdout: redact(result.stdout, secret: secret),
      stderr: redact(result.stderr, secret: secret)
    )
  }

  private func redacted(_ value: ShellStreamRead, secret: String?) -> ShellStreamRead {
    guard let text = value.text else {
      return value
    }
    var copy = value
    copy.text = redact(text, secret: secret)
    return copy
  }

  private func redact(_ value: String, secret: String?) -> String {
    guard let secret, !secret.isEmpty else {
      return value
    }
    return value.replacingOccurrences(of: secret, with: "[REDACTED]")
  }

  private func stableProcessFailure(_ result: CommandResult, secret: String?) -> String {
    if result.timedOut {
      return "Tunnel command timed out."
    }
    let detail = [result.stderr, result.stdout]
      .map { redact($0, secret: secret).trimmingCharacters(in: .whitespacesAndNewlines) }
      .first(where: { !$0.isEmpty })
    return detail
      ?? "Tunnel command failed with exit code \(result.exitCode.map(String.init) ?? "unknown")."
  }

  private func stableErrorDescription(_ error: Error) -> String {
    if let localized = error as? any LocalizedError, let description = localized.errorDescription {
      return description
    }
    return String(describing: type(of: error))
  }
}

private struct TunnelExecutionContext {
  var plan: OpenAITunnelPlan
  var environment: [String: String]
  var secret: String?
}

internal enum OpenAITunnelSupervisorError: Error, LocalizedError, Equatable {
  case invalidProfile(String)
  case tunnelClientUnavailable
  case secretMissing
  case profileProvisioningUnavailable
  case provisionFailed(String)
  case doctorFailed(String)
  case startFailed(String)
  case alreadyRunning(String)
  case notRunning(String)
  case invalidCursor

  internal var errorDescription: String? {
    switch self {
    case .invalidProfile(let detail):
      return "Invalid tunnel profile: \(detail)"
    case .tunnelClientUnavailable:
      return "tunnel-client is unavailable."
    case .secretMissing:
      return "The configured API key reference has no Keychain value."
    case .profileProvisioningUnavailable:
      return "The tunnel plan does not include profile provisioning."
    case .provisionFailed(let detail):
      return "Tunnel profile provisioning failed: \(detail)"
    case .doctorFailed(let detail):
      return "Tunnel doctor failed: \(detail)"
    case .startFailed(let detail):
      return "Tunnel startup failed: \(detail)"
    case .alreadyRunning(let id):
      return "Tunnel profile is already running: \(id)"
    case .notRunning(let id):
      return "Tunnel profile is not running: \(id)"
    case .invalidCursor:
      return "Tunnel log cursors and limits must be non-negative."
    }
  }
}
