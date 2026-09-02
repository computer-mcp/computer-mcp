import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
final class CodexValidationCleanupTests {
  @Test
  func testPrimarySuccessSurvivesCleanupTimeoutWithExactWarning() async throws {
    let owner = validationOwner(connectionID: "validation-timeout")
    let target = CodexValidationCleanupTarget(
      owner: owner,
      workspacePath: "/tmp/validation-workspace",
      threadID: "thread-validation",
      runtimeID: "runtime-validation",
      processID: 42_001,
      managedWorktreeID: "managed-validation"
    )
    let clock = ContinuousClock()
    let started = clock.now
    let outcome = try await CodexValidationCleanupCoordinator.run(
      target: target,
      deadlines: validationDeadlines(milliseconds: 25),
      cleanupOperations: [
        CodexValidationPhaseOperation(phase: .unsubscribeRelease) {
          try await Task.sleep(for: .seconds(30))
          return .object(["released": .bool(true)])
        }
      ]
    ) {
      "primary-passed"
    }

    #expect(outcome.value == "primary-passed")
    #expect(started.duration(to: clock.now) < .seconds(1))
    let warning = try #require(outcome.cleanup.warnings.first)
    #expect(warning.phase == .unsubscribeRelease)
    #expect(warning.status == .warning)
    #expect(warning.warning?.contains("25-millisecond deadline") == true)
    #expect(warning.safeManualAction?.contains("thread-validation") == true)
    #expect(outcome.cleanup.target == target)
  }

  @Test
  func testCleanupPhasesUseIndependentBoundedDeadlines() async throws {
    let probe = ValidationPhaseProbe()
    let target = CodexValidationCleanupTarget(
      owner: validationOwner(connectionID: "validation-independent-deadlines"),
      workspacePath: "/tmp/validation-workspace",
      threadID: "thread-deadlines",
      runtimeID: "runtime-deadlines",
      processID: nil,
      managedWorktreeID: nil
    )
    let clock = ContinuousClock()
    let started = clock.now
    let outcome = try await CodexValidationCleanupCoordinator.run(
      target: target,
      deadlines: validationDeadlines(milliseconds: 20),
      cleanupOperations: [
        CodexValidationPhaseOperation(phase: .threadFinish) {
          await probe.record(.threadFinish)
          try await Task.sleep(for: .seconds(30))
          return .null
        },
        CodexValidationPhaseOperation(phase: .unsubscribeRelease) {
          await probe.record(.unsubscribeRelease)
          return .object(["released": .bool(true)])
        },
        CodexValidationPhaseOperation(phase: .finalDiagnostics) {
          await probe.record(.finalDiagnostics)
          return .object(["healthy": .bool(true)])
        },
      ]
    ) {
      true
    }

    #expect(outcome.value)
    #expect(started.duration(to: clock.now) < .seconds(1))
    #expect(
      await probe.phases == [.threadFinish, .unsubscribeRelease, .finalDiagnostics]
    )
    #expect(
      outcome.cleanup.phases.first { $0.phase == .threadFinish }?.status == .warning
    )
    #expect(
      outcome.cleanup.phases.first { $0.phase == .unsubscribeRelease }?.status
        == .completed
    )
    #expect(
      outcome.cleanup.phases.first { $0.phase == .finalDiagnostics }?.status == .completed
    )
  }

  @Test
  func testValidationCleanupStopsOnlyTheExactOwnedRuntime() async throws {
    let fixture = try ValidationRuntimeFixture()
    defer { fixture.remove() }
    let owner = validationOwner(connectionID: "validation-owned-runtime")
    let runtime = fixture.makeRuntime(owner: owner)
    _ = try await runtime.call(method: "thread/loaded/list", params: .object([:]))
    let status = await runtime.status()
    let ownedProcessID = try #require(
      status.objectValue?["process"]?.objectValue?["process_id"]?.intValue.flatMap(Int32.init)
    )
    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
    unrelated.arguments = ["10"]
    try unrelated.run()
    let unrelatedProcessID = unrelated.processIdentifier
    defer {
      if unrelated.isRunning {
        unrelated.terminate()
      }
    }
    let target = CodexValidationCleanupTarget(
      owner: owner,
      workspacePath: fixture.directory.path,
      threadID: "thread_fixture",
      runtimeID: runtime.runtimeID,
      processID: ownedProcessID,
      managedWorktreeID: nil
    )

    let outcome = try await CodexValidationCleanupCoordinator.run(
      target: target,
      deadlines: validationDeadlines(milliseconds: 2_000),
      cleanupOperations: [
        CodexValidationCleanupCoordinator.ownedRuntimeStopOperation(
          runtime: runtime,
          target: target
        ),
        CodexValidationPhaseOperation(phase: .processReap) {
          for _ in 0..<200 {
            if !validationProcessExists(ownedProcessID) {
              return .object([
                "process_id": .number(Double(ownedProcessID)),
                "reaped": .bool(true),
              ])
            }
            try await Task.sleep(for: .milliseconds(10))
          }
          throw ValidationFixtureError.processDidNotExit(ownedProcessID)
        },
      ]
    ) {
      "primary-passed"
    }

    #expect(outcome.value == "primary-passed")
    #expect(outcome.cleanup.warnings.isEmpty)
    #expect(!validationProcessExists(ownedProcessID))
    #expect(validationProcessExists(unrelatedProcessID))
  }
}

private actor ValidationPhaseProbe {
  private(set) var phases: [CodexValidationPhase] = []

  func record(_ phase: CodexValidationPhase) {
    phases.append(phase)
  }
}

private enum ValidationFixtureError: Error {
  case processDidNotExit(Int32)
}

private struct ValidationRuntimeFixture {
  let directory: URL
  let executable: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cm-validation-cleanup-\(UUID().uuidString)",
      isDirectory: true
    )
    executable = directory.appendingPathComponent("codex-fixture")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(
      """
      #!/bin/sh
      IFS= read -r line || exit 74
      id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/')
      printf '{"id":%s,"result":{"codexHome":"%s","platformFamily":"unix","platformOs":"macos","userAgent":"Codex/validation-fixture"}}\n' "$id" "$(pwd -P)"
      IFS= read -r line || exit 75
      while IFS= read -r line; do
        id=$(printf '%s\n' "$line" | /usr/bin/sed -E 's/.*"id":("[^"]*"|[0-9]+).*/\\1/')
        case "$line" in
          *thread*loaded*list*)
            printf '{"id":%s,"result":{"data":["thread_fixture"],"nextCursor":null}}\n' "$id"
            ;;
          *thread*unsubscribe*)
            printf '{"id":%s,"result":{"status":"unsubscribed"}}\n' "$id"
            ;;
          *)
            printf '{"id":%s,"result":{}}\n' "$id"
            ;;
        esac
      done
      """.utf8
    ).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: executable.path
    )
  }

  func makeRuntime(owner: CodexRuntimeOwner) -> LiveCodexAppServerRuntime {
    LiveCodexAppServerRuntime(
      configuration: CodexConfig(
        enabled: true,
        executable: executable.path,
        execEnabled: false,
        mcpEnabled: false,
        appServerRequestTimeoutSeconds: 2,
        appServerTerminationGraceMilliseconds: 200,
        appServerKillGraceMilliseconds: 1_000,
        approvalPolicy: .never
      ),
      workspaceURL: directory,
      owner: owner
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private func validationOwner(connectionID: String) -> CodexRuntimeOwner {
  CodexRuntimeOwner(
    workspaceID: "validation-workspace",
    profileID: GatewayProfileID.localAdmin.rawValue,
    caller: GatewayCallerKind.localMCP.rawValue,
    transport: "validation",
    socketConnectionID: connectionID,
    tunnelInstanceID: nil,
    tunnelProfileID: nil
  )
}

private func validationDeadlines(milliseconds: Int) -> CodexValidationDeadlines {
  CodexValidationDeadlines(
    primaryAcceptanceMilliseconds: milliseconds,
    threadFinishMilliseconds: milliseconds,
    unsubscribeReleaseMilliseconds: milliseconds,
    runtimeStopMilliseconds: milliseconds,
    processReapMilliseconds: milliseconds,
    worktreeCleanupMilliseconds: milliseconds,
    finalDiagnosticsMilliseconds: milliseconds
  )
}

private func validationProcessExists(_ processID: Int32) -> Bool {
  errno = 0
  return kill(processID, 0) == 0 || errno != ESRCH
}
