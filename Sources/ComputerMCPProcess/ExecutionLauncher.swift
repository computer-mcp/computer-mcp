import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Constructs the entire child environment before handing an admitted command to an OS backend.
/// Callers supply authorization separately; a mode is a launch instruction, not a permission grant.
package struct ExecutionLauncher: Sendable {
  package var supportsRecovery: Bool { platform.supportsRecovery }
  package var supportsBestEffortOwnership: Bool { platform.supportsBestEffortOwnership }
  package var bootSessionID: String? { platform.bootSessionID }
  package var hostSystemReadPaths: [SandboxPath] { platform.hostSystemReadPaths }

  package func supportsDurableOwnership(sandboxed: Bool) -> Bool {
    platform.supportsDurableOwnership(sandboxed: sandboxed)
  }

  private let platform: any ExecutionPlatform

  package init(platform: any ExecutionPlatform = UnsupportedExecutionPlatform()) {
    self.platform = platform
  }

  package func interrupt(_ members: [ExecutionMember]) async throws {
    try await platform.interrupt(members)
  }

  package func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    try await platform.recover(state)
  }

  package func releaseRecovery(_ state: ExecutionRecoveryState) throws {
    try platform.releaseRecovery(state)
  }

  package func start(
    executable: SandboxPath, arguments: [String], directory: SandboxPath,
    environment: ExecutionEnvironment, mode: ExecutionMode,
    method: ExecutionLaunchMethod = .subprocess,
    input: Int32 = 0, output: Int32 = 1, error: Int32 = 2,
    directoryDescriptor: Int32? = nil, inheritedDescriptors: [Int32: Int32] = [:],
    hostProtocolMetadata: [String: String] = [:],
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void = { _ in }
  ) async throws -> any ExecutionOwnership {
    try Task.checkCancellation()
    guard inheritedDescriptors.allSatisfy({ $0.key > 2 && $0.key < Int32.max && $0.value >= 0 }),
      arguments.allSatisfy({ !$0.contains("\0") }),
      ([input, output, error] + [directoryDescriptor].compactMap { $0 }).allSatisfy({ $0 >= 0 })
    else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Invalid arguments or stream descriptors")
    }
    try Self.validateHostProtocolMetadata(
      hostProtocolMetadata, inheritedDescriptors: inheritedDescriptors)
    let prepared = try PreparedExecutionContext.current()
    guard prepared?.permitsProgramLaunch != false else {
      throw ExecutionEnvironmentError.unavailable("This service context cannot start host programs")
    }
    guard prepared != nil || ExecutionAdministration.current != nil else {
      throw ExecutionEnvironmentError.unavailable("No authorized execution context is installed")
    }
    let mode = prepared?.mode ?? ExecutionAdministration.current!.mode
    let environment = try HostCommandEnvironment.applying(
      to: prepared?.environment ?? ExecutionAdministration.current!.environment)
    var launchDirectory = directory
    let sandbox: SandboxConfiguration?
    switch mode {
    case .sandbox(let configuration):
      guard directoryDescriptor == nil || configuration.readOnly else {
        throw ExecutionEnvironmentError.invalidConfiguration(
          "Sandbox working directory must be its worktree")
      }
      launchDirectory = try SandboxPath(
        ProjectPathResolver.canonicalProject(URL(fileURLWithPath: directory.value)).path)
      guard launchDirectory == configuration.worktree else {
        throw ExecutionEnvironmentError.invalidConfiguration(
          "Sandbox working directory must be its worktree")
      }
      guard inheritedDescriptors.isEmpty else {
        throw ExecutionEnvironmentError.invalidConfiguration(
          "Sandbox launches cannot inherit extra descriptors")
      }
      sandbox = configuration
    case .fullAccess:
      sandbox = nil
    }
    try prepared?.validateFixedCommand(
      executable: executable, arguments: arguments, directory: launchDirectory,
      directoryDescriptor: directoryDescriptor, inheritedDescriptors: inheritedDescriptors)
    if prepared != nil, !platform.supportsDurableOwnership(sandboxed: sandbox != nil),
      !(sandbox == nil && platform.supportsBestEffortOwnership)
    {
      throw ExecutionEnvironmentError.unavailable(
        "This backend cannot enforce durable execution ownership in the requested mode")
    }
    var variables = try environment.variables(sandbox: sandbox)
    for key in Self.reservedHostProtocolKeys { variables.removeValue(forKey: key) }
    variables.merge(hostProtocolMetadata) { _, value in value }
    let command = ExecutionCommand(
      executable: executable, arguments: arguments, directory: launchDirectory,
      environment: variables,
      directoryDescriptor: directoryDescriptor,
      inheritedDescriptors: inheritedDescriptors
    )
    let childID = UUID()
    try prepared?.authority.reserveChild(childID)
    do {
      return try await platform.start(
        command, sandbox: sandbox,
        method: directoryDescriptor == nil && inheritedDescriptors.isEmpty ? method : .posixSpawn,
        input: input, output: output, error: error,
        bindOwnership: { ownership in
          prepared?.authority.bindChild(childID, ownership: ownership)
          bindOwnership(ownership)
        })
    } catch {
      prepared?.authority.launchFailed(childID)
      throw error
    }
  }

  private static let reservedHostProtocolKeys: Set<String> = [
    "COMPUTER_MCP_HOST_CONTEXT", "COMPUTER_MCP_HOST_FD", "COMPUTER_MCP_HOST_READ_HANDLE",
    "COMPUTER_MCP_HOST_WRITE_HANDLE",
  ]

  private static func validateHostProtocolMetadata(
    _ metadata: [String: String], inheritedDescriptors: [Int32: Int32]
  ) throws {
    guard Set(metadata.keys).isSubset(of: ["COMPUTER_MCP_HOST_CONTEXT", "COMPUTER_MCP_HOST_FD"]),
      metadata.values.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 16_384 })
    else {
      throw ExecutionEnvironmentError.invalidConfiguration("Invalid host protocol launch metadata")
    }
    if let descriptor = metadata["COMPUTER_MCP_HOST_FD"] {
      guard descriptor == "3", metadata["COMPUTER_MCP_HOST_CONTEXT"] != nil,
        let source = inheritedDescriptors[3], fcntl(source, F_GETFD) >= 0
      else {
        throw ExecutionEnvironmentError.invalidConfiguration(
          "Host protocol metadata requires its inherited descriptor")
      }
    }
  }

  package func run(
    executable: SandboxPath, arguments: [String], directory: SandboxPath,
    environment: ExecutionEnvironment, mode: ExecutionMode,
    method: ExecutionLaunchMethod = .subprocess,
    input: Int32 = 0, output: Int32 = 1, error: Int32 = 2,
    directoryDescriptor: Int32? = nil, inheritedDescriptors: [Int32: Int32] = [:],
    deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(120)),
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void = { _ in }
  ) async throws -> ExecutionExit {
    let ownership = try await start(
      executable: executable, arguments: arguments, directory: directory,
      environment: environment, mode: mode, method: method,
      input: input, output: output, error: error, directoryDescriptor: directoryDescriptor,
      inheritedDescriptors: inheritedDescriptors,
      bindOwnership: bindOwnership)
    return try await ownership.wait(until: deadline)
  }

}
