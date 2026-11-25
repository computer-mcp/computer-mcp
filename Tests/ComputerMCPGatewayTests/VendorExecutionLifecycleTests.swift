#if os(macOS)
  import ComputerMCPConfiguration
  import ComputerMCPCore
  import ComputerMCPPermissions
  import ComputerMCPPlatform
  import ComputerMCPPlatformPOSIX
  import ComputerMCPPlugins
  import ComputerMCPSandbox
  import ComputerMCPTestSupport
  import ComputerMCPTransport
  import Crypto
  import Foundation
  import Testing

  @testable import ComputerMCPGateway
  @testable import ComputerMCPProcess

  @Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(2)))
  struct VendorExecutionLifecycleTests {
    @Test func exactStopAndIndependentRetirementWithDeterministicPeer() async throws {
      let fixture = try Fixture()
      defer { fixture.base.remove() }
      let host = try VendorExecutionSession(
        source: fixture.vendor, launcher: fixture.base.platform.launcher)
      let transport = try MCPInheritedSocketTransport(
        takingOwnershipOf: host.providerChannel.takeEndpoint())
      try await transport.connect()
      var peer = Peer(transport: transport, replies: await transport.receive().makeAsyncIterator())
      do {
        let opening = try await fixture.prepare("open")
        if case .sandbox(let adapter) = opening.mode {
          #expect(!adapter.readableRoots.contains(fixture.vendor.executable))
        }
        #expect(opening.vendorSandbox?.readableRoots.contains(fixture.vendor.executable) == true)
        await #expect(throws: GatewayToolError.self) {
          try await host.admit(id: UUID(), tool: "open", arguments: [:], execution: opening)
        }
        let hello = try await peer.call(
          "initialize", ["capability": .string(VendorExecutionSource.capability)])
        #expect(hello["capability"] == .string(VendorExecutionSource.capability))

        let a = try await open("a", execution: opening, host: host, peer: &peer)
        let warm = try await fixture.prepare("open_async")
        let b = try await open("b", execution: warm, host: host, peer: &peer, detached: true)
        #expect(opening.executionID != warm.executionID && a.child != b.child)

        let interrupted = try await fixture.prepare("open")
        let openingID = UUID()
        try await host.admit(id: openingID, tool: "open", arguments: [:], execution: interrupted)
        var startup: [String: JSONValue] = [
          "call": .string(openingID.uuidString), "acquisition": .string(openingID.uuidString),
          "session": .string(String(repeating: "c", count: 32)),
        ]
        let reserved = try await peer.call("bind", startup)
        startup["child"] = try #require(reserved["probe"])
        _ = try await peer.call("probe", startup)
        await host.requestCancellation(openingID)
        startup["child"] = try #require(reserved["workload"])
        let stoppedStartup = try await peer.call("receipt", startup)
        #expect(stoppedStartup["probe_state"] == .string("retired"))
        #expect(stoppedStartup["workload_state"] == .string("never_dispatched"))
        #expect(try await peer.rejection("launch", startup) == "cancelled")
        await host.returned(openingID, confirmed: true)
        try interrupted.finishAdmission()
        #expect(try await peer.call("receipt", startup) == stoppedStartup)

        let prompt = try await admit("prompt", session: a, fixture: fixture, host: host)
        try await peer.write("wait", kind: "prompt", call: prompt, on: a)
        try await peer.expectOutput("begun\n", after: 0, call: prompt, on: a)

        let token = String(repeating: "a", count: 32)
        _ = try await peer.call(
          "pending", a.fields(prompt).merging(["token": .string(token)]) { _, new in new })
        let answer = try await admit(
          "answer", session: a, fixture: fixture, host: host, extra: ["request_id": .string(token)])
        let wrong = try await peer.rejection(
          "write",
          a.fields(answer).merging([
            "kind": .string("answer"), "token": .string(String(repeating: "b", count: 32)),
            "data": .string("answer"),
          ]) { _, new in new })
        #expect(wrong == "vendor_effect_denied")
        _ = try await peer.call(
          "write",
          a.fields(answer).merging([
            "kind": .string("answer"), "token": .string(token), "data": .string("answer"),
          ]) { _, new in new })
        try await peer.expectOutput("answer received\n", after: 1, call: prompt, on: a)
        #expect(
          try await peer.rejection(
            "write",
            a.fields(answer).merging([
              "kind": .string("answer"), "token": .string(token), "data": .string("answer"),
            ]) { _, new in new }) == "vendor_effect_denied")
        await host.returned(answer, confirmed: true)

        let nextToken = String(repeating: "c", count: 32)
        _ = try await peer.call(
          "pending", a.fields(prompt).merging(["token": .string(nextToken)]) { _, new in new })
        let lateAnswer = try await admit(
          "answer", session: a, fixture: fixture, host: host,
          extra: ["request_id": .string(nextToken)])
        let read = try await admit("list", session: a, fixture: fixture, host: host)
        #expect(
          try await peer.rejection(
            "write",
            a.fields(read).merging(["kind": .string("cancel"), "data": .string("cancel")]) {
              _, new in new
            }) == "vendor_effect_denied")
        let stop = try await admit("stop", session: a, fixture: fixture, host: host)
        let stopped = try await peer.call("stop", a.fields(stop))
        #expect(stopped["turn"] == .string(prompt.uuidString.lowercased()))
        #expect(
          try await peer.rejection(
            "write",
            a.fields(lateAnswer).merging([
              "kind": .string("answer"), "token": .string(nextToken), "data": .string("answer"),
            ]) { _, new in new }) == "vendor_effect_denied")
        await host.returned(lateAnswer, confirmed: true)
        try await peer.write("cancel", kind: "cancel", call: stop, on: a)
        try await peer.expectOutput("original:cancelled\n", after: 2, call: prompt, on: a)
        _ = try await peer.call("finish", a.fields(prompt))

        let ignored = try await admit("prompt", session: a, fixture: fixture, host: host)
        try await peer.write("ignore", kind: "prompt", call: ignored, on: a)
        try await peer.expectOutput("begun\n", after: 3, call: ignored, on: a)
        #expect(
          try await peer.rejection(
            "write",
            a.fields(stop).merging(["kind": .string("cancel"), "data": .string("cancel")]) {
              _, new in new
            }) == "vendor_effect_stale")
        await host.returned(stop, confirmed: true)
        let forced = try await admit("stop", session: a, fixture: fixture, host: host)
        _ = try await peer.call("stop", a.fields(forced))
        try await peer.write("cancel", kind: "cancel", call: forced, on: a)
        let retired = try await peer.call("retire", a.fields(ignored))
        #expect(retired["workload"] == .string(a.child.uuidString.lowercased()))
        #expect(retired["probe_state"] == .string("retired"))
        #expect(retired["workload_state"] == .string("retired"))
        #expect(retired["retired"] == .bool(true))
        #expect(try await peer.call("receipt", a.fields(ignored)) == retired)
        var wrongChild = a.fields(ignored)
        wrongChild["child"] = .string(b.child.uuidString)
        #expect(try await peer.rejection("receipt", wrongChild) == "vendor_effect_stale")

        let fresh = try await admit("prompt", session: b, fixture: fixture, host: host)
        let outbound = Data(("finish:" + String(repeating: "x", count: 1_048_568)).utf8)
        let frame = UUID()
        for offset in stride(from: 0, to: outbound.count, by: 196_608) {
          let end = min(offset + 196_608, outbound.count)
          _ = try await peer.call(
            "write",
            b.fields(fresh).merging([
              "kind": .string("prompt"), "frame": .string(frame.uuidString),
              "offset": .integer(Int64(offset)), "final": .bool(end == outbound.count),
              "data": .string(outbound.subdata(in: offset..<end).base64EncodedString()),
            ]) { _, new in new })
        }
        try await peer.expectOutput("done:1048575\n", after: 0, call: fresh, on: b)
        _ = try await peer.call("finish", b.fields(fresh))
        await transport.disconnect()
        for await _ in host.termination {}
        #expect(await host.shutdownConfirmed())
        try await fixture.cleanup()
      } catch {
        await transport.disconnect()
        await host.close()
        try? await fixture.cleanup()
        throw error
      }
    }

    @Test func selectedDependencyAndPackageFilesAreSourceBound() throws {
      let fixture = try Fixture()
      defer { fixture.base.remove() }
      #expect(fixture.vendor.executable == (try SandboxPath(fixture.executable.path)))
      try Data("changed encoder".utf8).write(to: fixture.adapter)
      #expect(throws: (any Error).self) { try fixture.vendor.verify() }
    }

    @Test func printReceivesEOFAndReportsNativeExitForItsOwnChild() async throws {
      let fixture = try Fixture(.print)
      defer { fixture.base.remove() }
      let host = try VendorExecutionSession(
        source: fixture.vendor, launcher: fixture.base.platform.launcher)
      let transport = try MCPInheritedSocketTransport(
        takingOwnershipOf: host.providerChannel.takeEndpoint())
      try await transport.connect()
      var peer = Peer(transport: transport, replies: await transport.receive().makeAsyncIterator())
      do {
        _ = try await peer.call(
          "initialize", ["capability": .string(VendorExecutionSource.capability)])
        let execution = try await fixture.prepare("claude.run")
        let run = UUID()
        try await host.admit(
          id: run, tool: "claude.run", arguments: ["prompt": .string("--text")],
          execution: execution)
        let handle = String(repeating: "d", count: 32)
        let binding = try await peer.call(
          "bind",
          [
            "call": .string(run.uuidString), "acquisition": .string(run.uuidString),
            "session": .string(handle),
          ])
        let probe = try #require(binding["probe"]?.stringValue)
        let child = try #require(binding["workload"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let work = Workload(acquisition: run, child: child, handle: handle)
        var probeFields = work.fields(run)
        probeFields["child"] = .string(probe)
        _ = try await peer.call("probe", probeFields)
        let supplied = work.fields(run).merging(["argv": .array([.string("--unexpected")])]) {
          _, new in new
        }
        #expect(try await peer.rejection("launch", supplied) == "vendor_effect_denied")
        _ = try await peer.call("launch", work.fields(run))
        let output = work.fields(run)
        let write = output.merging(["kind": .string("setup"), "data": .string("unsafe")]) {
          _, new in new
        }
        #expect(try await peer.rejection("write", write) == "vendor_effect_denied")
        #expect(try await peer.rejection("ready", output) == "vendor_effect_denied")
        try await peer.expectOutput("received prompt after EOF\n", after: 0, call: run, on: work)
        var end = output
        end["after"] = .integer(1)
        let deadline = ContinuousClock.now + .seconds(5)
        while try await peer.call("read", end)["eof"] != .bool(true) {
          try #require(ContinuousClock.now < deadline)
        }
        var receipt = try await peer.call("receipt", output)
        while receipt["workload_settled"] != .bool(true) {
          try #require(ContinuousClock.now < deadline)
          try await Task.sleep(for: .milliseconds(20))
          receipt = try await peer.call("receipt", output)
        }
        #expect(receipt["exit_code"] == .integer(23))
        #expect(receipt["exit_signal"] == nil)
        let close = UUID()
        let closing = try await fixture.prepare("claude.run.cancel")
        try await host.admit(
          id: close, tool: "claude.run.cancel", arguments: ["run_id": .string(handle)],
          execution: closing)
        let retired = try await peer.call("retire", work.fields(close))
        #expect(retired["retired"] == .bool(true))
        #expect(retired["exit_code"] == receipt["exit_code"])
        await host.returned(close, confirmed: true)
        await host.returned(run, confirmed: true)
        await transport.disconnect()
        for await _ in host.termination {}
        #expect(await host.shutdownConfirmed())
        try await fixture.cleanup()
      } catch {
        await transport.disconnect()
        await host.close()
        try? await fixture.cleanup()
        throw error
      }
    }

    @Test func addressedCloseFencesLaunchBeforeAdapterRetirement() async throws {
      let fixture = try Fixture()
      defer { fixture.base.remove() }
      try await withVendor(fixture) { host, peer in
        let work = try await acquire(
          tool: "open", arguments: [:], handle: "a", fixture: fixture, host: host, peer: &peer)
        let close = try await admit("close", session: work, fixture: fixture, host: host)

        // Exercise the Host's fence before delivering the adapter's private retire request.
        #expect(try await peer.rejection("launch", work.fields(work.acquisition)) == "cancelled")
        let receipt = try await peer.call("retire", work.fields(close))
        #expect(receipt["probe_state"] == .string("retired"))
        #expect(receipt["workload_state"] == .string("never_dispatched"))
        #expect(receipt["retired"] == .bool(true))
      }
    }

    @Test(arguments: [false, true])
    func observationDeadlineSettlesItsWaiterAndKeepsTheVendorSessionLive(
      freshCatalog: Bool
    ) async throws {
      let fixture = try Fixture(adapterSource: Self.managedAdapter(stallCatalog: freshCatalog))
      defer { fixture.base.remove() }
      let ownedWork = GatewayOwnedWork()
      let client = fixture.proxy(ownedWork: ownedWork)
      var configuration = fixture.server
      configuration.requestTimeoutMs = 5_000
      let server = configuration
      do {
        let instance: JSONValue
        if freshCatalog {
          // Initialize the adapter without a tool catalog, under a different execution
          // so the caller's lease can settle while the adapter stays alive.
          let adapter = try await fixture.prepare("open")
          let listed = try client.listResources(
            server: server, cursor: nil, context: .init(executionAuthority: adapter))
          let pid = try #require(
            listed.objectValue?["resources"]?.arrayValue?.first?
              .objectValue?["name"]?.stringValue.flatMap(Int64.init))
          instance = .integer(pid)
        } else {
          let opened = try await fixture.call("open", server: server, client: client)
          instance = try #require(opened["pid"])
        }

        let observation = try await fixture.prepare("list")
        let requestID = "observation-deadline"
        do {
          _ = try await client.callToolAsync(
            server: server, name: "list", arguments: .object([:]), requestID: requestID,
            context: .init(executionAuthority: observation))
          Issue.record("The unanswered managed request should time out.")
        } catch let error as GatewayToolError {
          #expect(String(describing: error).contains("request timed out"))
        }
        try await fixture.requireSettled(observation, requestID: requestID, ownedWork: ownedWork)

        if freshCatalog {
          let opened = try await fixture.call("open", server: server, client: client)
          #expect(opened["pid"] == instance)
        }
        let output = try await fixture.call(
          "prompt", server: server, client: client,
          arguments: ["session": .string(String(repeating: "a", count: 32))])
        #expect(output["pid"] == instance)
        #expect(output["exact_cancel"] == .bool(true))
        #expect(output["observations"] == .integer(freshCatalog ? 0 : 1))
        #expect(output["native_output"] == .string("done:11\n"))
      } catch {
        await client.shutdown()
        try? await fixture.cleanup()
        throw error
      }
      await client.shutdown()
      try await fixture.cleanup()
    }

    @Test func delayedObservationAdvisoryKeepsTheSiblingWorkloadOnItsAdapter() async throws {
      let fixture = try Fixture(adapterSource: Self.managedAdapter(stallAdvisory: true))
      defer { fixture.base.remove() }
      let ownedWork = GatewayOwnedWork()
      let client = fixture.proxy(ownedWork: ownedWork)
      var configuration = fixture.server
      let requestTimeout = 5_000
      configuration.requestTimeoutMs = requestTimeout
      let server = configuration
      let home = try fixture.base.database.prepareProviderContainer(.package(fixture.pluginID))
        .sandbox.home
      let gates = URL(fileURLWithPath: home.value)
      let release = gates.appendingPathComponent("advisory-release")
      var observed: Task<JSONValue, any Error>?
      var filler: Task<JSONValue, any Error>?
      do {
        let first = try await fixture.call("open", server: server, client: client)
        let sibling = try await fixture.call("open", server: server, client: client)
        let siblingSession = String(repeating: "b", count: 32)
        #expect(first["pid"] == sibling["pid"])
        try #require(first["child"] != sibling["child"])

        let observation = try await fixture.prepare("list")
        let requestID = "cancel-managed-observation"
        let waiting = Task {
          try await client.callToolAsync(
            server: server, name: "list", arguments: .object([:]), requestID: requestID,
            context: .init(executionAuthority: observation))
        }
        observed = waiting
        try await requireAdapterMarker("advisory-ready", in: gates)
        let fillerExecution = try await fixture.prepare("list")
        filler = Task {
          try await client.callToolAsync(
            server: server, name: "list",
            arguments: .object(["filler": .string(String(repeating: "x", count: 512 * 1024))]),
            requestID: nil, context: .init(executionAuthority: fillerExecution))
        }
        try await requireAdapterMarker("advisory-backpressure", in: gates)
        let cancelledAt = ContinuousClock.now
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(ContinuousClock.now - cancelledAt >= .milliseconds(requestTimeout))
        try await fixture.requireSettled(observation, requestID: requestID, ownedWork: ownedWork)
        #expect(!FileManager.default.fileExists(atPath: release.path))
        let status = try client.connectionStatus(
          server: server, context: .init(executionAuthority: fillerExecution))
        try #require(status.objectValue?["state"] == .string("connected"))

        try Data().write(to: release)
        _ = await filler?.result
        let output = try await fixture.call(
          "prompt", server: server, client: client, arguments: ["session": .string(siblingSession)])
        #expect(output["pid"] == sibling["pid"])
        #expect(output["child"] == sibling["child"])
        #expect(output["native_output"] == .string("done:11\n"))
      } catch {
        try? Data().write(to: release)
        observed?.cancel()
        filler?.cancel()
        await client.shutdown()
        _ = await observed?.result
        _ = await filler?.result
        try? await fixture.cleanup()
        throw error
      }
      await client.shutdown()
      try await fixture.cleanup()
    }

    private func requireAdapterMarker(_ name: String, in directory: URL) async throws {
      let path = directory.appendingPathComponent(name).path
      let deadline = ContinuousClock.now + .seconds(4)
      while !FileManager.default.fileExists(atPath: path) {
        try #require(ContinuousClock.now < deadline, "Adapter did not reach \(name).")
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    private static func managedAdapter(
      stallCatalog: Bool = false, stallAdvisory: Bool = false
    ) -> String {
      "stall_catalog = \(stallCatalog ? "True" : "False")\n"
        + "stall_advisory = \(stallAdvisory ? "True" : "False")\n" + observationAdapter
    }

    private static let observationAdapter = #"""
      import base64, fcntl, json, os, pathlib, socket, struct, sys, termios, time, uuid

      capability = 'io.github.computer-mcp/vendor-execution-v1'
      uri = 'computer-mcp://runtime/work/v1'
      instance = str(uuid.uuid4())
      vendor = socket.socket(fileno=3).makefile('rwb', buffering=0)
      home = pathlib.Path(os.environ['HOME'])
      private_id = 0
      sessions = {}
      hung = catalog_hung = None
      observations = 0
      cancelled = []

      def private(op, call=None, acquisition=None, **fields):
          global private_id
          private_id += 1
          request = {'id': private_id, 'op': op, **fields}
          if call is not None:
              request.update(call=call, acquisition=acquisition)
          vendor.write((json.dumps(request) + '\n').encode())
          reply = json.loads(vendor.readline())
          assert reply['id'] == private_id, reply
          return reply['result']

      def respond(id, result):
          print(json.dumps({'jsonrpc': '2.0', 'id': id, 'result': result}), flush=True)

      def hold_input():
          (home / 'advisory-ready').touch()
          release = home / 'advisory-release'
          deadline = time.monotonic() + 20
          while not release.exists():
              assert time.monotonic() < deadline, 'Host did not release test input'
              available = fcntl.ioctl(0, termios.FIONREAD, struct.pack('i', 0))
              if struct.unpack('i', available)[0] >= 4096:
                  (home / 'advisory-backpressure').touch()
              time.sleep(0.01)

      assert private('initialize', capability=capability)['capability'] == capability
      for line in sys.stdin:
          message = json.loads(line)
          method, id = message['method'], message.get('id')
          params = message.get('params', {})
          if method == 'initialize':
              respond(id, {'protocolVersion': '2025-06-18', 'serverInfo': {'name': 'fixture', 'version': '1'},
                           'capabilities': {'tools': {}, 'resources': {}, 'experimental': {capability: True}}})
          elif method == 'resources/list':
              respond(id, {'resources': [{'uri': uri, 'name': str(os.getpid())}]})
          elif method == 'tools/list':
              if stall_catalog and catalog_hung is None:
                  if 'cursor' not in params:
                      respond(id, {'tools': [], 'nextCursor': 'next'})
                  else:
                      catalog_hung = id
                  continue
              respond(id, {'tools': [
                  {'name': name, 'inputSchema': {'type': 'object'},
                   '_meta': {'io.github.computer-mcp/work': {'format_version': 1, 'uri': uri}}}
                  for name in ('open', 'list', 'prompt')]})
          elif method == 'resources/read':
              resources = [
                  {'kind': 'fixture.session', 'id': handle, 'acquired_by': acquisition, 'state': 'active'}
                  for handle, (acquisition, child) in sessions.items()]
              report = {'format_version': 1, 'instance_id': instance,
                        'revision': len(resources), 'resources': resources}
              respond(id, {'contents': [{'uri': uri, 'mimeType': 'application/json', 'text': json.dumps(report)}]})
          elif method == 'notifications/cancelled':
              cancelled.append(params['requestId'])
              if params['requestId'] == catalog_hung:
                  respond(catalog_hung, {'tools': []})
          elif method == 'tools/call':
              name = params['name']
              arguments = params.get('arguments', {})
              if name == 'list':
                  if 'filler' in arguments:
                      respond(id, {'content': []})
                  else:
                      observations += 1
                      hung = id
                      if stall_advisory:
                          hold_input()
                  continue
              call = params['_meta']['io.github.computer-mcp/work-invocation']
              if name == 'open':
                  handle = chr(ord('a') + len(sessions)) * 32
                  acquisition = call
                  slots = private('bind', call, acquisition, session=handle)
                  private('probe', call, acquisition, child=slots['probe'])
                  child = slots['workload']
                  private('launch', call, acquisition, child=child)
                  for _ in range(3):
                      private('write', call, acquisition, child=child, kind='setup', data='setup')
                  private('ready', call, acquisition, child=child)
                  sessions[handle] = (acquisition, child)
                  result = {'pid': os.getpid(), 'child': child}
              else:
                  acquisition, child = sessions[arguments['session']]
                  private('write', call, acquisition, child=child, kind='prompt', data='finish:ping')
                  output = {}
                  while 'data' not in output:
                      output = private('read', call, acquisition, child=child, after=0)
                  private('finish', call, acquisition, child=child)
                  expected_cancel = catalog_hung if stall_catalog else hung
                  result = {'pid': os.getpid(), 'child': child, 'observations': observations,
                            'exact_cancel': expected_cancel is not None and cancelled == [expected_cancel],
                            'native_output': base64.b64decode(output['data']).decode()}
              respond(id, {'content': [], 'structuredContent': result})
      """#

    @Test func traePromptWaitsForDetachedOpenCompletion() async throws {
      let fixture = try Fixture(.trae)
      defer { fixture.base.remove() }
      try await withVendor(fixture) { host, peer in
        let work = try await acquire(
          tool: "trae.session.open", arguments: [:], handle: "a", detached: true,
          fixture: fixture, host: host, peer: &peer)
        let opener = work.acquisition
        _ = try await peer.call("launch", work.fields(opener))
        let initialize =
          #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"computer-mcp-plugin-trae","version":"1"}}}"#
        try await peer.write(initialize, kind: "setup", call: opener, on: work)
        try await peer.expectOutput(
          #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{}}}"# + "\n",
          after: 0, call: opener, on: work)
        let directory = try ProjectPathResolver.canonicalProject(fixture.base.source).path
        let new: JSONValue = .object([
          "jsonrpc": .string("2.0"), "id": .integer(2), "method": .string("session/new"),
          "params": .object(["cwd": .string(directory), "mcpServers": .array([])]),
        ])
        try await peer.write(
          String(decoding: JSONEncoder().encode(new), as: UTF8.self),
          kind: "setup", call: opener, on: work)
        try await peer.expectOutput(
          #"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"native"}}"# + "\n",
          after: 1, call: opener, on: work)
        _ = try await peer.call("ready", work.fields(opener))

        let execution = try await fixture.prepare("trae.session.prompt")
        let args: [String: JSONValue] = [
          "session_handle": .string(work.handle), "prompt": .string("hello"),
        ]
        await #expect(throws: GatewayToolError.self) {
          try await host.admit(
            id: UUID(), tool: "trae.session.prompt", arguments: args, execution: execution)
        }
        _ = try await peer.call("finish", work.fields(opener))
        let prompt = UUID()
        try await host.admit(
          id: prompt, tool: "trae.session.prompt", arguments: args, execution: execution)
        try await peer.write(
          #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"native","prompt":[{"type":"text","text":"hello"}]}}"#,
          kind: "prompt", call: prompt, on: work)
        try await peer.expectOutput(
          #"{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}"# + "\n",
          after: 2, call: prompt, on: work)
        _ = try await peer.call("finish", work.fields(prompt))
      }
    }

    @Test(arguments: ["truncated", "oversized"])
    func vendorOutputFailureAfterFinalEventRetiresTheWorkload(_ kind: String) async throws {
      let fixture = try Fixture(.print)
      defer { fixture.base.remove() }
      try await withVendor(fixture) { host, peer in
        let work = try await acquire(
          tool: "claude.run", arguments: ["prompt": .string(kind)], handle: "a",
          fixture: fixture, host: host, peer: &peer)
        let run = work.acquisition
        _ = try await peer.call("launch", work.fields(run))
        try await peer.expectOutput(
          #"{"type":"result","is_error":false}"# + "\n", after: 0, call: run, on: work)
        try Data().write(to: fixture.base.source.appendingPathComponent("release-output"))
        var fields = work.fields(run)
        fields["after"] = .integer(1)
        let expected = kind == "truncated" ? "vendor_output_truncated" : "vendor_output_failed"
        let deadline = ContinuousClock.now + .seconds(8)
        while true {
          let reply = try await peer.exchange("read", fields)
          if let failure = reply["error"]?.stringValue {
            #expect(failure == expected)
            break
          }
          try #require(reply["result"]?.objectValue?["eof"] == .bool(false))
          try #require(.now < deadline)
        }
        var receipt = try await peer.call("receipt", fields)
        while receipt["retired"] != .bool(true) {
          try #require(.now < deadline)
          try await Task.sleep(for: .milliseconds(20))
          receipt = try await peer.call("receipt", fields)
        }
        #expect(receipt["workload_state"] == .string("retired"))
        #expect(receipt["output_error"] == .string(expected))
        if kind == "truncated" { #expect(receipt["exit_code"] == .integer(0)) }
        #expect(try await peer.rejection("read", fields) == expected)
      }
    }

    private func withVendor(
      _ fixture: Fixture, _ body: (VendorExecutionSession, inout Peer) async throws -> Void
    ) async throws {
      let host = try VendorExecutionSession(
        source: fixture.vendor, launcher: fixture.base.platform.launcher)
      let transport = try MCPInheritedSocketTransport(
        takingOwnershipOf: host.providerChannel.takeEndpoint())
      try await transport.connect()
      var peer = Peer(transport: transport, replies: await transport.receive().makeAsyncIterator())
      do {
        _ = try await peer.call(
          "initialize", ["capability": .string(VendorExecutionSource.capability)])
        try await body(host, &peer)
      } catch {
        await transport.disconnect()
        await host.close()
        try? await fixture.cleanup()
        throw error
      }
      await transport.disconnect()
      await host.close()
      #expect(await host.shutdownConfirmed())
      try await fixture.cleanup()
    }

    private func acquire(
      tool: String, arguments: [String: JSONValue], handle: String, detached: Bool = false,
      fixture: Fixture, host: VendorExecutionSession, peer: inout Peer
    ) async throws -> Workload {
      let execution = try await fixture.prepare(tool)
      let id = UUID()
      try await host.admit(id: id, tool: tool, arguments: arguments, execution: execution)
      var fields: [String: JSONValue] = [
        "call": .string(id.uuidString), "acquisition": .string(id.uuidString),
      ]
      if detached {
        _ = try await peer.call("detach", fields)
        await host.returned(id, confirmed: true)
        try execution.finishAdmission()
      }
      let session = String(repeating: handle, count: 32)
      fields["session"] = .string(session)
      let receipt = try await peer.call("bind", fields)
      fields["child"] = .string(try #require(receipt["probe"]?.stringValue))
      let probe = try await peer.call("probe", fields)
      #expect(probe["probe_state"] == .string("retired"))
      let workload = try #require(receipt["workload"]?.stringValue.flatMap(UUID.init(uuidString:)))
      return Workload(acquisition: id, child: workload, handle: session)
    }

    private func open(
      _ character: String, execution: PreparedExecutionContext, host: VendorExecutionSession,
      peer: inout Peer, detached: Bool = false
    ) async throws -> Workload {
      let call = UUID()
      try await host.admit(
        id: call, tool: detached ? "open_async" : "open", arguments: [:], execution: execution)
      if detached {
        _ = try await peer.call(
          "detach",
          [
            "call": .string(call.uuidString), "acquisition": .string(call.uuidString),
          ])
        await host.returned(call, confirmed: true)
        try execution.finishAdmission()
      }
      let handle = String(repeating: character, count: 32)
      let bind = try await peer.call(
        "bind",
        [
          "call": .string(call.uuidString), "acquisition": .string(call.uuidString),
          "session": .string(handle),
        ])
      let probe = try #require(bind["probe"]?.stringValue)
      let child = try #require(bind["workload"]?.stringValue.flatMap(UUID.init(uuidString:)))
      let workload = Workload(acquisition: call, child: child, handle: handle)
      var check = workload.fields(call)
      check["child"] = .string(probe)
      let verified = try await peer.call("probe", check)
      #expect(verified["probe_state"] == .string("retired"))
      _ = try await peer.call("launch", workload.fields(call))
      #expect(try await peer.rejection("launch", workload.fields(call)) == "vendor_effect_denied")
      for _ in 0..<3 { try await peer.write("setup", kind: "setup", call: call, on: workload) }
      _ = try await peer.call("ready", workload.fields(call))
      if detached {
        _ = try await peer.call("finish", workload.fields(call))
      } else {
        await host.returned(call, confirmed: true)
        try execution.finishAdmission()
      }
      return workload
    }

    private func admit(
      _ tool: String, session: Workload, fixture: Fixture, host: VendorExecutionSession,
      extra: [String: JSONValue] = [:]
    ) async throws -> UUID {
      let execution = try await fixture.prepare(tool)
      let id = UUID()
      try await host.admit(
        id: id, tool: tool,
        arguments: extra.merging(["session": .string(session.handle)]) {
          _, new in new
        }, execution: execution)
      return id
    }

    private struct Workload {
      let acquisition: UUID
      let child: UUID
      let handle: String

      func fields(_ call: UUID) -> [String: JSONValue] {
        [
          "call": .string(call.uuidString), "acquisition": .string(acquisition.uuidString),
          "child": .string(child.uuidString),
        ]
      }
    }

    private struct Peer {
      let transport: MCPInheritedSocketTransport
      var replies: AsyncThrowingStream<Data, any Error>.Iterator
      var nextID: Int64 = 0

      mutating func exchange(_ op: String, _ fields: [String: JSONValue]) async throws
        -> [String: JSONValue]
      {
        nextID += 1
        var request = fields
        request["id"] = .integer(nextID)
        request["op"] = .string(op)
        try await transport.send(JSONEncoder().encode(JSONValue.object(request)))
        let bytes = try #require(try await replies.next())
        let response = try #require(JSONDecoder().decode(JSONValue.self, from: bytes).objectValue)
        try #require(response["id"] == .integer(nextID))
        return response
      }

      mutating func call(_ op: String, _ fields: [String: JSONValue]) async throws
        -> [String: JSONValue]
      {
        let response = try await exchange(op, fields)
        return try #require(response["result"]?.objectValue, "\(op) \(response)")
      }

      mutating func rejection(_ op: String, _ fields: [String: JSONValue]) async throws -> String {
        let response = try await exchange(op, fields)
        return try #require(response["error"]?.stringValue, "\(op) \(response)")
      }

      mutating func write(_ line: String, kind: String, call: UUID, on work: Workload) async throws
      {
        _ = try await self.call(
          "write",
          work.fields(call).merging(["kind": .string(kind), "data": .string(line)]) {
            _, new in new
          })
      }

      mutating func expectOutput(
        _ expected: String, after: Int64, call: UUID, on work: Workload
      ) async throws {
        var fields = work.fields(call)
        fields["after"] = .integer(after)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
          let result = try await self.call("read", fields)
          if let encoded = result["data"]?.stringValue {
            #expect(Data(base64Encoded: encoded) == Data(expected.utf8))
            #expect(result["cursor"] == .integer(after + 1))
            return
          }
          try #require(result["eof"] == .bool(false))
        }
        Issue.record("The deterministic peer did not return \(expected)")
      }
    }

    private final class Fixture {
      enum Vendor { case acp, print, trae }

      let base: WorktreeServiceFixture
      let adapter: URL
      let executable: URL
      let source: GatewayProviderSource
      let vendor: VendorExecutionSource
      let pluginID: String
      let server: MCPServerConfig
      private var preparations: [PreparedExecutionContext] = []

      init(_ profile: Vendor = .acp, adapterSource: String = "pass") throws {
        let base = try WorktreeServiceFixture()
        self.base = base
        let root = base.root.appendingPathComponent("package")
        let tools = base.root.appendingPathComponent("tools")
        for url in [root, tools] {
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        adapter = root.appendingPathComponent("adapter")
        executable = tools.appendingPathComponent("vendor-peer")
        try writePythonTestExecutable(adapterSource, to: adapter)
        let component: String
        let dependency: String
        switch profile {
        case .acp: (pluginID, component, dependency) = ("vendor-fixture", "acp", "peer")
        case .print: (pluginID, component, dependency) = ("claude", "stream", "claude-code")
        case .trae: (pluginID, component, dependency) = ("trae", "acp", "trae-cli")
        }
        let printPeer = #"""
          #!/bin/sh
          if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
            printf 'deterministic print peer\n'
            exit 0
          fi
          if IFS= read -r unexpected; then exit 91; fi
          [ "$#" -eq 9 ] && [ "$1" = -p ] && [ "$7" = dontAsk ] && [ "$8" = -- ] || exit 92
          case "$9" in
            --text) printf 'received prompt after EOF\n'; exit 23 ;;
            truncated|oversized)
              printf '{"type":"result","is_error":false}\n'
              while [ ! -f release-output ]; do /bin/sleep 0.02; done
              if [ "$9" = truncated ]; then printf '{"type":'; else printf '%1048576s' ''; fi
              exit 0 ;;
          esac
          exit 92
          """#
        let acpPeer = #"""
          #!/bin/sh
          if [ "$#" -eq 1 ] && [ "$1" = --version ]; then
            printf 'ordinary-peer-1\n'
            exit 0
          fi
          [ "$#" -eq 1 ] && [ "$1" = acp ] || exit 1
          active=
          while IFS= read -r line; do
            case "$line" in
              wait|ignore) active=$line; printf 'begun\n' ;;
              cancel)
                if [ "$active" = wait ]; then
                  active=
                  printf 'original:cancelled\n'
                fi ;;
              answer) printf 'answer received\n' ;;
              finish:*) printf 'done:%s\n' "${#line}" ;;
            esac
          done
          """#
        if profile == .trae {
          try writePythonTestExecutable(
            #"""
            import json, sys
            if sys.argv[1:] == ['--version']:
                print('TRAE test peer')
                sys.exit(0)
            for line in sys.stdin:
                request = json.loads(line)
                results = {'initialize': {'protocolVersion': 1, 'agentCapabilities': {}},
                           'session/new': {'sessionId': 'native'},
                           'session/prompt': {'stopReason': 'end_turn'}}
                reply = {'jsonrpc': '2.0', 'id': request['id'], 'result': results[request['method']]}
                print(json.dumps(reply, separators=(',', ':')), flush=True)
            """#, to: executable)
        } else {
          try (profile == .print ? printPeer : acpPeer).write(
            to: executable, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let signature = root.appendingPathComponent("signature.json")
        let acpSignature = #"""
          {"capability":"io.github.computer-mcp/vendor-execution-v1","dependency":"peer",
           "tools":{"open":"acquire","open_async":"detached_acquire","prompt":"prompt","stop":"stop","answer":"answer","close":"close","list":"observe"},
           "probe":["--version"],"workload":["acp"],"version_stdout":"ordinary-peer-1\n"}
          """#
        let printSignature = #"""
          {"capability":"io.github.computer-mcp/vendor-execution-v1","dependency":"claude-code",
           "tools":{"claude.run":"acquire","claude.run.start":"detached_acquire","claude.run.cancel":"close"},
           "probe":["--version"],"workload":\#(ClaudePrintRecipeTests.recipe),
           "version_stdout":"deterministic print peer\n"}
          """#
        let traeSignature = #"""
          {"capability":"io.github.computer-mcp/vendor-execution-v1","dependency":"trae-cli",
           "tools":{"trae.session.open":"detached_acquire","trae.session.prompt":"detached_prompt",
                    "trae.session.close":"close","trae.permissions.respond":"answer","trae.turn.cancel":"stop"},
           "probe":["--version"],"workload":["--sandbox","read-only","--ask-for-approval","on-request","-c",
             "analytics.enabled=false","acp","serve"],"version_stdout":"TRAE test peer\n"}
          """#
        let recipe =
          switch profile {
          case .acp: acpSignature
          case .print: printSignature
          case .trae: traeSignature
          }
        try Data(recipe.utf8).write(to: signature)
        func digest(_ file: URL) throws -> String {
          SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        try """
        id = '\(pluginID)'
        name = 'Deterministic vendor fixture'
        version = '1.0.0'
        plugin_api = 1
        [[permissions]]
        id = 'project'
        access = 'read'
        purpose = 'Read the test project.'
        [[dependencies]]
        id = '\(dependency)'
        commands = ['vendor-peer']
        instructions = 'Use the deterministic peer.'
        [[mcp]]
        id = '\(component)'
        transport = 'stdio'
        executable = { path = 'adapter' }
        requirements = { project = 'read' }
        vendor_execution = { dependency = '\(dependency)', signature = 'signature.json', files = { adapter = '\(digest(adapter))', 'signature.json' = '\(digest(signature))' } }
        """.write(
          to: root.appendingPathComponent(PluginManifest.filename), atomically: true,
          encoding: .utf8)
        let package = try PluginPackage.load(at: root)
        var state = try base.database.pluginStoreSnapshot()
        let installed = PluginInstallationRecord(
          id: UUID().uuidString, pluginID: package.manifest.id, version: package.manifest.version,
          source: .init(kind: .artifact, root: package.root, artifactSHA256: try digest(signature)),
          manifestDigest: try PluginStore.manifestDigest(package.manifest),
          declarations: PluginPermissionDeclarations(package.manifest), registeredAt: .now)
        state.installations.append(installed)
        state.selectedInstallations[installed.pluginID] = installed.id
        state.settings[installed.pluginID] = .init(
          enabled: true, mcp: [component: .init(enabled: true)])
        let revision = state.revision
        state.revision += 1
        _ = try base.database.savePluginStoreSnapshot(state, expectedRevision: revision)
        let resolved = try PluginStore.resolve(
          snapshot: state, bundled: [], hostVersion: .init("1.0.0"),
          architecture: PluginHost.architecture, searchDirectories: [tools],
          applications: TestApplicationBundleLocator())
        let composition = try GatewayPluginComposition(
          configuration: GatewayConfiguration(), plugins: resolved.plugins)
        server = try #require(composition.runtimeConfiguration.mcp.servers.first)
        let owner = try GatewayPermissionOwner(
          context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
          validate: {})
        let view = try base.runtime.service.view(owner: owner)
        let review = try GatewayProviderReview(
          package: package, configuration: base.database.configurationState())
        var providerGrants = Permissions.newPrincipal
        try providerGrants.set(.granted(.read), for: .project("source"))
        _ = try base.runtime.service.approveProvider(
          review, permissions: providerGrants, fullAccess: false, owner: owner,
          expectedProviderRevision: nil, expectedRevision: view.revision,
          expectedEpoch: #require(view.epoch))
        source = try GatewayProviderSource.resolve(
          registration: .init(kind: .mcp, id: server.id),
          configuration: composition.runtimeConfiguration,
          origins: composition.origins, database: base.database)
        vendor = try #require(source.vendorExecution)
      }

      func proxy(ownedWork: GatewayOwnedWork) -> MCPProxyClient {
        let source = vendor
        var context = MCPHostContext(
          runtimeID: UUID(), context: .init(caller: .localMCP, profileID: .localAdmin),
          projectID: "source", rootURL: base.source, readOnly: true,
          processOwnershipRoot: base.root.appendingPathComponent("ownership"))
        context.ownedWork = ownedWork
        context.providerSource = { _ in
          MCPProviderExecutionSource(digest: source.manifestDigest, vendorExecution: source) {
            _, _ in
            throw PermissionModelError.invalidAuthorization
          }
        }
        return MCPProxyClient(
          launcher: base.platform.launcher, workingDirectory: base.source, hostContext: context)
      }

      func call(
        _ tool: String, server: MCPServerConfig, client: MCPProxyClient,
        arguments: [String: JSONValue] = [:]
      ) async throws -> [String: JSONValue] {
        let execution = try await prepare(tool)
        let reply = try await client.callToolAsync(
          server: server, name: tool, arguments: .object(arguments), requestID: nil,
          context: .init(executionAuthority: execution))
        return try #require(reply.objectValue?["structuredContent"]?.objectValue)
      }

      func requireSettled(
        _ observation: PreparedExecutionContext, requestID: String, ownedWork: GatewayOwnedWork
      ) async throws {
        try observation.finishAdmission()
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
          let running = try base.runtime.store.readWithDatabase { _, ledger in
            try #require(ledger.executions[observation.executionID]).isRunning
          }
          if !running, !ownedWork.snapshot.contains(where: { $0.resourceID == requestID }) {
            return
          }
          try #require(
            ContinuousClock.now < deadline, "Observation retained its execution or request")
          try await Task.sleep(for: .milliseconds(20))
        }
      }

      func prepare(_ tool: String) async throws -> PreparedExecutionContext {
        let caller = try base.runtime.store.transactionWithDatabase { _, ledger in
          let principal = Principal.client("vendor-fixture")
          let permission = Permission.plugin(pluginID)
          if ledger.permissions(for: principal).state(for: permission) != .granted(.use) {
            var grants = Permissions.newPrincipal
            try grants.set(.granted(.use), for: permission)
            try grants.set(.granted(.read), for: .project("source"))
            try ledger.setPermissions(grants, for: principal, expectedRevision: ledger.revision)
          }
          let decision = try ledger.authorize(
            invocation: .init(
              principal: principal, tool: tool, projectID: "source",
              argumentsDigest: UUID().uuidString),
            requirements: .init(
              actions: [
                .init(requirement: .init(permission, .use)),
                .init(requirement: .init(.project("source"), .read), scope: .project("source")),
              ], sandboxProjectID: "source"),
            now: Date())
          guard case .allowed(let authorization) = decision else {
            throw PermissionModelError.invalidAuthorization
          }
          return authorization
        }
        let execution = try await base.runtime.prepareProvider(
          review: source.review, registrationID: source.registrationID, authorization: caller,
          directory: base.source, connectionID: nil, source: source)
        preparations.append(execution)
        return execution
      }

      func cleanup() async throws {
        for execution in preparations { try execution.finishAdmission() }
        try await base.runtime.coordinator.stopExecutions(Set(preparations.map(\.executionID)))
      }
    }
  }
#endif
