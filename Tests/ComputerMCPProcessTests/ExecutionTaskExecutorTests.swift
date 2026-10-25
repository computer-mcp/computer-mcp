import Dispatch
import Testing

@testable import ComputerMCPProcess

@Suite struct ExecutionTaskExecutorTests {
  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func shortLivedExecutorsCompleteSharedActorWork(throwing: Bool) async throws {
    guard #available(macOS 15, *) else { return }
    let counter = ExecutionCounter()
    let values = try await withThrowingTaskGroup(of: Int.self, returning: Set<Int>.self) { group in
      for _ in 0..<2000 {
        group.addTask {
          if throwing {
            return try await ExecutionTasks.startThrowing { await counter.increment() }.value
          }
          return await ExecutionTasks.start { await counter.increment() }.value
        }
      }
      var values: Set<Int> = []
      for try await value in group { values.insert(value) }
      return values
    }
    #expect(values == Set(1...2000))
  }

  @Test func blockingOneExecutionDoesNotStallAnother() async {
    guard #available(macOS 15, *) else { return }
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let blocked = ExecutionTasks.start {
      entered.continuation.finish()
      // Bound failure if the second task queues behind this synchronous operation.
      return waitForRelease(release)
    }
    for await _ in entered.stream {}
    let other = ExecutionTasks.start { _ = release.signal() }
    await other.value
    #expect(await blocked.value)
  }
}

private func waitForRelease(_ semaphore: DispatchSemaphore) -> Bool {
  semaphore.wait(timeout: .now() + .seconds(5)) == .success
}

private actor ExecutionCounter {
  private var value = 0

  func increment() async -> Int {
    value += 1
    let result = value
    await Task.yield()
    return result
  }
}
