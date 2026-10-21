import Foundation
import NIOConcurrencyHelpers
import Subprocess

internal protocol ChildProcessInputWriting: Sendable {
  func write(_ bytes: [UInt8]) async throws -> Int
  func finish() async throws
}

extension StandardInputWriter: ChildProcessInputWriting {}

/// The actor owns FIFO admission and the admitted task. The box also lets synchronous
/// process cancellation stop admission without waiting for an actor hop or pipe I/O.
internal actor ChildProcessInput {
  struct Snapshot: Sendable {
    var pendingWrites = 0
    var writeInProgress = false
    var lastWriteCount: Int?
    var retired = false
  }

  enum Event: Sendable, Equatable {
    case turnGranted
    case writeStarted
    case writeSettled(Int?)
    case finishStarted
    case teardownWaiting
    case bodyReturning
  }

  private struct SharedState {
    var snapshot = Snapshot()
    var error: (any Error)?
  }

  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
  }

  private nonisolated let shared = NIOLockedValueBox(SharedState())
  private let closedError: any Error
  private let inputClosedError: any Error
  private var writer: (any ChildProcessInputWriting)?
  private var ready = false
  private var turnHeld = false
  private var waiters: [Waiter] = []
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var writeTask: Task<Int, any Error>?
  private var finishTask: Task<Void, any Error>?
  private var observer: (@Sendable (Event) -> Void)?
  private var settlementHook: (@Sendable () async -> Void)?

  init(closedError: any Error, inputClosedError: any Error) {
    self.closedError = closedError
    self.inputClosedError = inputClosedError
  }

  nonisolated var snapshot: Snapshot { shared.withLockedValue { $0.snapshot } }

  func observe(_ observer: @escaping @Sendable (Event) -> Void) {
    self.observer = observer
  }

  /// Test seam for holding the admitted operation while teardown attempts to join it.
  func beforeWriteSettles(_ hook: @escaping @Sendable () async -> Void) {
    settlementHook = hook
  }

  func attach(_ writer: any ChildProcessInputWriting, ready: Bool = true) {
    self.writer = writer
    self.ready = ready
    handOffTurn()
  }

  func activate() {
    ready = true
    handOffTurn()
  }

  /// Does not cancel the admitted task. Process termination cancels the library's I/O.
  nonisolated func stop(throwing error: (any Error)? = nil) {
    shared.withLockedValue { $0.error = error ?? closedError }
    Task { await self.rejectWaiters() }
  }

  func write(_ data: Data, close: Bool) async throws -> Int {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      do {
        try await acquireTurn(id)
      } catch {
        try Task.checkCancellation()
        throw error
      }
      do {
        // A cancelled waiter may already have received the turn. It must pass it on.
        try Task.checkCancellation()
        if let error = currentError { throw error }
      } catch {
        releaseTurn()
        throw error
      }

      // An unstructured owner task shields a whole frame from caller cancellation.
      // It releases admission itself, even if the caller has not resumed yet.
      let task = Task { try await self.performWrite(data, close: close) }
      writeTask = task
      return try await task.value
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  /// Must complete inside the run body, before its automatic StandardInputWriter.finish().
  func finish() async {
    stop()
    if turnHeld {
      await withCheckedContinuation {
        idleWaiters.append($0)
        observer?(.teardownWaiting)
      }
    }
    try? await finishWriter()
  }

  func bodyReturning() {
    observer?(.bodyReturning)
  }

  private var currentError: (any Error)? { shared.withLockedValue { $0.error } }

  private func acquireTurn(_ id: UUID) async throws {
    try Task.checkCancellation()
    if let error = currentError { throw error }
    if ready && !turnHeld {
      turnHeld = true
      updateDepth()
      return
    }
    try await withCheckedThrowingContinuation { continuation in
      waiters.append(.init(id: id, continuation: continuation))
      updateDepth()
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    updateDepth()
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func rejectWaiters() {
    guard let error = currentError else { return }
    let rejected = waiters
    waiters.removeAll()
    updateDepth()
    for waiter in rejected { waiter.continuation.resume(throwing: error) }
  }

  private func handOffTurn() {
    if currentError != nil { rejectWaiters() }
    guard ready, !turnHeld, !waiters.isEmpty else { return }
    turnHeld = true
    let waiter = waiters.removeFirst()
    updateDepth()
    observer?(.turnGranted)
    waiter.continuation.resume()
  }

  private func releaseTurn() {
    writeTask = nil
    turnHeld = false
    handOffTurn()
    updateDepth()
    if !turnHeld {
      let idle = idleWaiters
      idleWaiters.removeAll()
      for waiter in idle { waiter.resume() }
    }
  }

  private func updateDepth() {
    shared.withLockedValue { $0.snapshot.pendingWrites = waiters.count + (turnHeld ? 1 : 0) }
  }

  private func performWrite(_ data: Data, close: Bool) async throws -> Int {
    defer { releaseTurn() }
    guard let writer else { throw closedError }
    var count = 0
    if !data.isEmpty {
      shared.withLockedValue { $0.snapshot.writeInProgress = true }
      observer?(.writeStarted)
      do {
        count = try await writer.write(Array(data))
      } catch {
        await settlementHook?()
        writeSettled(nil)
        throw error
      }
      await settlementHook?()
      writeSettled(count)
      if count > 0 && count < data.count {
        shared.withLockedValue {
          $0.snapshot.retired = true
          $0.error = closedError
        }
        rejectWaiters()
      }
      guard count == data.count else { throw closedError }
    }
    if close {
      try await finishWriter()
      shared.withLockedValue { if $0.error == nil { $0.error = inputClosedError } }
    }
    return count
  }

  private func writeSettled(_ count: Int?) {
    shared.withLockedValue {
      $0.snapshot.writeInProgress = false
      $0.snapshot.lastWriteCount = count
    }
    observer?(.writeSettled(count))
  }

  private func finishWriter() async throws {
    if let finishTask { return try await finishTask.value }
    guard let writer else { return }
    let task = Task {
      self.observer?(.finishStarted)
      try await writer.finish()
    }
    finishTask = task
    try await task.value
  }
}
