#if os(Windows)
  import Foundation
  import Subprocess
  import Synchronization
  import WinSDK

  /// Owns only this invocation's descendants. The handle is never inherited or exposed.
  final class WindowsProcessJob: Sendable {
    enum StopReason { case exited, timedOut, cancelled, failed }

    private struct State {
      let handle: HANDLE
      var assigned = false
      var reason: StopReason?
      var failure: CommandRunnerError?
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

    deinit { state.withLock { _ = CloseHandle($0.handle) } }

    var timedOut: Bool { state.withLock { $0.reason == .timedOut } }

    /// Called while the initial thread is suspended. Subprocess owns both process handles.
    func start(_ process: ProcessIdentifier) {
      state.withLock { state in
        if state.reason != nil {
          Self.terminateSuspended(process, state: &state)
          return
        }
        guard AssignProcessToJobObject(state.handle, process.processDescriptor) else {
          state.failure = Self.error("AssignProcessToJobObject")
          state.reason = .failed
          Self.terminateSuspended(process, state: &state)
          return
        }
        state.assigned = true
        guard ResumeThread(process.threadHandle) != DWORD.max else {
          state.failure = Self.error("ResumeThread")
          Self.stop(.failed, state: &state)
          return
        }
      }
    }

    func stop(_ reason: StopReason) {
      state.withLock { Self.stop(reason, state: &$0) }
    }

    /// Runs inside the uncancelled invocation owner, while Subprocess still owns the handle.
    func monitorRoot(_ process: ProcessIdentifier) async {
      while true {
        switch WaitForSingleObject(process.processDescriptor, 0) {
        case DWORD(WAIT_OBJECT_0):
          stop(.exited)
          return
        case DWORD(WAIT_TIMEOUT):
          try? await Task.sleep(for: .milliseconds(10))
        default:
          state.withLock { state in
            state.failure = Self.error("WaitForSingleObject")
            Self.stop(.failed, state: &state)
          }
          return
        }
      }
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
          return accounting.ActiveProcesses == 0
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
      if state.assigned, !TerminateJobObject(state.handle, 1) {
        state.failure = error("TerminateJobObject")
      }
    }

    private static func terminateSuspended(_ process: ProcessIdentifier, state: inout State) {
      if !TerminateProcess(process.processDescriptor, 1),
        WaitForSingleObject(process.processDescriptor, 0) != DWORD(WAIT_OBJECT_0)
      {
        state.failure = error("TerminateProcess")
      }
    }

    private static func error(_ operation: String) -> CommandRunnerError {
      .launchFailed("\(operation) failed (Windows error \(GetLastError())).")
    }
  }
#endif
