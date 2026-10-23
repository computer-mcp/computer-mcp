import Dispatch

/// Each task has its own executor so synchronous lifecycle I/O does not monopolize
/// a shared execution queue.
/// On macOS 14 callers must use a blocking executor, as required by the synchronous API.
internal enum ExecutionTasks {
  @discardableResult
  static func start<Value: Sendable>(
    priority: TaskPriority? = nil, _ operation: @escaping @Sendable () async -> Value
  ) -> Task<Value, Never> {
    if #available(macOS 15, *) {
      return Task.detached(
        executorPreference: ExecutionTaskExecutor(), priority: priority, operation: operation)
    }
    return Task.detached(priority: priority, operation: operation)
  }

  @discardableResult
  static func startThrowing<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) -> Task<Value, any Error> {
    if #available(macOS 15, *) {
      return Task.detached(executorPreference: ExecutionTaskExecutor(), operation: operation)
    }
    return Task.detached(operation: operation)
  }
}

@available(macOS 15, *)
private final class ExecutionTaskExecutor: TaskExecutor {
  private let queue = DispatchQueue(label: "computer-mcp.execution-tasks", qos: .userInitiated)

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let executor = asUnownedTaskExecutor()
    queue.async { job.runSynchronously(on: executor) }
  }
}
