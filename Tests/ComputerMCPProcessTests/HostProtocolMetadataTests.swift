import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import Foundation
import Testing

@testable import ComputerMCPPermissions
@testable import ComputerMCPProcess

@Suite(.timeLimit(.minutes(1)))
struct HostProtocolMetadataTests {
  @Test(arguments: [false, true])
  func explicitMetadataPreservesPreparedEnvironment(sandboxed: Bool) async throws {
    let platform = MetadataPlatform()
    let authority = MetadataAuthority()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = try SandboxPath(ProjectPathResolver.canonicalProject(directory).path)
    let environment = try ExecutionEnvironment(
      searchPath: [SandboxPath(root.value + "/bin")], home: SandboxPath(root.value + "/home"),
      temporary: SandboxPath(root.value + "/tmp"), cache: SandboxPath(root.value + "/cache"),
      hostVariables: ["SELECTED": "prepared"])
    let sandbox = try SandboxConfiguration(
      worktree: root, temporaryDirectory: environment.temporary,
      homeDirectory: environment.home, cacheDirectory: environment.cache, readableRoots: [],
      proxy: .init(http: 12400, socks: 12401))
    let prepared = PreparedExecutionContext(
      authority: authority, mode: sandboxed ? .sandbox(sandbox) : .fullAccess,
      environment: environment, limits: MetadataAuthority.limits)
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    let metadata =
      sandboxed
      ? ["COMPUTER_MCP_HOST_CONTEXT": "{\"scope\":\"host\"}"]
      : ["COMPUTER_MCP_HOST_CONTEXT": "{\"scope\":\"host\"}", "COMPUTER_MCP_HOST_FD": "3"]
    _ = try await prepared.withValue {
      try await ExecutionLauncher(platform: platform).start(
        executable: SandboxPath("/fixture/tool"), arguments: [], directory: root,
        environment: ExecutionEnvironment(fullAccessVariables: [
          "HOME": "/forged", "TMPDIR": "/forged", "PATH": "/forged",
          "HTTP_PROXY": "http://forged", "PLUGIN_SECRET": "forged",
          "COMPUTER_MCP_HOST_CONTEXT": "forged", "COMPUTER_MCP_HOST_FD": "9",
        ]), mode: .fullAccess,
        inheritedDescriptors: sandboxed ? [:] : [3: pipe.fileHandleForWriting.fileDescriptor],
        hostProtocolMetadata: metadata)
    }
    let command = try #require(platform.commands.first)
    var expected = try environment.variables(sandbox: sandboxed ? sandbox : nil)
    expected.merge(metadata) { _, value in value }
    #expect(command.environment == expected)
    #expect(command.environment["PLUGIN_SECRET"] == nil)
    #expect(platform.commands.count == 1)
    #expect(platform.sandboxed == [sandboxed])
    #expect(authority.reservations == 1)
  }

  @Test(arguments: [
    ["HOME": "/forged"], ["TMPDIR": "/forged"], ["PATH": "/forged"],
    ["HTTP_PROXY": "http://forged"], ["PLUGIN_SECRET": "forged"],
    ["COMPUTER_MCP_HOST_READ_HANDLE": "3"], ["COMPUTER_MCP_HOST_WRITE_HANDLE": "3"],
    ["COMPUTER_MCP_HOST_CONTEXT": ""], ["COMPUTER_MCP_HOST_CONTEXT": "invalid\0value"],
    ["COMPUTER_MCP_HOST_CONTEXT": String(repeating: "x", count: 16_385)],
    ["COMPUTER_MCP_HOST_CONTEXT": "{}", "COMPUTER_MCP_HOST_FD": "03"],
    ["COMPUTER_MCP_HOST_CONTEXT": "{}", "COMPUTER_MCP_HOST_FD": "4"],
    ["COMPUTER_MCP_HOST_FD": "3"],
  ])
  func invalidOverlayFailsBeforeReservationOrBackend(metadata: [String: String]) async throws {
    let platform = MetadataPlatform()
    let authority = MetadataAuthority()
    let prepared = try fullAccess(authority: authority)
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    await #expect(throws: ExecutionEnvironmentError.self) {
      try await prepared.withValue {
        try await ExecutionLauncher(platform: platform).start(
          executable: SandboxPath("/fixture/tool"), arguments: [],
          directory: SandboxPath("/fixture"), environment: prepared.environment,
          mode: .fullAccess, inheritedDescriptors: [3: pipe.fileHandleForWriting.fileDescriptor],
          hostProtocolMetadata: metadata)
      }
    }
    #expect(authority.reservations == 0)
    #expect(platform.commands.isEmpty)
  }

  @Test(arguments: [false, true])
  func descriptorMetadataRequiresItsOpenInheritedDescriptor(invalidSource: Bool) async throws {
    let platform = MetadataPlatform()
    let authority = MetadataAuthority()
    let prepared = try fullAccess(authority: authority)
    let pipe = Pipe()
    let source = pipe.fileHandleForWriting.fileDescriptor
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    await #expect(throws: ExecutionEnvironmentError.self) {
      try await prepared.withValue {
        try await ExecutionLauncher(platform: platform).start(
          executable: SandboxPath("/fixture/tool"), arguments: [],
          directory: SandboxPath("/fixture"), environment: prepared.environment,
          mode: .fullAccess, inheritedDescriptors: invalidSource ? [3: Int32.max] : [4: source],
          hostProtocolMetadata: [
            "COMPUTER_MCP_HOST_CONTEXT": "{}", "COMPUTER_MCP_HOST_FD": "3",
          ])
      }
    }
    #expect(authority.reservations == 0)
    #expect(platform.commands.isEmpty)
  }

  @Test
  func metadataDoesNotProvideExecutionAuthority() async throws {
    let platform = MetadataPlatform()
    await #expect(
      throws: ExecutionEnvironmentError.unavailable("No authorized execution context is installed")
    ) {
      try await ExecutionLauncher(platform: platform).start(
        executable: SandboxPath("/fixture/tool"), arguments: [], directory: SandboxPath("/fixture"),
        environment: ExecutionEnvironment(fullAccessVariables: [:]), mode: .fullAccess,
        hostProtocolMetadata: ["COMPUTER_MCP_HOST_CONTEXT": "{}"])
    }
    #expect(platform.commands.isEmpty)
  }

  @Test
  func inheritedReservedMetadataCannotAssertHostProvenance() async throws {
    let platform = MetadataPlatform()
    let authority = MetadataAuthority()
    let environment = try ExecutionEnvironment(fullAccessVariables: [
      "HOME": "/selected", "COMPUTER_MCP_HOST_CONTEXT": "forged",
      "COMPUTER_MCP_HOST_FD": "3", "COMPUTER_MCP_HOST_READ_HANDLE": "4",
      "COMPUTER_MCP_HOST_WRITE_HANDLE": "5",
    ])
    let prepared = PreparedExecutionContext(
      authority: authority, mode: .fullAccess, environment: environment,
      limits: MetadataAuthority.limits)
    _ = try await prepared.withValue {
      try await ExecutionLauncher(platform: platform).start(
        executable: SandboxPath("/fixture/tool"), arguments: [], directory: SandboxPath("/fixture"),
        environment: environment, mode: .fullAccess)
    }
    #expect(platform.commands.first?.environment == ["HOME": "/selected"])
  }

  private func fullAccess(authority: MetadataAuthority) throws -> PreparedExecutionContext {
    PreparedExecutionContext(
      authority: authority, mode: .fullAccess,
      environment: try ExecutionEnvironment(fullAccessVariables: ["HOME": "/selected"]),
      limits: MetadataAuthority.limits)
  }
}

private final class MetadataAuthority: ExecutionAuthorizing, @unchecked Sendable {
  static let limits = EffectiveExecutionLimits(
    timeMilliseconds: nil, outputBytes: 1024, memoryBytes: nil, retentionSeconds: 60,
    retainedOutputBytes: 1024, sources: [:])
  let executionID = UUID()
  let authorizationIDs: Set<UUID> = [UUID()]
  private let lock = NSLock()
  private var reserved = 0
  var reservations: Int { lock.withLock { reserved } }

  func reserveChild(_ id: UUID) { lock.withLock { reserved += 1 } }
  func bindChild(_ id: UUID, ownership: any ExecutionOwnership) {}
  func launchFailed(_ id: UUID) {}
  func finishAdmission() {}
  func access(_ executionID: UUID, operation: ExecutionOperation) -> EffectiveExecutionLimits {
    Self.limits
  }
}

private final class MetadataPlatform: ExecutionPlatform, @unchecked Sendable {
  private let lock = NSLock()
  private var observed: [ExecutionCommand] = []
  private var observedSandbox: [Bool] = []
  var commands: [ExecutionCommand] { lock.withLock { observed } }
  var sandboxed: [Bool] { lock.withLock { observedSandbox } }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool { true }

  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    lock.withLock {
      observed.append(command)
      observedSandbox.append(sandbox != nil)
    }
    let owner = MetadataOwnership()
    bindOwnership(owner)
    return owner
  }
}

private struct MetadataOwnership: ExecutionOwnership {
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {}
  func members() async throws -> [ExecutionMember] { [] }
  func onCancellation(_ handler: @escaping @Sendable () -> Void) {}
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    .init(status: 0)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    .init(status: 0)
  }
}
