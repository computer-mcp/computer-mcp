import ComputerMCPSandbox
import Darwin
import Foundation
import ObjectiveC
import Subprocess
import System

package struct DarwinExecutionPlatform: ExecutionPlatform {
  package var supportsRecovery: Bool { true }
  package var supportsBestEffortOwnership: Bool { true }
  package func supportsDurableOwnership(sandboxed: Bool) -> Bool { sandboxed }
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
  private let launchTimeout: Duration
  private let table: DarwinExecutionProcessTable
  private let makeSentinel: @Sendable () async throws -> DarwinExecutionSentinel

  package init(bootstrapExecutable: URL? = nil) {
    launchTimeout = .seconds(30)
    responsibility = .init()
    self.bootstrapExecutable = bootstrapExecutable
    table = .system
    makeSentinel = { try await DarwinExecutionSentinel.create() }
  }

  init(
    responsibility: DarwinPrivacyResponsibility = .init(), bootstrapExecutable: URL? = nil,
    table: DarwinExecutionProcessTable = .system, launchTimeout: Duration = .seconds(30),
    makeSentinel: @escaping @Sendable () async throws -> DarwinExecutionSentinel = {
      try await DarwinExecutionSentinel.create()
    }
  ) {
    self.launchTimeout = launchTimeout
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

  package func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    guard state.backend == "darwin", state.root.processID > 0,
      state.root.identity > 0
    else {
      throw ExecutionEnvironmentError.unavailable("Invalid Darwin execution recovery")
    }
    let root = DarwinProcessIdentity(pid: state.root.processID, uniqueID: state.root.identity)
    if !state.sandboxed {
      guard state.payload == nil else {
        throw ExecutionEnvironmentError.unavailable("Invalid process-group recovery evidence")
      }
      let ownership = DarwinExecutionOwnership(marker: nil, table: table)
      // The bootstrap creates a session and process group whose ID is the recorded root PID.
      // Membership still needs a stable identity anchor; the numeric group never grants ownership.
      try ownership.recover([root], processGroup: root.pid)
      return ownership
    }
    guard let payload = state.payload, payload.count <= 65_536 else {
      throw ExecutionEnvironmentError.unavailable("Sandbox recovery evidence is unavailable")
    }
    let marker = try ExecutionSandboxMarker(
      recovery: JSONDecoder().decode(ExecutionSandboxMarker.Recovery.self, from: payload))
    let ownership = DarwinExecutionOwnership(
      marker: marker, table: table, recoveryRoot: root)
    try ownership.recover([root])
    return ownership
  }

  package func releaseRecovery(_ state: ExecutionRecoveryState) throws {
    guard state.backend == "darwin" else {
      throw ExecutionEnvironmentError.unavailable("Unknown execution recovery backend")
    }
    if state.sandboxed, let payload = state.payload {
      try ExecutionSandboxMarker.release(
        JSONDecoder().decode(ExecutionSandboxMarker.Recovery.self, from: payload))
    }
  }

  package func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?,
    method: ExecutionLaunchMethod, input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    try Task.checkCancellation()
    guard
      command.directoryDescriptor == nil
        || ((sandbox == nil || sandbox?.readOnly == true) && method == .posixSpawn)
    else {
      throw ExecutionEnvironmentError.invalidConfiguration(
        "Descriptor working directories require a Full access or read-only POSIX launch")
    }
    if sandbox == nil { try responsibility.preflight() }
    let bootstrap = try bootstrapExecutable ?? Self.locateBootstrap()
    let marker = try sandbox.map { _ in try ExecutionSandboxMarker() }
    let target =
      sandbox.map {
        [
          "/usr/bin/sandbox-exec", "-p", SeatbeltProfile.generate($0, marker: marker), "--",
          command.executable.value,
        ] + command.arguments
      } ?? [command.executable.value] + command.arguments
    let arguments = command.bootstrapOptions + target
    let channel = try ExecutionBootstrapChannel(input: input, error: error, timeout: launchTimeout)
    let diagnostics = try ExecutionBootstrapDiagnostics()
    let sentinel: DarwinExecutionSentinel?
    if marker != nil {
      sentinel = try await makeSentinel()
    } else {
      sentinel = nil
    }
    try Task.checkCancellation()
    let ownership = DarwinExecutionOwnership(marker: marker, sentinel: sentinel, table: table)
    let handle: any ExecutionOwnership
    do {
      handle = try await withTaskCancellationHandler {
        bindOwnership(ownership)
        return try await withCheckedThrowingContinuation { continuation in
          ownership.starting(continuation)
          if method == .subprocess {
            Task.detached {
              do {
                let policies = DarwinSpawnPolicyStorage()
                defer { withExtendedLifetime(policies) {} }
                var options = PlatformOptions()
                if sandbox == nil {
                  options.preSpawnProcessConfigurator = { attributes, _ in
                    try responsibility.disclaim(&attributes)
                    try policies.retain("Quarantine", in: &attributes)
                  }
                }
                // The raw-byte environment API passes NUL-terminated C strings to spawn.
                let environment = command.environment.map {
                  Array(($0.key + "=" + $0.value + "\0").utf8)
                }
                let result = try await Subprocess.run(
                  .path(FilePath(bootstrap.path)), arguments: .init(arguments),
                  environment: .custom(environment),
                  workingDirectory: FilePath(command.directory.value),
                  platformOptions: options,
                  input: .fileDescriptor(
                    .init(rawValue: channel.child), closeAfterSpawningProcess: false),
                  output: .fileDescriptor(
                    .init(rawValue: output), closeAfterSpawningProcess: false),
                  error: .fileDescriptor(
                    .init(rawValue: diagnostics.writer), closeAfterSpawningProcess: false)
                ) { execution in
                  channel.didSpawn(ownership: ownership)
                  diagnostics.didSpawn()
                  return await withCheckedContinuation { continuation in
                    DispatchQueue(label: "execution.launch", qos: .userInitiated).async {
                      var result = Result {
                        try channel.accept(
                          pid: execution.processIdentifier.value, ownership: ownership)
                      }
                      if case .failure = result { channel.disconnect() }
                      do {
                        try Self.waitForTerminalState(execution.processIdentifier.value)
                        ownership.observeRootForViolations()
                      } catch {
                        if case .success = result { result = .failure(error) }
                      }
                      continuation.resume(returning: result)
                    }
                  }
                }
                let exit: ExecutionExit
                switch result.terminationStatus {
                case .exited(let status): exit = ExecutionExit(status: status)
                case .signaled(let signal):
                  exit = ExecutionExit(status: 128 + signal, signal: signal)
                }
                if case .failure(let failure) = result.closureResult {
                  ownership.launchFailed(diagnostics.failure(failure, exit: exit))
                }
                channel.finished()
                ownership.exited(.success(exit))
              } catch {
                channel.disconnect()
                channel.finished()
                ownership.launchFailed(error)
                // A failed spawn has no child to reap. Once spawned, collector errors
                // remain completion failures and must retain ownership.
                ownership.exited(
                  channel.hasSpawned ? .failure(error) : .success(.init(status: 127)))
              }
            }
          } else {
            DispatchQueue(label: "execution.launch", qos: .userInitiated).async {
              do {
                let result: ExecutionExit
                if method == .foundation {
                  result = try foundation(
                    bootstrap, arguments: arguments, command: command, disclaim: sandbox == nil,
                    input: input, output: output, error: error, channel: channel,
                    diagnostics: diagnostics, ownership: ownership
                  )
                } else {
                  result = try spawn(
                    bootstrap.path, arguments: arguments, command: command,
                    disclaim: sandbox == nil,
                    input: input, output: output, error: error, channel: channel,
                    diagnostics: diagnostics, ownership: ownership
                  )
                }
                channel.finished()
                ownership.exited(.success(result))
              } catch {
                channel.disconnect()
                channel.finished()
                ownership.launchFailed(error)
                // A failed spawn has no child to reap. Once spawned, collector errors
                // remain completion failures and must retain ownership.
                ownership.exited(
                  channel.hasSpawned ? .failure(error) : .success(.init(status: 127)))
              }
            }
          }
        }
      } onCancel: {
        ownership.requestCancellation()
      }
    } catch {
      if Task.isCancelled {
        do { _ = try await ownership.cancel() } catch let failure as ExecutionCompletionFailure {
          throw failure
        } catch let expiry as ExecutionWaitExpired {
          throw expiry
        } catch {}
        throw CancellationError()
      }
      throw error
    }
    if Task.isCancelled {
      _ = try await handle.cancel()
      throw CancellationError()
    }
    return handle
  }

  /// Darwin may report a stopped child even for WEXITED. Leave collection to
  /// Subprocess only after terminal status is observable; its reaper requires it.
  private static func waitForTerminalState(_ pid: pid_t) throws {
    while true {
      var info = siginfo_t()
      guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0 else {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      if [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(info.si_code) { return }
      Thread.sleep(forTimeInterval: 0.001)
    }
  }

  private func foundation(
    _ executable: URL, arguments: [String], command: ExecutionCommand,
    disclaim: Bool, input: Int32, output: Int32, error: Int32,
    channel: ExecutionBootstrapChannel, diagnostics: ExecutionBootstrapDiagnostics,
    ownership: DarwinExecutionOwnership
  ) throws -> ExecutionExit {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = command.environment
    process.currentDirectoryURL = URL(fileURLWithPath: command.directory.value)
    process.standardInput = FileHandle(fileDescriptor: channel.child, closeOnDealloc: false)
    process.standardOutput = FileHandle(fileDescriptor: output, closeOnDealloc: false)
    process.standardError = FileHandle(fileDescriptor: diagnostics.writer, closeOnDealloc: false)
    if disclaim { try responsibility.disclaim(process) }
    try process.run()
    channel.didSpawn(ownership: ownership)
    diagnostics.didSpawn()
    var failure: Error?
    do {
      try channel.accept(pid: process.processIdentifier, ownership: ownership)
    } catch {
      channel.disconnect()
      failure = error
    }
    process.waitUntilExit()
    let exit = ExecutionExit(
      status: process.terminationReason == .exit
        ? process.terminationStatus : 128 + process.terminationStatus,
      signal: process.terminationReason == .exit ? nil : process.terminationStatus)
    if let failure { ownership.launchFailed(diagnostics.failure(failure, exit: exit)) }
    return exit
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
    channel: ExecutionBootstrapChannel, diagnostics: ExecutionBootstrapDiagnostics,
    ownership: DarwinExecutionOwnership
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
    // The directory descriptor can overlap a stdio destination.
    if let directory = command.directoryDescriptor {
      try check(posix_spawn_file_actions_addfchdir_np(&actions, directory))
    } else {
      try check(posix_spawn_file_actions_addchdir_np(&actions, command.directory.value))
    }
    // Copy every source above all destinations before remapping, including overlapping mappings.
    let mappings =
      [(STDIN_FILENO, channel.child), (STDOUT_FILENO, output), (STDERR_FILENO, diagnostics.writer)]
      + command.inheritedDescriptors.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    let minimum = (mappings.map { $0.0 }.max() ?? 2) + 1
    var copies: [FileHandle] = []
    defer { for handle in copies { try? handle.close() } }
    for (destination, source) in mappings {
      let copy = fcntl(source, F_DUPFD_CLOEXEC, minimum)
      guard copy >= 0 else {
        throw ExecutionEnvironmentError.launchFailed("Cannot copy launch descriptor")
      }
      copies.append(FileHandle(fileDescriptor: copy, closeOnDealloc: true))
    }
    for (mapping, copy) in zip(mappings, copies) {
      try check(posix_spawn_file_actions_adddup2(&actions, copy.fileDescriptor, mapping.0))
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
    channel.didSpawn(ownership: ownership)
    diagnostics.didSpawn()
    var failure: Error?
    do { try channel.accept(pid: pid, ownership: ownership) } catch {
      channel.disconnect()
      failure = error
    }
    // Closing a shared socket while libproc inspects it can drain the child's
    // endpoint on Darwin. Keep every launch copy until the handoff has ended.
    for handle in copies { try? handle.close() }
    copies.removeAll()
    if ownership.observesSandboxViolations {
      try? Self.waitForTerminalState(pid)
      ownership.observeRootForViolations()
    }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) != pid {
      if errno != EINTR { throw ExecutionEnvironmentError.launchFailed("waitpid failed: \(errno)") }
    }
    let signal = status & 0x7f
    let exit = ExecutionExit(
      status: signal == 0 ? (status >> 8) & 0xff : 128 + signal, signal: signal == 0 ? nil : signal)
    if let failure { ownership.launchFailed(diagnostics.failure(failure, exit: exit)) }
    return exit
  }

  private func check(_ status: Int32) throws {
    guard status == 0 else {
      throw ExecutionEnvironmentError.launchFailed("Process launch failed: \(status)")
    }
  }
}

/// The timer and admission worker share only short state transitions. A blocked admission
/// callback cannot retain the caller; descriptor copies and ownership outlive failed startup.
private final class ExecutionBootstrapChannel: @unchecked Sendable {
  private let lock = NSLock()
  private let parent: Int32
  private(set) var child: Int32
  private let input: FileHandle
  private let error: FileHandle
  private let timeout: Duration
  private var deadline: ContinuousClock.Instant?
  private var timer: (any DispatchSourceTimer)?
  private var spawned = false
  private var result: Result<Void, Error>?
  private let admitted = DispatchSemaphore(value: 0)

  init(input: Int32, error: Int32, timeout: Duration) throws {
    func copy(_ descriptor: Int32) throws -> FileHandle {
      let value = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
      guard value >= 0 else {
        throw ExecutionEnvironmentError.launchFailed("Cannot retain launch descriptor")
      }
      return FileHandle(fileDescriptor: value, closeOnDealloc: true)
    }
    self.input = try copy(input)
    self.error = try copy(error)
    self.timeout = timeout
    var sockets: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
      throw ExecutionEnvironmentError.launchFailed(
        "Cannot create launch identity channel: \(errno)")
    }
    parent = sockets[0]
    child = sockets[1]
    for descriptor in sockets {
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      var enabled: Int32 = 1
      guard
        setsockopt(
          descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
          socklen_t(MemoryLayout<Int32>.size)) == 0
      else {
        close(sockets[0])
        close(sockets[1])
        throw ExecutionEnvironmentError.launchFailed("Cannot configure launch identity channel")
      }
    }
  }

  var hasSpawned: Bool { lock.withLock { spawned } }

  func didSpawn(ownership: DarwinExecutionOwnership) {
    lock.withLock {
      deadline = .now.advanced(by: timeout)
      spawned = true
      let timer = DispatchSource.makeTimerSource(
        queue: DispatchQueue(label: "execution.launch-deadline"))
      let components = timeout.components
      let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
      timer.schedule(deadline: .now() + seconds)
      timer.setEventHandler { [self] in
        let failure = ExecutionBootstrapHandshakeFailure("Launch handshake deadline exceeded")
        let expired = lock.withLock {
          guard self.timer != nil else { return false }
          shutdown(parent, SHUT_RDWR)
          closeChild()
          if result == nil {
            result = .failure(failure)
            admitted.signal()
          }
          ownership.launchFailed(failure)
          stopTimer()
          return true
        }
        guard expired else { return }
        // Cancellation callbacks and kernel inspection cannot delay the launch deadline.
        DispatchQueue.global().async { ownership.requestCancellation() }
      }
      self.timer = timer
      timer.resume()
    }
  }

  func accept(pid: pid_t, ownership: DarwinExecutionOwnership) throws {
    DispatchQueue(label: "execution.launch-admission").async { [self] in
      var outcome = Result {
        try ownership.spawned(pid)
        let deadline = lock.withLock { self.deadline! }
        let identity = try DarwinProcessIdentity.receive(from: parent, pid: pid, deadline: deadline)
        try ownership.launched(identity)
        // Serialize the release with expiry. A late callback can never acknowledge the target.
        try lock.withLock {
          guard result == nil else { throw ExecutionBootstrapHandshakeFailure("Launch expired") }
          try ExecutionBootstrapDeadline.check(deadline)
          var control: [UInt32] = [
            20, UInt32(SOL_SOCKET), UInt32(SCM_RIGHTS), UInt32(bitPattern: input.fileDescriptor),
            UInt32(bitPattern: error.fileDescriptor),
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
                return sendmsg(parent, &message, MSG_DONTWAIT)
              }
            }
          }
          guard sent == 1 else {
            throw ExecutionBootstrapHandshakeFailure("Cannot acknowledge launch identity: \(errno)")
          }
        }
        var confirmation: UInt8 = 0
        var received: Int
        repeat {
          try ExecutionBootstrapDeadline.waitForReadable(parent, pid: pid, until: deadline)
          received = recv(parent, &confirmation, 1, 0)
        } while received < 0 && errno == EINTR
        guard received == 1, confirmation == 2 else {
          throw ExecutionBootstrapHandshakeFailure("Cannot confirm execution descriptor handoff")
        }
      }
      lock.withLock {
        guard result == nil else { return }
        if case .success = outcome {
          outcome = Result { try ExecutionBootstrapDeadline.check(deadline!) }
        }
        result = outcome
        shutdown(parent, SHUT_RDWR)
        closeChild()
        if case .success = outcome {
          stopTimer()
          ownership.ready()
        }
        admitted.signal()
      }
      if case .failure = outcome { ownership.requestCancellation() }
    }
    admitted.wait()
    try lock.withLock { try result!.get() }
  }

  func disconnect() {
    lock.withLock {
      shutdown(parent, SHUT_RDWR)
      closeChild()
    }
  }

  func finished() { lock.withLock { stopTimer() } }

  private func closeChild() {
    if child >= 0 { close(child) }
    child = -1
  }

  private func stopTimer() {
    timer?.cancel()
    timer?.setEventHandler {}
    timer = nil
  }

  deinit {
    close(parent)
    if child >= 0 { close(child) }
  }
}
/// One monotonic budget covers scheduling, partial reads, ownership admission and confirmation.
private enum ExecutionBootstrapDeadline {
  static func check(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else {
      throw ExecutionBootstrapHandshakeFailure("Launch handshake deadline exceeded")
    }
  }

  static func waitForReadable(
    _ socket: Int32, pid: pid_t, until deadline: ContinuousClock.Instant
  ) throws {
    while true {
      try check(deadline)
      let remaining = ContinuousClock.now.duration(to: deadline).components
      let milliseconds = max(
        1, remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000)
      var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
      let result = poll(&descriptor, 1, Int32(min(milliseconds, 50)))
      if result < 0, errno == EINTR { continue }
      if result == 0 {
        // Retained child-end copies prevent EOF. Observe exit without reaping;
        // each launch backend still owns collection and the diagnostic status.
        var state = siginfo_t()
        let observed = waitid(P_PID, id_t(pid), &state, WEXITED | WNOHANG | WNOWAIT)
        if observed < 0, errno == EINTR { continue }
        guard observed == 0,
          ![CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(state.si_code)
        else {
          throw ExecutionBootstrapHandshakeFailure(
            "Bootstrap exited before completing the handshake")
        }
        continue
      }
      guard result > 0 else {
        throw ExecutionBootstrapHandshakeFailure("Launch handshake polling failed: \(errno)")
      }
      return
    }
  }
}

/// The bootstrap reports its kernel identity on the private launch channel before target exec.
/// The spawn PID binds that report; ownership checks subsequent liveness and signal identities.
struct DarwinProcessIdentity: Hashable, Sendable {
  let pid: pid_t
  let uniqueID: UInt64

  static func receive(
    from socket: Int32, pid: pid_t,
    deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(30))
  ) throws -> Self {
    var bytes = [UInt8](repeating: 0, count: 16)
    var offset = 0
    let started = ContinuousClock.now
    while offset < bytes.count {
      try ExecutionBootstrapDeadline.waitForReadable(socket, pid: pid, until: deadline)
      let received = bytes.withUnsafeMutableBytes { buffer in
        recv(socket, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
      }
      if received < 0, errno == EINTR { continue }
      guard received > 0 else {
        let status = received < 0 ? errno : 0
        let elapsed = (ContinuousClock.now - started).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        throw ExecutionBootstrapHandshakeFailure(
          "Launch identity handshake failed: received \(received), offset \(offset), errno \(status), after \(milliseconds) ms"
        )
      }
      offset += received
    }
    let identity = bytes.withUnsafeBytes { buffer in
      Self(
        pid: pid_t(bitPattern: buffer.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
        uniqueID: buffer.loadUnaligned(as: UInt64.self))
    }
    guard identity.pid == pid, identity.uniqueID != 0 else {
      throw ExecutionBootstrapHandshakeFailure("Bootstrap reported an invalid launch identity")
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
