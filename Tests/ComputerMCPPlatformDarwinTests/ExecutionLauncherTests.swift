import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite struct ExecutionLauncherTests {
  @Test
  func launchWithoutAnInstalledContextIsRefusedBeforeEffects() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    await #expect(
      throws: ExecutionEnvironmentError.unavailable("No authorized execution context is installed")
    ) {
      try await ExecutionLauncher(platform: platform()).run(
        executable: .init("/bin/sh"), arguments: ["-c", "touch should-not-exist"],
        directory: .init(fixture.root.path), environment: .init(fullAccessVariables: [:]),
        mode: .fullAccess)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.path + "/should-not-exist"))
  }

  @Test(.timeLimit(.minutes(1)))
  func inheritedDescriptorMappingsPreserveOverlappingSources() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let first = Pipe()
    let second = Pipe()
    let firstFD = first.fileHandleForWriting.fileDescriptor
    let secondFD = second.fileHandleForWriting.fileDescriptor
    let owner = try await ExecutionAdministration.$current.withValue(
      .init(mode: .fullAccess, environment: ExecutionEnvironment(fullAccessVariables: [:]))
    ) {
      try await ExecutionLauncher(platform: platform()).start(
        executable: .init("/bin/bash"),
        arguments: ["-c", "printf first >&\(secondFD); printf second >&\(firstFD)"],
        directory: fixture.configuration().worktree,
        environment: ExecutionEnvironment(fullAccessVariables: [:]), mode: .fullAccess,
        inheritedDescriptors: [firstFD: secondFD, secondFD: firstFD])
    }
    try first.fileHandleForWriting.close()
    try second.fileHandleForWriting.close()
    let exit = try await owner.wait()
    #expect(exit.status == 0)
    #expect(try first.fileHandleForReading.readToEnd() == Data("first".utf8))
    #expect(try second.fileHandleForReading.readToEnd() == Data("second".utf8))
  }

  @Test
  func sandboxLaunchesRefuseInheritedDescriptors() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    let pipe = Pipe()
    defer { try? pipe.fileHandleForWriting.close() }
    await #expect(
      throws: ExecutionEnvironmentError.invalidConfiguration(
        "Sandbox launches cannot inherit extra descriptors")
    ) {
      _ = try await ExecutionAdministration.$current.withValue(
        .init(mode: .sandbox(configuration), environment: environment)
      ) {
        try await ExecutionLauncher(platform: platform()).start(
          executable: .init("/bin/sh"), arguments: ["-c", "true"],
          directory: configuration.worktree, environment: environment,
          mode: .sandbox(configuration),
          inheritedDescriptors: [3: pipe.fileHandleForWriting.fileDescriptor])
      }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func sandboxLaunchUsesThePhysicalWorktreeForDirectoryAliases(method: ExecutionLaunchMethod)
    async throws
  {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    let alias = fixture.root.appendingPathComponent("launch-directory")
    try FileManager.default.createSymbolicLink(
      at: alias, withDestinationURL: URL(fileURLWithPath: configuration.worktree.value))
    let observations = ExecutionObservations { command in
      #expect(command.directory == configuration.worktree)
    }
    let launcher = ExecutionLauncher(
      platform: ObservedExecutionPlatform(base: try platform(), observations: observations))
    for directory in [
      URL(fileURLWithPath: configuration.worktree.value).standardizedFileURL, alias,
    ] {
      let result = try await ExecutionAdministration.$current.withValue(
        .init(mode: .sandbox(configuration), environment: environment)
      ) {
        try await launcher.run(
          executable: .init("/bin/sh"),
          arguments: [
            "-c", "test \"$(pwd -P)\" = \"$1\" && printf verified > alias-marker", "test",
            configuration.worktree.value,
          ],
          directory: .init(directory.path), environment: environment,
          mode: .sandbox(configuration), method: method)
      }
      #expect(result.status == 0)
    }
    #expect(observations.members.count == 2)
    #expect(
      try String(
        contentsOfFile: configuration.worktree.value + "/alias-marker", encoding: .utf8)
        == "verified")
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func sandboxLaunchRefusesMissingOrRedirectedDirectoryBeforeStarting(missing: Bool) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    let alias = fixture.root.appendingPathComponent("launch-directory")
    try FileManager.default.createSymbolicLink(
      at: alias, withDestinationURL: URL(fileURLWithPath: configuration.worktree.value))
    try FileManager.default.removeItem(at: alias)
    if !missing {
      try FileManager.default.createSymbolicLink(
        at: alias, withDestinationURL: fixture.root.appendingPathComponent("siblings"))
    }
    let observations = ExecutionObservations()
    let launcher = ExecutionLauncher(
      platform: ObservedExecutionPlatform(base: try platform(), observations: observations))
    await #expect(throws: (any Error).self) {
      try await ExecutionAdministration.$current.withValue(
        .init(mode: .sandbox(configuration), environment: environment)
      ) {
        try await launcher.run(
          executable: .init("/bin/sh"), arguments: ["-c", "touch should-not-exist"],
          directory: .init(alias.path), environment: environment, mode: .sandbox(configuration))
      }
    }
    #expect(observations.ownerships.isEmpty)
    #expect(observations.members.isEmpty)
    #expect(
      !FileManager.default.fileExists(atPath: configuration.worktree.value + "/should-not-exist"))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.path + "/siblings/should-not-exist"))
  }

  @Test(arguments: ExecutionLaunchMethod.allCases)
  func fullAccessRunsWithExplicitEnvironment(method: ExecutionLaunchMethod) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/usr/bin"), .init("/bin")],
      home: configuration.homeDirectory, temporary: configuration.temporaryDirectory,
      cache: configuration.cacheDirectory)
    let result = try await ExecutionAdministration.$current.withValue(
      .init(mode: .fullAccess, environment: environment)
    ) {
      try await ExecutionLauncher(platform: platform()).run(
        executable: .init("/bin/sh"),
        arguments: [
          "-c",
          "test \"$HOME\" = \"$1\" && test -z \"$SSH_AUTH_SOCK\" && test -z \"$GITHUB_TOKEN\"",
          "test", configuration.homeDirectory.value,
        ],
        directory: configuration.worktree, environment: environment, mode: .fullAccess,
        method: method
      )
    }
    #expect(result.status == 0)
  }

  @Test(arguments: ExecutionLaunchMethod.allCases)
  func missingInterfacesRejectBeforeLaunch(method: ExecutionLaunchMethod) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    for (missing, reason) in [
      (
        DarwinPrivacyResponsibility(symbol: { nil }),
        "Full access unavailable: responsibility_spawnattrs_setdisclaim is missing"
      ),
      (
        DarwinPrivacyResponsibility(foundationMethod: { _ in nil }),
        "Full access unavailable: Foundation responsibility setter is missing"
      ),
    ] {
      await #expect(throws: ExecutionEnvironmentError.unavailable(reason)) {
        try await ExecutionAdministration.$current.withValue(
          .init(mode: .fullAccess, environment: environment)
        ) {
          try await ExecutionLauncher(platform: DarwinExecutionPlatform(responsibility: missing))
            .run(
              executable: .init("/bin/sh"), arguments: ["-c", "touch should-not-exist"],
              directory: configuration.worktree, environment: environment, mode: .fullAccess,
              method: method)
        }
      }
    }
    #expect(
      !FileManager.default.fileExists(atPath: configuration.worktree.value + "/should-not-exist"))
  }

  @Test(arguments: ExecutionLaunchMethod.allCases)
  func sandboxLaunchUsesBackend(method: ExecutionLaunchMethod) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    let result = try await ExecutionAdministration.$current.withValue(
      .init(mode: .sandbox(configuration), environment: environment)
    ) {
      try await ExecutionLauncher(platform: platform()).run(
        executable: .init("/bin/sh"),
        arguments: ["-c", "echo ok > allowed && ! (echo no > ../outside)"],
        directory: configuration.worktree,
        environment: environment, mode: .sandbox(configuration), method: method)
    }
    #expect(result.status == 0)
  }

  @Test func unsupportedSandboxRefuses() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    await #expect(
      throws: ExecutionEnvironmentError.unavailable(
        "Sandbox execution is unavailable: the Linux bubblewrap backend has not been implemented")
    ) {
      try await ExecutionAdministration.$current.withValue(
        .init(mode: .sandbox(configuration), environment: environment)
      ) {
        try await ExecutionLauncher().run(
          executable: .init("/bin/true"), arguments: [], directory: configuration.worktree,
          environment: environment, mode: .sandbox(configuration))
      }
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases, [false, true])
  func cancellationKillsChildIgnoringTermination(method: ExecutionLaunchMethod, sandboxed: Bool)
    async throws
  {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    let launcher = try ExecutionLauncher(platform: platform())
    let child = Task {
      try await ExecutionAdministration.$current.withValue(
        .init(mode: sandboxed ? .sandbox(configuration) : .fullAccess, environment: environment)
      ) {
        try await launcher.run(
          executable: .init("/bin/sh"),
          arguments: ["-c", "trap '' TERM; echo ready > ready; exec /bin/sleep 20"],
          directory: configuration.worktree, environment: environment,
          mode: sandboxed ? .sandbox(configuration) : .fullAccess, method: method)
      }
    }
    defer { child.cancel() }
    try await waitForFile(configuration.worktree.value + "/ready")
    let start = ContinuousClock.now
    child.cancel()
    do {
      let result = try await child.value
      #expect(result.status == 128 + SIGKILL)
    } catch is CancellationError {
      // Subprocess reports task cancellation after its owned child has been reaped.
    }
    #expect(start.duration(to: .now) >= .milliseconds(400))
    #expect(start.duration(to: .now) < .seconds(5))
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func cancellationAllowsGracefulTermination(method: ExecutionLaunchMethod) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    let launcher = try ExecutionLauncher(platform: platform())
    let child = Task {
      try await ExecutionAdministration.$current.withValue(
        .init(mode: .fullAccess, environment: environment)
      ) {
        try await launcher.run(
          executable: .init("/bin/sh"),
          arguments: [
            "-c",
            "trap 'echo terminated > terminated; exit 42' TERM; echo ready > ready; while :; do :; done",
          ],
          directory: configuration.worktree, environment: environment, mode: .fullAccess,
          method: method)
      }
    }
    defer { child.cancel() }
    try await waitForFile(configuration.worktree.value + "/ready")
    child.cancel()
    do { _ = try await child.value } catch is CancellationError {}
    #expect(FileManager.default.fileExists(atPath: configuration.worktree.value + "/terminated"))
  }

  @Test func foundationPreservesStandardInputDescriptor() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    try fixture.write("input", "original input\n")
    let input = try FileHandle(forReadingFrom: fixture.root.appendingPathComponent("input"))
    defer { try? input.close() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    let result = try await ExecutionAdministration.$current.withValue(
      .init(mode: .fullAccess, environment: environment)
    ) {
      try await ExecutionLauncher(platform: platform()).run(
        executable: .init("/bin/sh"),
        arguments: ["-c", "read line; test \"$line\" = 'original input'"],
        directory: configuration.worktree,
        environment: environment, mode: .fullAccess, method: .foundation,
        input: input.fileDescriptor)
    }
    #expect(result.status == 0)
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func bootstrapExitReportsStatusAndBoundedDiagnosticsImmediately(method: ExecutionLaunchMethod)
    async throws
  {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let bootstrap = fixture.root.appendingPathComponent("failed-bootstrap")
    try """
    #!/bin/sh
    printf 'bootstrap fixture failed\\n' >&2
    /usr/bin/yes diagnostic | /usr/bin/head -c 65536 >&2
    exit 73
    """.write(to: bootstrap, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bootstrap.path)
    let callerError = Pipe()
    let start = ContinuousClock.now
    do {
      _ = try await ExecutionAdministration.$current.withValue(
        .init(mode: .fullAccess, environment: ExecutionEnvironment(fullAccessVariables: [:]))
      ) {
        try await ExecutionLauncher(
          platform: DarwinExecutionPlatform(bootstrapExecutable: bootstrap)
        ).run(
          executable: .init("/bin/sh"), arguments: ["-c", "touch should-not-exist"],
          directory: fixture.configuration().worktree,
          environment: ExecutionEnvironment(fullAccessVariables: [:]), mode: .fullAccess,
          method: method, error: callerError.fileHandleForWriting.fileDescriptor)
      }
      Issue.record("An exited bootstrap must fail launch")
    } catch {
      let message = String(describing: error)
      #expect(message.contains("status 73"))
      #expect(message.contains("bootstrap fixture failed"))
      #expect(message.contains("[truncated]"))
      #expect(message.utf8.count < 5000)
      #expect(!message.contains("errno 35"))
    }
    try callerError.fileHandleForWriting.close()
    #expect(try callerError.fileHandleForReading.readToEnd()?.isEmpty != false)
    #expect(start.duration(to: .now) < .seconds(5))
    #expect(
      try !FileManager.default.fileExists(
        atPath: fixture.configuration().worktree.value + "/should-not-exist"))
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases, [false, true])
  func handshakeToleratesDelayedPeer(method: ExecutionLaunchMethod, delayHost: Bool) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let realBootstrap = try SeatbeltFixture.executionBootstrap
    let bootstrap = fixture.root.appendingPathComponent("slow-bootstrap")
    try """
    #!/bin/sh
    /bin/sleep 6
    exec \"\(realBootstrap.path)\" \"$@\"
    """.write(to: bootstrap, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bootstrap.path)
    let output = Pipe()
    let start = ContinuousClock.now
    let exit = try await ExecutionAdministration.$current.withValue(
      .init(mode: .fullAccess, environment: ExecutionEnvironment(fullAccessVariables: [:]))
    ) {
      try await ExecutionLauncher(
        platform: DarwinExecutionPlatform(
          bootstrapExecutable: delayHost ? realBootstrap : bootstrap)
      ).run(
        executable: .init("/bin/sh"), arguments: ["-c", "printf target-stderr >&2"],
        directory: fixture.configuration().worktree,
        environment: ExecutionEnvironment(fullAccessVariables: [:]), mode: .fullAccess,
        method: method, error: output.fileHandleForWriting.fileDescriptor,
        bindOwnership: { owner in
          if delayHost { owner.beforeStart { _ in Thread.sleep(forTimeInterval: 6) } }
        })
    }
    try output.fileHandleForWriting.close()
    #expect(exit.status == 0)
    #expect(try output.fileHandleForReading.readToEnd() == Data("target-stderr".utf8))
    #expect(start.duration(to: .now) >= .seconds(6))
  }

  @Test(.timeLimit(.minutes(1)))
  func managedLineProcessPreservesBootstrapFailure() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let bootstrap = fixture.root.appendingPathComponent("failed-bootstrap")
    try "#!/bin/sh\nprintf 'bootstrap line fixture failed' >&2\nexit 74\n"
      .write(to: bootstrap, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bootstrap.path)
    let process = try ExecutionAdministration.$current.withValue(
      .init(
        mode: .fullAccess,
        environment: ExecutionEnvironment(fullAccessVariables: [
          "PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "TMPDIR": fixture.root.path + "/",
        ]))
    ) {
      try ManagedLineProcess(
        launcher: ExecutionLauncher(
          platform: DarwinExecutionPlatform(bootstrapExecutable: bootstrap)),
        configuration: .init(executable: "/bin/cat", workingDirectory: fixture.root))
    }
    do {
      for try await _ in process.inboundLines {}
      Issue.record("Bootstrap failure must fail the line stream")
    } catch {
      #expect(String(describing: error).contains("status 74"))
      #expect(String(describing: error).contains("bootstrap line fixture failed"))
    }
    await process.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func ownershipAdmissionFailureRetainsItsType(method: ExecutionLaunchMethod) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    await #expect(throws: AdmissionFailure.refused) {
      _ = try await ExecutionAdministration.$current.withValue(
        .init(mode: .fullAccess, environment: ExecutionEnvironment(fullAccessVariables: [:]))
      ) {
        try await ExecutionLauncher(platform: platform()).start(
          executable: .init("/bin/sh"), arguments: ["-c", "touch should-not-exist"],
          directory: .init(fixture.root.path),
          environment: ExecutionEnvironment(fullAccessVariables: [:]), mode: .fullAccess,
          method: method,
          bindOwnership: { owner in
            owner.beforeStart { _ in throw AdmissionFailure.refused }
          })
      }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.root.path + "/should-not-exist"))
  }

  @Test(.timeLimit(.minutes(1)))
  func managedCloseWaitsForDelayedAdmission() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let entered = AsyncStream<Void>.makeStream()
    let process = try ExecutionAdministration.$current.withValue(
      .init(
        mode: .fullAccess,
        environment: ExecutionEnvironment(fullAccessVariables: [
          "PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "TMPDIR": fixture.root.path + "/",
        ]))
    ) {
      try ManagedLineProcess(
        launcher: ExecutionLauncher(
          platform: AdmissionPlatform(
            base: platform(),
            beforeStart: {
              entered.continuation.finish()
              Thread.sleep(forTimeInterval: 6)
            })),
        configuration: .init(executable: "/bin/cat", workingDirectory: fixture.root))
    }
    for await _ in entered.stream {}
    await process.close()
    #expect(await process.snapshot().hasExited)
    for try await _ in process.inboundLines {}
  }

  @Test(.timeLimit(.minutes(1)))
  func managedAdmissionErrorsRemainRedacted() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let process = try ExecutionAdministration.$current.withValue(
      .init(
        mode: .fullAccess,
        environment: ExecutionEnvironment(fullAccessVariables: [
          "PATH": "/usr/bin:/bin", "HOME": fixture.root.path, "TMPDIR": fixture.root.path + "/",
        ]))
    ) {
      try ManagedLineProcess(
        launcher: ExecutionLauncher(
          platform: AdmissionPlatform(
            base: platform(),
            beforeStart: {
              throw ExecutionEnvironmentError.launchFailed("private-admission-payload")
            })),
        configuration: .init(executable: "/bin/cat", workingDirectory: fixture.root))
    }
    do {
      for try await _ in process.inboundLines {}
      Issue.record("Admission failure must fail the stream")
    } catch {
      #expect(!String(describing: error).contains("private-admission-payload"))
      #expect(String(describing: error).contains("Managed process I/O failed"))
    }
    await process.close()
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func launchDeadlineReapsWhileAdmissionRemainsBlocked(method: ExecutionLaunchMethod) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let blocked = DispatchSemaphore(value: 0)
    let returned = AsyncStream<Void>.makeStream()
    let capture = LaunchCapture()
    defer { blocked.signal() }
    let start = ContinuousClock.now
    await #expect {
      _ = try await ExecutionAdministration.$current.withValue(
        .init(mode: .fullAccess, environment: .init(fullAccessVariables: [:]))
      ) {
        try await ExecutionLauncher(
          platform: DarwinExecutionPlatform(
            bootstrapExecutable: try SeatbeltFixture.executionBootstrap, launchTimeout: .seconds(1)
          )
        ).start(
          executable: .init("/bin/sh"), arguments: ["-c", "touch should-not-exist"],
          directory: .init(fixture.root.path), environment: .init(fullAccessVariables: [:]),
          mode: .fullAccess, method: method,
          bindOwnership: { owner in
            capture.setOwner(owner)
            owner.beforeStart { member in
              capture.setMember(member)
              blocked.wait()
              returned.continuation.finish()
            }
          })
      }
    } throws: { error in
      String(describing: error).contains("Launch handshake deadline exceeded")
    }
    #expect(start.duration(to: .now) < .seconds(4))
    // Exit collection proceeds while the admission callback is still held.
    let owner = try #require(capture.owner)
    _ = try? await owner.wait(until: .now.advanced(by: .seconds(5)))
    let member = try #require(capture.member)
    #expect(DarwinProcessIdentity.current(pid: member.processID, includingZombies: true) == nil)
    blocked.signal()
    for await _ in returned.stream {}
    #expect(!FileManager.default.fileExists(atPath: fixture.root.path + "/should-not-exist"))
  }

  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func launchDeadlineReapsBootstrapWithoutHandshake(method: ExecutionLaunchMethod) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let bootstrap = fixture.root.appendingPathComponent("stopped-bootstrap")
    // STOP prevents both handshaking and normal termination; cleanup must escalate to KILL.
    try "#!/bin/sh\necho $$ > bootstrap-pid\nkill -STOP $$\nwhile :; do :; done\n"
      .write(to: bootstrap, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bootstrap.path)
    let capture = LaunchCapture()
    let start = ContinuousClock.now
    await #expect {
      _ = try await ExecutionAdministration.$current.withValue(
        .init(mode: .fullAccess, environment: .init(fullAccessVariables: [:]))
      ) {
        try await ExecutionLauncher(
          platform: DarwinExecutionPlatform(
            bootstrapExecutable: bootstrap, launchTimeout: .seconds(1)
          )
        ).start(
          executable: .init("/bin/true"), arguments: [], directory: .init(fixture.root.path),
          environment: .init(fullAccessVariables: [:]), mode: .fullAccess, method: method,
          bindOwnership: { capture.setOwner($0) })
      }
    } throws: { error in
      String(describing: error).contains("Launch handshake deadline exceeded")
    }
    #expect(start.duration(to: .now) < .seconds(4))
    let pid = try #require(
      Int32(
        String(
          contentsOf: fixture.root.appendingPathComponent("bootstrap-pid"),
          encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)))
    let owner = try #require(capture.owner)
    _ = try? await owner.wait(until: .now.advanced(by: .seconds(5)))
    #expect(DarwinProcessIdentity.current(pid: pid, includingZombies: true) == nil)
    #expect(try await owner.members().isEmpty)
  }

  private final class LaunchCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOwner: (any ExecutionOwnership)?
    private var storedMember: ExecutionMember?
    var owner: (any ExecutionOwnership)? { lock.withLock { storedOwner } }
    var member: ExecutionMember? { lock.withLock { storedMember } }
    func setOwner(_ value: any ExecutionOwnership) { lock.withLock { storedOwner = value } }
    func setMember(_ value: ExecutionMember) { lock.withLock { storedMember = value } }
  }

  private enum AdmissionFailure: Error { case refused }

  @Test(.timeLimit(.minutes(1)))
  func partialIdentityReadUsesTheOriginalDeadline() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    var sockets: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    defer { for descriptor in sockets { close(descriptor) } }
    var prefix: UInt64 = 1
    try #require(write(sockets[1], &prefix, MemoryLayout<UInt64>.size) == 8)
    let start = ContinuousClock.now
    do {
      _ = try DarwinProcessIdentity.receive(
        from: sockets[0], pid: process.processIdentifier,
        deadline: start.advanced(by: .milliseconds(100)))
      Issue.record("A partial identity cannot extend its deadline")
    } catch let error as ExecutionBootstrapHandshakeFailure {
      #expect(error.reason == "Launch handshake deadline exceeded")
    }
    #expect(start.duration(to: .now) < .seconds(5))
  }

  private struct AdmissionPlatform: ExecutionPlatform {
    let base: DarwinExecutionPlatform
    let beforeStart: @Sendable () throws -> Void

    func start(
      _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
      input: Int32, output: Int32, error: Int32,
      bindOwnership: @Sendable (any ExecutionOwnership) -> Void
    ) async throws -> any ExecutionOwnership {
      try await base.start(
        command, sandbox: sandbox, method: method, input: input, output: output,
        error: error,
        bindOwnership: { owner in
          bindOwnership(owner)
          owner.beforeStart { _ in try beforeStart() }
        })
    }
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func bootstrapRequiresHostAcknowledgement(disconnect: Bool) throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    var sockets: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    defer { for descriptor in sockets where descriptor >= 0 { close(descriptor) } }
    let process = Process()
    process.executableURL = try SeatbeltFixture.executionBootstrap
    process.arguments = ["/bin/sh", "-c", "touch should-not-exist"]
    process.currentDirectoryURL = fixture.root
    process.standardInput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: false)
    try process.run()
    close(sockets[1])
    sockets[1] = -1
    _ = try DarwinProcessIdentity.receive(from: sockets[0], pid: process.processIdentifier)
    if disconnect { shutdown(sockets[0], SHUT_RDWR) }
    let start = ContinuousClock.now
    process.waitUntilExit()
    #expect(process.terminationStatus == 126)
    #expect(start.duration(to: .now) < .seconds(45))
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("should-not-exist").path))
  }

  @Test func bootstrapIdentityRemainsAvailableAfterHelperExit() throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    var sockets: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    defer { for descriptor in sockets where descriptor >= 0 { close(descriptor) } }
    let process = Process()
    process.executableURL = try SeatbeltFixture.executionBootstrap
    process.arguments = ["/bin/sh", "-c", "touch should-not-exist"]
    process.currentDirectoryURL = fixture.root
    process.standardInput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: false)
    try process.run()
    close(sockets[1])
    sockets[1] = -1
    // Retain the queued identity while making the acknowledgement impossible.
    try #require(shutdown(sockets[0], SHUT_WR) == 0)
    process.waitUntilExit()
    #expect(process.terminationStatus == 126)
    let identity = try DarwinProcessIdentity.receive(
      from: sockets[0], pid: process.processIdentifier)
    #expect(identity.pid == process.processIdentifier)
    #expect(identity.uniqueID != 0)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("should-not-exist").path))
  }

  @Test(.timeLimit(.minutes(1)))
  func bootstrapConfirmsDescriptorsBeforeHostReleasesThem() throws {
    var sockets: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    defer { for descriptor in sockets where descriptor >= 0 { close(descriptor) } }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    try #require(
      setsockopt(
        sockets[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        == 0)
    let input = Pipe()
    let output = Pipe()
    try input.fileHandleForWriting.write(contentsOf: Data("transferred input\n".utf8))
    try input.fileHandleForWriting.close()
    let process = Process()
    process.executableURL = try SeatbeltFixture.executionBootstrap
    process.arguments = ["/bin/cat"]
    process.standardInput = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: false)
    process.standardOutput = output
    try process.run()
    _ = try DarwinProcessIdentity.receive(from: sockets[0], pid: process.processIdentifier)
    var control: [UInt32] = [
      20, UInt32(SOL_SOCKET), UInt32(SCM_RIGHTS),
      UInt32(bitPattern: input.fileHandleForReading.fileDescriptor), UInt32(STDERR_FILENO),
    ]
    var acknowledgement: UInt8 = 1
    let sent = withUnsafeMutablePointer(to: &acknowledgement) { byte in
      var payload = iovec(iov_base: byte, iov_len: 1)
      return withUnsafeMutablePointer(to: &payload) { payloadPointer in
        control.withUnsafeMutableBytes { bytes in
          var message = msghdr()
          message.msg_iov = payloadPointer
          message.msg_iovlen = 1
          message.msg_control = bytes.baseAddress
          message.msg_controllen = socklen_t(bytes.count)
          return sendmsg(sockets[0], &message, 0)
        }
      }
    }
    #expect(sent == 1)
    var confirmation: UInt8 = 0
    #expect(recv(sockets[0], &confirmation, 1, 0) == 1)
    #expect(confirmation == 2)
    close(sockets[1])
    sockets[1] = -1
    shutdown(sockets[0], SHUT_RDWR)
    try input.fileHandleForReading.close()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(output.fileHandleForReading.readDataToEndOfFile() == Data("transferred input\n".utf8))
  }

  private func platform() throws -> DarwinExecutionPlatform {
    DarwinExecutionPlatform(bootstrapExecutable: try SeatbeltFixture.executionBootstrap)
  }

  private func waitForFile(_ path: String) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: path), "Child did not become ready")
  }
}
