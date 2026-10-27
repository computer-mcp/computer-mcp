import ComputerMCPCore
import Dispatch

/// Each task has its own executor so synchronous lifecycle I/O does not monopolize
/// a shared execution queue.
/// On macOS 14 callers must use a blocking executor, as required by the synchronous API.
internal enum ExecutionTasks {
  @discardableResult
  static func start<Value: Sendable>(
    priority: TaskPriority? = nil, _ operation: @escaping @Sendable () async -> Value
  ) -> Task<Value, Never> {
    let authority = InvocationExecution.current
    let access = HostPathAccess.current ?? authority?.pathAccess
    let recovery = ExecutionRecovery.key
    let administration = ExecutionAdministration.current
    let helperEnvironment = HostCommandEnvironment.current
    let captured: @Sendable () async -> Value = {
      await InvocationExecution.$current.withValue(authority) {
        await HostPathAccess.$current.withValue(access) {
          await ExecutionRecovery.$key.withValue(recovery) {
            await ExecutionAdministration.$current.withValue(administration) {
              await HostCommandEnvironment.$current.withValue(helperEnvironment) {
                await operation()
              }
            }
          }
        }
      }
    }
    if #available(macOS 15, *) {
      return Task.detached(
        executorPreference: ExecutionTaskExecutor(), priority: priority, operation: captured)
    }
    return Task.detached(priority: priority, operation: captured)
  }

  @discardableResult
  static func startThrowing<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) -> Task<Value, any Error> {
    let authority = InvocationExecution.current
    let access = HostPathAccess.current ?? authority?.pathAccess
    let recovery = ExecutionRecovery.key
    let administration = ExecutionAdministration.current
    let helperEnvironment = HostCommandEnvironment.current
    let captured: @Sendable () async throws -> Value = {
      try await InvocationExecution.$current.withValue(authority) {
        try await HostPathAccess.$current.withValue(access) {
          try await ExecutionRecovery.$key.withValue(recovery) {
            try await ExecutionAdministration.$current.withValue(administration) {
              try await HostCommandEnvironment.$current.withValue(helperEnvironment) {
                try await operation()
              }
            }
          }
        }
      }
    }
    if #available(macOS 15, *) {
      return Task.detached(executorPreference: ExecutionTaskExecutor(), operation: captured)
    }
    return Task.detached(operation: captured)
  }
}

@available(macOS 15, *)
private final class ExecutionTaskExecutor: TaskExecutor {
  private let queue = DispatchQueue(label: "computer-mcp.execution-tasks", qos: .userInitiated)

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let executor = asUnownedTaskExecutor()
    // Actor processing can enqueue more work after its last task releases its executor.
    // Keep the executor alive through the runtime's entire job invocation.
    queue.async { [self] in
      withExtendedLifetime(self) { job.runSynchronously(on: executor) }
    }
  }
}
