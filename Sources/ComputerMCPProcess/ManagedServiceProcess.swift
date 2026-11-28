import ComputerMCPSandbox
import Foundation
import NIOConcurrencyHelpers

/// A long-lived host service with synchronous status reads and ownership-confirmed cleanup.
package final class ManagedServiceProcess: Sendable {
  private struct State: Sendable {
    var exit: ExecutionExit?
    var handler: (@Sendable (ManagedServiceProcess) -> Void)?
    var monitor: Task<Void, Never>?
  }
  private let state = NIOLockedValueBox(State())
  private let ownership: any ExecutionOwnership
  package let processIdentifier: Int32
  package var isRunning: Bool { state.withLockedValue { $0.exit == nil } }
  package var terminationStatus: Int32 { state.withLockedValue { $0.exit?.status ?? 0 } }
  package var terminationHandler: (@Sendable (ManagedServiceProcess) -> Void)? {
    get { state.withLockedValue { $0.handler } }
    set { state.withLockedValue { $0.handler = newValue } }
  }

  private init(ownership: any ExecutionOwnership, processID: Int32) {
    self.ownership = ownership
    processIdentifier = processID
  }

  package static func start(
    launcher: ExecutionLauncher, executable: String, arguments: [String],
    directory: URL, environment: [String: String], output: Int32, error: Int32,
    onExit: @escaping @Sendable (ManagedServiceProcess) -> Void
  ) async throws -> ManagedServiceProcess {
    let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
    defer { try? input.close() }
    let root = NIOLockedValueBox<Int32?>(nil)
    let owner = NIOLockedValueBox<(any ExecutionOwnership)?>(nil)
    do {
      let ownership = try await launcher.start(
        executable: SandboxPath(executable), arguments: arguments,
        directory: SandboxPath(directory.path),
        environment: ExecutionEnvironment(fullAccessVariables: environment), mode: .fullAccess,
        input: input.fileDescriptor, output: output, error: error,
        bindOwnership: { handle in
          owner.withLockedValue { $0 = handle }
          handle.beforeStart { member in root.withLockedValue { $0 = member.processID } }
        })
      guard let processID = root.withLockedValue({ $0 }) else {
        throw ExecutionEnvironmentError.launchFailed("Service launch has no process identity")
      }
      let process = ManagedServiceProcess(ownership: ownership, processID: processID)
      process.terminationHandler = onExit
      let monitor = Task {
        let exit: ExecutionExit
        do { exit = try await ownership.waitForExit() } catch {
          await ownership.cancelAndWait()
          exit = ExecutionExit(status: 1)
        }
        let handler = process.state.withLockedValue {
          $0.exit = exit
          return $0.handler
        }
        handler?(process)
      }
      process.state.withLockedValue { $0.monitor = monitor }
      return process
    } catch {
      if let ownership = owner.withLockedValue({ $0 }) { await ownership.cancelAndWait() }
      throw error
    }
  }

  package func stop() async {
    terminationHandler = nil
    await ownership.cancelAndWait()
    await state.withLockedValue { $0.monitor }?.value
  }
}
