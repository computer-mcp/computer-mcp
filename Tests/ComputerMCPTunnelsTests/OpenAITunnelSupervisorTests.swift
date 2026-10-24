import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPPlatform
@testable import ComputerMCPProcess
@testable import ComputerMCPTunnels

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)

final class OpenAITunnelSupervisorTests {
  @Test
  func resolverRejectsAFailedVersionProbe() {
    let runner = OpenAITunnelCommandRunner(exitCode: 64)
    let configuration = GatewayConfiguration(
      mcp: .init(servers: [
        .init(id: "tunnel-client", transport: .stdio, command: "/bin/echo")
      ]))
    #expect(throws: (any Error).self) {
      try OpenAITunnelClientResolver(
        executableSearchDirectories: [],
        commandRunner: runner
      ).resolve(
        requestedPath: nil, configuration: configuration)
    }
    #expect(runner.allArguments == [["--version"]])
  }

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
    let secretStore = InMemoryTunnelSecretStore()
    let reference = try SecretReference(account: "tunnel.primary.openai-api-key")
    try await secretStore.setAsynchronously("super-secret", for: reference)
    let commandRunner = OpenAITunnelCommandRunner(output: "key=super-secret")
    let process = TestOpenAITunnelProcessManager(output: "connected super-secret")
    let supervisor = OpenAITunnelSupervisor(
      launcher: testExecutionLauncher(),
      secretStore: secretStore,
      executableSearchDirectories: [],
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
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
      launcher: testExecutionLauncher(),
      secretStore: InMemoryTunnelSecretStore(),
      executableSearchDirectories: [],
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
      launcher: testExecutionLauncher(),
      secretStore: InMemoryTunnelSecretStore(),
      executableSearchDirectories: [],
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
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
      launcher: testExecutionLauncher(),
      secretStore: InMemoryTunnelSecretStore(),
      executableSearchDirectories: [],
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
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
    let secretStore = InMemoryTunnelSecretStore()
    let commandRunner = OpenAITunnelCommandRunner(
      output: "invalid profile",
      exitCodesByCommand: ["doctor": 2]
    )
    let process = TestOpenAITunnelProcessManager()
    let supervisor = OpenAITunnelSupervisor(
      launcher: testExecutionLauncher(),
      secretStore: secretStore,
      executableSearchDirectories: [],
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
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
    let secretStore = InMemoryTunnelSecretStore()
    let supervisor = OpenAITunnelSupervisor(
      launcher: testExecutionLauncher(),
      secretStore: secretStore,
      executableSearchDirectories: [],
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
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
  func testStartPassesSecretAuthenticationPolicy() async throws {
    let secretStore = InMemoryTunnelSecretStore()
    let reference = try SecretReference(account: "tunnel.primary.openai-api-key")
    try await secretStore.setAsynchronously("super-secret", for: reference)
    let supervisor = OpenAITunnelSupervisor(
      launcher: testExecutionLauncher(),
      secretStore: secretStore,
      executableSearchDirectories: [],
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
      commandRunner: OpenAITunnelCommandRunner(),
      processManager: TestOpenAITunnelProcessManager(),
      startupStabilityMilliseconds: 0
    )

    _ = try await supervisor.start(
      tunnelProfile(reference: reference), configuration: GatewayConfiguration(),
      authenticationUI: .fail)

    #expect(await secretStore.lastAuthenticationUI == .fail)
  }

  @Test
  func testSecretReadDoesNotBlockStatusSnapshot() async throws {
    let secretStore = SuspendingTunnelSecretStore(secret: "super-secret")
    let reference = try SecretReference(account: "tunnel.primary.openai-api-key")
    let supervisor = OpenAITunnelSupervisor(
      launcher: testExecutionLauncher(),
      secretStore: secretStore,
      executableSearchDirectories: [],
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
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
    defer { Task { await secretStore.resumeSecretRead() } }

    for _ in 0..<100 where !(await secretStore.secretReadStarted) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await secretStore.secretReadStarted)

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

    await secretStore.resumeSecretRead()
    _ = try await doctorTask.value
    _ = await statusTask.value

    #expect(statusWasResponsive?.state == .stopped)
  }

  @Test
  func testAdapterErrorCannotLeakReferencedSecret() async throws {
    let secretStore = InMemoryTunnelSecretStore()
    let reference = try SecretReference(account: "tunnel.primary.openai-api-key")
    try await secretStore.setAsynchronously("super-secret", for: reference)
    let supervisor = OpenAITunnelSupervisor(
      launcher: testExecutionLauncher(),
      secretStore: secretStore,
      executableSearchDirectories: [],
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
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
    let secretStore = InMemoryTunnelSecretStore()
    let process = TestOpenAITunnelProcessManager()
    let supervisor = OpenAITunnelSupervisor(
      launcher: testExecutionLauncher(),
      secretStore: secretStore,
      executableSearchDirectories: [],
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
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
    let secretStore = InMemoryTunnelSecretStore()
    let process = TestOpenAITunnelProcessManager(exitAfterReadCount: 2)
    let supervisor = OpenAITunnelSupervisor(
      launcher: testExecutionLauncher(),
      secretStore: secretStore,
      executableSearchDirectories: [],
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      proxyResolver: FixedOpenAITunnelHTTPProxyResolver(),
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

private actor InMemoryTunnelSecretStore: SecretStore {
  private var values: [SecretReference: String] = [:]
  private(set) var lastAuthenticationUI: KeychainAuthenticationUI?

  func setAsynchronously(_ secret: String, for reference: SecretReference) async throws {
    values[reference] = secret
  }

  func valueAsynchronously(
    for reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) async throws -> String? {
    lastAuthenticationUI = authenticationUI
    return values[reference]
  }

  func containsAsynchronously(
    _ reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) async throws -> Bool {
    values[reference] != nil
  }

  func deleteAsynchronously(_ reference: SecretReference) async throws {
    values[reference] = nil
  }
}

private actor SuspendingTunnelSecretStore: SecretStore {
  private let secret: String
  private var readContinuation: CheckedContinuation<String?, Never>?
  private(set) var secretReadStarted = false

  init(secret: String) {
    self.secret = secret
  }

  func resumeSecretRead() {
    readContinuation?.resume(returning: secret)
    readContinuation = nil
  }

  func setAsynchronously(_ secret: String, for reference: SecretReference) async throws {}

  func valueAsynchronously(
    for reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) async throws -> String? {
    await withCheckedContinuation {
      secretReadStarted = true
      readContinuation = $0
    }
  }

  func containsAsynchronously(
    _ reference: SecretReference, authenticationUI: KeychainAuthenticationUI
  ) async throws -> Bool { true }

  func deleteAsynchronously(_ reference: SecretReference) async throws {}
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
