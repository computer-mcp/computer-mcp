import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class OpenAITunnelSupervisorTests {
  @Test
  func testProfileRejectsAnIDOutsideTheSchemaIdentifierContract() throws {
    var profile = tunnelProfile(reference: nil)
    profile.id = "../primary"

    expectThrows(try profile.validate()) { error in
      #expect(error.localizedDescription.contains("transports.openai.id"))
    }
  }

  @Test
  func testProvisionDoctorStartLogsReconnectAndStop() async throws {
    let adapter = MemoryKeychainAdapter()
    let secretStore = try KeychainSecretStore(adapter: adapter)
    let reference = try SecretReference(account: "tunnel.primary.openai-api-key")
    try secretStore.set("super-secret", for: reference)
    let commandRunner = OpenAITunnelCommandRunner(output: "key=super-secret")
    let process = TestOpenAITunnelProcessManager(output: "connected super-secret")
    let supervisor = OpenAITunnelSupervisor(
      secretStore: secretStore,
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: commandRunner,
      processManager: process
    )
    let profile = tunnelProfile(reference: reference)
    let configuration = GatewayConfiguration()

    let provision = try await supervisor.provision(
      profile,
      configuration: configuration
    )
    #expect(provision.passed)
    #expect((provision.stdout) == ("key=[REDACTED]"))

    let doctor = try await supervisor.doctor(profile, configuration: configuration)
    #expect(doctor.passed)
    #expect((doctor.stdout) == ("key=[REDACTED]"))
    #expect(!commandRunner.lastArguments.contains("--health.listen-addr"))

    let started = try await supervisor.start(profile, configuration: configuration)
    #expect((started.state) == (.running))
    #expect((commandRunner.lastEnvironment["CONTROL_PLANE_API_KEY"]) == ("super-secret"))
    #expect((commandRunner.lastEnvironment["OPENAI_API_KEY"]) == ("super-secret"))
    #expect((process.lastEnvironment["CONTROL_PLANE_API_KEY"]) == ("super-secret"))
    #expect((process.lastEnvironment["OPENAI_API_KEY"]) == ("super-secret"))

    let runningDoctor = try await supervisor.doctor(profile, configuration: configuration)
    #expect(runningDoctor.passed)
    #expect(
      commandRunner.lastArguments.suffix(2) == [
        "--health.listen-addr",
        "127.0.0.1:0",
      ]
    )

    let logs = try await supervisor.logs(
      profileID: profile.id,
      maxReadBytes: 1_024,
      secretReference: reference
    )
    #expect((logs.stdout.text) == ("connected [REDACTED]"))
    #expect((logs.stdout.nextCursor) == (Int64("connected super-secret".utf8.count)))

    let reconnected = try await supervisor.reconnect(
      profile,
      configuration: configuration
    )
    #expect((reconnected.state) == (.running))
    #expect((process.cancelledSessionIDs) == (["session-1"]))

    let stopped = try await supervisor.stop(profileID: profile.id)
    #expect((stopped.state) == (.stopped))
    #expect((process.cancelledSessionIDs) == (["session-1", "session-2"]))
  }

  @Test
  func testExplicitHTTPProxyOverridesSystemProxyAndBlankUsesSystemProxy() async throws {
    let process = TestOpenAITunnelProcessManager()
    let supervisor = OpenAITunnelSupervisor(
      secretStore: try KeychainSecretStore(adapter: MemoryKeychainAdapter()),
      resolver: ExecutableOpenAITunnelClientResolver(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(
        value: "http://127.0.0.1:6152"
      ),
      commandRunner: OpenAITunnelCommandRunner(),
      processManager: process,
      startupStabilityMilliseconds: 0
    )
    var profile = tunnelProfile(reference: nil)
    profile.httpProxy = "http://127.0.0.1:7000"

    _ = try await supervisor.start(profile, configuration: GatewayConfiguration())
    #expect(process.lastArguments.suffix(2) == ["--http-proxy", "http://127.0.0.1:7000"])
    _ = try await supervisor.stop(profileID: profile.id)

    profile.httpProxy = nil
    _ = try await supervisor.start(profile, configuration: GatewayConfiguration())
    #expect(process.lastArguments.suffix(2) == ["--http-proxy", "http://127.0.0.1:6152"])
  }

  @Test
  func testStartRefreshesManagedProfileBeforeDoctorAndLaunch() async throws {
    let commandRunner = OpenAITunnelCommandRunner()
    let process = TestOpenAITunnelProcessManager()
    let supervisor = OpenAITunnelSupervisor(
      secretStore: try KeychainSecretStore(adapter: MemoryKeychainAdapter()),
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: commandRunner,
      processManager: process,
      startupStabilityMilliseconds: 0
    )

    _ = try await supervisor.start(
      tunnelProfile(reference: nil),
      configuration: GatewayConfiguration()
    )

    #expect(
      commandRunner.allArguments == [
        ["init", "--tunnel-id", "tunnel_123", "--force"],
        ["doctor", "--profile", "computer-mcp"],
      ]
    )
    #expect(process.spawnCount == 1)
  }

  @Test
  func testManagedProfileRefreshFailurePreventsDoctorAndLaunch() async throws {
    let commandRunner = OpenAITunnelCommandRunner(
      output: "stale profile could not be replaced",
      exitCodesByCommand: ["init": 2]
    )
    let process = TestOpenAITunnelProcessManager()
    let supervisor = OpenAITunnelSupervisor(
      secretStore: try KeychainSecretStore(adapter: MemoryKeychainAdapter()),
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: commandRunner,
      processManager: process
    )

    do {
      _ = try await supervisor.start(
        tunnelProfile(reference: nil),
        configuration: GatewayConfiguration()
      )
      Issue.record("Expected managed profile refresh failure.")
    } catch let error as OpenAITunnelSupervisorError {
      guard case .startFailed(let detail) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(detail.contains("provisioning failed"))
    }

    #expect(commandRunner.allArguments.count == 1)
    #expect(commandRunner.allArguments.first?.first == "init")
    #expect(process.spawnCount == 0)
  }

  @Test
  func testDoctorFailurePreventsProcessLaunch() async throws {
    let secretStore = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let commandRunner = OpenAITunnelCommandRunner(
      output: "invalid profile",
      exitCodesByCommand: ["doctor": 2]
    )
    let process = TestOpenAITunnelProcessManager()
    let supervisor = OpenAITunnelSupervisor(
      secretStore: secretStore,
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: commandRunner,
      processManager: process
    )

    do {
      _ = try await supervisor.start(
        tunnelProfile(reference: nil),
        configuration: GatewayConfiguration()
      )
      Issue.record("Expected doctor failure.")
    } catch let error as OpenAITunnelSupervisorError {
      guard case .startFailed(let detail) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(detail.contains("doctor failed"))
    }

    #expect((process.spawnCount) == (0))
    let status = await supervisor.status(profileID: "primary")
    #expect((status.state) == (.failed))
  }

  @Test
  func testMissingReferencedSecretFailsClosed() async throws {
    let secretStore = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let supervisor = OpenAITunnelSupervisor(
      secretStore: secretStore,
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: OpenAITunnelCommandRunner(),
      processManager: TestOpenAITunnelProcessManager()
    )
    let reference = try SecretReference(account: "tunnel.primary.openai-api-key")

    do {
      _ = try await supervisor.doctor(
        tunnelProfile(reference: reference),
        configuration: GatewayConfiguration()
      )
      Issue.record("Expected missing secret failure.")
    } catch let error as OpenAITunnelSupervisorError {
      #expect((error) == (.secretMissing))
    }
  }

  @Test
  func testKeychainAuthorizationDoesNotBlockStatusSnapshot() async throws {
    let adapter = BlockingTunnelKeychainAdapter(secret: "super-secret")
    let secretStore = try KeychainSecretStore(adapter: adapter)
    let reference = try SecretReference(account: "tunnel.primary.openai-api-key")
    let supervisor = OpenAITunnelSupervisor(
      secretStore: secretStore,
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: OpenAITunnelCommandRunner(),
      processManager: TestOpenAITunnelProcessManager()
    )
    let profile = tunnelProfile(reference: reference)
    let doctorTask = Task {
      try await supervisor.doctor(
        profile,
        configuration: GatewayConfiguration()
      )
    }
    defer { adapter.resumeSecretRead() }

    for _ in 0..<100 where !adapter.secretReadStarted {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(adapter.secretReadStarted)

    let completion = TunnelStatusCompletion()
    let statusTask = Task {
      let status = await supervisor.status(profileID: "primary")
      completion.complete(with: status)
      return status
    }
    for _ in 0..<50 where completion.status == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    let statusWasResponsive = completion.status

    adapter.resumeSecretRead()
    _ = try await doctorTask.value
    _ = await statusTask.value

    #expect(statusWasResponsive?.state == .stopped)
  }

  @Test
  func testAdapterErrorCannotLeakReferencedSecret() async throws {
    let adapter = MemoryKeychainAdapter()
    let secretStore = try KeychainSecretStore(adapter: adapter)
    let reference = try SecretReference(account: "tunnel.primary.openai-api-key")
    try secretStore.set("super-secret", for: reference)
    let supervisor = OpenAITunnelSupervisor(
      secretStore: secretStore,
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: ThrowingTunnelCommandRunner(),
      processManager: TestOpenAITunnelProcessManager()
    )

    do {
      _ = try await supervisor.doctor(
        tunnelProfile(reference: reference),
        configuration: GatewayConfiguration()
      )
      Issue.record("Expected doctor adapter failure.")
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      #expect(!(message.contains("super-secret")))
      #expect(message.contains("[REDACTED]"))
    }
  }

  @Test
  func testStatusRefreshDetectsExitedTunnelProcess() async throws {
    let secretStore = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let process = TestOpenAITunnelProcessManager()
    let supervisor = OpenAITunnelSupervisor(
      secretStore: secretStore,
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: OpenAITunnelCommandRunner(),
      processManager: process
    )
    let profile = tunnelProfile(reference: nil)

    _ = try await supervisor.start(profile, configuration: GatewayConfiguration())
    process.finish(exitCode: 7)

    let status = await supervisor.status(profileID: profile.id)
    #expect((status.state) == (.failed))
    #expect((status.lastError) == ("Tunnel process exited with code 7."))
  }

  @Test
  func testStartFailsClosedWhenProcessExitsDuringStabilization() async throws {
    let secretStore = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let process = TestOpenAITunnelProcessManager(exitAfterReadCount: 2)
    let supervisor = OpenAITunnelSupervisor(
      secretStore: secretStore,
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: OpenAITunnelCommandRunner(),
      processManager: process,
      startupStabilityMilliseconds: 1
    )
    let profile = tunnelProfile(reference: nil)

    do {
      _ = try await supervisor.start(profile, configuration: GatewayConfiguration())
      Issue.record("Expected an unstable Tunnel process to fail startup.")
    } catch let error as OpenAITunnelSupervisorError {
      guard case .startFailed(let detail) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(detail.contains("code 7"))
    }

    let status = await supervisor.status(profileID: profile.id)
    #expect(status.state == .failed)
    #expect(status.lastError?.contains("code 7") == true)

    let logs = try await supervisor.logs(profileID: profile.id)
    #expect(logs.status.state == .failed)
    #expect(logs.status.lastError == "Tunnel process exited with code 7.")
  }

  private func tunnelProfile(reference: SecretReference?) -> OpenAITunnelConfiguration {
    OpenAITunnelConfiguration(
      id: "primary",
      tunnelClientProfile: "computer-mcp",
      tunnelID: "tunnel_123",
      manifestPath: "/tmp/computer-mcp.toml",
      gatewayExecutablePath: "/tmp/computer-mcp",
      apiKeyReference: reference
    )
  }
}

struct FixedOpenAITunnelClientResolver: OpenAITunnelClientResolving {
  func resolve(
    requestedPath: String?,
    configuration: GatewayConfiguration
  ) throws -> String {
    "/fake/tunnel-client"
  }
}

struct ExecutableOpenAITunnelClientResolver: OpenAITunnelClientResolving {
  func resolve(
    requestedPath: String?,
    configuration: GatewayConfiguration
  ) throws -> String {
    "/bin/echo"
  }
}

struct FixedOpenAITunnelHTTPProxyResolver: OpenAITunnelHTTPProxyResolving {
  var value: String?

  func systemHTTPProxy() -> String? {
    value
  }
}

struct FixedOpenAITunnelPlanBuilder: OpenAITunnelPlanBuilding {
  func plan(
    profile: OpenAITunnelConfiguration,
    tunnelClientPath: String,
    force: Bool
  ) throws -> OpenAITunnelPlan {
    let command = "computer-mcp serve stdio"
    return OpenAITunnelPlan(
      initInvocation: OpenAITunnelInvocation(
        tunnelClient: tunnelClientPath,
        arguments: ["init", "--tunnel-id", profile.tunnelID] + (force ? ["--force"] : []),
        mcpCommand: command
      ),
      doctorInvocation: OpenAITunnelInvocation(
        tunnelClient: tunnelClientPath,
        arguments: ["doctor", "--profile", profile.tunnelClientProfile],
        mcpCommand: command
      ),
      runInvocation: OpenAITunnelInvocation(
        tunnelClient: tunnelClientPath,
        arguments: ["run", "--profile", profile.tunnelClientProfile],
        mcpCommand: command
      )
    )
  }
}

final class OpenAITunnelCommandRunner: CommandRunning, @unchecked Sendable {
  private let output: String
  private let exitCode: Int32
  private let exitCodesByCommand: [String: Int32]
  private let lock = NSLock()
  private var environment: [String: String] = [:]
  private var arguments: [String] = []
  private var argumentsHistory: [[String]] = []

  init(
    output: String = "ok",
    exitCode: Int32 = 0,
    exitCodesByCommand: [String: Int32] = [:]
  ) {
    self.output = output
    self.exitCode = exitCode
    self.exitCodesByCommand = exitCodesByCommand
  }

  var lastEnvironment: [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return environment
  }

  var lastArguments: [String] {
    lock.lock()
    defer { lock.unlock() }
    return arguments
  }

  var allArguments: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return argumentsHistory
  }

  func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult {
    lock.lock()
    self.environment = environment
    self.arguments = arguments
    argumentsHistory.append(arguments)
    lock.unlock()
    let effectiveExitCode = arguments.first.flatMap { exitCodesByCommand[$0] } ?? exitCode
    return CommandResult(
      executable: executable,
      arguments: arguments,
      exitCode: effectiveExitCode,
      timedOut: false,
      stdout: output,
      stderr: "",
      stdoutTruncated: false,
      stderrTruncated: false
    )
  }

  func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult {
    fatalError("Unused by tunnel supervisor tests.")
  }
}

private struct ThrowingTunnelCommandRunner: CommandRunning {
  func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult {
    throw TunnelAdapterTestError.failure("adapter echoed super-secret")
  }

  func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult {
    fatalError("Unused by tunnel supervisor tests.")
  }
}

private enum TunnelAdapterTestError: Error, LocalizedError {
  case failure(String)

  var errorDescription: String? {
    switch self {
    case .failure(let message):
      return message
    }
  }
}

final class TestOpenAITunnelProcessManager: OpenAITunnelProcessManaging, @unchecked Sendable {
  private let output: String
  private let lock = NSLock()
  private var sessions = 0
  private var environment: [String: String] = [:]
  private var arguments: [String] = []
  private var cancelled: [String] = []
  private var running = true
  private var exitCode: Int32?
  private var readCount = 0
  private let exitAfterReadCount: Int?

  init(output: String = "", exitAfterReadCount: Int? = nil) {
    self.output = output
    self.exitAfterReadCount = exitAfterReadCount
  }

  var spawnCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sessions
  }

  var lastEnvironment: [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return environment
  }

  var lastArguments: [String] {
    lock.lock()
    defer { lock.unlock() }
    return arguments
  }

  var cancelledSessionIDs: [String] {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func finish(exitCode: Int32) {
    lock.lock()
    running = false
    self.exitCode = exitCode
    lock.unlock()
  }

  func spawn(
    executable: String,
    arguments: [String],
    environment: [String: String],
    maxOutputBytes: Int
  ) throws -> String {
    lock.lock()
    sessions += 1
    self.environment = environment
    self.arguments = arguments
    running = true
    exitCode = nil
    readCount = 0
    let id = "session-\(sessions)"
    lock.unlock()
    return id
  }

  func read(
    sessionID: String,
    stdoutCursor: Int64,
    stderrCursor: Int64,
    maxReadBytes: Int
  ) throws -> ShellSessionSnapshot {
    lock.lock()
    readCount += 1
    if let exitAfterReadCount, readCount >= exitAfterReadCount {
      running = false
      exitCode = 7
    }
    let isRunning = running
    let exitCode = exitCode
    lock.unlock()
    let data = Data(output.utf8)
    let pageData = data.dropFirst(min(Int(stdoutCursor), data.count))
      .prefix(maxReadBytes)
    return ShellSessionSnapshot(
      sessionID: sessionID,
      processID: 42,
      isRunning: isRunning,
      exitCode: exitCode,
      signal: nil,
      timedOut: false,
      cancelled: false,
      startedAt: Date(timeIntervalSince1970: 1_000),
      finishedAt: nil,
      launchError: nil,
      streamErrors: [],
      stdout: ShellStreamRead(
        requestedCursor: stdoutCursor,
        startCursor: stdoutCursor,
        nextCursor: stdoutCursor + Int64(pageData.count),
        endCursor: Int64(data.count),
        missedBytes: false,
        truncated: false,
        encoding: .utf8,
        text: String(decoding: pageData, as: UTF8.self),
        base64: nil
      ),
      stderr: ShellStreamRead(
        requestedCursor: stderrCursor,
        startCursor: stderrCursor,
        nextCursor: stderrCursor,
        endCursor: stderrCursor,
        missedBytes: false,
        truncated: false,
        encoding: .utf8,
        text: "",
        base64: nil
      )
    )
  }

  func cancel(sessionID: String) throws {
    lock.lock()
    cancelled.append(sessionID)
    if running {
      exitCode = 0
    }
    running = false
    lock.unlock()
  }
}

private final class BlockingTunnelKeychainAdapter: KeychainAdapter, @unchecked Sendable {
  private let secret: Data
  private let lock = NSLock()
  private let resumeSemaphore = DispatchSemaphore(value: 0)
  private var started = false
  private var resumed = false

  init(secret: String) {
    self.secret = Data(secret.utf8)
  }

  var secretReadStarted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return started
  }

  func resumeSecretRead() {
    lock.lock()
    guard !resumed else {
      lock.unlock()
      return
    }
    resumed = true
    lock.unlock()
    resumeSemaphore.signal()
  }

  func set(service: String, account: String, data: Data) throws {}

  func get(service: String, account: String) throws -> Data? {
    lock.lock()
    started = true
    lock.unlock()
    _ = resumeSemaphore.wait(timeout: .now() + 5)
    return secret
  }

  func delete(service: String, account: String) throws {}
}

private final class TunnelStatusCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var completedStatus: OpenAITunnelStatus?

  var status: OpenAITunnelStatus? {
    lock.lock()
    defer { lock.unlock() }
    return completedStatus
  }

  func complete(with status: OpenAITunnelStatus) {
    lock.lock()
    completedStatus = status
    lock.unlock()
  }
}
