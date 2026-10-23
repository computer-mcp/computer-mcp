import ComputerMCPEgress
import ComputerMCPPlatformDarwin
import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@Suite struct SeatbeltBoundaryTests {
  @Test func proxyPortsAreExecutionSpecificAndDirectTrafficIsDenied() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let probe = try compileProbe(fixture)
    let first = try await EgressProxy.start(
      executionID: "first", policy: .init(), routing: DarwinEgressRouting(), limits: .init())
    let second = try await EgressProxy.start(
      executionID: "second", policy: .init(), routing: DarwinEgressRouting(), limits: .init())
    let own = try await first.sandboxPorts()
    let other = try await second.sandboxPorts()
    let configuration = try fixture.configuration(proxy: own)
    let cases: [([String], Bool)] = [
      (["tcp", "127.0.0.1", String(own.http)], true),
      (["tcp", "::1", String(own.http)], true),
      (["tcp", "127.0.0.1", String(other.http)], false),
      (["tcp", "::1", String(other.http)], false),
      (["tcp", "1.1.1.1", "443"], false),
      (["tcp", "2606:4700:4700::1111", "443"], false),
      (["tcp", "140.82.112.3", "443"], false),
      (["udp", "127.0.0.1", String(own.http)], false),
      (["udp", "1.1.1.1", "443"], false),
      (["udp", "1.1.1.1", "53"], false),
      (["tcp", "1.1.1.1", "53"], false),
      (["dns"], false),
    ]
    for (arguments, allowed) in cases {
      #expect(
        (try run(probe, arguments, configuration: configuration)) == (allowed ? 0 : 1),
        "\(arguments)")
    }
    try await first.revoke()
    let third = try await EgressProxy.start(
      executionID: "third", policy: .init(), routing: DarwinEgressRouting(), limits: .init())
    #expect(try await third.sandboxPorts().http != own.http)
    try await first.releaseAfterExecutionEnds()
    try await second.releaseAfterExecutionEnds()
    try await third.releaseAfterExecutionEnds()
  }

  @Test func siblingProcessEnvironmentIsUnreadable() throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let probe = try compileProbe(fixture)
    let sentinel = Process()
    sentinel.executableURL = probe
    sentinel.arguments = ["sentinel"]
    sentinel.environment = ["SYNTHETIC_TEST_TOKEN": "not-a-real-credential"]
    try sentinel.run()
    defer {
      sentinel.terminate()
      sentinel.waitUntilExit()
    }
    #expect(
      try run(
        probe, ["procargs", String(sentinel.processIdentifier)],
        configuration: fixture.configuration()) == 0)
  }

  @Test(arguments: 0..<8)
  func serviceRulesAreEnforcedIndependently(mask: Int) throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let probe = try compileProbe(fixture)
    let base = try fixture.configuration()
    let configuration = try SandboxConfiguration(
      worktree: base.worktree, temporaryDirectory: base.temporaryDirectory,
      homeDirectory: base.homeDirectory, cacheDirectory: base.cacheDirectory,
      readableRoots: base.readableRoots,
      listableAncestors: base.listableAncestors,
      services: .init(
        screenCapture: mask & 1 != 0, accessibility: mask & 2 != 0, appleEvents: mask & 4 != 0))
    for (name, enabled) in [
      ("com.apple.windowserver.active", mask & 3 != 0),
      ("com.apple.replayd", mask & 1 != 0), ("com.apple.axserver", mask & 2 != 0),
      ("com.apple.axregistrar", mask & 2 != 0),
      ("com.apple.coreservices.appleevents", mask & 4 != 0),
    ] {
      #expect(
        try run(probe, ["service", "mach-lookup", name], configuration: configuration)
          == (enabled ? 0 : 1),
        "\(name), service mask \(mask)")
    }
  }

  @Test func systemRouteQuery() throws {
    let route = try DarwinEgressRouting().route(to: "127.0.0.1")
    #expect(route.interface == "lo0")
    #expect(!route.isTunnel)
  }

  private func compileProbe(_ fixture: SeatbeltFixture) throws -> URL {
    let source = try #require(
      Bundle.module.url(forResource: "BoundaryProbe", withExtension: "c", subdirectory: "Fixtures"))
    let output = fixture.root.appendingPathComponent("worktree/probe")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    process.arguments = [source.path, "-o", output.path]
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return output
  }

  private func run(_ executable: URL, _ arguments: [String], configuration: SandboxConfiguration)
    throws -> Int32
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    process.arguments =
      ["-p", SeatbeltProfile.generate(configuration), executable.path] + arguments
    process.environment = [:]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
}
