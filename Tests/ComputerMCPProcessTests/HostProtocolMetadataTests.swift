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

  @Test
  func providerChannelIsHostCreatedSingleUseAndRejectsRawDescriptors() async throws {
    let root = try SandboxPath(
      ProjectPathResolver.canonicalProject(
        FileManager.default.temporaryDirectory
      ).path)
    let binding = try providerBinding()
    let authority = MetadataAuthority(authorizationIDs: binding.authorizationIDs)
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/usr/bin")], home: root, temporary: root, cache: root)
    let sandbox = try SandboxConfiguration(
      readOnly: true, worktree: root, temporaryDirectory: root, homeDirectory: root,
      cacheDirectory: root, readableRoots: [root])
    let base = PreparedExecutionContext(
      authority: authority, mode: .sandbox(sandbox),
      environment: environment, limits: MetadataAuthority.limits, provider: binding)
    let pair = try ProviderHostServiceChannel.make(metadata: "{\"scope\":\"verified\"}")
    defer {
      try? pair.host.close()
      pair.channel.close()
    }
    let prepared = try base.withHostServiceChannel(pair.channel)
    let platform = MetadataPlatform()
    let pipe = Pipe()
    for mapping in [
      [Int32(3): pipe.fileHandleForWriting.fileDescriptor],
      [Int32(8): pipe.fileHandleForWriting.fileDescriptor],
    ] {
      await #expect(throws: ExecutionEnvironmentError.self) {
        try await prepared.withValue {
          try await ExecutionLauncher(platform: platform).start(
            executable: .init("/fixture/tool"), arguments: [], directory: root,
            environment: environment, mode: .fullAccess, inheritedDescriptors: mapping)
        }
      }
    }
    #expect(authority.reservations == 0)
    _ = try await prepared.withValue {
      try await ExecutionLauncher(platform: platform).start(
        executable: .init("/fixture/tool"), arguments: [], directory: root,
        environment: environment, mode: .fullAccess,
        hostProtocolMetadata: ["COMPUTER_MCP_HOST_CONTEXT": "forged"])
    }
    let command = try #require(platform.commands.first)
    #expect(command.environment["COMPUTER_MCP_HOST_FD"] == "3")
    #expect(command.environment["COMPUTER_MCP_HOST_CONTEXT"] == pair.channel.metadata)
    #expect(Set(command.inheritedDescriptors.keys) == [3])
    await #expect(throws: ExecutionEnvironmentError.self) {
      try await prepared.withValue {
        try await ExecutionLauncher(platform: platform).start(
          executable: .init("/fixture/tool"), arguments: [], directory: root,
          environment: environment, mode: .fullAccess)
      }
    }
    #expect(platform.commands.count == 1)
  }

  @Test func channelAttachmentReceivesCoordinatorLimitUpdates() throws {
    let binding = try providerBinding()
    let authority = MetadataAuthority(authorizationIDs: binding.authorizationIDs)
    let root = try SandboxPath(
      ProjectPathResolver.canonicalProject(FileManager.default.temporaryDirectory).path)
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/usr/bin")], home: root, temporary: root, cache: root)
    let sandbox = try SandboxConfiguration(
      readOnly: true, worktree: root, temporaryDirectory: root, homeDirectory: root,
      cacheDirectory: root, readableRoots: [])
    var preparation: PreparedExecutionContext? = PreparedExecutionContext(
      authority: authority, mode: .sandbox(sandbox), environment: environment,
      limits: MetadataAuthority.limits, provider: binding)
    // The coordinator publishes limit updates through its weak registration.
    weak var registered = preparation
    let pair = try ProviderHostServiceChannel.make(metadata: "{}")
    defer {
      try? pair.host.close()
      pair.channel.close()
    }
    let attached = try #require(preparation).withHostServiceChannel(pair.channel)
    preparation = nil
    let tightened = EffectiveExecutionLimits(
      timeMilliseconds: nil, outputBytes: 512,
      memoryBytes: nil, retentionSeconds: 60, retainedOutputBytes: 512, sources: [:])
    registered?.applyLimits(tightened)
    #expect(attached.limits.outputBytes == 512)
    #expect(attached.limits.retainedOutputBytes == 512)
  }

  /// A callback-created program has no provider binding but carries the provider's compiled
  /// read exceptions, so its bootstrap repeats the recheck too.
  @Test(arguments: [1, 2, 3], [true, false])
  func providerRevisionRacePreventsPublication(validation: Int, bound: Bool) async throws {
    let binding = try providerBinding()
    let authority = MetadataAuthority(
      authorizationIDs: bound ? binding.authorizationIDs : [UUID()])
    let platform = MetadataPlatform()
    let root = try SandboxPath(
      ProjectPathResolver.canonicalProject(FileManager.default.temporaryDirectory).path)
    let environment = try ExecutionEnvironment(
      searchPath: [.init("/usr/bin")], home: root, temporary: root, cache: root)
    let sandbox = try SandboxConfiguration(
      readOnly: true, worktree: root, temporaryDirectory: root, homeDirectory: root,
      cacheDirectory: root, readableRoots: [])
    let race = ProviderValidationRace(failAt: validation)
    let prepared = PreparedExecutionContext(
      authority: authority, mode: .sandbox(sandbox), environment: environment,
      limits: MetadataAuthority.limits, provider: bound ? binding : nil,
      validateProvider: { try race.validate() })
    await #expect(throws: PermissionModelError.self) {
      try await prepared.withValue {
        try await ExecutionLauncher(platform: platform).start(
          executable: .init("/fixture/tool"), arguments: [], directory: root,
          environment: environment, mode: .sandbox(sandbox))
      }
    }
    #expect(authority.reservations == (validation == 1 ? 0 : 1))
    #expect(platform.commands.count == (validation == 1 ? 0 : 1))
    #expect(platform.owner.cancellations == (validation == 3 ? 1 : 0))
  }

  private func providerBinding() throws -> ProviderExecutionBinding {
    var ledger = PermissionLedger()
    let identity = PluginIdentity.package("fixture")
    let decision = try ledger.authorize(
      invocation: .init(
        principal: .plugin(identity), tool: "discover", projectID: nil,
        argumentsDigest: "fixture"), requirements: .init(), now: Date())
    guard case .allowed(let proof) = decision else {
      throw PermissionModelError.invalidAuthorization
    }
    return try ProviderExecutionBinding(
      identity: identity, registrationID: "fixture",
      sourceDigest: String(repeating: "a", count: 64),
      providerAuthorization: proof, delegatingAuthorization: nil)
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
  let authorizationIDs: Set<UUID>
  init(authorizationIDs: Set<UUID> = [UUID()]) { self.authorizationIDs = authorizationIDs }
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
  let owner = MetadataOwnership()
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
    bindOwnership(owner)
    try owner.starting()
    return owner
  }
}

private final class MetadataOwnership: ExecutionOwnership, @unchecked Sendable {
  private let lock = NSLock()
  private var handlers: [@Sendable (ExecutionMember) throws -> Void] = []
  private var cancelled = 0
  var cancellations: Int { lock.withLock { cancelled } }
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {
    lock.withLock { handlers.append(handler) }
  }
  func starting() throws {
    for handler in lock.withLock({ handlers }) {
      try handler(.init(processID: 999999, identity: 1))
    }
  }
  func members() async throws -> [ExecutionMember] { [] }
  func onCancellation(_ handler: @escaping @Sendable () -> Void) {}
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    lock.withLock { cancelled += 1 }
    return .init(status: 0)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    .init(status: 0)
  }
}

private final class ProviderValidationRace: @unchecked Sendable {
  let failAt: Int
  private let lock = NSLock()
  private var validations = 0
  init(failAt: Int) { self.failAt = failAt }
  func validate() throws {
    try lock.withLock {
      validations += 1
      if validations == failAt { throw PermissionModelError.invalidAuthorization }
    }
  }
}
