import Darwin
import Foundation
import Testing

@testable import ComputerMCPValidation
@testable import ComputerMCPValidationCLI

@Suite(.timeLimit(.minutes(1)))
struct ValidationGatewayCleanupTests {
  @Test(arguments: [false, true])
  func concurrentDisconnectJoinsOwnedBridgeCleanup(stubborn: Bool) async throws {
    let fixture = try BridgeFixture(mode: stubborn ? "stubborn" : "normal")
    defer { fixture.remove() }
    let session = try await GatewayClientSession.connectSocket(configuration: fixture.configuration)
    do {
      let report = try await session.call(toolName: "fixture", timeoutSeconds: 2)
      #expect(report.toolName == "fixture")
      let started = ContinuousClock.now
      async let first: Void = session.disconnect()
      async let second: Void = session.disconnect()
      _ = try await (first, second)
      try await session.disconnect()
      #expect(started.duration(to: .now) < .seconds(4))
      try fixture.expectStopped()
    } catch { throw await session.disconnect(after: error) }
  }

  @Test(arguments: ["initialize", "call", "cancel", "catalog", "cursor-loop"])
  func incompleteOperationsFinishCleanupBeforeReturning(mode: String) async throws {
    let fixture = try BridgeFixture(mode: mode)
    defer { fixture.remove() }
    let started = ContinuousClock.now
    if mode == "initialize" {
      await #expect(throws: (any Error).self) {
        try await GatewayClientSession.connectSocket(
          configuration: fixture.configuration, timeoutSeconds: 1)
      }
    } else {
      let session = try await GatewayClientSession.connectSocket(
        configuration: fixture.configuration)
      let call = Task {
        if mode == "catalog" || mode == "cursor-loop" {
          _ = try await session.listTools(timeoutSeconds: 1)
        } else {
          _ = try await session.call(toolName: "fixture", timeoutSeconds: mode == "cancel" ? 10 : 1)
        }
      }
      if mode == "cancel" {
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: fixture.called.path)
          && ContinuousClock.now < deadline
        {
          try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.called.path))
        call.cancel()
      }
      let result = await call.result
      if case .success = result { Issue.record("Incomplete operation unexpectedly succeeded.") }
      try await session.disconnect()
    }
    #expect(started.duration(to: .now) < .seconds(5))
    try fixture.expectStopped()
  }
}

private struct BridgeFixture {
  let root: URL
  let called: URL
  let configuration: GatewaySocketConfiguration

  init(mode: String) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "validation-bridge-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    called = root.appendingPathComponent("called")
    let script = root.appendingPathComponent("bridge")
    try Data(
      """
      #!/usr/bin/perl
      use strict;
      use JSON::PP;
      use FindBin;
      $| = 1;
      $SIG{TERM} = 'IGNORE';
      open(my $pid, '>', "$FindBin::Bin/pid") or die $!;
      print $pid $$; close($pid);
      while (my $line = <STDIN>) {
        my $request = decode_json($line);
        my $method = $request->{method} // '';
        next if $method eq 'initialize' && '\(mode)' eq 'initialize';
        if ($method eq 'initialize') {
          print encode_json({jsonrpc=>'2.0', id=>$request->{id}, result=>{
            protocolVersion=>$request->{params}->{protocolVersion}, capabilities=>{tools=>{}},
            serverInfo=>{name=>'fixture',version=>'1'}}}), "\\n";
        } elsif ($method eq 'tools/list') {
          next if '\(mode)' eq 'catalog';
          print encode_json({jsonrpc=>'2.0',id=>$request->{id},result=>{tools=>[],nextCursor=>'same'}}), "\\n";
        } elsif ($method eq 'tools/call') {
          open(my $called, '>', "$FindBin::Bin/called"); close($called);
          next if '\(mode)' eq 'call' || '\(mode)' eq 'cancel';
          print encode_json({jsonrpc=>'2.0',id=>$request->{id},result=>{content=>[],isError=>JSON::PP::false}}), "\\n";
        }
      }
      while ('\(mode)' ne 'normal') { sleep 1; }
      """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    configuration = .init(
      socketURL: root.appendingPathComponent("fixture.sock"), bridgeExecutableURL: script)
  }

  func expectStopped() throws {
    let pid = try #require(
      Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
