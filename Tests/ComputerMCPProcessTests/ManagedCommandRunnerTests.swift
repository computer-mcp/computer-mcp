import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPPlatform
@testable import ComputerMCPProcess

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct ManagedCommandRunnerTests {
  @Test
  func closesInputAndUsesOnlyTheCompleteEnvironment() async throws {
    let result = try await BlockingOperationExecutor(label: "test.managed-command").perform {
      // A shell adds nothing to its environment, unlike interpreter launchers.
      try ManagedCommandRunner().run(
        executable: "/bin/sh",
        arguments: [
          "-c",
          #"if IFS= read -r line; then exit 3; fi; [ -z "${HOME+x}" ] || exit 4; printf '%s\n' "$PROBE_VALUE""#,
        ],
        workingDirectory: FileManager.default.temporaryDirectory,
        environment: ["PATH": "/usr/bin:/bin", "PROBE_VALUE": "isolated"],
        timeoutMilliseconds: 2000, maxOutputBytes: 1024)
    }
    #expect(result.exitCode == 0 && !result.timedOut, "\(result.stderr)")
    #expect(result.stdout == "isolated\n")
  }

  @Test
  func binaryOutputAndTruncationRemainExplicit() async throws {
    let runner = ManagedCommandRunner()
    let bytes = try await BlockingOperationExecutor(label: "test.managed-command").perform {
      try runner.runData(
        executable: "/bin/sh", arguments: ["-c", #"printf '\000\377\200\n'; printf error >&2"#],
        workingDirectory: nil, environment: ["PATH": "/usr/bin:/bin"],
        timeoutMilliseconds: 2000, maxOutputBytes: 1024)
    }
    #expect(!bytes.timedOut)
    #expect(bytes.stdout == Data([0, 255, 128, 10]))
    #expect(bytes.stderr == Data("error".utf8))
    let truncated = try await BlockingOperationExecutor(label: "test.managed-command").perform {
      try runner.run(
        executable: "/bin/sh", arguments: ["-c", "printf '%8192s' '' | tr ' ' x"],
        workingDirectory: nil, environment: ["PATH": "/usr/bin:/bin"],
        timeoutMilliseconds: 2000, maxOutputBytes: 64)
    }
    #expect(!truncated.timedOut)
    #expect(truncated.stdout == String(repeating: "x", count: 64) && truncated.stdoutTruncated)
    #expect(!truncated.stderrTruncated)
  }

  @Test
  func timeoutReclaimsANonCooperativeProcessGroup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let receipt = root.appendingPathComponent("pids")
    // Both shells ignore SIGTERM; only the group kill after the grace period ends them.
    let source = #"""
      trap '' TERM
      sh -c 'trap "" TERM; sleep 30' &
      printf '%s\n%s\n' "$$" "$!" > "$0"
      sleep 30
      """#
    let started = ContinuousClock.now
    let result = try await BlockingOperationExecutor(label: "managed-probe-test").perform {
      try ManagedCommandRunner().run(
        executable: "/bin/sh", arguments: ["-c", source, receipt.path],
        workingDirectory: root, environment: ["PATH": "/usr/bin:/bin"],
        timeoutMilliseconds: 1000, maxOutputBytes: 1024)
    }
    #expect(result.timedOut && result.exitCode != nil)
    #expect(started.duration(to: .now) < .seconds(5))
    let pids = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").compactMap {
      Int32($0)
    }
    try #require(pids.count == 2)
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline && !pids.allSatisfy(Self.exited) {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(pids.allSatisfy(Self.exited))
  }

  @Test
  func discoveryUsesTheManagedDefaultWithoutInstallingAnything() async throws {
    let result = try await BlockingOperationExecutor(label: "test.managed-command").perform {
      try ExternalProviderDiscovery(
        definitions: [.init(id: "probe", kind: .tunnelClient, executableNames: ["probe"])],
        configuredProviders: [
          "probe": [
            .init(
              executable: "/bin/sh",
              arguments: [
                "-c",
                #"[ -z "${HOME+x}" ] || exit 4; if IFS= read -r line || [ -n "$line" ]; then exit 3; fi; echo 'probe 1.2.3'"#,
              ])
          ]
        ],
        environment: ["PATH": "/usr/bin:/bin"], commonSearchDirectories: []
      ).discover()
    }
    #expect(result.first?.version == "probe 1.2.3")
    #expect(result.first?.doctorStatus.state == .notApplicable)
    #expect(result.first?.diagnostics.isEmpty == true)
  }

  /// A killed process whose new parent never reaps it remains a zombie; it has still exited.
  private static func exited(_ pid: Int32) -> Bool { ProcessTable.hasExited(pid) }
}
