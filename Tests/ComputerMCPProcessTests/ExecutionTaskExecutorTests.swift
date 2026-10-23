import Dispatch
import Testing

@testable import ComputerMCPProcess

@Suite struct ExecutionTaskExecutorTests {
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
