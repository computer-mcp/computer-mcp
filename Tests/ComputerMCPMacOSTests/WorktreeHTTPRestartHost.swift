import ComputerMCPDarwinTestSupport
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import computer_mcp

struct WorktreeRestartSpec: Codable {
  let root: String
  let source: String
  let managed: Bool
  let gitExecutable: String

  var directories: AppControlPlaneServiceDirectories? {
    managed ? GatewayManagedHostFixture.directories(root: URL(fileURLWithPath: root)) : nil
  }

  var databaseURL: URL {
    directories?.database ?? URL(fileURLWithPath: root).appendingPathComponent("state.sqlite")
  }
}

@Suite(
  .nativeIntegration, .timeLimit(.minutes(5)),
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_WORKTREE_RESTART_CHILD"] != nil))
struct WorktreeHTTPRestartHostTests {
  @Test func serveUntilKilled() async throws {
    let path = try #require(
      ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_WORKTREE_RESTART_CHILD"])
    let spec = try JSONDecoder().decode(
      WorktreeRestartSpec.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let root = URL(fileURLWithPath: spec.root)
    let directories = spec.directories
    try directories?.prepare()
    let location = spec.databaseURL
    let fresh = !FileManager.default.fileExists(atPath: location.path)
    let database = try GatewayDatabase(
      path: location.path, applicationSupportRoot: directories?.applicationSupport)
    _ = database.permissionStore(counter: WorktreeAcceptanceCounter(directory: root))
    var platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    platform = fixturePlatformWithGit(platform, executable: spec.gitExecutable)
    platform.permissionPolicyReader = TestManagedPolicyReader()
    if let directories { platform.hostDataPaths.formUnion(directories.hostDataPaths) }
    let profile = ProfileGrant(
      id: .chatGPTOperate,
      permissions: fixturePermissions([.project("fixture"): .granted(.write)]),
      allowedCallers: [.cloudflareTunnel])
    if fresh {
      try database.saveProfile(profile)
      try database.bootstrapPermissionProfiles([profile])
      try database.saveProject(
        .init(id: "fixture", displayName: "Restart source", rootPath: spec.source))
    }
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .cloudflareTunnel, profileID: .chatGPTOperate),
      policy: .init(shellEnabled: true), profiles: [.init(grant: profile)],
      builtin: .init(enabled: [
        "file.write", "git.add", "git.commit", "git.worktree_add", "git.worktree_list",
        "git.worktree_remove", "git.merge", "git.branch_delete", "git.status",
      ]), projectDirectory: URL(fileURLWithPath: spec.source))
    let source: GatewayHTTPSessionSource
    if spec.managed {
      let app = try await GatewayManagedHostFixture(
        root: root, configuration: configuration, database: database, platform: platform)
      let sessions = try await app.service.makeHTTPSessions(
        profileID: .chatGPTOperate, trace: .init(transport: "http", tunnelInstanceID: "restart"))
      source = .managed(sessions)
      // The listener's callbacks borrow the App owner for its entire lifetime.
      defer { withExtendedLifetime(app) {} }
      try await serve(configuration: configuration, source: source, root: root)
    } else {
      let manifest = root.appendingPathComponent("standalone.toml")
      if fresh {
        try configuration.exportedTOML().write(to: manifest, atomically: true, encoding: .utf8)
      }
      let command = try ServeHTTP.parse(["--config", manifest.path, "--port", "0"])
      let loaded = try await command.runtime.loadConfiguration(
        database: database, platform: platform)
      let sessions = try await command.makeTerminalSessions(
        database: database, platform: platform, configuration: loaded)
      let runtime = try await GatewayRuntime.make(
        configuration: loaded,
        context: loaded.executionContext(caller: .cloudflareTunnel, profileID: .chatGPTOperate),
        database: database, platform: platform,
        bundledPlugins: .init(packages: [], issues: []), terminalSessions: sessions)
      source = .registry(runtime)
      try await serve(configuration: loaded, source: source, root: root)
    }
  }

  private func serve(
    configuration: GatewayConfiguration, source: GatewayHTTPSessionSource, root: URL
  ) async throws {
    let http = GatewayHTTPRuntime(
      configuration: configuration, source: source, host: "127.0.0.1", port: 0,
      publicBaseURL: nil, accessToken: "restart-owner")
    try await http.startListening()
    let port = try #require(await http.boundPort())
    try JSONEncoder().encode(port).write(
      to: root.appendingPathComponent("ready.json"), options: .atomic)
    while true { try await Task.sleep(for: .seconds(1)) }
  }
}

/// Isolated acceptance counter shared only by the disposable host processes.
/// Production uses the platform authorization counter service.
struct WorktreeAcceptanceCounter: AuthorizationEpochCounter {
  let directory: URL
  func withExclusiveAccess<Result>(_ body: (any AuthorizationEpochCounterAccess) throws -> Result)
    throws -> Result
  {
    let deadline = ContinuousClock.now + .seconds(5)
    let lease: FileLock
    while true {
      do {
        lease = try FileLock(
          path: directory.appendingPathComponent("counter.lock").path, mode: .exclusive)
        break
      } catch FileLockError.held where ContinuousClock.now < deadline {
        Thread.sleep(forTimeInterval: 0.005)
      }
    }
    defer { lease.release() }
    return try body(Access(url: directory.appendingPathComponent("counter.json")))
  }
  private struct Access: AuthorizationEpochCounterAccess {
    let url: URL
    func read() throws -> AuthorizationEpochWatermark? {
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return try JSONDecoder().decode(AuthorizationEpochWatermark.self, from: Data(contentsOf: url))
    }
    func advance(to watermark: AuthorizationEpochWatermark) throws {
      guard watermark.revision > (try read()?.revision ?? 0) else {
        throw AuthorizationEpochCounterError.nonMonotonicWrite
      }
      try JSONEncoder().encode(watermark).write(to: url, options: .atomic)
    }
  }
}
