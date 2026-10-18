#if os(Windows)
  import Foundation
  import Synchronization
  import WinSDK

  /// Owns only this invocation's descendants. The handle is never inherited or exposed.
  final class WindowsProcessJob: Sendable {
    enum StopReason { case exited, timedOut, cancelled, failed }

    // Native handles identify kernel objects, not Swift memory. The enclosing
    // mutex serializes every state mutation, borrowed admission and handle close.
    private struct State: @unchecked Sendable {
      let handle: HANDLE
      var assigned = false
      var reason: StopReason?
      var failure: CommandRunnerError?
      var members: [HANDLE] = []
    }

    private let state: Mutex<State>

    init() throws {
      guard let handle = CreateJobObjectW(nil, nil) else {
        throw Self.error("CreateJobObjectW")
      }
      var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
      limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
      guard
        SetInformationJobObject(
          handle, JobObjectExtendedLimitInformation, &limits,
          DWORD(MemoryLayout.size(ofValue: limits)))
      else {
        let error = Self.error("SetInformationJobObject")
        CloseHandle(handle)
        throw error
      }
      state = Mutex(State(handle: handle))
    }

    deinit {
      state.withLock {
        for member in $0.members { CloseHandle(member) }
        CloseHandle($0.handle)
      }
    }

    var timedOut: Bool { state.withLock { $0.reason == .timedOut } }

    /// Called while the initial thread is suspended. The command owns the borrowed handles.
    func start(process: HANDLE, thread: HANDLE) {
      state.withLock { state in
        if state.reason != nil {
          Self.terminateSuspended(process, state: &state)
          return
        }
        guard AssignProcessToJobObject(state.handle, process) else {
          state.failure = Self.error("AssignProcessToJobObject")
          state.reason = .failed
          Self.terminateSuspended(process, state: &state)
          return
        }
        state.assigned = true
        guard ResumeThread(thread) != DWORD.max else {
          state.failure = Self.error("ResumeThread")
          Self.stop(.failed, state: &state)
          return
        }
      }
    }

    func stop(_ reason: StopReason) {
      state.withLock { Self.stop(reason, state: &$0) }
    }

    /// A successful termination request alone does not prove that descendants have exited.
    func confirmCleanup() async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while true {
        let complete = try state.withLock { state in
          if let failure = state.failure { throw failure }
          var accounting = JOBOBJECT_BASIC_ACCOUNTING_INFORMATION()
          guard
            QueryInformationJobObject(
              state.handle, JobObjectBasicAccountingInformation, &accounting,
              DWORD(MemoryLayout.size(ofValue: accounting)), nil)
          else { throw Self.error("QueryInformationJobObject") }
          var membersExited = true
          for member in state.members {
            switch WaitForSingleObject(member, 0) {
            case DWORD(WAIT_OBJECT_0): break
            case DWORD(WAIT_TIMEOUT): membersExited = false
            default: throw Self.error("WaitForSingleObject")
            }
          }
          return accounting.ActiveProcesses == 0 && membersExited
        }
        if complete { return }
        guard ContinuousClock.now < deadline else {
          throw CommandRunnerError.launchFailed(
            "Command descendant cleanup could not be confirmed.")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    private static func stop(_ reason: StopReason, state: inout State) {
      guard state.reason == nil else { return }
      state.reason = reason
      guard state.assigned else { return }
      do { try retainMembers(state: &state) } catch {
        state.failure =
          (error as? CommandRunnerError) ?? .launchFailed("Cannot observe command descendants.")
      }
      if !TerminateJobObject(state.handle, 1) {
        state.failure = state.failure ?? error("TerminateJobObject")
      }
    }

    /// Stop admission before enumerating, so a live member cannot create an unobserved child.
    private static func retainMembers(state: inout State) throws {
      var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
      limits.BasicLimitInformation.LimitFlags = DWORD(
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS)
      limits.BasicLimitInformation.ActiveProcessLimit = 1
      guard
        SetInformationJobObject(
          state.handle, JobObjectExtendedLimitInformation, &limits,
          DWORD(MemoryLayout.size(ofValue: limits)))
      else { throw error("SetInformationJobObject") }

      var capacity = 16
      for _ in 0..<4 {
        // The native structure ends in a variable-length ULONG_PTR process-id array.
        let bytes = 2 * MemoryLayout<DWORD>.size + capacity * MemoryLayout<ULONG_PTR>.stride
        let storage = UnsafeMutableRawPointer.allocate(
          byteCount: bytes, alignment: MemoryLayout<ULONG_PTR>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        let queried = QueryInformationJobObject(
          state.handle, JobObjectBasicProcessIdList, storage, DWORD(bytes), nil)
        let code = GetLastError()
        let assigned = Int(storage.load(as: DWORD.self))
        let count = Int(storage.load(fromByteOffset: MemoryLayout<DWORD>.size, as: DWORD.self))
        if !queried {
          guard code == DWORD(ERROR_MORE_DATA), assigned > capacity, assigned <= 131_072 else {
            throw WindowsCommandProcess.error("QueryInformationJobObject", code: code)
          }
          capacity = assigned
          continue
        }
        guard count <= capacity, count == assigned else {
          throw CommandRunnerError.launchFailed(
            "Command descendant inventory changed during cleanup.")
        }
        for index in 0..<count {
          let id = storage.load(
            fromByteOffset: 2 * MemoryLayout<DWORD>.size + index * MemoryLayout<ULONG_PTR>.stride,
            as: ULONG_PTR.self)
          guard let pid = DWORD(exactly: id) else {
            throw CommandRunnerError.launchFailed("Invalid native command process identifier.")
          }
          guard
            let member = OpenProcess(
              DWORD(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION), false, pid)
          else {
            let code = GetLastError()
            // A process whose object has already disappeared has completed termination.
            if code == DWORD(ERROR_INVALID_PARAMETER) { continue }
            throw WindowsCommandProcess.error("OpenProcess", code: code)
          }
          var belongs: WindowsBool = false
          guard IsProcessInJob(member, state.handle, &belongs) else {
            let failure = error("IsProcessInJob")
            CloseHandle(member)
            throw failure
          }
          if !belongs.boolValue {
            let exited = WaitForSingleObject(member, 0) == DWORD(WAIT_OBJECT_0)
            CloseHandle(member)
            if exited { continue }
            throw CommandRunnerError.launchFailed(
              "Command process ownership changed during cleanup.")
          }
          state.members.append(member)
        }
        return
      }
      throw CommandRunnerError.launchFailed("Command descendant inventory could not be confirmed.")
    }

    private static func terminateSuspended(_ process: HANDLE, state: inout State) {
      if !TerminateProcess(process, 1),
        WaitForSingleObject(process, 0) != DWORD(WAIT_OBJECT_0)
      {
        state.failure = error("TerminateProcess")
      }
    }

    private static func error(_ operation: String) -> CommandRunnerError {
      .launchFailed("\(operation) failed (Windows error \(GetLastError())).")
    }
  }
#endif
