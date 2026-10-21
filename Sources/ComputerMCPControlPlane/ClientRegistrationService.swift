import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

package struct ClientRegistrationStatus: Codable, Sendable {
  package let client: RegistrationClient
  package let state: ClientRegistrationState
  /// When true, state is the last observation before an unconfirmed process exit.
  package let uncertain: Bool
  package let location: ClientRegistrationLocation
  package let observedEntry: ClientRegistrationEntrySummary?

  package init(
    client: RegistrationClient, state: ClientRegistrationState, uncertain: Bool = false,
    location: ClientRegistrationLocation, observedEntry: ClientRegistrationEntrySummary?
  ) {
    self.client = client
    self.state = state
    self.uncertain = uncertain
    self.location = location
    self.observedEntry = observedEntry
  }

  enum CodingKeys: String, CodingKey {
    case client, state, uncertain, location
    case observedEntry = "observed_entry"
  }
}

/// The same immutable service can be used by several callers; apply also locks across processes.
package struct ClientRegistrationService: Sendable {
  private let homeDirectory: URL
  private let stateDirectory: URL
  private let searchDirectories: [String]
  private let invokingEnvironment: [String: String]
  private let processRunner: any RegistrationProcessRunning
  private let desktop: ClaudeDesktopRegistration?
  private let timeoutMilliseconds: Int
  private let maxOutputBytes: Int
  private let argumentLimit: Int
  var desktopWriter = DesktopRegistrationFileWriter()

  package init(
    homeDirectory: URL, stateDirectory: URL, executableSearchDirectories: [String],
    environment: [String: String],
    processRunner: any RegistrationProcessRunning = RegistrationProcessRunner(),
    desktop: ClaudeDesktopRegistration? = nil, timeoutMilliseconds: Int = 30_000,
    maxOutputBytes: Int = 1_048_576, argumentLimit: Int? = nil
  ) {
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.stateDirectory = stateDirectory.standardizedFileURL
    self.searchDirectories =
      executableSearchDirectories + [homeDirectory.appendingPathComponent(".local/bin").path]
    self.invokingEnvironment = environment
    self.processRunner = processRunner
    self.desktop = desktop
    self.timeoutMilliseconds = timeoutMilliseconds
    self.maxOutputBytes = maxOutputBytes
    self.argumentLimit = argumentLimit ?? Int(sysconf(_SC_ARG_MAX))
  }

  package func statuses(server: ClientRegistrationCommand, name: String = "computer-mcp") throws
    -> [ClientRegistrationStatus]
  {
    try RegistrationClient.allCases.map { client in
      let plan = try makePlan(
        bind(client: client, operation: .register, server: server, name: name, clientCLI: nil))
      return .init(
        client: client, state: plan.display.state,
        uncertain: plan.contents.observation.uncertainStep != nil, location: plan.display.location,
        observedEntry: plan.display.observedEntry)
    }
  }

  package func preview(
    client: RegistrationClient, operation: ClientRegistrationOperation,
    server: ClientRegistrationCommand,
    name: String = "computer-mcp", clientCLI: String? = nil
  ) throws -> ClientRegistrationPlan {
    if operation == .register { try server.validateExecutable() }
    return try makePlan(
      bind(client: client, operation: operation, server: server, name: name, clientCLI: clientCLI))
  }

  /// Rechecks the bound location under the writer lock. No private client data leaves this API.
  package func apply(_ plan: ClientRegistrationPlan) throws -> ClientRegistrationResult {
    if let uncertain = plan.uncertainResult { return uncertain }
    let lock = try acquireWriterLock()
    defer { lock.release() }
    let fresh = try makePlan(plan.contents)
    if let uncertain = fresh.uncertainResult {
      return result(
        .uncertain, plan: fresh.contents, steps: uncertain.steps,
        observation: plan.contents.observation, error: .uncertain)
    }
    guard fresh.fingerprint == plan.fingerprint else {
      throw ClientRegistrationError(.changedSincePreview)
    }
    if let refusal = fresh.display.refusalCode { throw ClientRegistrationError(refusal) }
    let contents = fresh.contents
    if contents.actions.isEmpty {
      return result(.succeeded, plan: contents, steps: [], observation: contents.observation)
    }
    if contents.client == .claudeDesktop {
      guard let desktop else { throw ClientRegistrationError(.unavailable) }
      try desktopWriter.write(contents, isRunning: desktop.isRunning)
      let final = read(contents)
      let reached = goalReached(contents, final)
      return result(
        reached ? .succeeded : .failed, plan: contents,
        steps: [.init(step: contents.operation.rawValue, outcome: .succeeded, exitCode: nil)],
        observation: final, error: reached ? nil : .writeFailed)
    }
    if contents.client == .claudeCode {
      return ClaudeCodeClientRegistrar().apply(contents, using: self)
    }
    var steps: [ClientRegistrationStep] = []
    for action in contents.actions {
      let step = execute(action, plan: contents)
      steps.append(step)
      if step.outcome == .uncertain {
        return result(
          .uncertain, plan: contents, steps: steps, observation: contents.observation,
          error: .uncertain)
      }
      if step.outcome != .succeeded { break }
    }
    let final = read(contents)
    if let step = final.uncertainStep {
      steps.append(.init(step: step, outcome: .uncertain, exitCode: nil))
      return result(
        .uncertain, plan: contents, steps: steps, observation: contents.observation,
        error: .uncertain)
    }
    let reached = goalReached(contents, final)
    return result(
      reached ? .succeeded : .failed, plan: contents, steps: steps, observation: final,
      error: reached ? nil : .processFailed)
  }

  private func bind(
    client: RegistrationClient, operation: ClientRegistrationOperation,
    server: ClientRegistrationCommand, name: String, clientCLI: String?
  ) throws -> RegistrationPlanContents {
    guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"),
      client != .claudeDesktop || clientCLI == nil
    else { throw ClientRegistrationError(.invalidInput) }
    let location: ClientRegistrationLocation
    switch client {
    case .codex:
      let directory = ClientRegistrationCommand.absolute(
        invokingEnvironment["CODEX_HOME"] ?? homeDirectory.appendingPathComponent(".codex").path)
      location = .init(
        configurationFile: URL(fileURLWithPath: directory).appendingPathComponent("config.toml")
          .path, configurationVariable: "CODEX_HOME", configurationValue: directory)
    case .claudeCode:
      let directory = invokingEnvironment["CLAUDE_CONFIG_DIR"].map(
        ClientRegistrationCommand.absolute)
      location = .init(
        configurationFile: URL(fileURLWithPath: directory ?? homeDirectory.path)
          .appendingPathComponent(".claude.json").path, configurationVariable: "CLAUDE_CONFIG_DIR",
        configurationValue: directory)
    case .claudeDesktop:
      location = .init(
        configurationFile: desktop?.configurationFile.path ?? "", configurationVariable: nil,
        configurationValue: nil)
    }
    let executable = client == .claudeDesktop ? nil : resolveClient(clientCLI, client: client)
    let user = invokingEnvironment["USER"] ?? NSUserName()
    var environment = [
      "HOME": homeDirectory.path, "USER": user, "LOGNAME": invokingEnvironment["LOGNAME"] ?? user,
      "TMPDIR": invokingEnvironment["TMPDIR"] ?? NSTemporaryDirectory(),
      "LANG": invokingEnvironment["LANG"] ?? "en_US.UTF-8",
      "PATH":
        ([executable.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }].compactMap {
          $0
        } + searchDirectories).joined(separator: ":"),
    ]
    if let variable = location.configurationVariable, let value = location.configurationValue {
      environment[variable] = value
    }
    return .init(
      client: client, operation: operation, serverName: name, location: location, server: server,
      clientExecutable: executable, environment: environment,
      observation: .init(state: .unavailable, entry: nil), actions: [], refusalCode: nil,
      warnings: [])
  }

  private func makePlan(_ bound: RegistrationPlanContents) throws -> ClientRegistrationPlan {
    var observed: RegistrationObservation
    if bound.client == .claudeDesktop {
      observed =
        desktop?.isInstalled() == true ? read(bound) : .init(state: .unavailable, entry: nil)
    } else if let executable = bound.clientExecutable {
      do {
        let probe = try run(executable, ["--version"], bound.environment)
        if probe.exitCode == nil {
          observed = .init(state: .unavailable, entry: nil, uncertainStep: "probe")
        } else if probe.exitCode == 0, !probe.timedOut, !probe.stdoutTruncated,
          !probe.stderrTruncated
        {
          observed = read(bound)
        } else {
          observed = .init(state: .unavailable, entry: nil)
        }
      } catch { observed = .init(state: .unavailable, entry: nil) }
    } else {
      observed = .init(state: .unavailable, entry: nil)
    }
    var refusal: ClientRegistrationErrorCode?
    if observed.uncertainStep != nil {
      refusal = .uncertain
    } else if observed.state == .unavailable {
      refusal = .unavailable
    } else if observed.state == .unreadable {
      refusal = .unreadable
    } else if bound.client == .claudeCode, bound.operation == .register,
      observed.state == .different,
      !ClaudeCodeClientRegistrar().canRestore(
        observed.entry, plan: bound, argumentLimit: argumentLimit)
    {
      refusal = .unsupportedEntry
    }
    let warnings =
      bound.client == .claudeDesktop
      ? [
        "Claude Desktop must be closed before applying this plan.",
        "Close other programs that edit this file. A write after the final check can be lost.",
      ] : []
    let candidate = RegistrationPlanContents(
      client: bound.client, operation: bound.operation, serverName: bound.serverName,
      location: bound.location, server: bound.server, clientExecutable: bound.clientExecutable,
      environment: bound.environment, observation: observed, actions: [], refusalCode: refusal,
      warnings: warnings)
    var actions: [ClientRegistrationAction] = []
    if refusal == nil, !(observed.state == .registered && bound.operation == .register),
      !(observed.state == .notRegistered && bound.operation == .remove)
    {
      switch bound.client {
      case .codex: actions = CodexClientRegistrar().actions(candidate)
      case .claudeCode: actions = ClaudeCodeClientRegistrar().actions(candidate)
      case .claudeDesktop: actions = ClaudeDesktopClientRegistrar().actions(candidate)
      }
    }
    let contents = RegistrationPlanContents(
      client: candidate.client, operation: candidate.operation, serverName: candidate.serverName,
      location: candidate.location, server: candidate.server,
      clientExecutable: candidate.clientExecutable, environment: candidate.environment,
      observation: candidate.observation, actions: actions, refusalCode: refusal, warnings: warnings
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let fingerprint = SHA256.hash(data: try encoder.encode(contents)).map {
      String(format: "%02x", $0)
    }.joined()
    let display = ClientRegistrationDisplayPlan(
      schemaVersion: 1, client: contents.client, operation: contents.operation,
      serverName: contents.serverName, location: contents.location, state: observed.state,
      observedEntry: observed.entry.map { .init($0, client: bound.client) },
      server: contents.server, actions: actions, requiresConfirmation: observed.state == .different,
      refusalCode: refusal, warnings: warnings, appliesAfter: contents.client.appliesAfter,
      fingerprint: fingerprint)
    return .init(contents: contents, display: display)
  }

  private func resolveClient(_ explicit: String?, client: RegistrationClient) -> String? {
    let candidates =
      explicit.map { [ClientRegistrationCommand.absolute($0)] }
      ?? searchDirectories.map {
        URL(fileURLWithPath: $0).appendingPathComponent(client == .codex ? "codex" : "claude").path
      }
    return candidates.first { path in
      var info = stat()
      return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
    }
  }

  private func read(_ plan: RegistrationPlanContents) -> RegistrationObservation {
    switch plan.client {
    case .codex: CodexClientRegistrar().read(plan, using: self)
    case .claudeCode: ClaudeCodeClientRegistrar().read(plan, using: self)
    case .claudeDesktop: ClaudeDesktopClientRegistrar().read(plan, using: self)
    }
  }

  func observation(_ entry: JSONValue?, for plan: RegistrationPlanContents)
    -> RegistrationObservation
  {
    guard let entry else { return .init(state: .notRegistered, entry: nil) }
    guard let object = entry.objectValue else { return .init(state: .unreadable, entry: nil) }
    let command = plan.client == .codex ? object["transport"]?.objectValue : object
    let matches =
      command?["command"]?.stringValue == plan.server.executable
      && (command?["args"] ?? .array([])) == .array(plan.server.arguments.map(JSONValue.string))
    return .init(state: matches ? .registered : .different, entry: entry)
  }

  func run(_ executable: String, _ arguments: [String], _ environment: [String: String]) throws
    -> CommandResult
  {
    try processRunner.run(
      executable: executable, arguments: arguments, environment: environment,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
  }

  func execute(_ action: ClientRegistrationAction, plan: RegistrationPlanContents)
    -> ClientRegistrationStep
  {
    guard let command = action.command else {
      return .init(step: action.step, outcome: .launchFailed, exitCode: nil)
    }
    return executePrivate(
      step: action.step, executable: command.executable, arguments: command.arguments, plan: plan)
  }

  func executePrivate(
    step: String, executable: String, arguments: [String], plan: RegistrationPlanContents
  ) -> ClientRegistrationStep {
    do {
      let result = try run(executable, arguments, plan.environment)
      let outcome: ClientRegistrationStep.Outcome =
        result.exitCode == nil
        ? .uncertain
        : result.timedOut ? .timedOut : result.exitCode == 0 ? .succeeded : .failed
      return .init(step: step, outcome: outcome, exitCode: result.exitCode)
    } catch { return .init(step: step, outcome: .launchFailed, exitCode: nil) }
  }

  func goalReached(_ plan: RegistrationPlanContents, _ observed: RegistrationObservation) -> Bool {
    observed.state == (plan.operation == .register ? .registered : .notRegistered)
  }

  func result(
    _ outcome: ClientRegistrationResult.Outcome, plan: RegistrationPlanContents,
    steps: [ClientRegistrationStep], observation: RegistrationObservation,
    error: ClientRegistrationErrorCode? = nil, recovery: ClientRegistrationRecovery? = nil
  ) -> ClientRegistrationResult {
    .init(
      outcome: outcome, errorCode: error, steps: steps, finalState: observation.state,
      finalEntry: observation.entry.map { .init($0, client: plan.client) },
      appliesAfter: plan.client.appliesAfter, recovery: recovery)
  }

  private func acquireWriterLock() throws -> FileLock {
    do {
      try FileManager.default.createDirectory(
        at: stateDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch { throw ClientRegistrationError(.writeFailed) }
    let deadline = ContinuousClock.now + .seconds(30)
    while true {
      do {
        return try FileLock(
          path: stateDirectory.appendingPathComponent("client-registration.lock").path,
          mode: .exclusive)
      } catch is FileLockError {
        guard ContinuousClock.now < deadline else { throw ClientRegistrationError(.writerBusy) }
        usleep(10_000)
      } catch { throw ClientRegistrationError(.writeFailed) }
    }
  }
}
