import Testing

package var nativeSandboxAvailable: Bool {
  #if os(macOS)
    true
  #else
    false
  #endif
}

/// Native functions reserve process and I/O capacity before individual case deadlines begin.
/// Parameterized functions reserve a whole batch, preserving their existing case parallelism
/// and concurrency within each case.
package struct NativeIntegrationTrait: TestTrait, SuiteTrait, TestScoping {
  fileprivate var permits = 1
  package var isRecursive: Bool { true }

  package func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
    guard testCase == nil, !test.isSuite else { return nil }
    return Self(permits: test.isParameterized ? 4 : permits)
  }

  package func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    await NativeIntegrationCapacity.shared.acquire(permits)
    do {
      try Task.checkCancellation()
      try await function()
    } catch {
      await NativeIntegrationCapacity.shared.release(permits)
      throw error
    }
    await NativeIntegrationCapacity.shared.release(permits)
  }
}

extension Trait where Self == NativeIntegrationTrait {
  package static var nativeIntegration: Self { .init() }
}

private actor NativeIntegrationCapacity {
  static let shared = NativeIntegrationCapacity()
  private var available = 4
  private var waiters: [(permits: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func acquire(_ permits: Int) async {
    if waiters.isEmpty && available >= permits {
      available -= permits
    } else {
      await withCheckedContinuation { waiters.append((permits, $0)) }
    }
  }

  func release(_ permits: Int) {
    available += permits
    while let next = waiters.first, next.permits <= available {
      available -= next.permits
      waiters.removeFirst().continuation.resume()
    }
  }
}
