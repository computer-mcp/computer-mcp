import ComputerMCPProcess
import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite struct ExecutionLauncherTests {
  @Test(arguments: ExecutionLaunchMethod.allCases)
  func fullAccessRunsWithExplicitEnvironment(method: ExecutionLaunchMethod) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/usr/bin"), .init("/bin")],
      home: configuration.homeDirectory, temporary: configuration.temporaryDirectory,
      cache: configuration.cacheDirectory)
    let result = try await ExecutionLauncher(platform: platform()).run(
      executable: .init("/bin/sh"),
      arguments: [
        "-c", "test \"$HOME\" = \"$1\" && test -z \"$SSH_AUTH_SOCK\" && test -z \"$GITHUB_TOKEN\"",
        "test", configuration.homeDirectory.value,
      ],
      directory: configuration.worktree, environment: environment, mode: .fullAccess, method: method
    )
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
    for missing in [
      DarwinPrivacyResponsibility(symbol: { nil }),
      DarwinPrivacyResponsibility(foundationMethod: { _ in nil }),
    ] {
      await #expect(throws: ExecutionEnvironmentError.self) {
        try await ExecutionLauncher(platform: DarwinExecutionPlatform(responsibility: missing))
          .run(
            executable: .init("/bin/sh"), arguments: ["-c", "touch should-not-exist"],
            directory: configuration.worktree, environment: environment, mode: .fullAccess,
            method: method)
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
    let result = try await ExecutionLauncher(platform: platform()).run(
      executable: .init("/bin/sh"),
      arguments: ["-c", "echo ok > allowed && ! (echo no > ../outside)"],
      directory: configuration.worktree,
      environment: environment, mode: .sandbox(configuration), method: method)
    #expect(result.status == 0)
  }

  @Test func unsupportedSandboxRefuses() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    await #expect(throws: ExecutionEnvironmentError.self) {
      try await ExecutionLauncher().run(
        executable: .init("/bin/true"), arguments: [], directory: configuration.worktree,
        environment: environment, mode: .sandbox(configuration))
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
      try await launcher.run(
        executable: .init("/bin/sh"),
        arguments: ["-c", "trap '' TERM; echo ready > ready; exec /bin/sleep 20"],
        directory: configuration.worktree, environment: environment,
        mode: sandboxed ? .sandbox(configuration) : .fullAccess, method: method)
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
      try await launcher.run(
        executable: .init("/bin/sh"),
        arguments: [
          "-c",
          "trap 'echo terminated > terminated; exit 42' TERM; echo ready > ready; while :; do :; done",
        ],
        directory: configuration.worktree, environment: environment, mode: .fullAccess,
        method: method)
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
    let result = try await ExecutionLauncher(platform: platform()).run(
      executable: .init("/bin/sh"),
      arguments: ["-c", "read line; test \"$line\" = 'original input'"],
      directory: configuration.worktree,
      environment: environment, mode: .fullAccess, method: .foundation, input: input.fileDescriptor)
    #expect(result.status == 0)
  }

  @Test func foundationRejectsBootstrapEOF() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let configuration = try fixture.configuration()
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/bin")], home: configuration.homeDirectory,
      temporary: configuration.temporaryDirectory, cache: configuration.cacheDirectory)
    await #expect(throws: ExecutionEnvironmentError.self) {
      try await ExecutionLauncher(
        platform: DarwinExecutionPlatform(
          bootstrapExecutable: URL(fileURLWithPath: "/usr/bin/true"))
      )
      .run(
        executable: .init("/bin/sh"), arguments: ["-c", "touch should-not-exist"],
        directory: configuration.worktree, environment: environment, mode: .fullAccess,
        method: .foundation)
    }
    #expect(
      !FileManager.default.fileExists(atPath: configuration.worktree.value + "/should-not-exist"))
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
    #expect(start.duration(to: .now) < .seconds(8))
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
  func bootstrapConfirmsInputBeforeHostReleasesIt() throws {
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
      16, UInt32(SOL_SOCKET), UInt32(SCM_RIGHTS),
      UInt32(bitPattern: input.fileHandleForReading.fileDescriptor),
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
