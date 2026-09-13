import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct ManagedCommandRunnerTests {
  @Test
  func closesInputAndUsesOnlyTheCompleteEnvironment() async throws {
    let result = try await BlockingOperationExecutor(label: "test.managed-command").perform {
      try ManagedCommandRunner().run(
        executable: "/usr/bin/python3",
        arguments: [
          "-c",
          "import os,sys; assert sys.stdin.read() == ''; assert 'HOME' not in os.environ; print(os.environ['PROBE_VALUE'])",
        ],
        workingDirectory: FileManager.default.temporaryDirectory,
        environment: ["PATH": "/usr/bin:/bin", "PROBE_VALUE": "isolated"],
        timeoutMilliseconds: 2000, maxOutputBytes: 1024)
    }
    #expect(result.exitCode == 0 && !result.timedOut)
    #expect(result.stdout == "isolated\n")
  }

  @Test
  func binaryOutputAndTruncationRemainExplicit() async throws {
    let runner = ManagedCommandRunner()
    let bytes = try await BlockingOperationExecutor(label: "test.managed-command").perform {
      try runner.runData(
        executable: "/usr/bin/python3",
        arguments: ["-c", "import os; os.write(1, bytes([0,255,128,10])); os.write(2, b'error')"],
        workingDirectory: nil, environment: ["PATH": "/usr/bin:/bin"],
        timeoutMilliseconds: 2000, maxOutputBytes: 1024)
    }
    #expect(bytes.stdout == Data([0, 255, 128, 10]))
    #expect(bytes.stderr == Data("error".utf8))
    let truncated = try await BlockingOperationExecutor(label: "test.managed-command").perform {
      try runner.run(
        executable: "/usr/bin/python3", arguments: ["-c", "import os; os.write(1,b'x'*8192)"],
        workingDirectory: nil, environment: ["PATH": "/usr/bin:/bin"],
        timeoutMilliseconds: 2000, maxOutputBytes: 64)
    }
    #expect(truncated.stdout.utf8.count == 64 && truncated.stdoutTruncated)
    #expect(!truncated.stderrTruncated)
  }

  @Test
  func timeoutReclaimsANonCooperativeProcessGroup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let receipt = root.appendingPathComponent("pids")
    let source = #"""
      import os, pathlib, signal, subprocess, sys, time
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      child = subprocess.Popen([sys.executable, "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"])
      pathlib.Path(sys.argv[1]).write_text(str(os.getpid()) + "\n" + str(child.pid))
      time.sleep(30)
      """#
    let started = ContinuousClock.now
    let result = try await BlockingOperationExecutor(label: "managed-probe-test").perform {
      try ManagedCommandRunner().run(
        executable: "/usr/bin/python3", arguments: ["-c", source, receipt.path],
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
              executable: "/usr/bin/python3",
              arguments: [
                "-c",
                "import os,sys; assert 'HOME' not in os.environ; assert sys.stdin.read() == ''; print('probe 1.2.3')",
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

  private static func exited(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
}
