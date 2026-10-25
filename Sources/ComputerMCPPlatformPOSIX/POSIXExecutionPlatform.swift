#if os(Linux)
  import ComputerMCPSandbox
  import Foundation
  import Glibc

  /// Linux Full access backend. The unreaped leader pins the process-group identity.
  /// Sandbox execution requires a separate Linux confinement backend.
  package struct POSIXExecutionPlatform: ExecutionPlatform {
    package init() {}
    package var bootSessionID: String? {
      try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package func start(
      _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
      input: Int32, output: Int32, error: Int32,
      bindOwnership: @Sendable (any ExecutionOwnership) -> Void
    ) async throws -> any ExecutionOwnership {
      guard sandbox == nil else {
        throw ExecutionEnvironmentError.unavailable("Linux sandbox execution is unavailable")
      }
      try Task.checkCancellation()
      let owner = POSIXExecutionOwnership()
      bindOwnership(owner)
      do {
        try owner.launch(command, input: input, output: output, error: error)
      } catch {
        owner.failedLaunch(error)
        throw error
      }
      return owner
    }
  }

  @_silgen_name("posix_spawn_file_actions_addchdir_np")
  private func addWorkingDirectory(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t>, _ path: UnsafePointer<CChar>
  ) -> Int32

  @_silgen_name("posix_spawn_file_actions_addclosefrom_np")
  private func closeDescriptors(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t>, _ first: Int32
  ) -> Int32

  private final class POSIXExecutionOwnership: ExecutionOwnership, @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var identity: UInt64 = 0
    private var known: [pid_t: UInt64] = [:]
    private var exit: ExecutionExit?
    private var failure: (any Error)?
    private var cancellation: ContinuousClock.Instant?
    private var handlers: [@Sendable () -> Void] = []
    private var launchHandlers: [@Sendable (ExecutionMember) throws -> Void] = []
    private var timer: (any DispatchSourceTimer)?

    func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {
      lock.withLock { launchHandlers.append(handler) }
    }

    func launch(_ command: ExecutionCommand, input: Int32, output: Int32, error: Int32) throws {
      var actions = posix_spawn_file_actions_t()
      var attributes = posix_spawnattr_t()
      func check(_ status: Int32) throws {
        guard status == 0 else {
          throw ExecutionEnvironmentError.launchFailed("POSIX launch: \(status)")
        }
      }
      try check(posix_spawn_file_actions_init(&actions))
      defer { posix_spawn_file_actions_destroy(&actions) }
      try check(posix_spawnattr_init(&attributes))
      defer { posix_spawnattr_destroy(&attributes) }
      for (source, destination) in [(input, 0), (output, 1), (error, 2)] {
        try check(posix_spawn_file_actions_adddup2(&actions, source, Int32(destination)))
      }
      // Inherited pipe writers prevent stdin EOF even after the host closes its writer.
      try check(closeDescriptors(&actions, 3))
      try command.directory.value.withCString { try check(addWorkingDirectory(&actions, $0)) }
      try check(posix_spawnattr_setpgroup(&attributes, 0))
      var mask = sigset_t()
      sigemptyset(&mask)
      try check(posix_spawnattr_setsigmask(&attributes, &mask))
      var defaults = sigset_t()
      sigfillset(&defaults)
      try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
      try check(
        posix_spawnattr_setflags(
          &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        ))
      let bootstrap = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("computer-mcp-execution-bootstrap")
      guard FileManager.default.isExecutableFile(atPath: bootstrap.path) else {
        throw ExecutionEnvironmentError.unavailable(
          "Execution requires the bundled execution bootstrap")
      }
      let argv =
        ([bootstrap.path, command.executable.value] + command.arguments)
        .map { strdup($0) } + [nil]
      let env = command.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
      defer { for value in argv + env { free(value) } }
      var child: pid_t = 0
      try check(
        argv.withUnsafeBufferPointer { argv in
          env.withUnsafeBufferPointer { env in
            posix_spawn(
              &child, bootstrap.path, &actions, &attributes, argv.baseAddress!,
              env.baseAddress!)
          }
        })
      // The bootstrap stops before exec. Keeping it unreaped pins its PID throughout admission.
      lock.withLock { pid = child }
      var status: Int32 = 0
      var waited: pid_t
      repeat { waited = waitpid(child, &status, WUNTRACED) } while waited < 0 && errno == EINTR
      guard waited == child, status & 0xff == 0x7f, let process = Self.read(child) else {
        if waited == child && status & 0xff != 0x7f { lock.withLock { pid = nil } }
        throw ExecutionEnvironmentError.launchFailed("Execution bootstrap did not stop before exec")
      }
      let callbacks = lock.withLock {
        identity = process.identity
        known[child] = identity
        return launchHandlers
      }
      defer { startMonitoring() }
      for callback in callbacks {
        try callback(.init(processID: child, identity: process.identity))
      }
      _ = kill(child, SIGCONT)
    }

    func failedLaunch(_ error: any Error) {
      let active = lock.withLock {
        guard pid != nil else {
          failure = error
          return false
        }
        cancellation = .now.advanced(by: .milliseconds(-500))
        return true
      }
      if active { startMonitoring() }
    }

    private func startMonitoring() {
      lock.withLock {
        guard timer == nil, pid != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "execution.posix"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { self.poll() }
        self.timer = timer
        timer.resume()
      }
    }

    func onCancellation(_ handler: @escaping @Sendable () -> Void) {
      let cancelled = lock.withLock {
        handlers.append(handler)
        return cancellation != nil
      }
      if cancelled { handler() }
    }

    func members() async throws -> [ExecutionMember] {
      lock.withLock { known.map { .init(processID: $0.key, identity: $0.value) } }
    }

    func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
      let callbacks = lock.withLock {
        if cancellation == nil { cancellation = .now }
        return handlers
      }
      for callback in callbacks { callback() }
      return try await wait(until: deadline)
    }

    func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
      while true {
        if let error = lock.withLock({ failure }) { throw error }
        if let result = lock.withLock({ exit }) { return result }
        if ContinuousClock.now >= deadline {
          throw ExecutionCompletionFailure(
            ownership: self, members: [], reasons: ["POSIX execution remains active"],
            bestEffort: true)
        }
        if Task.isCancelled {
          let callbacks = lock.withLock {
            if cancellation == nil { cancellation = .now }
            return handlers
          }
          for callback in callbacks { callback() }
        }
        await withCheckedContinuation { continuation in
          DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
            continuation.resume()
          }
        }
      }
    }

    private struct ProcessRecord {
      let pid: pid_t
      let identity: UInt64
      let parent: pid_t
      let group: pid_t
      let zombie: Bool
    }

    private static func read(_ pid: pid_t) -> ProcessRecord? {
      guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
        let end = text.lastIndex(of: ")")
      else { return nil }
      let fields = text[text.index(after: end)...].split(separator: " ")
      guard fields.count > 19, let parent = pid_t(fields[1]), let group = pid_t(fields[2]),
        let identity = UInt64(fields[19])
      else { return nil }
      return .init(
        pid: pid, identity: identity, parent: parent, group: group, zombie: fields[0] == "Z")
    }

    private static func signal(_ member: ProcessRecord, _ signal: Int32) {
      typealias Open = @convention(c) (Int32, UInt32) -> Int32
      typealias Send = @convention(c) (Int32, Int32, UnsafeRawPointer?, UInt32) -> Int32
      guard let library = dlopen(nil, RTLD_LAZY) else { return }
      defer { dlclose(library) }
      guard let openAddress = dlsym(library, "pidfd_open"),
        let sendAddress = dlsym(library, "pidfd_send_signal")
      else { return }
      let open = unsafeBitCast(openAddress, to: Open.self)
      let send = unsafeBitCast(sendAddress, to: Send.self)
      let descriptor = open(member.pid, 0)
      guard descriptor >= 0 else { return }
      defer { close(descriptor) }
      guard read(member.pid)?.identity == member.identity else { return }
      _ = send(descriptor, signal, nil, 0)
    }

    private func poll() {
      lock.withLock {
        guard let pid, exit == nil else { return }
        let records = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [])
          .compactMap(pid_t.init).compactMap(Self.read)
        var members = records.filter { $0.group == pid || known[$0.pid] == $0.identity }
        var expanded = true
        while expanded {
          let parents = Set(members.map(\.pid))
          let extra = records.filter { parents.contains($0.parent) && !parents.contains($0.pid) }
          expanded = !extra.isEmpty
          members += extra
        }
        for member in members { known[member.pid] = member.identity }
        if let cancellation {
          let signal = ContinuousClock.now - cancellation >= .milliseconds(500) ? SIGKILL : SIGTERM
          // The unreaped leader keeps this group ID reserved. Escaped children require pidfds.
          _ = kill(-pid, signal)
          _ = kill(-pid, SIGCONT)
          for member in members where !member.zombie && member.group != pid {
            Self.signal(member, signal)
          }
        }
        guard let root = members.first(where: { $0.pid == pid }), root.zombie,
          !members.contains(where: { $0.pid != pid && !$0.zombie })
        else { return }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        let signal = status & 0x7f
        exit = .init(
          status: signal == 0 ? (status >> 8) & 0xff : 128 + signal,
          signal: signal == 0 ? nil : signal)
        known.removeAll()
        timer?.cancel()
        timer = nil
      }
    }
  }
#endif
