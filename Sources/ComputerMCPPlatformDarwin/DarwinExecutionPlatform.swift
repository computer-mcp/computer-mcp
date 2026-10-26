import ComputerMCPSandbox
import Darwin
import Foundation
import ObjectiveC
import Subprocess
import System

package struct DarwinExecutionPlatform: ExecutionPlatform {
  package var supportsRecovery: Bool { true }
  package var bootSessionID: String? {
    var buffer = [CChar](repeating: 0, count: 128)
    var count = buffer.count
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &count, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
  }

  package var hostSystemReadPaths: [SandboxPath] {
    [
      "/System", "/usr", "/bin", "/sbin", "/Library/Apple",
      "/Library/Preferences/SystemConfiguration",
      "/private/etc", "/private/var/run", "/dev",
    ].compactMap { try? SandboxPath($0) }
  }
  private let responsibility: DarwinPrivacyResponsibility
  private let bootstrapExecutable: URL?
  private let table: DarwinExecutionProcessTable
  private let makeSentinel: @Sendable () async throws -> DarwinExecutionSentinel

  package init(bootstrapExecutable: URL? = nil) {
    responsibility = .init()
    self.bootstrapExecutable = bootstrapExecutable
    table = .system
    makeSentinel = { try await DarwinExecutionSentinel.create() }
  }

  init(
    responsibility: DarwinPrivacyResponsibility = .init(), bootstrapExecutable: URL? = nil,
    table: DarwinExecutionProcessTable = .system,
    makeSentinel: @escaping @Sendable () async throws -> DarwinExecutionSentinel = {
      try await DarwinExecutionSentinel.create()
    }
  ) {
    self.responsibility = responsibility
    self.bootstrapExecutable = bootstrapExecutable
    self.table = table
    self.makeSentinel = makeSentinel
  }

  package func interrupt(_ members: [ExecutionMember]) async throws {
    guard !members.isEmpty else { return }
    let identities = members.map { DarwinProcessIdentity(pid: $0.processID, uniqueID: $0.identity) }
    let ownership = DarwinExecutionOwnership(marker: nil, table: table)
    try ownership.recover(identities)
    _ = try await ownership.cancel()
  }

  package func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?,
    method: ExecutionLaunchMethod, input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    try Task.checkCancellation()
    if sandbox == nil { try responsibility.preflight() }
    let bootstrap = try bootstrapExecutable ?? Self.locateBootstrap()
    let marker = try sandbox.map { _ in try ExecutionSandboxMarker() }
    let arguments =
      sandbox.map {
        [
          "/usr/bin/sandbox-exec", "-p", SeatbeltProfile.generate($0, marker: marker), "--",
          command.executable.value,
        ] + command.arguments
      } ?? [command.executable.value] + command.arguments
    let channel = try ExecutionBootstrapChannel()
    let sentinel: DarwinExecutionSentinel?
    if marker != nil {
      sentinel = try await makeSentinel()
    } else {
      sentinel = nil
    }
    try Task.checkCancellation()
    let ownership = DarwinExecutionOwnership(marker: marker, sentinel: sentinel, table: table)
    let handle = try await withTaskCancellationHandler {
      bindOwnership(ownership)
      return try await withCheckedThrowingContinuation { continuation in
        ownership.starting(continuation)
        if method == .subprocess {
          Task.detached {
            do {
              var options = PlatformOptions()
              if sandbox == nil {
                options.preSpawnProcessConfigurator = { attributes, _ in
                  try responsibility.disclaim(&attributes)
                }
              }
              let environment = command.environment.map { Array(($0.key + "=" + $0.value).utf8) }
              let result = try await Subprocess.run(
                .path(FilePath(bootstrap.path)), arguments: .init(arguments),
                environment: .custom(environment),
                workingDirectory: FilePath(command.directory.value),
                platformOptions: options,
                input: .fileDescriptor(
                  .init(rawValue: channel.child), closeAfterSpawningProcess: false),
                output: .fileDescriptor(.init(rawValue: output), closeAfterSpawningProcess: false),
                error: .fileDescriptor(.init(rawValue: error), closeAfterSpawningProcess: false)
              ) { execution in
                try await withCheckedThrowingContinuation { continuation in
                  DispatchQueue(label: "execution.launch", qos: .userInitiated).async {
                    continuation.resume(
                      with: Result {
                        try channel.accept(
                          pid: execution.processIdentifier.value, input: input,
                          ownership: ownership)
                      })
                  }
                }
              }
              switch result.terminationStatus {
              case .exited(let status): ownership.exited(.success(ExecutionExit(status: status)))
              case .signaled(let signal):
                ownership.exited(.success(ExecutionExit(status: 128 + signal, signal: signal)))
              }
            } catch {
              channel.disconnect()
              ownership.exited(.failure(error))
            }
          }
        } else {
          DispatchQueue(label: "execution.launch", qos: .userInitiated).async {
            do {
              let result: ExecutionExit
              if method == .foundation {
                result = try foundation(
                  bootstrap, arguments: arguments, command: command, disclaim: sandbox == nil,
                  input: input, output: output, error: error, channel: channel, ownership: ownership
                )
              } else {
                result = try spawn(
                  bootstrap.path, arguments: arguments, command: command, disclaim: sandbox == nil,
                  input: input, output: output, error: error, channel: channel, ownership: ownership
                )
              }
              ownership.exited(.success(result))
            } catch {
              channel.disconnect()
              ownership.exited(.failure(error))
            }
          }
        }
      }
    } onCancel: {
      ownership.requestCancellation()
    }
    if Task.isCancelled {
      _ = try await handle.cancel()
      throw CancellationError()
    }
    return handle
  }

  private func foundation(
    _ executable: URL, arguments: [String], command: ExecutionCommand,
    disclaim: Bool, input: Int32, output: Int32, error: Int32,
    channel: ExecutionBootstrapChannel, ownership: DarwinExecutionOwnership
  ) throws -> ExecutionExit {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = command.environment
    process.currentDirectoryURL = URL(fileURLWithPath: command.directory.value)
    process.standardInput = FileHandle(fileDescriptor: channel.child, closeOnDealloc: false)
    process.standardOutput = FileHandle(fileDescriptor: output, closeOnDealloc: false)
    process.standardError = FileHandle(fileDescriptor: error, closeOnDealloc: false)
    if disclaim { try responsibility.disclaim(process) }
    try process.run()
    do {
      try channel.accept(pid: process.processIdentifier, input: input, ownership: ownership)
    } catch {
      channel.disconnect()
      process.waitUntilExit()
      throw error
    }
    process.waitUntilExit()
    return ExecutionExit(
      status: process.terminationReason == .exit
        ? process.terminationStatus : 128 + process.terminationStatus,
      signal: process.terminationReason == .exit ? nil : process.terminationStatus)
  }

  private static func locateBootstrap() throws -> URL {
    let name = "computer-mcp-execution-bootstrap"
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
      .resolvingSymlinksInPath()
    let candidates = [
      Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + name),
      executable.deletingLastPathComponent().appendingPathComponent(name),
      executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "Helpers/" + name),
    ]
    guard
      let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }
      )
    else {
      throw ExecutionEnvironmentError.unavailable(
        "Execution requires the bundled execution bootstrap")
    }
    return result
  }

  private func spawn(
    _ executable: String, arguments: [String], command: ExecutionCommand,
    disclaim: Bool, input: Int32, output: Int32, error: Int32,
    channel: ExecutionBootstrapChannel, ownership: DarwinExecutionOwnership
  ) throws -> ExecutionExit {
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try check(
      posix_spawnattr_setflags(
        &attributes,
        Int16(
          POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
    var signalMask = sigset_t()
    var signalDefaults = sigset_t()
    sigemptyset(&signalMask)
    sigfillset(&signalDefaults)
    try check(posix_spawnattr_setsigmask(&attributes, &signalMask))
    try check(posix_spawnattr_setsigdefault(&attributes, &signalDefaults))
    try check(posix_spawn_file_actions_addchdir_np(&actions, command.directory.value))
    for (source, destination) in [
      (channel.child, STDIN_FILENO), (output, STDOUT_FILENO), (error, STDERR_FILENO),
    ] {
      try check(posix_spawn_file_actions_adddup2(&actions, source, destination))
    }
    if disclaim { try responsibility.disclaim(&attributes) }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp =
      command.environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) }
      + [nil]
    defer { for pointer in argv + envp { free(pointer) } }
    var pid: pid_t = 0
    try argv.withUnsafeBufferPointer { args in
      try envp.withUnsafeBufferPointer { environment in
        let result = posix_spawn(
          &pid, executable, &actions, &attributes,
          UnsafeMutablePointer(mutating: args.baseAddress!),
          UnsafeMutablePointer(mutating: environment.baseAddress!))
        guard result == 0 else {
          var isDirectory: ObjCBool = false
          let directoryExists =
            FileManager.default.fileExists(
              atPath: command.directory.value, isDirectory: &isDirectory) && isDirectory.boolValue
          let bootstrapExists = FileManager.default.isExecutableFile(atPath: executable)
          throw ExecutionEnvironmentError.launchFailed(
            "Process launch failed: \(result); bootstrap available: \(bootstrapExists); working directory available: \(directoryExists)"
          )
        }
      }
    }
    var failure: Error?
    do { try channel.accept(pid: pid, input: input, ownership: ownership) } catch {
      channel.disconnect()
      failure = error
    }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) != pid {
      if errno != EINTR { throw ExecutionEnvironmentError.launchFailed("waitpid failed: \(errno)") }
    }
    if let failure { throw failure }
    let signal = status & 0x7f
    return ExecutionExit(
      status: signal == 0 ? (status >> 8) & 0xff : 128 + signal, signal: signal == 0 ? nil : signal)
  }

  private func check(_ status: Int32) throws {
    guard status == 0 else {
      throw ExecutionEnvironmentError.launchFailed("Process launch failed: \(status)")
    }
  }
}

/// Used by one launch worker; the child blocks until the host has captured its exact identity.
private final class ExecutionBootstrapChannel: @unchecked Sendable {
  private var parent: Int32
  private(set) var child: Int32

  init() throws {
    var sockets: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
      throw ExecutionEnvironmentError.launchFailed(
        "Cannot create launch identity channel: \(errno)")
    }
    parent = sockets[0]
    child = sockets[1]
    for descriptor in sockets {
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      var timeout = timeval(tv_sec: 5, tv_usec: 0)
      var enabled: Int32 = 1
      guard
        setsockopt(
          descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
          == 0,
        setsockopt(
          descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
      else {
        disconnect()
        throw ExecutionEnvironmentError.launchFailed(
          "Cannot configure launch identity channel: \(errno)")
      }
    }
  }

  func accept(pid: pid_t, input: Int32, ownership: DarwinExecutionOwnership) throws {
    // Keep both socket endpoints alive throughout the child's descriptor receipt.
    let identity = try DarwinProcessIdentity.receive(from: parent, pid: pid)
    try ownership.launched(identity)
    // Darwin CMSG_LEN/CMSG_SPACE align the header and payload to four bytes.
    var control: [UInt32] = [16, UInt32(SOL_SOCKET), UInt32(SCM_RIGHTS), UInt32(bitPattern: input)]
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
          return sendmsg(parent, &message, 0)
        }
      }
    }
    guard sent == 1 else {
      throw ExecutionEnvironmentError.launchFailed("Cannot acknowledge launch identity: \(errno)")
    }
    // Keep the caller's input alive until the child owns the transferred descriptor.
    var confirmation: UInt8 = 0
    var received: Int
    repeat { received = recv(parent, &confirmation, 1, 0) } while received < 0 && errno == EINTR
    guard received == 1, confirmation == 2 else {
      let status = received < 0 ? errno : 0
      throw ExecutionEnvironmentError.launchFailed(
        "Cannot confirm execution input handoff: received \(received), value \(confirmation), errno \(status)"
      )
    }
    disconnect()
    ownership.ready()
  }

  func disconnect() {
    if parent >= 0 {
      shutdown(parent, SHUT_RDWR)
      close(parent)
      parent = -1
    }
    if child >= 0 {
      close(child)
      child = -1
    }
  }

  deinit { disconnect() }
}
/// The bootstrap reports its kernel identity on the private launch channel before target exec.
/// The spawn PID binds that report; ownership checks subsequent liveness and signal identities.
struct DarwinProcessIdentity: Hashable, Sendable {
  let pid: pid_t
  let uniqueID: UInt64

  static func receive(from socket: Int32, pid: pid_t) throws -> Self {
    var bytes = [UInt8](repeating: 0, count: 16)
    var offset = 0
    while offset < bytes.count {
      let received = bytes.withUnsafeMutableBytes { buffer in
        recv(socket, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
      }
      if received < 0, errno == EINTR { continue }
      guard received > 0 else {
        throw ExecutionEnvironmentError.launchFailed("Launch identity handshake failed")
      }
      offset += received
    }
    let identity = bytes.withUnsafeBytes { buffer in
      Self(
        pid: pid_t(bitPattern: buffer.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
        uniqueID: buffer.loadUnaligned(as: UInt64.self))
    }
    guard identity.pid == pid, identity.uniqueID != 0 else {
      throw ExecutionEnvironmentError.launchFailed("Bootstrap reported an invalid launch identity")
    }
    return identity
  }

  static func current(pid: pid_t, includingZombies: Bool = false) -> (
    identity: Self, version: UInt32, parentUniqueID: UInt64
  )? {
    // XNU bsd/sys/proc_info_private.h defines PROC_PIDUNIQIDENTIFIERINFO (17) and the
    // 56-byte proc_uniqidentifierinfo ABI, not exposed in the SDK. proc_info.c permits
    // cross-user reads for this flavor; arg 1 includes zombies. kern_fork.c preserves
    // p_uniqueid across exec; p_idversion changes and is used only for signaling.
    var bytes = [UInt8](repeating: 0, count: 56)
    guard proc_pidinfo(pid, 17, includingZombies ? 1 : 0, &bytes, Int32(bytes.count)) == bytes.count
    else { return nil }
    return bytes.withUnsafeBytes { buffer in
      (
        Self(pid: pid, uniqueID: buffer.loadUnaligned(fromByteOffset: 16, as: UInt64.self)),
        buffer.loadUnaligned(fromByteOffset: 32, as: UInt32.self),
        buffer.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
      )
    }
  }

}

struct DarwinPrivacyResponsibility: Sendable {
  typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
  typealias FoundationDisclaim = @convention(c) (AnyObject, Selector, Bool) -> Void
  let symbol: @Sendable () -> Disclaim?
  let foundationMethod: @Sendable (Process) -> Method?

  init(
    symbol: @escaping @Sendable () -> Disclaim? = {
      let scope = UnsafeMutableRawPointer(bitPattern: -2)
      guard let pointer = dlsym(scope, "responsibility_spawnattrs_setdisclaim") else { return nil }
      return unsafeBitCast(pointer, to: Disclaim.self)
    },
    foundationMethod: @escaping @Sendable (Process) -> Method? = { process in
      class_getInstanceMethod(
        type(of: process), NSSelectorFromString("setSpawnedProcessDisclaimed:"))
    }
  ) {
    self.symbol = symbol
    self.foundationMethod = foundationMethod
  }

  func preflight() throws {
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw ExecutionEnvironmentError.unavailable(
        "Cannot create privacy responsibility spawn attributes")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    try disclaim(&attributes)
    try disclaim(Process())
  }

  func disclaim(_ attributes: inout posix_spawnattr_t?) throws {
    guard let set = symbol() else {
      throw ExecutionEnvironmentError.unavailable(
        "Full access unavailable: responsibility_spawnattrs_setdisclaim is missing")
    }
    let status = set(&attributes, 1)
    guard status == 0 else {
      throw ExecutionEnvironmentError.unavailable(
        "Full access unavailable: responsibility disclaimer failed (\(status))")
    }
  }

  func disclaim(_ process: Process) throws {
    guard let method = foundationMethod(process), method_getNumberOfArguments(method) == 3 else {
      throw ExecutionEnvironmentError.unavailable(
        "Full access unavailable: Foundation responsibility setter is missing")
    }
    let argument = method_copyArgumentType(method, 2)
    let result = method_copyReturnType(method)
    defer {
      free(argument)
      free(result)
    }
    guard let argument, ["c", "B"].contains(String(cString: argument)),
      String(cString: result) == "v"
    else {
      throw ExecutionEnvironmentError.unavailable(
        "Full access unavailable: Foundation responsibility setter ABI changed")
    }
    let implementation = unsafeBitCast(
      method_getImplementation(method), to: FoundationDisclaim.self)
    implementation(process, NSSelectorFromString("setSpawnedProcessDisclaimed:"), true)
  }
}
