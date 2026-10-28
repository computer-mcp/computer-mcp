import ComputerMCPSandbox
import Darwin
import Foundation

/// The lock protects published state only. Kernel queries and identity-checked signals run on a
/// serial worker; an independent timer expires callers even if libproc is blocked in exec.
final class DarwinExecutionOwnership: ExecutionOwnership, @unchecked Sendable {
  private let lock = NSLock()
  private let worker = DispatchQueue(label: "execution.process-inspection")
  private let timerQueue = DispatchQueue(label: "execution.deadlines")
  private let table: DarwinExecutionProcessTable
  private let observationInterval: DispatchTimeInterval
  private let sentinel: DarwinExecutionSentinel?
  private let recoveryRoot: DarwinProcessIdentity?
  private var marker: ExecutionSandboxMarker?
  private let bestEffort: Bool
  private var launchHandlers: [@Sendable (ExecutionMember) throws -> Void] = []
  private var sandboxViolations: DarwinSandboxViolationObserver?
  private var root: DarwinProcessIdentity?
  private var state = DarwinExecutionScan()
  private var cancellationStarted: ContinuousClock.Instant?
  private var cancellationDeadline: ContinuousClock.Instant?
  private var cancellationHandlers: [@Sendable () -> Void] = []
  private var pendingRevocations = 0
  private var generation: UInt64 = 0
  private var inspecting = false
  private var inspectionRequested = false
  private var completedScans: UInt64 = 0
  private var timer: (any DispatchSourceTimer)?
  private var rootExit: Result<ExecutionExit, Error>?
  private var completion: Result<ExecutionExit, Error>?
  private var startup: CheckedContinuation<any ExecutionOwnership, Error>?
  private var waiters:
    [(deadline: ContinuousClock.Instant?, continuation: CheckedContinuation<ExecutionExit, Error>)] =
      []

  init(
    marker: ExecutionSandboxMarker?, sentinel: DarwinExecutionSentinel? = nil,
    table: DarwinExecutionProcessTable = .system,
    observationInterval: DispatchTimeInterval = .milliseconds(25),
    recoveryRoot: DarwinProcessIdentity? = nil
  ) {
    precondition(marker == nil ? sentinel == nil : sentinel != nil || recoveryRoot != nil)
    self.recoveryRoot = recoveryRoot
    self.sentinel = sentinel
    self.marker = marker
    self.table = table
    self.observationInterval = observationInterval
    bestEffort = marker == nil
  }

  /// Recovered identities are revalidated before signalling; old numeric PIDs alone confer no ownership.
  func recover(_ identities: [DarwinProcessIdentity], processGroup: pid_t? = nil) throws {
    var anchor: DarwinProcessSnapshot?
    for identity in identities {
      if let snapshot = try table.read(identity.pid), snapshot.identity == identity,
        snapshot.state != .zombie,
        try table.read(identity.pid)?.identity == identity
      {
        anchor = snapshot
        break
      }
    }
    lock.withLock {
      root = identities.first
      state.known.formUnion(identities)
      state.group = processGroup ?? anchor.flatMap { $0.group > 0 ? $0.group : nil }
      rootExit = .success(ExecutionExit(status: 128 + SIGTERM, signal: SIGTERM))
      startMonitor()
    }
  }

  func starting(_ continuation: CheckedContinuation<any ExecutionOwnership, Error>) {
    lock.withLock {
      startup = continuation
      startMonitor()
    }
  }

  func recoveryState() throws -> ExecutionRecoveryState {
    let (root, marker) = lock.withLock { (self.root, self.marker) }
    guard let root else {
      throw ExecutionEnvironmentError.unavailable("Execution has no root identity")
    }
    return try ExecutionRecoveryState(
      root: root.member, sandboxed: !bestEffort, backend: "darwin",
      payload: marker.map { try JSONEncoder().encode($0.recovery()) })
  }

  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {
    lock.withLock { launchHandlers.append(handler) }
  }

  func onSandboxViolation(_ handler: @escaping @Sendable (ExecutionSandboxViolation) -> Void) {
    guard let marker = lock.withLock({ completion == nil ? self.marker : nil }) else { return }
    let observer = DarwinSandboxViolationObserver(marker: marker, handler: handler)
    lock.withLock { sandboxViolations = observer }
  }

  var observesSandboxViolations: Bool { lock.withLock { sandboxViolations != nil } }

  func observeRootForViolations() {
    lock.withLock { sandboxViolations }?.observeRoot()
  }

  /// Capture ownership even if the bootstrap never sends a handshake. No process group
  /// is trusted until the real bootstrap has established and reported its isolated session.
  func spawned(_ pid: pid_t) throws {
    guard let process = DarwinProcessIdentity.current(pid: pid, includingZombies: true) else {
      return  // An already reaped bootstrap is reported by the backend's exit collector.
    }
    lock.withLock {
      root = process.identity
      state.known.insert(process.identity)
      requestInspection()
    }
  }

  /// Startup failure does not mean process completion; retain ownership until reaping.
  func launchFailed(_ error: Error) {
    lock.withLock {
      startup?.resume(throwing: error)
      startup = nil
    }
  }

  func launched(_ identity: DarwinProcessIdentity) throws {
    // The bootstrap establishes its own process group and session before the identity handshake.
    lock.withLock {
      root = identity
      state.known.insert(identity)
      state.group = bestEffort ? identity.pid : nil
      generation &+= 1
      state.complete = false
      requestInspection()
      startMonitor()
    }
    let handlers = lock.withLock {
      let handlers = launchHandlers
      launchHandlers.removeAll()
      return handlers
    }
    lock.withLock { sandboxViolations }?.admitRoot(identity)
    for handler in handlers { try handler(identity.member) }
  }

  private func startMonitor() {
    guard timer == nil, completion == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: timerQueue)
    timer.schedule(deadline: .now() + observationInterval, repeating: observationInterval)
    // Self-retention keeps failed cancellations owned until fresh scans confirm completion.
    timer.setEventHandler { self.lock.withLock { self.poll() } }
    self.timer = timer
    timer.resume()
  }

  /// Publish after the bootstrap confirms receipt of the caller's stdin and stderr descriptors.
  func ready() {
    lock.withLock {
      startup?.resume(returning: self)
      startup = nil
    }
  }

  func exited(_ result: Result<ExecutionExit, Error>) {
    lock.withLock {
      rootExit = result
      if case .success = result, let root { state.exitedMembers.insert(root) }
      if let startup {
        if case .failure(let error) = result {
          startup.resume(throwing: error)
        } else {
          startup.resume(
            throwing: ExecutionEnvironmentError.launchFailed("Launch handshake failed"))
        }
        self.startup = nil
      }
      if root == nil { finish(result) } else { requestInspection() }
    }
  }

  package func onCancellation(_ handler: @escaping @Sendable () -> Void) {
    let invoke = lock.withLock {
      guard completion == nil else { return false }
      cancellationHandlers.append(handler)
      guard cancellationStarted != nil else { return false }
      pendingRevocations += 1
      return true
    }
    if invoke {
      handler()
      revocationDispatched()
    }
  }

  func requestCancellation(until deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5)))
  {
    let handlers: [@Sendable () -> Void]? = lock.withLock {
      guard completion == nil else { return nil }
      cancellationDeadline = min(cancellationDeadline ?? deadline, deadline)
      guard cancellationStarted == nil else { return nil }
      cancellationStarted = .now
      pendingRevocations += 1
      generation &+= 1
      state.complete = false
      return cancellationHandlers
    }
    guard let handlers else { return }
    // Completion cannot release authority until every concurrent revocation batch is dispatched.
    for handler in handlers { handler() }
    revocationDispatched()
  }

  private func revocationDispatched() {
    lock.withLock {
      pendingRevocations -= 1
      if root == nil, let rootExit {
        finish(rootExit)
      } else {
        requestInspection()
      }
    }
  }

  package func members() async throws -> [ExecutionMember] {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    let previousScan = lock.withLock {
      // Running sandboxes publish observed identities without starting a classification round.
      if marker != nil, rootExit == nil, cancellationStarted == nil { return nil as UInt64? }
      let previous = completedScans
      requestInspection()
      return previous
    }
    guard let previousScan else {
      return lock.withLock { state.known.subtracting(state.exitedMembers).map(\.member) }
    }
    while true {
      let result: [ExecutionMember]? = lock.withLock {
        if completion != nil { return [] }
        guard completedScans > previousScan, state.scanReasons.isEmpty else { return nil }
        let members = state.known.subtracting(state.exitedMembers)
        // A member can fork after enumeration and exit before confirmation. An empty known
        // set is not an empty execution until a fully classified snapshot proves it.
        guard !members.isEmpty || state.complete else { return nil }
        return members.map(\.member).sorted { $0.processID < $1.processID }
      }
      if let result { return result }
      guard ContinuousClock.now < deadline else {
        throw lock.withLock { failure() }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  package func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    requestCancellation()
    return try await wait(until: deadline)
  }

  package func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    try await waitForCompletion(until: deadline)
  }

  package func wait() async throws -> ExecutionExit {
    try await waitForCompletion(until: nil)
  }

  private func waitForCompletion(until deadline: ContinuousClock.Instant?) async throws
    -> ExecutionExit
  {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          if let completion {
            continuation.resume(with: completion)
          } else if let deadline, ContinuousClock.now >= deadline {
            continuation.resume(throwing: ExecutionWaitExpired(ownership: self))
          } else {
            waiters.append((deadline, continuation))
            startMonitor()
          }
        }
      }
    } onCancel: {
      requestCancellation()
    }
  }

  private func poll() {
    guard completion == nil else { return }
    expire()
    guard root != nil, !inspecting, pendingRevocations == 0 else { return }
    guard bestEffort || rootExit != nil || cancellationStarted != nil else { return }
    if state.complete, let rootExit {
      finish(rootExit)
      return
    }
    let deadline = min(
      ContinuousClock.now.advanced(by: .seconds(1)),
      cancellationDeadline ?? .now.advanced(by: .seconds(1)))
    let generation = self.generation
    let initial = state
    let started = cancellationStarted
    inspectionRequested = false
    inspecting = true
    worker.async { [self] in
      var scan = inspect(initial, started: started, deadline: deadline, generation: generation)
      let handlers: [@Sendable () -> Void]? = lock.withLock {
        inspecting = false
        // Exit, cancellation and membership requests that arrived during this round need
        // a fresh observation immediately. Timer ticks alone must not create a busy loop.
        defer {
          if inspectionRequested { poll() }
        }
        var handlers: [@Sendable () -> Void]?
        if let reason = scan.sentinelFailure, completion == nil {
          // Sentinel uncertainty can only revoke authority. Preserve this conservative failure
          // even if the query outlived its deadline; late exit/completeness observations cannot
          // publish, but losing the boundary must still trigger egress revocation and KILL.
          state.complete = false
          state.scanReasons = [reason]
          if cancellationStarted == nil {
            handlers = cancellationHandlers
            pendingRevocations += 1
          }
          cancellationStarted = cancellationStarted ?? .now.advanced(by: .seconds(-1))
          let failure = failure()
          let pending = waiters
          waiters.removeAll()
          for waiter in pending { waiter.continuation.resume(throwing: failure) }
          startup?.resume(throwing: failure)
          startup = nil
        }
        expire()
        // A timed-out query cannot publish observations, retire markers or release resources.
        guard self.generation == generation, ContinuousClock.now < deadline,
          completion == nil
        else {
          state.complete = false
          return handlers
        }
        scan.exitedMembers.formUnion(state.exitedMembers)
        state = scan
        completedScans &+= 1
        if bestEffort, state.complete, let rootExit { finish(rootExit) }
        return handlers
      }
      if let handlers {
        for handler in handlers { handler() }
        revocationDispatched()
      }
    }
  }

  private func requestInspection() {
    inspectionRequested = true
    poll()
  }

  /// Release the worker's marker reference before completion can retire it and resume waiters.
  private func inspect(
    _ initial: DarwinExecutionScan, started: ContinuousClock.Instant?,
    deadline: ContinuousClock.Instant, generation: UInt64
  ) -> DarwinExecutionScan {
    let marker = lock.withLock { self.marker }
    var scan = initial
    scan.poll(
      table: table, marker: marker, sentinel: sentinel?.identity, started: started,
      recoveryRoot: recoveryRoot,
      deadline: deadline,
      check: {
        try DarwinExecutionProcessTable.check(deadline)
        guard self.lock.withLock({ self.generation == generation }) else {
          throw CancellationError()
        }
      })
    return scan
  }

  private func failure() -> ExecutionCompletionFailure {
    ExecutionCompletionFailure(
      ownership: self,
      members: state.known.subtracting(state.exitedMembers).map {
        .init(process: $0.member, reason: state.memberReasons[$0] ?? "Exit has not been confirmed")
      }.sorted { $0.process.processID < $1.process.processID },
      reasons: state.scanReasons + (inspecting ? ["Process inspection is pending"] : [])
        + (rootExit == nil ? ["Root exit has not been collected"] : []),
      bestEffort: bestEffort)
  }

  /// Failure retains ownership. Cleanup keeps observing and, after cancellation, killing members;
  /// sandbox resources require a fresh, fully classified snapshot before retirement.
  private func expire() {
    let now = ContinuousClock.now
    if let deadline = cancellationDeadline, now >= deadline {
      let failure = failure()
      generation &+= 1
      state.complete = false
      cancellationDeadline = nil
      let pending = waiters
      waiters.removeAll()
      for waiter in pending { waiter.continuation.resume(throwing: failure) }
      startup?.resume(throwing: failure)
      startup = nil
    }
    let expired = waiters.filter { $0.deadline.map { now >= $0 } == true }
    waiters.removeAll { $0.deadline.map { now >= $0 } == true }
    for waiter in expired {
      waiter.continuation.resume(throwing: ExecutionWaitExpired(ownership: self))
    }
  }

  private func finish(_ result: Result<ExecutionExit, Error>) {
    guard pendingRevocations == 0 else { return }
    sandboxViolations?.finish()
    marker = nil
    completion = result
    cancellationHandlers.removeAll()
    launchHandlers.removeAll()
    timer?.cancel()
    timer?.setEventHandler {}
    timer = nil
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.continuation.resume(with: result) }
  }
}

/// A scan is a worker-local value. Only a result from the current deadline generation is published.
private struct DarwinExecutionScan: Sendable {
  var known: Set<DarwinProcessIdentity> = []
  var exitedMembers: Set<DarwinProcessIdentity> = []
  var memberReasons: [DarwinProcessIdentity: String] = [:]
  var scanReasons: [String] = []
  var group: pid_t?
  var terminated: Set<DarwinProcessIdentity> = []
  var complete = false
  var sentinelFailure: String?

  mutating func poll(
    table: DarwinExecutionProcessTable, marker: ExecutionSandboxMarker?,
    sentinel: DarwinProcessIdentity?, started: ContinuousClock.Instant?,
    recoveryRoot: DarwinProcessIdentity? = nil,
    deadline: ContinuousClock.Instant,
    check: () throws -> Void
  ) {
    complete = false
    let force = started.map { $0.duration(to: .now) >= .milliseconds(500) } ?? false
    // Identity-checked TERM reaches known members before enumeration can block.
    if started != nil && !force {
      for identity in known.subtracting(exitedMembers).subtracting(terminated)
        .sorted(by: { $0.pid < $1.pid })
      {
        do { try check() } catch { break }
        do {
          if let process = try table.read(identity.pid), process.identity == identity {
            if signal(process, SIGTERM, table: table) { terminated.insert(identity) }
          }
        } catch { memberReasons[identity] = "Cannot read signal identity: \(error)" }
      }
    }
    guard let marker, sentinel != nil || recoveryRoot != nil else {
      pollFullAccess(table: table, started: started, force: force, check: check)
      return
    }
    let scan = snapshot(
      until: deadline, table: table, marker: marker, sentinel: sentinel,
      recoveryRoot: recoveryRoot, started: started != nil, force: force, check: check)
    scanReasons = scan.reasons
    // Include members discovered by this round. Only reaping or replacement confirms exit;
    // kern_exit.c moves processes to zombproc before all their threads have terminated.
    for identity in known.subtracting(exitedMembers).sorted(by: { $0.pid < $1.pid }) {
      do {
        try check()
        let process = try table.read(identity.pid)
        try check()
        guard let process, process.identity == identity else {
          exitedMembers.insert(identity)
          memberReasons[identity] = nil
          continue
        }
        if memberReasons[identity] == nil {
          memberReasons[identity] = "Exit has not been confirmed"
        }
      } catch {
        memberReasons[identity] = "Cannot confirm identity or exit: \(error)"
      }
    }
    // Every PID in this snapshot has the same (pid, uniqueid) before and after classification,
    // below the pre-enumeration watermark, and none is a member, including zombproc. Thus no member
    // existed at the list-lock instant t. Membership is inherited through fork, only members
    // can create members, and the launcher has stopped creating
    // processes for this execution. No member can therefore appear after t.
    complete =
      scan.reasons.isEmpty && scan.members.isEmpty && known.isSubset(of: exitedMembers)
      && (started == nil || force)
  }

  @discardableResult
  private mutating func signal(
    _ process: DarwinProcessSnapshot, _ signal: Int32, table: DarwinExecutionProcessTable
  ) -> Bool {
    let identity = process.identity
    let result = table.signal(process, signal)
    memberReasons[identity] =
      result == 0
      ? "Exit has not been confirmed"
      : result == ESRCH
        ? "Signal identity no longer exists; reaping or exec remains to be classified"
        : "Signal \(signal) failed: errno \(result); exit unconfirmed"
    return result == 0
  }

  /// Full access is best effort: observe the execution's group and retain exact identities
  /// even after members leave it. Escaped descendants never observed in that group, or work
  /// delegated to another service, may outlive the execution. Only sandboxes need global proof.
  private mutating func pollFullAccess(
    table: DarwinExecutionProcessTable, started: ContinuousClock.Instant?, force: Bool,
    check: () throws -> Void
  ) {
    scanReasons = []
    var processes: [DarwinProcessIdentity: DarwinProcessSnapshot] = [:]
    for identity in known.subtracting(exitedMembers) {
      do {
        try check()
        if let process = try table.read(identity.pid), process.identity == identity {
          processes[identity] = process
        } else {
          exitedMembers.insert(identity)
          memberReasons[identity] = nil
        }
      } catch { scanReasons.append("Cannot inspect PID \(identity.pid): \(error)") }
    }
    if let group {
      do {
        try check()
        let pids = try table.group(group)
        var candidates: [DarwinProcessSnapshot] = []
        for pid in pids {
          try check()
          if let process = try table.read(pid), process.group == group {
            candidates.append(process)
          }
        }
        // Numeric groups confer ownership only while an exact known identity anchors them.
        // A child whose parent unique ID is known can supply that anchor after root reaping.
        let parents = Set(known.map(\.uniqueID))
        let anchors = candidates.filter {
          known.contains($0.identity) || parents.contains($0.parentUniqueID)
        }
        var anchored = false
        for anchor in anchors {
          try check()
          if let confirmed = try table.read(anchor.identity.pid),
            confirmed.identity == anchor.identity, confirmed.group == group,
            confirmed.session == anchor.session
          {
            anchored = true
            break
          }
        }
        if anchored {
          for process in candidates {
            known.insert(process.identity)
            processes[process.identity] = process
          }
        } else if pids.isEmpty {
          self.group = nil
        } else {
          scanReasons.append("Process group is nonempty without a validated ownership anchor")
        }
      } catch { scanReasons.append("Cannot inspect process group \(group): \(error)") }
    }
    for process in processes.values {
      let identity = process.identity
      if started != nil {
        do { try check() } catch {
          scanReasons.append(String(describing: error))
          break
        }
        if force {
          signal(process, SIGKILL, table: table)
        } else if !terminated.contains(identity) {
          if signal(process, SIGTERM, table: table) { terminated.insert(identity) }
        }
      }
    }
    complete = scanReasons.isEmpty && known.isSubset(of: exitedMembers) && group == nil
  }

  private mutating func snapshot(
    until deadline: ContinuousClock.Instant, table: DarwinExecutionProcessTable,
    marker: ExecutionSandboxMarker, sentinel: DarwinProcessIdentity?,
    recoveryRoot: DarwinProcessIdentity?, started: Bool, force: Bool, check: () throws -> Void
  ) -> (members: Set<DarwinProcessIdentity>, reasons: [String]) {
    var processes: [DarwinProcessSnapshot] = []
    var reasons: [String] = []
    let hostSentinels = DarwinExecutionSentinel.identities()
    sentinelFailure = nil
    if let sentinel {
      do {
        guard let boundary = try table.read(sentinel.pid), boundary.identity == sentinel,
          boundary.state == .zombie
        else {
          throw ExecutionEnvironmentError.launchFailed("Execution sentinel is missing or replaced")
        }
      } catch { sentinelFailure = "Cannot confirm execution sentinel: \(error)" }
    }
    if let sentinelFailure { reasons.append(sentinelFailure) }
    do {
      try check()
      let snapshot: DarwinExecutionProcessTable.Snapshot
      if let sentinel {
        snapshot = try table.list(deadline, sentinel)
      } else if let wholeList = table.wholeList {
        snapshot = try wholeList(deadline)
      } else {
        throw ExecutionEnvironmentError.unavailable("Complete recovery snapshots are unavailable")
      }
      if sentinel == nil, !snapshot.complete { reasons.append("Recovery snapshot is incomplete") }
      if !snapshot.pids.contains(0) {
        reasons.append("Process snapshot did not reach kernproc")
      }
      let boundary =
        sentinelFailure == nil ? sentinel.flatMap { snapshot.pids.firstIndex(of: $0.pid) } : nil
      if sentinel != nil, boundary == nil {
        reasons.append("Process snapshot did not reach execution sentinel")
      }
      if let boundary, let kernel = snapshot.pids.firstIndex(of: 0), boundary <= kernel {
        reasons.append("Execution sentinel is not in zombproc")
      }
      // proc_info.c enumerates allproc then zombproc. kern_exit.c inserts exiting processes
      // before terminating their threads and setting SZOMB. Every entry before the unreaped
      // sentinel needs classification; older zombies cannot belong to this execution.
      let pids = boundary.map { Array(snapshot.pids[..<$0]) } ?? snapshot.pids
      let kernel = snapshot.pids.firstIndex(of: 0)
      for (index, pid) in pids.enumerated() where pid > 0 {
        do {
          try check()
          guard let before = try table.read(pid) else {
            reasons.append("PID \(pid) disappeared during classification")
            continue
          }
          try check()
          let knownMember = known.contains(before.identity)
          let hostSentinel = hostSentinels.contains(before.identity)
          let preexisting = recoveryRoot.map { before.identity.uniqueID < $0.uniqueID } ?? false
          let zombie = (kernel.map { index > $0 } ?? false) || before.state == .zombie
          let nonmemberParent =
            try !knownMember && !hostSentinel && !preexisting && zombie
            && hasNonmemberParent(before, table: table, marker: marker, check: check)
          let marked =
            try !knownMember && !hostSentinel && !preexisting && !nonmemberParent
            ? table.contains(pid, marker) : false
          // Use the version read before classification. proc_find_audit_token (kern_proc.c)
          // pins that identity for psignal_by_audit_token (proc_info.c); PID reuse returns ESRCH.
          // A failed later read cannot prevent this identity-bound KILL from making progress.
          if (marked || knownMember) && force { signal(before, SIGKILL, table: table) }
          try check()
          // The launcher-owned bootstrap is a member before it installs the sandbox.
          let belongs = marked || knownMember
          guard let after = try table.read(pid),
            before.identity == after.identity
          else {
            reasons.append("PID \(pid) changed during membership inspection")
            continue
          }
          try check()
          guard before.identity.uniqueID < snapshot.watermark else {
            reasons.append("PID \(pid) is at or above the snapshot watermark")
            continue
          }
          if !belongs,
            (kernel.map { index > $0 } ?? false) || before.state == .zombie
              || after.state == .zombie,
            !hostSentinel, !preexisting, !nonmemberParent
          {
            // sandbox_check may report denial for every path once a proc enters zombproc.
            // Only independent provenance or an untraced zombie's live, identity-checked
            // nonmember parent can establish nonmembership when its sandbox is unreadable.
            reasons.append("PID \(pid) zombie membership cannot be classified")
          }
          if belongs { processes.append(after) }
          if belongs {
            known.insert(after.identity)
            if !force && started && !terminated.contains(after.identity) {
              if signal(before, SIGTERM, table: table) { terminated.insert(after.identity) }
            }
          }
        } catch {
          reasons.append("PID \(pid): \(error)")
        }
      }
    } catch { reasons.append(String(describing: error)) }

    let members = Set(processes.map(\.identity))
    known.formUnion(members)
    if let sentinel {
      do {
        guard let boundary = try table.read(sentinel.pid), boundary.identity == sentinel,
          boundary.state == .zombie
        else {
          throw ExecutionEnvironmentError.launchFailed("Execution sentinel is missing or replaced")
        }
      } catch {
        sentinelFailure = "Cannot confirm execution sentinel: \(error)"
        reasons.append(sentinelFailure!)
      }
    }
    return (members, reasons)
  }

  private func hasNonmemberParent(
    _ zombie: DarwinProcessSnapshot, table: DarwinExecutionProcessTable,
    marker: ExecutionSandboxMarker, check: () throws -> Void
  ) throws -> Bool {
    // Members can also be parented by launchd after adoption or this host's launcher;
    // other live parents prove nonmembership only while p_puniqueid names that exact parent.
    // Parent provenance requires readable BSD flags proving the zombie is untraced; traced or
    // unreadable zombies remain members or unclassifiable until reaped. This trusts processes
    // with debugging rights over members: one can reparent a member to itself, and exec then
    // rewrites p_puniqueid (the traced flag clears on detach). Only the owner's tools hold
    // task rights over a sandboxed member, and they already control it.
    guard zombie.isTraced == false, zombie.parentID > 1, zombie.parentID != getpid() else {
      return false
    }
    try check()
    guard let parent = try table.read(zombie.parentID), parent.state != .zombie,
      parent.identity.uniqueID == zombie.parentUniqueID, !known.contains(parent.identity)
    else { return false }
    try check()
    guard try !table.contains(parent.identity.pid, marker) else { return false }
    try check()
    guard let confirmed = try table.read(parent.identity.pid), confirmed.state != .zombie,
      confirmed.identity == parent.identity
    else { return false }
    return true
  }
}

struct DarwinProcessSnapshot: Sendable {
  enum State: Sendable { case running, stopped, zombie }
  let identity: DarwinProcessIdentity
  let parentUniqueID: UInt64
  let group: pid_t
  let session: pid_t
  let state: State
  var version: UInt32 = 0
  var parentID: pid_t = 0
  /// Nil means BSD tracing state is unavailable and cannot establish parent provenance.
  var isTraced: Bool? = nil

  func signal(_ signal: Int32) -> Int32 {
    var token = audit_token_t(val: (0, 0, 0, 0, 0, UInt32(bitPattern: identity.pid), 0, version))
    return proc_signal_with_audittoken(&token, signal)
  }
}

/// Injectable kernel boundary: nil means ESRCH, never an unreadable process record.
struct DarwinExecutionProcessTable: Sendable {
  struct Snapshot: Sendable {
    let pids: [pid_t]
    /// Unique ID read from an unreaped probe before enumeration.
    let watermark: UInt64
    var complete = false
  }
  let list: @Sendable (ContinuousClock.Instant, DarwinProcessIdentity) throws -> Snapshot
  let read: @Sendable (pid_t) throws -> DarwinProcessSnapshot?
  let signal: @Sendable (DarwinProcessSnapshot, Int32) -> Int32
  let contains: @Sendable (pid_t, ExecutionSandboxMarker) throws -> Bool
  var wholeList: (@Sendable (ContinuousClock.Instant) throws -> Snapshot)? = nil
  var group: @Sendable (pid_t) throws -> [pid_t] = { group in
    var capacity = 32
    while true {
      var pids = [pid_t](repeating: 0, count: capacity)
      let bytes = proc_listpids(
        UInt32(PROC_PGRP_ONLY), UInt32(bitPattern: group), &pids,
        Int32(pids.count * MemoryLayout<pid_t>.size))
      guard bytes >= 0 else {
        throw ExecutionEnvironmentError.launchFailed("Cannot enumerate process group: \(errno)")
      }
      let count = Int(bytes) / MemoryLayout<pid_t>.size
      if count < capacity { return Array(pids.prefix(count)) }
      guard capacity < Int(Int32.max) / MemoryLayout<pid_t>.size / 2 else {
        throw ExecutionEnvironmentError.launchFailed("Process group exceeds inspection capacity")
      }
      capacity *= 2
    }
  }

  static func check(_ deadline: ContinuousClock.Instant) throws {
    guard ContinuousClock.now < deadline else {
      throw ExecutionEnvironmentError.launchFailed("Process inspection deadline reached")
    }
  }

  /// XNU kern_fork.c assigns pid and monotonically increasing p_uniqueid inside the same
  /// proc_list_lock section; exec preserves p_uniqueid. A replacement allocated after the
  /// list lock must exceed this pre-list watermark. Births between probe and list only retry.
  static func identityWatermark(
    read: (pid_t) throws -> DarwinProcessIdentity? = {
      DarwinProcessIdentity.current(pid: $0, includingZombies: true)?.identity
    }
  ) throws -> UInt64 {
    var attributes: posix_spawnattr_t?
    var result = posix_spawnattr_init(&attributes)
    guard result == 0 else {
      throw ExecutionEnvironmentError.launchFailed("Cannot initialize identity probe: \(result)")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    result = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    guard result == 0 else {
      throw ExecutionEnvironmentError.launchFailed("Cannot configure identity probe: \(result)")
    }
    let executable = strdup("/usr/bin/true")!
    defer { free(executable) }
    var arguments: [UnsafeMutablePointer<CChar>?] = [executable, nil]
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    result = posix_spawn(&pid, executable, nil, &attributes, &arguments, &environment)
    guard result == 0 else {
      throw ExecutionEnvironmentError.launchFailed("Cannot spawn identity probe: \(result)")
    }
    // The child retains its identity until reaping; arg 1 also finds its zombie record.
    // Capture read errors so failed or cancelled rounds still reap this exact child.
    let identity = Result { try read(pid) }
    var status: Int32 = 0
    var reaped: pid_t
    repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR
    guard reaped == pid, status == 0 else {
      throw ExecutionEnvironmentError.launchFailed(
        "Identity probe failed: reap result \(reaped), errno \(errno), status \(status)")
    }
    guard let identity = try identity.get(), identity.pid == pid, identity.uniqueID > 0 else {
      throw ExecutionEnvironmentError.launchFailed("Identity probe failed: identity unavailable")
    }
    return identity.uniqueID
  }

  static let system = system(watermark: { try identityWatermark() })

  static func system(watermark: @escaping @Sendable () throws -> UInt64) -> Self {
    var table = Self(
      list: { deadline, sentinel in
        try check(deadline)
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else {
          throw ExecutionEnvironmentError.launchFailed("Cannot size process snapshot: \(errno)")
        }
        var capacity = max(1024, Int(estimate) * 4)
        while true {
          try check(deadline)
          var pids = [pid_t](repeating: -1, count: capacity)
          let watermark = try watermark()
          try check(deadline)
          let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
          guard count > 0, count <= pids.count else {
            throw ExecutionEnvironmentError.launchFailed("Cannot enumerate processes: \(errno)")
          }
          pids = Array(pids.prefix(Int(count)))
          // PID 0 bounds allproc; the retained sentinel bounds this execution's zombproc.
          // A short result alone proves nothing: proc_info.c sizes its buffer before locking.
          if pids.contains(0), pids.contains(sentinel.pid) {
            return Snapshot(pids: pids, watermark: watermark)
          }
          guard
            DarwinProcessIdentity.current(pid: sentinel.pid, includingZombies: true)?.identity
              == sentinel
          else {
            // Return the incomplete list so cleanup can still signal identifiable members.
            return Snapshot(pids: pids, watermark: watermark)
          }
          guard capacity <= Int(Int32.max) / MemoryLayout<pid_t>.size / 2 else {
            throw ExecutionEnvironmentError.launchFailed(
              "Process snapshot did not reach kernproc and execution sentinel")
          }
          capacity *= 2
        }
      },
      read: { pid in
        let before = DarwinProcessIdentity.current(pid: pid, includingZombies: true)
        // SHORTBSDINFO permits cross-user state reads (XNU proc_info.c).
        var info = proc_bsdshortinfo()
        guard
          proc_pidinfo(
            pid, PROC_PIDT_SHORTBSDINFO, 1, &info, Int32(MemoryLayout.size(ofValue: info)))
            == MemoryLayout.size(ofValue: info)
        else {
          if errno == ESRCH { return nil }
          throw ExecutionEnvironmentError.launchFailed("Cannot read process state: errno \(errno)")
        }
        var isTraced: Bool?
        if info.pbsi_status == 5 {
          var bsd = proc_bsdinfo()
          if proc_pidinfo(pid, PROC_PIDTBSDINFO, 1, &bsd, Int32(MemoryLayout.size(ofValue: bsd)))
            == MemoryLayout.size(ofValue: bsd)
          {
            isTraced = bsd.pbi_flags & UInt32(PROC_FLAG_TRACED) != 0
          }
        }
        guard let before,
          let after = DarwinProcessIdentity.current(pid: pid, includingZombies: true),
          before.identity == after.identity
        else {
          throw ExecutionEnvironmentError.launchFailed(
            "Identity unavailable or changed during process inspection")
        }
        return DarwinProcessSnapshot(
          identity: after.identity, parentUniqueID: after.parentUniqueID,
          group: pid_t(info.pbsi_pgid), session: getsid(pid),
          state: info.pbsi_status == 5 ? .zombie : info.pbsi_status == 4 ? .stopped : .running,
          version: before.version, parentID: pid_t(info.pbsi_ppid), isTraced: isTraced)
      },
      signal: { $0.signal($1) },
      contains: { pid, marker in
        let marked = try marker.contains(pid)
        // A proc can move from allproc to zombproc after enumeration but before SZOMB. Negative
        // sandbox_check results are authoritative only while proc_find still finds a live proc.
        // proc_info.c arg 0 excludes zombproc; the caller also checks identity across this query.
        guard marked || DarwinProcessIdentity.current(pid: pid) != nil else {
          throw ExecutionEnvironmentError.launchFailed(
            "PID \(pid) zombie membership cannot be classified")
        }
        return marked
      })
    table.wholeList = { deadline in
      try check(deadline)
      let estimate = proc_listallpids(nil, 0)
      guard estimate > 0 else {
        throw ExecutionEnvironmentError.unavailable("Cannot size recovery snapshot")
      }
      let capacity = max(1024, Int(estimate) * 4)
      guard capacity <= Int(Int32.max) / MemoryLayout<pid_t>.size else {
        throw ExecutionEnvironmentError.unavailable("Recovery snapshot exceeds capacity")
      }
      var pids = [pid_t](repeating: -1, count: capacity)
      let before = try watermark()
      try check(deadline)
      let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
      let after = try watermark()
      try check(deadline)
      guard count > 0, count <= capacity else {
        throw ExecutionEnvironmentError.unavailable("Cannot enumerate recovery snapshot")
      }
      let (next, overflow) = before.addingReportingOverflow(1)
      // Only the post-list probe may be born between probes. Delayed fork
      // publication is already counted; exec preserves identity and does not add
      // a visible row. A quiet, non-full list does not depend on sizing slack.
      return Snapshot(
        pids: Array(pids.prefix(Int(count))), watermark: before,
        complete: !overflow && after == next && count < capacity && pids.contains(0))
    }
    return table

  }
}

extension DarwinProcessIdentity {
  fileprivate var member: ExecutionMember { .init(processID: pid, identity: uniqueID) }
}
