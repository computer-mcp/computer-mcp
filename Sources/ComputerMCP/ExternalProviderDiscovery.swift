import Foundation

internal enum ExternalProviderKind: String, Codable, CaseIterable, Equatable, Sendable {
  case appleCLIMCP = "apple-cli-mcp"
  case browser
  case codex
  case tunnelClient = "tunnel-client"
}

internal enum ExternalProviderDoctorState: String, Codable, Equatable, Sendable {
  case unavailable
  case notApplicable = "not-applicable"
  case passed
  case failed
  case contractIncomplete = "contract-incomplete"
}

internal enum ExternalProviderDiagnosticCode: String, Codable, Equatable, Sendable {
  case executableNotFound = "executable-not-found"
  case versionProbeFailed = "version-probe-failed"
  case versionUnavailable = "version-unavailable"
  case contractIncomplete = "contract-incomplete"
  case doctorFailed = "doctor-failed"
  case probeLaunchFailed = "probe-launch-failed"
}

internal struct ExternalProviderDiagnostic: Codable, Equatable, Sendable {
  internal var code: ExternalProviderDiagnosticCode
  internal var operation: String
  internal var message: String

}

internal struct ExternalProviderDoctorStatus: Codable, Equatable, Sendable {
  internal var state: ExternalProviderDoctorState
  internal var message: String
  internal var exitCode: Int32?
  internal var missingCapabilities: [String]

  internal init(
    state: ExternalProviderDoctorState,
    message: String,
    exitCode: Int32? = nil,
    missingCapabilities: [String] = []
  ) {
    self.state = state
    self.message = message
    self.exitCode = exitCode
    self.missingCapabilities = missingCapabilities
  }
}

internal struct ExternalProviderDiscoveryResult: Codable, Equatable, Sendable {
  internal var providerID: String
  internal var kind: ExternalProviderKind
  internal var resolvedPath: String?
  internal var launchArguments: [String]
  internal var version: String?
  internal var doctorStatus: ExternalProviderDoctorStatus
  internal var diagnostics: [ExternalProviderDiagnostic]

}

internal struct ExternalProviderLaunchConfig: Codable, Equatable, Hashable, Sendable {
  internal var executable: String
  internal var arguments: [String]

  internal init(executable: String, arguments: [String] = []) {
    self.executable = executable
    self.arguments = arguments
  }
}

internal struct ExternalProviderDefinition: Codable, Equatable, Sendable {
  internal var id: String
  internal var kind: ExternalProviderKind
  internal var executableNames: [String]

  internal static let defaults = [
    ExternalProviderDefinition(
      id: "apple-cli-mcp",
      kind: .appleCLIMCP,
      executableNames: ["apple-cli-mcp", "apple-cli"]
    ),
    ExternalProviderDefinition(
      id: "browser",
      kind: .browser,
      executableNames: [
        "playwright-mcp",
        "playwright-cli",
        "playwright",
        "browser-provider",
      ]
    ),
    ExternalProviderDefinition(
      id: "codex",
      kind: .codex,
      executableNames: ["codex"]
    ),
    ExternalProviderDefinition(
      id: "tunnel-client",
      kind: .tunnelClient,
      executableNames: ["tunnel-client"]
    ),
  ]
}

internal enum ExternalProviderDiscoveryError: Error, LocalizedError, Equatable {
  case duplicateProviderID(String)
  case invalidDefinition(String)

  internal var errorDescription: String? {
    switch self {
    case .duplicateProviderID(let id):
      return "External provider definition id is duplicated: \(id)"
    case .invalidDefinition(let message):
      return "Invalid external provider definition: \(message)"
    }
  }
}

internal struct ExternalProviderDiscovery: @unchecked Sendable {
  internal var definitions: [ExternalProviderDefinition]
  internal var configuredProviders: [String: [ExternalProviderLaunchConfig]]
  internal var commandRunner: CommandRunning
  internal var environment: [String: String]
  internal var configurationBaseDirectory: URL
  internal var commonSearchDirectories: [URL]?
  internal var timeoutMilliseconds: Int
  internal var maxOutputBytes: Int

  private let fileManager: FileManager

  internal init(
    definitions: [ExternalProviderDefinition] = ExternalProviderDefinition.defaults,
    configuredProviders: [String: [ExternalProviderLaunchConfig]] = [:],
    commandRunner: CommandRunning = ProcessCommandRunner(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    configurationBaseDirectory: URL = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath),
    commonSearchDirectories: [URL]? = nil,
    timeoutMilliseconds: Int = 10_000,
    maxOutputBytes: Int = 256 * 1024,
    fileManager: FileManager = .default
  ) {
    self.definitions = definitions
    self.configuredProviders = configuredProviders
    self.commandRunner = commandRunner
    self.environment = environment
    self.configurationBaseDirectory = configurationBaseDirectory
    self.commonSearchDirectories = commonSearchDirectories
    self.timeoutMilliseconds = timeoutMilliseconds
    self.maxOutputBytes = maxOutputBytes
    self.fileManager = fileManager
  }

  internal init(
    configuration: GatewayConfiguration,
    definitions: [ExternalProviderDefinition] = ExternalProviderDefinition.defaults,
    commandRunner: CommandRunning = ProcessCommandRunner(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    commonSearchDirectories: [URL]? = nil,
    timeoutMilliseconds: Int = 10_000,
    maxOutputBytes: Int = 256 * 1024,
    fileManager: FileManager = .default
  ) {
    self.init(
      definitions: definitions,
      configuredProviders: Self.configuredProviders(
        from: configuration,
        definitions: definitions
      ),
      commandRunner: commandRunner,
      environment: environment,
      configurationBaseDirectory: configuration.workspaceDirectory,
      commonSearchDirectories: commonSearchDirectories,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes,
      fileManager: fileManager
    )
  }

  internal func discover() throws -> [ExternalProviderDiscoveryResult] {
    try validateDefinitions()
    return definitions.map(inspect)
  }

  private func inspect(_ definition: ExternalProviderDefinition)
    -> ExternalProviderDiscoveryResult
  {
    guard let resolved = resolve(definition) else {
      let message =
        "Executable was not found in configured, PATH, or common executable locations."
      return ExternalProviderDiscoveryResult(
        providerID: definition.id,
        kind: definition.kind,
        resolvedPath: nil,
        launchArguments: [],
        version: nil,
        doctorStatus: ExternalProviderDoctorStatus(
          state: .unavailable,
          message: message
        ),
        diagnostics: [
          ExternalProviderDiagnostic(
            code: .executableNotFound,
            operation: "resolve",
            message: message
          )
        ]
      )
    }

    var diagnostics: [ExternalProviderDiagnostic] = []
    let version = inspectVersion(resolved, diagnostics: &diagnostics)
    let doctorStatus: ExternalProviderDoctorStatus
    switch definition.kind {
    case .appleCLIMCP:
      doctorStatus = inspectAppleCLIContract(resolved, diagnostics: &diagnostics)
    case .codex:
      doctorStatus = ExternalProviderDoctorStatus(
        state: version == nil ? .failed : .passed,
        message: version == nil
          ? "Codex executable was found but its version probe failed."
          : "Codex executable and version probe passed."
      )
    case .browser, .tunnelClient:
      doctorStatus = ExternalProviderDoctorStatus(
        state: .notApplicable,
        message: "No context-free doctor contract is defined for this provider kind."
      )
    }

    return ExternalProviderDiscoveryResult(
      providerID: definition.id,
      kind: definition.kind,
      resolvedPath: resolved.executable,
      launchArguments: resolved.arguments,
      version: version,
      doctorStatus: doctorStatus,
      diagnostics: diagnostics
    )
  }

  private func inspectVersion(
    _ resolved: ResolvedLaunch,
    diagnostics: inout [ExternalProviderDiagnostic]
  ) -> String? {
    switch runProbe(resolved, operation: "version", arguments: ["--version"]) {
    case .failure:
      diagnostics.append(
        ExternalProviderDiagnostic(
          code: .probeLaunchFailed,
          operation: "version",
          message: "Version probe could not be launched."
        ))
      return nil
    case .success(let result):
      guard probeSucceeded(result) else {
        diagnostics.append(
          ExternalProviderDiagnostic(
            code: .versionProbeFailed,
            operation: "version",
            message: probeFailureMessage(operation: "Version", result: result)
          ))
        return nil
      }
      guard let version = firstNonemptyLine(result.stdout, result.stderr) else {
        diagnostics.append(
          ExternalProviderDiagnostic(
            code: .versionUnavailable,
            operation: "version",
            message: "Version probe succeeded but returned no version text."
          ))
        return nil
      }
      return version
    }
  }

  private func inspectAppleCLIContract(
    _ resolved: ResolvedLaunch,
    diagnostics: inout [ExternalProviderDiagnostic]
  ) -> ExternalProviderDoctorStatus {
    let helpProbe = runProbe(resolved, operation: "help", arguments: ["--help"])
    let catalogProbe = runProbe(resolved, operation: "catalog", arguments: ["catalog"])

    var missingCapabilities: [String] = []
    var declarations = ""

    switch helpProbe {
    case .failure:
      missingCapabilities.append("help")
      diagnostics.append(
        ExternalProviderDiagnostic(
          code: .probeLaunchFailed,
          operation: "help",
          message: "apple-cli-mcp help probe could not be launched."
        ))
    case .success(let result):
      if probeSucceeded(result) {
        declarations += result.stdout + "\n" + result.stderr
      } else {
        missingCapabilities.append("help")
      }
    }

    switch catalogProbe {
    case .failure:
      missingCapabilities.append("catalog")
      diagnostics.append(
        ExternalProviderDiagnostic(
          code: .probeLaunchFailed,
          operation: "catalog",
          message: "apple-cli-mcp catalog probe could not be launched."
        ))
    case .success(let result):
      let output = (result.stdout + "\n" + result.stderr)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if probeSucceeded(result), !output.isEmpty {
        declarations += "\n" + output
      } else {
        missingCapabilities.append("catalog")
      }
    }

    let normalizedDeclarations =
      declarations
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    if !normalizedDeclarations.contains("catalog") {
      missingCapabilities.append("catalog")
    }
    if !normalizedDeclarations.contains("doctor") {
      missingCapabilities.append("doctor")
    }
    if !normalizedDeclarations.contains("--dry-run")
      && !normalizedDeclarations.contains("dry-run")
      && !normalizedDeclarations.contains("dryrun")
    {
      missingCapabilities.append("dry-run")
    }
    missingCapabilities = orderedUnique(missingCapabilities)

    guard missingCapabilities.isEmpty else {
      let message =
        "apple-cli-mcp contract is incomplete: missing \(missingCapabilities.joined(separator: ", "))."
      diagnostics.append(
        ExternalProviderDiagnostic(
          code: .contractIncomplete,
          operation: "contract",
          message: message
        ))
      return ExternalProviderDoctorStatus(
        state: .contractIncomplete,
        message: message,
        missingCapabilities: missingCapabilities
      )
    }

    switch runProbe(resolved, operation: "doctor", arguments: ["doctor"]) {
    case .failure:
      let message = "apple-cli-mcp doctor probe could not be launched."
      diagnostics.append(
        ExternalProviderDiagnostic(
          code: .doctorFailed,
          operation: "doctor",
          message: message
        ))
      return ExternalProviderDoctorStatus(state: .failed, message: message)
    case .success(let result):
      guard probeSucceeded(result) else {
        let message = probeFailureMessage(operation: "apple-cli-mcp doctor", result: result)
        diagnostics.append(
          ExternalProviderDiagnostic(
            code: .doctorFailed,
            operation: "doctor",
            message: message
          ))
        return ExternalProviderDoctorStatus(
          state: .failed,
          message: message,
          exitCode: result.exitCode
        )
      }
      return ExternalProviderDoctorStatus(
        state: .passed,
        message: "apple-cli-mcp contract and doctor probes passed.",
        exitCode: result.exitCode
      )
    }
  }

  private func runProbe(
    _ resolved: ResolvedLaunch,
    operation: String,
    arguments: [String]
  ) -> Result<CommandResult, Error> {
    do {
      return .success(
        try commandRunner.run(
          executable: resolved.executable,
          arguments: resolved.arguments + arguments,
          workingDirectory: nil,
          environment: [:],
          timeoutMilliseconds: timeoutMilliseconds,
          maxOutputBytes: maxOutputBytes
        ))
    } catch {
      return .failure(error)
    }
  }

  private func resolve(_ definition: ExternalProviderDefinition) -> ResolvedLaunch? {
    var launches = configuredProviders[definition.id] ?? []
    launches += definition.executableNames.map {
      ExternalProviderLaunchConfig(executable: $0)
    }

    var visited = Set<ExternalProviderLaunchConfig>()
    for launch in launches where visited.insert(launch).inserted {
      guard let executable = resolveExecutable(launch.executable) else {
        continue
      }
      return ResolvedLaunch(executable: executable, arguments: launch.arguments)
    }
    return nil
  }

  private func resolveExecutable(_ executable: String) -> String? {
    guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }

    if executable.contains("/") {
      let url =
        executable.hasPrefix("/")
        ? URL(fileURLWithPath: executable)
        : configurationBaseDirectory.appendingPathComponent(executable)
      return executablePathIfValid(url)
    }

    for directory in executableSearchDirectories() {
      if let path = executablePathIfValid(directory.appendingPathComponent(executable)) {
        return path
      }
    }
    return nil
  }

  private func executablePathIfValid(_ url: URL) -> String? {
    let standardized = url.standardizedFileURL
    guard fileManager.isExecutableFile(atPath: standardized.path) else {
      return nil
    }
    return standardized.resolvingSymlinksInPath().path
  }

  private func executableSearchDirectories() -> [URL] {
    let pathDirectories = (environment["PATH"] ?? "")
      .split(separator: ":", omittingEmptySubsequences: true)
      .map { URL(fileURLWithPath: String($0), isDirectory: true) }
    let commonDirectories = commonSearchDirectories ?? defaultCommonSearchDirectories()

    var seen = Set<String>()
    return (pathDirectories + commonDirectories).compactMap { url in
      let standardized = url.standardizedFileURL
      return seen.insert(standardized.path).inserted ? standardized : nil
    }
  }

  private func defaultCommonSearchDirectories() -> [URL] {
    var paths = [
      "/Applications/ChatGPT.app/Contents/Resources",
      "/Applications/Codex.app/Contents/Resources",
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/opt/local/bin",
      "/usr/bin",
      "/bin",
    ]
    if let home = environment["HOME"], !home.isEmpty {
      paths.insert("\(home)/.local/bin", at: 0)
      paths.insert("\(home)/bin", at: 1)
      paths.insert("\(home)/.volta/bin", at: 2)
      paths.insert("\(home)/.asdf/shims", at: 3)
      let nodeVersions = URL(fileURLWithPath: home)
        .appendingPathComponent(".nvm/versions/node", isDirectory: true)
      if let versions = try? fileManager.contentsOfDirectory(
        at: nodeVersions,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ) {
        paths.insert(
          contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("bin", isDirectory: true).path },
          at: min(4, paths.count)
        )
      }
    }
    return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
  }

  private func validateDefinitions() throws {
    var ids = Set<String>()
    for definition in definitions {
      guard !definition.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ExternalProviderDiscoveryError.invalidDefinition("provider id must not be empty.")
      }
      guard !definition.executableNames.isEmpty else {
        throw ExternalProviderDiscoveryError.invalidDefinition(
          "provider '\(definition.id)' must declare at least one executable name.")
      }
      guard ids.insert(definition.id).inserted else {
        throw ExternalProviderDiscoveryError.duplicateProviderID(definition.id)
      }
    }
  }

  private func probeSucceeded(_ result: CommandResult) -> Bool {
    result.exitCode == 0 && !result.timedOut
  }

  private func probeFailureMessage(operation: String, result: CommandResult) -> String {
    if result.timedOut {
      return "\(operation) probe timed out."
    }
    return
      "\(operation) probe failed with exit code \(result.exitCode.map(String.init) ?? "unknown")."
  }

  private func firstNonemptyLine(_ values: String...) -> String? {
    for value in values {
      if let line = value.split(whereSeparator: \.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .first(where: { !$0.isEmpty })
      {
        return line
      }
    }
    return nil
  }

  private func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  private static func configuredProviders(
    from configuration: GatewayConfiguration,
    definitions: [ExternalProviderDefinition]
  ) -> [String: [ExternalProviderLaunchConfig]] {
    var providers: [String: [ExternalProviderLaunchConfig]] = [:]
    for definition in definitions {
      var launches: [ExternalProviderLaunchConfig] = []
      if definition.kind == .codex, configuration.codex.enabled {
        launches.append(
          ExternalProviderLaunchConfig(executable: configuration.codex.executable)
        )
      }
      for server in configuration.mcp.servers {
        guard let command = server.command,
          matches(
            definition,
            id: server.id,
            executable: command,
            arguments: server.args
          )
        else {
          continue
        }
        launches.append(
          ExternalProviderLaunchConfig(
            executable: command,
            arguments: server.args
          ))
      }
      for command in configuration.cli.commands
      where matches(
        definition,
        id: command.id,
        executable: command.executable,
        arguments: []
      ) {
        launches.append(ExternalProviderLaunchConfig(executable: command.executable))
      }
      if !launches.isEmpty {
        providers[definition.id] = orderedUnique(launches)
      }
    }
    return providers
  }

  private static func matches(
    _ definition: ExternalProviderDefinition,
    id: String,
    executable: String,
    arguments: [String]
  ) -> Bool {
    let aliases = ([definition.id] + definition.executableNames).map {
      $0.lowercased()
    }
    let tokens = [id, URL(fileURLWithPath: executable).lastPathComponent] + arguments
    return tokens.lazy.map { $0.lowercased() }.contains { token in
      aliases.contains { token == $0 || token.contains($0) }
    }
  }

  private static func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
  }
}

private struct ResolvedLaunch: Equatable, Sendable {
  var executable: String
  var arguments: [String]
}
