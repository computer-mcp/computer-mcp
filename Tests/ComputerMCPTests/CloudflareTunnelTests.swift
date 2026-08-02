import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
final class CloudflareTunnelTests {
  @Test
  func testProfileRequiresNamedRemoteTunnelBoundaries() throws {
    let token = try SecretReference(account: "cloudflare.primary.tunnel-token")
    let accessToken = try SecretReference(account: "cloudflare.primary.access-token")
    let valid = CloudflareTunnelConfiguration(
      id: "primary",
      tunnelName: "computer-mcp-primary",
      publicHostname: "mcp.example.com",
      tunnelTokenReference: token,
      accessTokenReference: accessToken
    )

    try valid.validate()
    #expect(valid.mcpURL?.absoluteString == "https://mcp.example.com/mcp")

    var localAdmin = valid
    localAdmin.gatewayProfile = .localAdmin
    expectThrows(try localAdmin.validate()) { error in
      #expect(
        error.localizedDescription.contains("local-admin cannot be remotely exposed")
      )
    }

    var invalidHostname = valid
    invalidHostname.publicHostname = "https://trycloudflare.example/path"
    expectThrows(try invalidHostname.validate())

    var invalidID = valid
    invalidID.id = "../primary"
    expectThrows(try invalidID.validate()) { error in
      #expect(error.localizedDescription.contains("transports.cloudflare.id"))
    }

    var conflictingPorts = valid
    conflictingPorts.metricsPort = conflictingPorts.localPort
    expectThrows(try conflictingPorts.validate())
  }

  @Test
  func testNamedTunnelLifecycleUsesKeychainSecretsAndEphemeralTokenFile() async throws {
    let fixture = try CloudflareControlPlaneFixture()
    defer { fixture.cleanup() }
    let ports = try availableLoopbackPorts(count: 2)
    let executable = try fixture.makeFakeCloudflared()
    let tokenReference = try SecretReference(account: "cloudflare.primary.tunnel-token")
    let accessTokenReference = try SecretReference(account: "cloudflare.primary.access-token")
    let profile = CloudflareTunnelConfiguration(
      id: "primary",
      tunnelName: "computer-mcp-primary",
      publicHostname: "mcp.example.com",
      gatewayProfile: .cloudflareObserve,
      localPort: ports[0],
      metricsPort: ports[1],
      cloudflaredPath: executable.path,
      tunnelTokenReference: tokenReference,
      accessTokenReference: accessTokenReference
    )

    let onboarding = try await fixture.controlPlane.saveCloudflareTunnelConfiguration(
      profile,
      tunnelToken: "named-tunnel-secret"
    )
    let generatedAccessToken = try #require(onboarding.generatedAccessToken)
    #expect(generatedAccessToken.count >= 32)
    let credentialState = try await fixture.controlPlane.cloudflareCredentialState(for: profile)
    #expect(credentialState.tunnelTokenPresent)
    #expect(credentialState.accessTokenPresent)

    let activeConfiguration = try await fixture.controlPlane.activeConfiguration()
    #expect(activeConfiguration.transports.cloudflare.map(\.id) == [profile.id])
    let exportedManifest = try activeConfiguration.exportedTOML()
    #expect(exportedManifest.contains("[[transports.cloudflare]]"))
    #expect(!exportedManifest.contains("named-tunnel-secret"))
    #expect(!exportedManifest.contains(generatedAccessToken))

    let doctor = try await fixture.controlPlane.doctorCloudflareTunnel(profileID: profile.id)
    #expect(doctor.passed)
    #expect(doctor.namedTunnelOnly)
    #expect(doctor.version == "cloudflared version 2026.8.0")
    #expect(doctor.tokenFileSupported == true)

    var started = false
    do {
      let status = try await fixture.controlPlane.startCloudflareTunnel(profileID: profile.id)
      started = true
      #expect(status.state == .running)
      #expect(status.originURL == "http://127.0.0.1:\(ports[0])/mcp")
      #expect(status.metricsURL == "http://127.0.0.1:\(ports[1])/metrics")
      #expect((try await fixture.controlPlane.desiredCloudflareProfileIDs()) == [profile.id])

      let tokenFile = fixture.directories.runtime.appendingPathComponent(
        "cloudflare-primary-token"
      )
      let tokenAttributes = try FileManager.default.attributesOfItem(atPath: tokenFile.path)
      #expect((tokenAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
      #expect(try String(contentsOf: tokenFile, encoding: .utf8) == "named-tunnel-secret\n")

      let invocation = try await waitForCloudflaredInvocation(
        controlPlane: fixture.controlPlane,
        profileID: profile.id
      )
      #expect(invocation.contains("--no-autoupdate"))
      #expect(invocation.contains("--metrics"))
      #expect(invocation.contains("run"))
      #expect(invocation.contains("--token-file"))
      #expect(!invocation.contains("--url"))
      #expect(!invocation.contains("trycloudflare"))
      #expect(!invocation.contains("named-tunnel-secret"))

      let stopped = try await fixture.controlPlane.stopCloudflareTunnel(profileID: profile.id)
      started = false
      #expect(stopped.state == .stopped)
      #expect(!FileManager.default.fileExists(atPath: tokenFile.path))
      #expect((try await fixture.controlPlane.desiredCloudflareProfileIDs()).isEmpty)
      let lifecycleEvents = try fixture.database.auditEvents().filter {
        $0.capabilityID.hasPrefix("tunnel.cloudflare.")
      }
      #expect(
        Set(lifecycleEvents.map(\.capabilityID)) == [
          "tunnel.cloudflare.start", "tunnel.cloudflare.stop",
        ])
      #expect(lifecycleEvents.allSatisfy { $0.transport == "control_socket" })
    } catch {
      if started {
        _ = try? await fixture.controlPlane.stopCloudflareTunnel(profileID: profile.id)
      }
      throw error
    }
  }

  @Test
  func testOpenAIAndCloudflareTunnelsRunAndStopIndependently() async throws {
    let fixture = try CloudflareControlPlaneFixture()
    defer { fixture.cleanup() }
    let ports = try availableLoopbackPorts(count: 2)
    let cloudflareProfile = CloudflareTunnelConfiguration(
      id: "cloudflare-primary",
      tunnelName: "computer-mcp-primary",
      publicHostname: "mcp.example.com",
      gatewayProfile: .cloudflareObserve,
      localPort: ports[0],
      metricsPort: ports[1],
      cloudflaredPath: try fixture.makeFakeCloudflared().path,
      tunnelTokenReference: try SecretReference(
        account: "cloudflare.cloudflare-primary.tunnel-token"
      ),
      accessTokenReference: try SecretReference(
        account: "cloudflare.cloudflare-primary.access-token"
      )
    )
    let openAIProfile = OpenAITunnelConfiguration(
      id: "openai-primary",
      tunnelClientProfile: "computer-mcp",
      tunnelID: "tunnel_validation",
      gatewayProfile: .chatGPTObserve,
      manifestPath: fixture.directories.manifest.path,
      gatewayExecutablePath: "/tmp/computer-mcp",
      gatewaySocketPath: fixture.directories.gatewaySocket.path
    )

    _ = try await fixture.controlPlane.saveCloudflareTunnelConfiguration(
      cloudflareProfile,
      tunnelToken: "named-tunnel-secret"
    )
    try await fixture.controlPlane.saveOpenAITunnelConfiguration(openAIProfile)

    var openAIStarted = false
    var cloudflareStarted = false
    do {
      let openAIStatus = try await fixture.controlPlane.startOpenAITunnel(
        profileID: openAIProfile.id
      )
      openAIStarted = true
      let cloudflareStatus = try await fixture.controlPlane.startCloudflareTunnel(
        profileID: cloudflareProfile.id
      )
      cloudflareStarted = true
      #expect(openAIStatus.state == .running)
      #expect(cloudflareStatus.state == .running)

      var snapshot = try await fixture.controlPlane.snapshot()
      #expect(snapshot.openAITunnelStatuses.first?.state == .running)
      #expect(snapshot.cloudflareStatuses.first?.state == .running)
      #expect(
        try await fixture.controlPlane.desiredOpenAITunnelConfigurationIDs()
          == [openAIProfile.id]
      )
      #expect(
        try await fixture.controlPlane.desiredCloudflareProfileIDs()
          == [cloudflareProfile.id]
      )

      _ = try await fixture.controlPlane.stopCloudflareTunnel(profileID: cloudflareProfile.id)
      cloudflareStarted = false
      snapshot = try await fixture.controlPlane.snapshot()
      #expect(snapshot.openAITunnelStatuses.first?.state == .running)
      #expect(snapshot.cloudflareStatuses.first?.state == .stopped)
      #expect(
        try await fixture.controlPlane.desiredOpenAITunnelConfigurationIDs()
          == [openAIProfile.id]
      )
      #expect((try await fixture.controlPlane.desiredCloudflareProfileIDs()).isEmpty)

      _ = try await fixture.controlPlane.stopOpenAITunnel(profileID: openAIProfile.id)
      openAIStarted = false
      snapshot = try await fixture.controlPlane.snapshot()
      #expect(snapshot.openAITunnelStatuses.first?.state == .stopped)
      #expect(snapshot.cloudflareStatuses.first?.state == .stopped)
    } catch {
      if cloudflareStarted {
        _ = try? await fixture.controlPlane.stopCloudflareTunnel(
          profileID: cloudflareProfile.id
        )
      }
      if openAIStarted {
        _ = try? await fixture.controlPlane.stopOpenAITunnel(profileID: openAIProfile.id)
      }
      throw error
    }
  }

  @Test
  func testFailedOriginStartRemovesTheTemporaryTokenAndPreservesDesiredState() async throws {
    let fixture = try CloudflareControlPlaneFixture()
    defer { fixture.cleanup() }
    let occupiedOrigin = try OccupiedLoopbackPort()
    let metricsPort = try #require(availableLoopbackPorts(count: 1).first)
    let profile = CloudflareTunnelConfiguration(
      id: "origin-conflict",
      tunnelName: "computer-mcp-origin-conflict",
      publicHostname: "mcp.example.com",
      gatewayProfile: .cloudflareObserve,
      localPort: occupiedOrigin.port,
      metricsPort: metricsPort,
      cloudflaredPath: try fixture.makeFakeCloudflared().path,
      tunnelTokenReference: try SecretReference(
        account: "cloudflare.origin-conflict.tunnel-token"
      ),
      accessTokenReference: try SecretReference(
        account: "cloudflare.origin-conflict.access-token"
      )
    )
    _ = try await fixture.controlPlane.saveCloudflareTunnelConfiguration(
      profile,
      tunnelToken: "named-tunnel-secret"
    )
    let tokenFile = fixture.directories.runtime.appendingPathComponent(
      "cloudflare-origin-conflict-token"
    )

    await expectThrowsAsync(
      try await fixture.controlPlane.startCloudflareTunnel(profileID: profile.id)
    )

    #expect(!FileManager.default.fileExists(atPath: tokenFile.path))
    #expect((try await fixture.controlPlane.desiredCloudflareProfileIDs()).isEmpty)
    #expect(await fixture.controlPlane.cloudflareTunnelStatuses().first?.state == .stopped)
  }

  @Test
  func testEarlyCloudflaredExitRollsBackTheOriginAndTemporaryToken() async throws {
    let fixture = try CloudflareControlPlaneFixture()
    defer { fixture.cleanup() }
    let ports = try availableLoopbackPorts(count: 2)
    let profile = CloudflareTunnelConfiguration(
      id: "early-exit",
      tunnelName: "computer-mcp-early-exit",
      publicHostname: "mcp.example.com",
      gatewayProfile: .cloudflareObserve,
      localPort: ports[0],
      metricsPort: ports[1],
      cloudflaredPath: try fixture.makeExitingFakeCloudflared().path,
      tunnelTokenReference: try SecretReference(
        account: "cloudflare.early-exit.tunnel-token"
      ),
      accessTokenReference: try SecretReference(
        account: "cloudflare.early-exit.access-token"
      )
    )
    _ = try await fixture.controlPlane.saveCloudflareTunnelConfiguration(
      profile,
      tunnelToken: "named-tunnel-secret"
    )
    let tokenFile = fixture.directories.runtime.appendingPathComponent(
      "cloudflare-early-exit-token"
    )

    await expectThrowsAsync(
      try await fixture.controlPlane.startCloudflareTunnel(profileID: profile.id)
    ) { error in
      #expect(error.localizedDescription.contains("exited during startup"))
    }

    #expect(!FileManager.default.fileExists(atPath: tokenFile.path))
    #expect((try await fixture.controlPlane.desiredCloudflareProfileIDs()).isEmpty)
    #expect(await fixture.controlPlane.cloudflareTunnelStatuses().first?.state == .stopped)
  }

  @Test
  func testUnexpectedCloudflaredExitReleasesRuntimeResourcesAndRecordsFailure() async throws {
    let fixture = try CloudflareControlPlaneFixture()
    defer { fixture.cleanup() }
    let ports = try availableLoopbackPorts(count: 2)
    let profile = CloudflareTunnelConfiguration(
      id: "unexpected-exit",
      tunnelName: "computer-mcp-unexpected-exit",
      publicHostname: "mcp.example.com",
      gatewayProfile: .cloudflareObserve,
      localPort: ports[0],
      metricsPort: ports[1],
      cloudflaredPath: try fixture.makeDelayedExitingFakeCloudflared().path,
      tunnelTokenReference: try SecretReference(
        account: "cloudflare.unexpected-exit.tunnel-token"
      ),
      accessTokenReference: try SecretReference(
        account: "cloudflare.unexpected-exit.access-token"
      )
    )
    _ = try await fixture.controlPlane.saveCloudflareTunnelConfiguration(
      profile,
      tunnelToken: "named-tunnel-secret"
    )
    let tokenFile = fixture.directories.runtime.appendingPathComponent(
      "cloudflare-unexpected-exit-token"
    )

    let started = try await fixture.controlPlane.startCloudflareTunnel(profileID: profile.id)
    #expect(started.state == .running)
    for _ in 0..<30 {
      if await fixture.controlPlane.cloudflareTunnelStatuses().first?.state == .failed {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }

    let failed = try #require(await fixture.controlPlane.cloudflareTunnelStatuses().first)
    #expect(failed.state == .failed)
    #expect(failed.processID == nil)
    #expect(!FileManager.default.fileExists(atPath: tokenFile.path))
    #expect((try await fixture.controlPlane.desiredCloudflareProfileIDs()) == [profile.id])
    let releasedOrigin = try OccupiedLoopbackPort(port: profile.localPort)
    #expect(releasedOrigin.port == profile.localPort)
    let exitEvent = try #require(
      fixture.database.auditEvents().first {
        $0.capabilityID == "tunnel.cloudflare.exit"
      }
    )
    #expect(exitEvent.decision == .failed)
    #expect(exitEvent.errorCode == "tunnel.cloudflare.process_exited")

    _ = try await fixture.controlPlane.stopCloudflareTunnel(profileID: profile.id)
    #expect((try await fixture.controlPlane.desiredCloudflareProfileIDs()).isEmpty)
  }

  @Test
  func testTokenFileRequiresSupportedCloudflaredVersion() async throws {
    let fixture = try CloudflareControlPlaneFixture()
    defer { fixture.cleanup() }
    let ports = try availableLoopbackPorts(count: 2)
    let profile = CloudflareTunnelConfiguration(
      id: "old-cloudflared",
      tunnelName: "computer-mcp-old-cloudflared",
      publicHostname: "mcp.example.com",
      gatewayProfile: .cloudflareObserve,
      localPort: ports[0],
      metricsPort: ports[1],
      cloudflaredPath: try fixture.makeOldFakeCloudflared().path,
      tunnelTokenReference: try SecretReference(
        account: "cloudflare.old-cloudflared.tunnel-token"
      ),
      accessTokenReference: try SecretReference(
        account: "cloudflare.old-cloudflared.access-token"
      )
    )
    _ = try await fixture.controlPlane.saveCloudflareTunnelConfiguration(
      profile,
      tunnelToken: "named-tunnel-secret"
    )

    let doctor = try await fixture.controlPlane.doctorCloudflareTunnel(profileID: profile.id)
    #expect(!doctor.passed)
    #expect(doctor.tokenFileSupported == false)
    #expect(doctor.diagnostics.contains { $0.contains("2025.4.0") })
    await expectThrowsAsync(
      try await fixture.controlPlane.startCloudflareTunnel(profileID: profile.id)
    ) { error in
      #expect(error.localizedDescription.contains("2025.4.0"))
    }
    #expect((try await fixture.controlPlane.desiredCloudflareProfileIDs()).isEmpty)
  }

  @Test
  func testOnboardingValidatesCallerBeforeWritingKeychainSecrets() async throws {
    let fixture = try CloudflareControlPlaneFixture()
    defer { fixture.cleanup() }
    let ports = try availableLoopbackPorts(count: 2)
    let profile = CloudflareTunnelConfiguration(
      id: "wrong-caller",
      tunnelName: "computer-mcp-wrong-caller",
      publicHostname: "mcp.example.com",
      gatewayProfile: .chatGPTObserve,
      localPort: ports[0],
      metricsPort: ports[1],
      cloudflaredPath: try fixture.makeFakeCloudflared().path,
      tunnelTokenReference: try SecretReference(
        account: "cloudflare.wrong-caller.tunnel-token"
      ),
      accessTokenReference: try SecretReference(
        account: "cloudflare.wrong-caller.access-token"
      )
    )

    await expectThrowsAsync(
      try await fixture.controlPlane.saveCloudflareTunnelConfiguration(
        profile,
        tunnelToken: "named-tunnel-secret"
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not allow cloudflare-tunnel"))
    }

    let credentials = try await fixture.controlPlane.cloudflareCredentialState(for: profile)
    #expect(!credentials.tunnelTokenPresent)
    #expect(!credentials.accessTokenPresent)
    #expect(try await fixture.controlPlane.cloudflareTunnelConfigurations().isEmpty)
  }

  @Test
  func testNewCloudflareProfileRequiresATunnelToken() async throws {
    let fixture = try CloudflareControlPlaneFixture()
    defer { fixture.cleanup() }
    let ports = try availableLoopbackPorts(count: 2)
    let profile = CloudflareTunnelConfiguration(
      id: "missing-token",
      tunnelName: "computer-mcp-missing-token",
      publicHostname: "mcp.example.com",
      gatewayProfile: .cloudflareObserve,
      localPort: ports[0],
      metricsPort: ports[1],
      cloudflaredPath: try fixture.makeFakeCloudflared().path,
      tunnelTokenReference: try SecretReference(
        account: "cloudflare.missing-token.tunnel-token"
      ),
      accessTokenReference: try SecretReference(
        account: "cloudflare.missing-token.access-token"
      )
    )

    await expectThrowsAsync(
      try await fixture.controlPlane.saveCloudflareTunnelConfiguration(
        profile,
        tunnelToken: nil
      )
    ) { error in
      #expect(error.localizedDescription.contains("named tunnel token is missing"))
    }
    #expect(try await fixture.controlPlane.cloudflareTunnelConfigurations().isEmpty)
  }

  private func waitForCloudflaredInvocation(
    controlPlane: AppControlPlaneService,
    profileID: String
  ) async throws -> String {
    for _ in 0..<40 {
      let logs = try await controlPlane.cloudflareTunnelLogs(profileID: profileID)
      if logs.stdout.contains("--token-file") { return logs.stdout }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Fake cloudflared invocation was not recorded.")
    return ""
  }
}

private final class OccupiedLoopbackPort {
  let descriptor: Int32
  let port: Int

  init(port requestedPort: Int = 0) throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    address.sin_port = UInt16(requestedPort).bigEndian
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0, listen(descriptor, 1) == 0 else {
      close(descriptor)
      throw POSIXError(.EADDRINUSE)
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard nameResult == 0 else {
      close(descriptor)
      throw POSIXError(.EIO)
    }
    self.descriptor = descriptor
    self.port = Int(UInt16(bigEndian: address.sin_port))
  }

  deinit {
    close(descriptor)
  }
}

private final class CloudflareControlPlaneFixture {
  let temporaryDirectory: ScopedTemporaryDirectory
  let directories: AppControlPlaneServiceDirectories
  let database: GatewayDatabase
  let controlPlane: AppControlPlaneService

  init() throws {
    temporaryDirectory = try ScopedTemporaryDirectory()
    directories = AppControlPlaneServiceDirectories(
      applicationSupport: temporaryDirectory.url.appendingPathComponent("Application Support"),
      logs: temporaryDirectory.url.appendingPathComponent("Logs")
    )
    try directories.prepare()
    database = try GatewayDatabase(path: directories.database.path)
    let manifestStore = try AtomicManifestStore(
      manifestURL: directories.manifest,
      database: database
    )
    _ = try manifestStore.activate(manifest: DefaultGatewayConfiguration.manifest)
    let secretStore = try KeychainSecretStore(
      service: "com.showxu.computer-mcp.cloudflare-tests",
      adapter: MemoryCloudflareKeychainAdapter()
    )
    let openAITunnelSupervisor = OpenAITunnelSupervisor(
      secretStore: secretStore,
      resolver: FixedOpenAITunnelClientResolver(),
      planBuilder: FixedOpenAITunnelPlanBuilder(),
      commandRunner: OpenAITunnelCommandRunner(),
      processManager: TestOpenAITunnelProcessManager()
    )
    controlPlane = AppControlPlaneService(
      directories: directories,
      database: database,
      manifestStore: manifestStore,
      secretStore: secretStore,
      openAITunnelSupervisor: openAITunnelSupervisor
    )
  }

  func makeFakeCloudflared() throws -> URL {
    let executable = temporaryDirectory.url.appendingPathComponent("fake-cloudflared")
    try """
    #!/bin/sh
    if [ "$1" = "version" ]; then
      echo "cloudflared version 2026.8.0"
      exit 0
    fi
    printf '%s\n' "$@"
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: executable.path
    )
    return executable
  }

  func makeExitingFakeCloudflared() throws -> URL {
    let executable = temporaryDirectory.url.appendingPathComponent("exiting-cloudflared")
    try """
    #!/bin/sh
    if [ "$1" = "version" ]; then
      echo "cloudflared version 2026.8.0"
      exit 0
    fi
    exit 23
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: executable.path
    )
    return executable
  }

  func makeDelayedExitingFakeCloudflared() throws -> URL {
    let executable = temporaryDirectory.url.appendingPathComponent("delayed-exit-cloudflared")
    try """
    #!/bin/sh
    if [ "$1" = "version" ]; then
      echo "cloudflared version 2026.8.0"
      exit 0
    fi
    sleep 1
    exit 24
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: executable.path
    )
    return executable
  }

  func makeOldFakeCloudflared() throws -> URL {
    let executable = temporaryDirectory.url.appendingPathComponent("old-cloudflared")
    try """
    #!/bin/sh
    if [ "$1" = "version" ]; then
      echo "cloudflared version 2025.3.1"
      exit 0
    fi
    exit 0
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: executable.path
    )
    return executable
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: temporaryDirectory.url)
  }
}

private final class MemoryCloudflareKeychainAdapter: KeychainAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  func set(service: String, account: String, data: Data) {
    lock.withLock { values["\(service):\(account)"] = data }
  }

  func get(service: String, account: String) -> Data? {
    lock.withLock { values["\(service):\(account)"] }
  }

  func delete(service: String, account: String) {
    _ = lock.withLock { values.removeValue(forKey: "\(service):\(account)") }
  }
}

private func availableLoopbackPorts(count: Int) throws -> [Int] {
  var descriptors: [Int32] = []
  defer {
    for descriptor in descriptors { close(descriptor) }
  }
  var ports: [Int] = []
  for _ in 0..<count {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    descriptors.append(descriptor)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else { throw POSIXError(.EADDRINUSE) }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard nameResult == 0 else { throw POSIXError(.EIO) }
    ports.append(Int(UInt16(bigEndian: address.sin_port)))
  }
  return ports
}
