import Testing

/// Native integration cases share the machine's process and I/O capacity even
/// when their files and ports are independent. Concurrency inside a case is retained.
struct NativeIntegrationTrait: TestTrait, SuiteTrait, TestScoping {
  var isRecursive: Bool { true }

  func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    testCase == nil ? nil : self
  }

  func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    await NativeIntegrationCapacity.shared.acquire()
    do {
      try Task.checkCancellation()
      try await function()
    } catch {
      await NativeIntegrationCapacity.shared.release()
      throw error
    }
    await NativeIntegrationCapacity.shared.release()
  }
}

extension Trait where Self == NativeIntegrationTrait {
  static var nativeIntegration: Self { .init() }
}

private actor NativeIntegrationCapacity {
  static let shared = NativeIntegrationCapacity()
  private var available = 4
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if available > 0 {
      available -= 1
    } else {
      await withCheckedContinuation { waiters.append($0) }
    }
  }

  func release() {
    if waiters.isEmpty {
      available += 1
    } else {
      waiters.removeFirst().resume()
    }
  }
}
