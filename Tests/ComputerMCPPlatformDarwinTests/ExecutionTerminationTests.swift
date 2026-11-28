import ComputerMCPTestSupport
import Foundation
import Testing

@Suite(.nativeIntegration, .serialized) struct ExecutionTerminationTests {
  @Test(.timeLimit(.minutes(1)), arguments: ["running", "stopped"])
  func reapingDrainsQueuedSandboxWrites(mode: String) throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let source = try #require(
      Bundle.module.url(
        forResource: "execution-aio-reaping", withExtension: "c", subdirectory: "Fixtures"))
    let binary = fixture.root.appendingPathComponent("aio-reaping")
    let compiler = Process()
    compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
    compiler.arguments = [
      "-O2", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations",
      source.path, "-o", binary.path,
    ]
    try compiler.run()
    compiler.waitUntilExit()
    try #require(compiler.terminationStatus == 0)
    let probe = Process()
    probe.executableURL = binary
    probe.arguments = [fixture.root.path, mode]
    try probe.run()
    probe.waitUntilExit()
    #expect(probe.terminationReason == .exit)
    #expect(probe.terminationStatus == 0)
  }
}
