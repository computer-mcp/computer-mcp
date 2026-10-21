import Foundation
import Testing

@testable import ComputerMCPProcess

@Suite(.timeLimit(.minutes(1)))
struct ManagedLineProcessInputTests {
  enum WriteEnd: CaseIterable, Sendable {
    case zero, partial, error
  }

  @Test(arguments: WriteEnd.allCases)
  func writeResultControlsAdmissionBeforeTheNextTurn(_ end: WriteEnd) async throws {
    let input = ChildProcessInput(closedError: Failure.closed, inputClosedError: Failure.eof)
    let writer = ScriptedWriter(end: end)
    defer { writer.release.continuation.finish() }
    await input.attach(writer)
    let first = Task { try await input.write(Data("first".utf8), close: false) }
    for await _ in writer.entered.stream {}
    let second = Task { try await input.write(Data("second".utf8), close: true) }
    try await waitUntil { input.snapshot.pendingWrites == 2 }
    writer.release.continuation.finish()
    await #expect(throws: end == .error ? Failure.library : Failure.closed) {
      try await first.value
    }
    if end == .partial {
      await #expect(throws: Failure.closed) { try await second.value }
      await #expect(throws: Failure.closed) { try await input.write(Data(), close: true) }
      #expect(await writer.operations == ["first"])
      #expect(input.snapshot.retired)
    } else {
      #expect(try await second.value == 6)
      #expect(await writer.operations == ["first", "second", "eof"])
      #expect(!input.snapshot.retired)
    }
    #expect(input.snapshot.pendingWrites == 0)
    await input.finish()
  }

  @Test
  func cancellationAtTurnHandoffPassesTheTurnWithoutWriting() async throws {
    let input = ChildProcessInput(closedError: Failure.closed, inputClosedError: Failure.eof)
    let writer = ScriptedWriter(end: .zero)
    defer { writer.release.continuation.finish() }
    await input.attach(writer)
    let first = Task { try await input.write(Data("first".utf8), close: false) }
    for await _ in writer.entered.stream {}
    let cancelled = Task { try await input.write(Data("cancelled".utf8), close: true) }
    try await waitUntil { input.snapshot.pendingWrites == 2 }
    let last = Task { try await input.write(Data("last".utf8), close: false) }
    try await waitUntil { input.snapshot.pendingWrites == 3 }
    await input.observe { event in if event == .turnGranted { cancelled.cancel() } }
    writer.release.continuation.finish()
    await #expect(throws: Failure.closed) { try await first.value }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try await last.value == 4)
    #expect(await writer.operations == ["first", "last"])
    #expect(input.snapshot.pendingWrites == 0)
    await input.finish()
  }

  @Test
  func cancellationBeforeProcessReadyRemovesTheWaiter() async throws {
    let input = ChildProcessInput(closedError: Failure.closed, inputClosedError: Failure.eof)
    let waiting = Task { try await input.write(Data("waiting".utf8), close: false) }
    try await waitUntil { input.snapshot.pendingWrites == 1 }
    waiting.cancel()
    try await waitUntil { input.snapshot.pendingWrites == 0 }
    await #expect(throws: CancellationError.self) { try await waiting.value }
    await input.finish()
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
      try #require(ContinuousClock.now < deadline)
      try Task.checkCancellation()
      await Task.yield()
    }
  }

  private enum Failure: Error, Equatable {
    case closed, eof, library
  }

  private actor ScriptedWriter: ChildProcessInputWriting {
    let end: WriteEnd
    nonisolated let entered = AsyncStream<Void>.makeStream()
    nonisolated let release = AsyncStream<Void>.makeStream()
    var operations: [String] = []

    init(end: WriteEnd) { self.end = end }

    func write(_ bytes: [UInt8]) async throws -> Int {
      operations.append(String(decoding: bytes, as: UTF8.self))
      guard operations.count == 1 else { return bytes.count }
      entered.continuation.finish()
      for await _ in release.stream {}
      switch end {
      case .zero: return 0
      case .partial: return 1
      case .error: throw Failure.library
      }
    }

    func finish() { operations.append("eof") }
  }
}
